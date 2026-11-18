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

/// 对焦点局部语义识别。做法：以相机记录的对焦点为中心，裁一块画面（默认边长约 25%），
/// 对裁块跑 Vision 的 ImageNet 风格分类，看 top 结果里有没有人脸/鸟/其他明确物体。
///
/// 边界（务必如实）：Vision 没有专门的「鸟身体部位」检测器，这里用的是通用图像分类，
/// 对大而清楚的鸟识别率高（实测鹭 0.63），对很小/复杂背景的鸟会漏。因此：
/// - 只有「明确识别到鸟」时才据此判拍鸟；
/// - 识别不出时返回 unknown，交回原有规则，绝不硬猜；
/// - 结果仅决定题材权重，不影响合焦结论。
enum FocusSemanticsEngine {
    /// 检测对焦点处的语义。af 为相机对焦点（归一化左上原点）；image 为原图或缩略图。
    static func detect(image: CGImage, af: AFInfo?) -> FocusSemantics {
        guard let af = af, let p = af.points.first else {
            return FocusSemantics(kind: .unknown, reason: "无相机对焦点数据", labels: [])
        }
        // 人脸对焦模式：相机的对焦系统已判定是人脸，优先级最高、最可靠。
        if af.modeName.contains("人脸") {
            return FocusSemantics(kind: .face, reason: "相机使用「\(af.modeName)」对焦模式",
                                  labels: [])
        }

        guard let crop = cropAround(image: image, cx: p.cx, cy: p.cy) else {
            return FocusSemantics(kind: .unknown, reason: "对焦点区域无法裁剪", labels: [])
        }
        let req = VNClassifyImageRequest()
        let handler = VNImageRequestHandler(cgImage: crop, options: [:])
        try? handler.perform([req])
        let obs = (req.results ?? []).filter { $0.confidence >= 0.05 }.prefix(12)
        let tops = Array(obs)
        guard !tops.isEmpty else {
            return FocusSemantics(kind: .unknown, reason: "对焦点区域识别不出明确内容", labels: [])
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
    static func detect(url: URL) -> FocusSemantics? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1024
        ]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let af = AFReader.read(url)
        return detect(image: img, af: af)
    }
}
