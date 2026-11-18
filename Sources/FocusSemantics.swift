import Foundation
import Vision
import CoreGraphics
import ImageIO

/// 对焦点处的语义判断结果。只用于「题材自动识别」，不改变原有的合焦判定与评分。
/// 所有结论都带一句可供人核对的依据（识别到什么 + 置信度），识别不出来就明确说没认出来。
struct FocusSemantics {
    enum Kind: String {
        case face       // 对焦点处识别到人脸
        case bird       // 对焦点处识别到鸟 / 鸟的身体部位
        case nonBird    // 对焦点处识别到明确的其他东西（水面、山、建筑等）
        case unknown    // 没有对焦点数据，或识别不出来
    }
    let kind: Kind
    let reason: String      // 「对焦点处识别到：鹭 (63%)」这类可核对文字
    let labels: [String]    // top 标签，供界面悬停查看
}

/// 对焦点局部语义识别。做法：以相机记录的对焦点为中心裁一块画面（边长约 30%），
/// 跑 Vision 分类，看 top 结果里有没有人脸/鸟/其他明确物体；认不出鸟时再用
/// 专门的动物检测（VNRecognizeAnimalsRequest）和主体框交叉复核兜底。
///
/// 边界（务必如实）：
/// - 通用分类对大而清楚的鸟识别率高（实测鹭 0.63），对很小/纯蓝天的飞鸟会漏
///   （实测飞鸭裁块只有蓝天 96%）；
/// - 动物检测能认出分类漏掉的小飞鸟（实测 66%），但它分不清猫狗鸟，
///   所以只在长焦镜头（焦距≥200mm 或镜头长焦端≥300mm）时启用兜底——
///   长焦对着的动物绝大多数是鸟，也避免公园里拍到狗被误判成拍鸟；
/// - 只有「明确识别到」才推翻，识别不出一律交回原有规则，绝不硬猜；
/// - 结果仅决定题材权重，不影响合焦结论。
enum FocusSemanticsEngine {
    /// 动物检测置信度门槛：实测小飞鸟 66%，纯风景裁块无结果，0.40 稳妥。
    private static let animalThreshold: Double = 0.40

    /// 检测对焦点处的语义。af 为相机对焦点（归一化左上原点）；image 为缩略图。
    /// subjectBoxes 为主体检测框（归一化、左下原点，同 PhotoMetrics.bboxes）；
    /// telephoto 表示当前是长焦镜头（允许动物检测兜底）。
    static func detect(image: CGImage, af: AFInfo?,
                       subjectBoxes: [CGRect] = [],
                       telephoto: Bool = false) -> FocusSemantics {
        guard let af = af, let p = af.points.first else {
            return FocusSemantics(kind: .unknown, reason: "无相机对焦点数据", labels: [])
        }
        // 人脸对焦模式：相机的对焦系统已判定是人脸，优先级最高、最可靠。
        if af.modeName.contains("人脸") {
            return FocusSemantics(kind: .face, reason: "相机使用「\(af.modeName)」对焦模式",
                                  labels: [])
        }

        let focusCrop = cropAround(image: image, cx: p.cx, cy: p.cy)
        var result: FocusSemantics
        if let crop = focusCrop {
            result = classify(crop: crop, fallbackReason: "对焦点区域识别不出明确内容")
        } else {
            result = FocusSemantics(kind: .unknown, reason: "对焦点区域无法裁剪", labels: [])
        }

        // 对焦点处已明确认出鸟或人脸 → 直接采用。
        if result.kind == .bird || result.kind == .face { return result }

        if telephoto {
            // 兜底一：对焦点裁块跑动物检测。小飞鸟被蓝天淹没、分类认不出时，
            // 动物检测器常常仍能检出（实测飞鸭 66%）。
            if let crop = focusCrop, let conf = animalConfidence(in: crop), conf >= animalThreshold {
                return FocusSemantics(
                    kind: .bird,
                    reason: "对焦点处识别到：\(Self.cnName("bird")) (\(Int((conf * 100).rounded()))%)",
                    labels: result.labels)
            }
            // 兜底二：对焦点没认出鸟（判成风景/认不出），拿主体检测框再复核。
            // 主体分割框往往正框在鸟身上，逐框跑动物检测和分类。
            if let hit = birdInSubjectBoxes(image: image, boxes: subjectBoxes) {
                let pct = Int((hit.confidence * 100).rounded())
                let why = hit.byAnimal
                      ? "对焦点处没认出鸟，但画面主体处检测到动物 (\(pct)%)，长焦镜头下多为鸟"
                      : "对焦点处没认出鸟，但画面主体处识别到：\(Self.cnName(hit.identifier)) (\(pct)%)"
                return FocusSemantics(kind: .bird, reason: why, labels: hit.labels)
            }
        }
        return result
    }

    /// 对一块裁剪图跑分类，返回按置信度过滤后的 top 标签。
    private static func classify(crop: CGImage,
                                 fallbackReason: String) -> FocusSemantics {
        let req = VNClassifyImageRequest()
        let handler = VNImageRequestHandler(cgImage: crop, options: [:])
        try? handler.perform([req])
        let obs = (req.results ?? []).filter { $0.confidence >= 0.05 }.prefix(12)
        let tops = Array(obs)
        guard !tops.isEmpty else {
            return FocusSemantics(kind: .unknown, reason: fallbackReason, labels: [])
        }
        let labels = tops.map { "\($0.identifier) \(Int(($0.confidence * 100).rounded()))%" }

        // 鸟：先找明确的鸟种标签，再看通用 bird 标签。置信度门槛 0.20 以压低误报。
        if let hit = tops.first(where: { Self.isBirdLabel($0.identifier) && $0.confidence >= 0.20 }) {
            return FocusSemantics(kind: .bird,
                                  reason: "对焦点处识别到：\(Self.cnName(hit.identifier)) (\(Int((hit.confidence * 100).rounded()))%)",
                                  labels: labels)
        }
        // 人脸：分类里的 face / person 也算人脸优先。
        if let hit = tops.first(where: { Self.isFaceLabel($0.identifier) && $0.confidence >= 0.20 }) {
            return FocusSemantics(kind: .face,
                                  reason: "对焦点处识别到人脸 (\(Int((hit.confidence * 100).rounded()))%)",
                                  labels: labels)
        }
        // 大场景风景：焦点落在天空/水面/山/田野等，典型是「长焦拍风光」。
        // 只收自然环境大场景，不收 structure/wood/branch/fence —— 鸟常站在这些上面，
        // 若把它们算风景会把「落在树枝/雕塑上的鸟」误判成风光。
        if let scene = tops.first(where: { Self.isLandscapeLabel($0.identifier) && $0.confidence >= 0.25 }) {
            return FocusSemantics(kind: .nonBird,
                                  reason: "对焦点处是\(Self.cnName(scene.identifier))，没识别到鸟",
                                  labels: labels)
        }
        return FocusSemantics(kind: .unknown, reason: "对焦点处识别不明确", labels: labels)
    }

    /// 裁块动物检测：检出即返回最高置信度（Vision 动物检测支持猫/狗/鸟等）。
    private static func animalConfidence(in crop: CGImage) -> Double? {
        let req = VNRecognizeAnimalsRequest()
        let handler = VNImageRequestHandler(cgImage: crop, options: [:])
        try? handler.perform([req])
        guard let results = req.results, !results.isEmpty else { return nil }
        return Double(results.map { $0.confidence }.max() ?? 0)
    }

    /// 在主体检测框里找鸟：逐个（最多前 3 大的框）裁块，先跑动物检测、
    /// 再跑分类找鸟种标签。识别到即返回；找不到返回 nil，不硬猜。
    private static func birdInSubjectBoxes(image: CGImage,
                                           boxes: [CGRect]) -> (confidence: Double,
                                                                identifier: String,
                                                                labels: [String],
                                                                byAnimal: Bool)? {
        guard !boxes.isEmpty else { return nil }
        let sorted = boxes.sorted { $0.width * $0.height > $1.width * $1.height }.prefix(3)
        for box in sorted {
            guard let crop = cropAroundBox(image: image, box: box) else { continue }
            // 动物检测：对分类认不出的小飞鸟更稳。
            if let conf = animalConfidence(in: crop), conf >= animalThreshold {
                return (conf, "bird", [], true)
            }
            // 分类兜底：能认出鸟种就认鸟种。
            let req = VNClassifyImageRequest()
            let handler = VNImageRequestHandler(cgImage: crop, options: [:])
            try? handler.perform([req])
            let tops = (req.results ?? []).filter { $0.confidence >= 0.05 }.prefix(12)
            if let hit = tops.first(where: { Self.isBirdLabel($0.identifier) && $0.confidence >= 0.20 }) {
                let labels = tops.map { "\($0.identifier) \(Int(($0.confidence * 100).rounded()))%" }
                return (Double(hit.confidence), hit.identifier, labels, false)
            }
        }
        return nil
    }

    /// 以对焦点为中心裁一块正方形，边长取画面短边的 focusSpan 比例，并保证最小像素数。
    private static let focusSpan = 0.30
    private static func cropAround(image: CGImage, cx: Double, cy: Double) -> CGImage? {
        let w = image.width, h = image.height
        let side = max(160, Int(Double(min(w, h)) * focusSpan))
        let halfW = side / 2, halfH = side / 2
        var x = Int(cx * Double(w)) - halfW
        var y = Int(cy * Double(h)) - halfH
        x = max(0, min(x, w - side))
        y = max(0, min(y, h - side))
        guard side > 0, w >= side, h >= side else { return image }
        return image.cropping(to: CGRect(x: x, y: y, width: side, height: side))
    }

    /// 以主体框为中心裁一块正方形：边长框最长边的 2.4 倍（留足鸟的翅膀/周围上下文），
    /// 最短不低于 160 像素，保证小到只有几十像素的飞鸟也能凑出可检测的裁块。
    private static func cropAroundBox(image: CGImage, box: CGRect) -> CGImage? {
        let w = image.width, h = image.height
        let bwPx = box.width * CGFloat(w), bhPx = box.height * CGFloat(h)
        let side = max(160, Int(max(bwPx, bhPx) * 2.4))
        let cx = (box.minX + box.width / 2) * CGFloat(w)          // Vision 坐标 x 与像素一致
        let cyTop = (1 - box.minY - box.height / 2) * CGFloat(h)  // y 翻转成左上原点
        var x = Int(cx) - side / 2
        var y = Int(cyTop) - side / 2
        x = max(0, min(x, w - side))
        y = max(0, min(y, h - side))
        guard side > 0, side <= w, side <= h else { return image }
        return image.cropping(to: CGRect(x: x, y: y, width: side, height: side))
    }

    // MARK: 标签判定

    /// ImageNet 里的鸟类标签：通用词 + 常见鸟种/部位。
    private static let birdWords = ["bird", "robin", "hummingbird", "eagle", "vulture",
        "heron", "egret", "crane", "penguin", "pelican", "flamingo", "ostrich", "owl",
        "parrot", "macaw", "cockatoo", "lorikeet", "hornbill", "toucan", "duck", "goose",
        "swan", "gull", "tern", "puffin", "albatross", "quail", "partridge", "grouse",
        "turkey", "peacock", "jay", "magpie", "finch", "sparrow", "warbler", "wren",
        "dove", "pigeon", "cuckoo", "kingfisher", "woodpecker", "flicker", "plover",
        "sandpiper", "oystercatcher", "bittern", "limpkin", "spoonbill", "frigatebird"]
    private static func isBirdLabel(_ id: String) -> Bool {
        let s = id.lowercased()
        return birdWords.contains { s == $0 || s.hasSuffix("_\($0)") || s.contains($0) }
    }

    private static func isFaceLabel(_ id: String) -> Bool {
        let s = id.lowercased()
        return s.contains("face") || s.contains("human") || s == "person"
    }

    /// 大场景自然风景标签（用于判定「长焦拍风光」）。刻意不含结构/树木/栅栏。
    private static let landscapeWords = ["sky", "blue_sky", "water", "lake", "river",
        "sea", "ocean", "land", "hill", "mountain", "field", "plateau", "desert",
        "beach", "coast", "valley", "wetland", "marsh", "pond", "reservoir", "snow",
        "cloud", "horizon", "lakeside", "seashore", "promontory", "cliff"]
    private static func isLandscapeLabel(_ id: String) -> Bool {
        let s = id.lowercased()
        return landscapeWords.contains { s == $0 || s.hasSuffix("_\($0)") }
    }

    /// 常见分类标签的中文名，没收录就保留英文（保持可核对，不臆造）。
    private static func cnName(_ id: String) -> String {
        let map: [String: String] = [
            "bird": "鸟", "heron": "鹭", "egret": "白鹭", "eagle": "鹰", "duck": "鸭",
            "goose": "鹅", "swan": "天鹅", "gull": "鸥", "owl": "猫头鹰", "penguin": "企鹅",
            "lake": "湖", "water": "水面", "river": "河流", "sea": "海", "land": "陆地",
            "blue_sky": "蓝天", "cloud": "云", "snow": "雪", "wetland": "湿地", "marsh": "沼泽",
            "hill": "山丘", "mountain": "山", "sky": "天空", "grass": "草地", "field": "田野",
            "forest": "树林", "tree": "树", "building": "建筑", "house": "房屋",
            "boat": "船", "bridge": "桥", "person": "人", "human": "人", "face": "人脸",
            "structure": "建筑结构", "wood_natural": "树木", "fence": "栅栏", "shrub": "灌木",
            "plant": "植物", "branch": "树枝", "outdoor": "户外", "park": "公园"
        ]
        let s = id.lowercased()
        if let v = map[s] { return v }
        for (k, v) in map where s.hasSuffix("_\(k)") { return v }
        return id
    }

    /// 从 RAW/JPG 载入缩略图后检测。供 Store 异步调用。
    /// subjectBoxes 为主体检测框（归一化、左下原点），用于对焦点没认出鸟时的交叉复核。
    static func detect(url: URL, subjectBoxes: [CGRect] = []) -> FocusSemantics? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2048
        ]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let af = AFReader.read(url)
        let exif = ExifInfo.read(url)
        return detect(image: img, af: af, subjectBoxes: subjectBoxes,
                      telephoto: isTelephoto(exif))
    }

    /// 是否长焦：实际焦距≥200mm，或镜头型号里的长焦端≥300mm。
    /// 长焦时才允许动物检测兜底（避免普通焦段拍到猫狗被误判拍鸟）。
    private static func isTelephoto(_ exif: ExifInfo?) -> Bool {
        guard let exif = exif else { return false }
        let focal = exif.focalLength.flatMap { maxNumber(in: $0) } ?? 0
        let lensMax = exif.lens.flatMap { maxNumber(in: $0) } ?? 0
        return focal >= 200 || lensMax >= 300
    }

    /// 从「800mm」「RF100-400mm F5.6-8」这类串里取最大的数字。
    private static func maxNumber(in s: String) -> Double? {
        var best = 0.0
        var cur = ""
        func flush() {
            if let v = Double(cur), v >= 10 { best = max(best, v) }
            cur = ""
        }
        for ch in s {
            if ch.isNumber || ch == "." { cur.append(ch) } else { flush() }
        }
        flush()
        return best > 0 ? best : nil
    }
}
