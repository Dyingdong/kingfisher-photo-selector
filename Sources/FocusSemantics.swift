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

    /// 裁块标签复核 (a)：具体非鸟动物标签置信度 ≥ 最高鸟标签 × 此比例时，
    /// 判为「动物局部被误认成鸟」，改交 AI 主体复核。
    /// 取 0.6 的理由：实测野兔片 JD5A9143 的 rabbit 16% / 鸟 22% ≈ 0.73，
    /// 需覆盖它；而真鸟片 9163/9174 裁块无具体动物标签，不受影响。
    private static let animalVsBirdRatio: Double = 0.60

    /// 裁块标签复核 (b)：长焦下多个鸟种标签互证时采纳为鸟的最低置信度。
    /// 取 0.15 的理由：实测漏判片 JD5A9173 的最高鸟标签 18%（低于原 0.20
    /// 门槛），且有 sparrow/raptor/owl 共 4 个鸟种标签互证；0.15 能救回它，
    /// 仍显著低于单标签噪声，配合「≥2 鸟标签 + 无具体动物」三重条件压低误报。
    private static let multiBirdMinConfidence: Double = 0.15

    /// 把 classify 产生的 "identifier NN%" 标签串解析成 (标识, 置信度 0~1)。
    /// 只用于 detect 里的裁块标签复核，避免重复跑 Vision 分类。
    private static func parsedLabels(_ labels: [String]) -> [(id: String, conf: Double)] {
        var out: [(id: String, conf: Double)] = []
        for label in labels {
            let parts = label.split(separator: " ")
            guard parts.count >= 2,
                  let pct = Double(parts[1].replacingOccurrences(of: "%", with: "")) else { continue }
            out.append((id: String(parts[0]), conf: pct / 100.0))
        }
        return out
    }

    /// 是否具体非鸟动物标签（rabbit/hare/horse…，复用 specificAnimalWords，
    /// 不含笼统的 animal/mammal/rodent，避免把兔片里的 animal 笼统标签当作物证据）。
    private static func isSpecificAnimalLabel(_ id: String) -> Bool {
        let s = id.lowercased()
        return specificAnimalWords.contains { s == $0 || s.hasSuffix("_\($0)") }
    }

    /// 长焦裁块标签复核（30% 与 15% 两级裁块共用同一套规则，保证门槛一致）：
    /// (a) 具体动物标签置信度 ≥ 最高鸟标签 × animalVsBirdRatio 时，判「动物局部
    ///     被误认成鸟」，返回 nonBird 交回 AI 主体复核（实测 JD5A9143：兔 16% vs 鸟 22%）；
    /// (b) ≥2 个鸟种标签、最高 ≥ multiBirdMinConfidence、无具体动物标签时，
    ///     采纳为鸟（实测 JD5A9173：鸟 18% + sparrow/raptor/owl）。
    /// 返回 nil 表示两条规则都不适用，调用方维持原判。
    private static func telephotoLabelReview(_ result: FocusSemantics) -> FocusSemantics? {
        let parsed = Self.parsedLabels(result.labels)
        let birdHits = parsed.filter { Self.isBirdLabel($0.id) }
        let topBird = birdHits.max { $0.conf < $1.conf }
        let animalHits = parsed.filter { Self.isSpecificAnimalLabel($0.id) }
        let topAnimal = animalHits.max { $0.conf < $1.conf }

        // (a) 兔子等具体动物局部被误判为鸟
        if result.kind == .bird, let bird = topBird, let animal = topAnimal,
           animal.conf >= bird.conf * Self.animalVsBirdRatio {
            return FocusSemantics(
                kind: .nonBird,
                reason: "焦点裁块把动物局部认成鸟，交回 AI 主体复核（\(Self.cnName(animal.id)) \(Int((animal.conf * 100).rounded()))% vs 鸟 \(Int((bird.conf * 100).rounded()))%）",
                labels: result.labels)
        }
        // (b) 多个鸟种标签互证但被大场景标签压过
        if result.kind == .nonBird, topAnimal == nil,
           birdHits.count >= 2, let bird = topBird,
           bird.conf >= Self.multiBirdMinConfidence {
            return FocusSemantics(
                kind: .bird,
                reason: "长焦下焦点裁块多个鸟种标签互证，采纳为鸟（\(Self.cnName(bird.id)) \(Int((bird.conf * 100).rounded()))%）",
                labels: result.labels)
        }
        return nil
    }

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

        // 长焦镜头下的裁块标签复核（30% 与 15% 两级裁块共用同一套规则）：
        // classify 只看「top 鸟标签≥0.20」与「风景标签≥0.25」两个孤立信号，
        // 实测在两种情况下会错判，这里用完整标签分布修正：
        // (a) 动物局部（如兔耳）被认成鸟：具体动物标签置信度接近最高鸟标签时，
        //     改判 nonBird 交回 AI 主体复核（AI 认出兔 → 风光）；
        // (b) 多个弱鸟标签被大场景标签压过：≥2 个鸟种标签、最高≥0.15、且无具体
        //     动物标签时，采纳为鸟。
        // 两处都直接 return，避免后续动物检测兜底把 (a) 又判回鸟。
        if telephoto, let reviewed = telephotoLabelReview(result) {
            return reviewed
        }

        // 对焦点处已明确认出鸟或人脸 → 直接采用。
        if result.kind == .bird || result.kind == .face { return result }

        // 兜底零：长焦镜头下对焦点落在天空/云上，不足以断定是风光——
        // 飞鸟大多以天空为背景，焦点落空非常常见（实测：鸟群、悬停飞鹰片
        // 大量因「对焦点处是蓝天」被误判成风光）。降级为 unknown，交回
        // 动物检测兜底与焦距规则。水面/陆地/山等仍维持风光结论。
        if result.kind == .nonBird && telephoto {
            let sceneIDs = result.labels.map { ident(of: $0) }
            if sceneIDs.contains(where: { Self.isSkyLabel($0) }) {
                result = FocusSemantics(kind: .unknown,
                                        reason: "对焦点处是天空/云，长焦镜头下不排除拍鸟",
                                        labels: result.labels)
            }
        }

        // 兜底〇·五：长焦小裁块二次复核。
        // 30% 裁块被天空/枝叶淹没认不出鸟（unknown）时，以对焦点为中心收紧到 15% span
        // 再 classify 一次，鸟在裁块里的相对占比变大，标签置信度随之上升
        // （实测 test2 极小飞鸟片：3875 从 8% 升到 29%，3891/3950 也在此被正式识别）。
        // 门槛与 30% 裁块完全一致（单鸟标签 ≥0.20，或多鸟互证 ≥0.15 且 ≥2 标签，
        // 且无具体动物标签），识别不出就继续走原流程，绝不硬猜。
        // 边界（回归实测踩过的坑）：
        // - 只在 30% 裁块 unknown 时复核：30% 已认出水面/陆地等明确风景（nonBird）
        //   就不再复核——那些是比小裁块更强的风光证据（8330/8331 水面由此保持风光）；
        // - 30% 裁块已认出具体动物（兔/马等 ≥0.20）时禁止复核：实测兔片 9141/9142
        //   的 15% 小裁块会把兔子头部认成 bird/owl 55~66%，且动物检测在小裁块上
        //   不报（拦不住），只能靠 30% 裁块的具体动物标签挡在门外；
        // - 刻意不做 10% 档：实验显示 10% 裁块上动物检测会出 Cat/Dog 0.6+ 假检出。
        if telephoto, result.kind == .unknown,
           !Self.parsedLabels(result.labels).contains(where: {
               Self.isSpecificAnimalLabel($0.id) && $0.conf >= 0.20 }),
           let smallCrop = cropAround(image: image, cx: p.cx, cy: p.cy, span: 0.15) {
            let small = classify(crop: smallCrop, fallbackReason: "对焦点区域识别不出明确内容")
            let parsed = Self.parsedLabels(small.labels)
            let birdHits = parsed.filter { Self.isBirdLabel($0.id) }
            let topBird = birdHits.max { $0.conf < $1.conf }
            let animalHits = parsed.filter { Self.isSpecificAnimalLabel($0.id) }
            let topAnimal = animalHits.max { $0.conf < $1.conf }
            // (a) 动物局部被误认成鸟：不采信小裁块，继续原流程（兜底一/二）。
            if let bird = topBird, let animal = topAnimal,
               animal.conf >= bird.conf * Self.animalVsBirdRatio {
                // fall through
            } else if small.kind == .bird, topAnimal == nil, let bird = topBird {
                return FocusSemantics(
                    kind: .bird,
                    reason: "小裁块复核识别到：\(Self.cnName(bird.id)) (\(Int((bird.conf * 100).rounded()))%)",
                    labels: small.labels)
            } else if small.kind == .nonBird, topAnimal == nil,
                      birdHits.count >= 2, let bird = topBird,
                      bird.conf >= Self.multiBirdMinConfidence {
                return FocusSemantics(
                    kind: .bird,
                    reason: "长焦下小裁块多个鸟种标签互证，采纳为鸟（\(Self.cnName(bird.id)) \(Int((bird.conf * 100).rounded()))%）",
                    labels: small.labels)
            }
        }

        if telephoto {
            // 兜底一：对焦点裁块跑动物检测。小飞鸟被蓝天淹没、分类认不出时，
            // 动物检测器常常仍能检出（实测飞鸭 66%）。
            // 但 Vision 会把兔子竖耳剪影认成 Cat（实测兔片 58~73%）：若检出的是
            // 明确的非鸟动物，不据此判鸟，交回后续 AI 主体 / Score 兜底。
            if let crop = focusCrop, let hit = topAnimal(in: crop),
               hit.confidence >= animalThreshold,
               !Self.isDefiniteNonBirdAnimal(hit.identifier) {
                return FocusSemantics(
                    kind: .bird,
                    reason: "对焦点处识别到：\(Self.cnName("bird")) (\(Int((hit.confidence * 100).rounded()))%)",
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

    /// 裁块动物检测：取置信度最高的检出，连同 Vision 给出的具体类别一起返回。
    /// 类别来自 observation.labels.first?.identifier（实测首字母大写，如 "Cat"，判定时 lowercased）。
    /// 历史 bug：旧实现只返回 confidence、丢弃类别，导致兔子竖耳剪影被 Vision 认成 Cat 后
    /// 仍按「检到动物 = 鸟」判成拍鸟。类别必须随置信度一起传出去。
    /// internal：供 AISubject 的动物检测兜底复用，避免两处各跑一遍还丢弃类别。
    static func topAnimal(in crop: CGImage) -> (identifier: String, confidence: Double)? {
        let req = VNRecognizeAnimalsRequest()
        let handler = VNImageRequestHandler(cgImage: crop, options: [:])
        try? handler.perform([req])
        guard let results = req.results, !results.isEmpty else { return nil }
        guard let best = results.max(by: { $0.confidence < $1.confidence }) else { return nil }
        return (best.labels.first?.identifier ?? "", Double(best.confidence))
    }

    /// 动物检测是否检出了「明确的非鸟动物」——这类检出不能作为判鸟依据。
    /// 复用已有 specificAnimalWords（cat/dog/rabbit/hare/horse/…），并排除鸟类名；
    /// 类别为空或笼统（animal/mammal）时返回 false，维持原有兜底行为（判鸟）。
    /// internal：供 AISubject 复用同一判定口径，避免两处各写一套词表判断。
    static func isDefiniteNonBirdAnimal(_ identifier: String) -> Bool {
        let s = identifier.lowercased()
        guard !s.isEmpty, !isBirdLabel(s) else { return false }
        return isSpecificAnimalLabel(s)
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
            // 明确的非鸟动物（如 Vision 把兔子认成 Cat）不能据此判鸟，跳过该框。
            if let hit = topAnimal(in: crop), hit.confidence >= animalThreshold,
               !Self.isDefiniteNonBirdAnimal(hit.identifier) {
                return (hit.confidence, "bird", [], true)
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

    /// 以对焦点为中心裁一块正方形，边长取画面短边的 span 比例，并保证最小像素数。
    /// span 默认 0.30（主裁块）；15% 小裁块二次复核传 0.15。
    private static let focusSpan = 0.30
    private static func cropAround(image: CGImage, cx: Double, cy: Double,
                                   span: Double = focusSpan) -> CGImage? {
        let w = image.width, h = image.height
        let side = max(160, Int(Double(min(w, h)) * span))
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

    // MARK: 标签判定（AI 主体识别引擎共用，故开放为 internal）

    /// ImageNet 里的鸟类标签：通用词 + 常见鸟种/部位。
    private static let birdWords = ["bird", "robin", "hummingbird", "eagle", "vulture",
        "heron", "egret", "crane", "penguin", "pelican", "flamingo", "ostrich", "owl",
        "parrot", "macaw", "cockatoo", "lorikeet", "hornbill", "toucan", "duck", "goose",
        "swan", "gull", "tern", "puffin", "albatross", "quail", "partridge", "grouse",
        "turkey", "peacock", "jay", "magpie", "finch", "sparrow", "warbler", "wren",
        "dove", "pigeon", "cuckoo", "kingfisher", "woodpecker", "flicker", "plover",
        "sandpiper", "oystercatcher", "bittern", "limpkin", "spoonbill", "frigatebird",
        // 鸦科/鸣禽：深色鸟（乌鸦、喜鹊）整图分类常给出 raven/crow 而不是 bird，
        // 补上这些词，避免「同一只黑鸟有时认出、有时认不出」。
        "raven", "crow", "blackbird", "jackdaw", "rook", "cormorant", "swallow",
        "swift", "starling", "thrush", "shrike", "bulbul", "oriole", "bunting",
        "wagtail", "titmouse", "chickadee", "nuthatch", "redstart", "wheatear",
        "stonechat", "nightingale", "pipit"]
    static func isBirdLabel(_ id: String) -> Bool {
        let s = id.lowercased()
        return birdWords.contains { s == $0 || s.hasSuffix("_\($0)") || s.contains($0) }
    }

    /// 花的标签（ImageNet 常见词）。用于 AI 主体识别说明「识别到：花」，
    /// 不改变题材枚举，花照仍归风光。
    private static let flowerWords = ["flower", "flowers", "blossom", "bloom", "blooming",
        "floral", "petal", "pollen", "daffodil", "orchid", "daisy", "sunflower",
        "rose", "tulip", "iris", "poppy", "lily", "clover", "hibiscus", "jasmine",
        "lilac", "peony", "azalea", "camellia"]
    private static func isFlowerLabel(_ id: String) -> Bool {
        let s = id.lowercased()
        return flowerWords.contains { s == $0 || s.hasSuffix("_\($0)") || s.contains($0) }
    }

    /// 花证据：抠图后的小主体置信度天然偏低（实测草地小花只有 6%~9%），
    /// 单独一个低分标签不足以采信；要求「≥10% 单一花标签」或
    /// 「≥6% 且至少两个花相关标签互相印证」。人/鸟/动物判定都在它之前，不会抢优先级。
    static func flowerEvidence(in tops: [VNClassificationObservation]) -> VNClassificationObservation? {
        let hits = tops.filter { isFlowerLabel($0.identifier) }
        guard let best = hits.max(by: { $0.confidence < $1.confidence }) else { return nil }
        if best.confidence >= 0.10 { return best }
        if best.confidence >= 0.06 && hits.count >= 2 { return best }
        return nil
    }

    /// 明确的具体动物标签（不含笼统的 animal/mammal）。用于把马/兔/狗等
    /// 从「有明确主体但认不出」里摘出来，避免背景里的小人把马照判成人像。
    private static let specificAnimalWords = ["horse", "pony", "donkey", "cow", "bull",
        "calf", "sheep", "goat", "pig", "hog", "dog", "cat", "kitten", "puppy",
        "rabbit", "hare", "deer", "bear", "fox", "wolf", "tiger", "lion", "zebra",
        "giraffe", "elephant", "kangaroo", "monkey", "squirrel", "mouse", "camel",
        "llama", "yak", "buffalo", "rhino", "hippo"]
    static func specificAnimalConfidence(in tops: [VNClassificationObservation]) -> VNClassificationObservation? {
        tops.first {
            let s = $0.identifier.lowercased()
            return $0.confidence >= 0.20 && specificAnimalWords.contains { s == $0 || s.hasSuffix("_\($0)") }
        }
    }

    private static func isFaceLabel(_ id: String) -> Bool {
        let s = id.lowercased()
        return s.contains("face") || s.contains("human") || s == "person"
    }
    /// 供 AI 主体识别引擎使用
    static func faceLabelConfidence(in tops: [VNClassificationObservation]) -> VNClassificationObservation? {
        tops.first { Self.isFaceLabel($0.identifier) && $0.confidence >= 0.20 }
    }
    static func birdLabelConfidence(in tops: [VNClassificationObservation]) -> VNClassificationObservation? {
        tops.first { Self.isBirdLabel($0.identifier) && $0.confidence >= 0.20 }
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

    /// 天空类标签：长焦+对焦点落天空时不作为「风光」的强证据。
    private static func isSkyLabel(_ id: String) -> Bool {
        let s = id.lowercased()
        return s == "sky" || s == "blue_sky" || s == "cloud" || s == "cloudy" || s == "horizon"
    }

    /// 从 "blue_sky 96%" 这类标签串里取标签名。
    private static func ident(of label: String) -> String {
        let parts = label.split(separator: " ")
        return parts.isEmpty ? label : String(parts[0])
    }

    /// 常见分类标签的中文名，没收录就保留英文（保持可核对，不臆造）。
    private static func cnName(_ id: String) -> String {
        let map: [String: String] = [
            "bird": "鸟", "heron": "鹭", "egret": "白鹭", "eagle": "鹰", "duck": "鸭",
            "goose": "雁", "swan": "天鹅", "gull": "鸥", "owl": "猫头鹰", "penguin": "企鹅",
            "crane": "鹤", "pelican": "鹈鹕", "flamingo": "火烈鸟", "kingfisher": "翠鸟",
            "woodpecker": "啄木鸟", "pigeon": "鸽子", "dove": "鸽子", "magpie": "喜鹊",
            "sparrow": "麻雀", "finch": "雀", "parrot": "鹦鹉", "macaw": "金刚鹦鹉",
            "peacock": "孔雀", "tern": "燕鸥", "vulture": "秃鹫", "quail": "鹌鹑",
            "turkey": "火鸡", "ostrich": "鸵鸟", "albatross": "信天翁", "puffin": "海鹦",
            "lake": "湖", "water": "水面", "river": "河流", "sea": "海", "land": "陆地",
            "blue_sky": "蓝天", "cloud": "云", "snow": "雪", "wetland": "湿地", "marsh": "沼泽",
            "hill": "山丘", "mountain": "山", "sky": "天空", "grass": "草地", "field": "田野",
            "forest": "树林", "tree": "树", "building": "建筑", "house": "房屋",
            "boat": "船", "bridge": "桥", "person": "人", "human": "人", "face": "人脸",
            "structure": "建筑结构", "wood_natural": "树木", "fence": "栅栏", "shrub": "灌木",
            "plant": "植物", "branch": "树枝", "outdoor": "户外", "park": "公园",
            "raven": "渡鸦", "crow": "乌鸦", "blackbird": "乌鸫", "jackdaw": "寒鸦",
            "rook": "秃鼻乌鸦", "cormorant": "鸬鹚", "swallow": "燕子", "swift": "雨燕",
            "starling": "椋鸟", "thrush": "鸫", "shrike": "伯劳", "bulbul": "鹎",
            "oriole": "黄鹂", "bunting": "鹀", "wagtail": "鹡鸰", "titmouse": "山雀",
            "chickadee": "山雀", "nuthatch": "䴓", "redstart": "红尾鸲",
            "wheatear": "石䳭", "stonechat": "石即鸟", "nightingale": "夜莺",
            "pipit": "鹨", "flower": "花", "blossom": "花", "bloom": "花",
            "daffodil": "水仙", "orchid": "兰花", "daisy": "雏菊", "sunflower": "向日葵",
            "rose": "玫瑰", "tulip": "郁金香", "iris": "鸢尾", "poppy": "虞美人",
            "lily": "百合", "clover": "三叶草", "horse": "马", "pony": "小马",
            "donkey": "驴", "cow": "牛", "bull": "公牛", "sheep": "羊", "goat": "山羊",
            "pig": "猪", "dog": "狗", "cat": "猫", "rabbit": "兔", "hare": "野兔",
            "deer": "鹿", "bear": "熊", "fox": "狐狸", "wolf": "狼", "tiger": "虎",
            "lion": "狮", "zebra": "斑马", "giraffe": "长颈鹿", "elephant": "大象",
            "kangaroo": "袋鼠", "monkey": "猴", "squirrel": "松鼠"
        ]
        let s = id.lowercased()
        if let v = map[s] { return v }
        for (k, v) in map where s.hasSuffix("_\(k)") { return v }
        return id
    }

    /// 从标签串（如 "eagle 63%"）里挑置信度最高的鸟种标签，给中文名。
    /// 只认出通用 "bird" 时返回 nil（调用方如实写「认不出鸟种」）。
    /// 边界：雄雌羽色差别系统分类器给不出来，这里不做雄雌判断。
    static func speciesName(fromLabels labels: [String]) -> String? {
        var best: (id: String, conf: Double)?
        for l in labels {
            let parts = l.split(separator: " ")
            guard parts.count >= 2,
                  let conf = Double(parts[1].replacingOccurrences(of: "%", with: "")) else { continue }
            let id = String(parts[0])
            guard isBirdLabel(id) else { continue }
            if best == nil || conf > best!.conf { best = (id.lowercased(), conf) }
        }
        guard let b = best, b.id != "bird" else { return nil }
        return cnName(b.id)
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
