import Foundation
import Vision
import CoreGraphics
import CoreVideo
import CoreImage
import ImageIO

/// AI 主体识别结果。与对焦点语义互补：对焦点语义看「相机对哪儿」，
/// AI 主体识别看「画面里的主体到底是什么」——前景实例分割把主体抠出来再分类，
/// 背景被抠掉后分类器不受蓝天/水面干扰，小主体也能认出来。
struct AISubject {
    enum Kind: String {
        case face       // 主体是人（含人脸/人体）
        case bird       // 主体是鸟（认出鸟种或通用 bird）
        case flower     // 主体是花（低置信度但多个花标签互相印证；题材仍归风光）
        case animal     // 主体是明确的具体非人动物（马/兔/狗…）
        case other      // 有明确主体但认不出是什么（如只有笼统 animal 标签）
        case none       // 没有可识别的主体
    }
    let kind: Kind
    let reason: String      // 可核对的一句依据（识别到什么 + 置信度）
    let labels: [String]    // top 标签，供界面悬停/调试导出
}

/// 整图 AI 主体识别引擎。
///
/// 做法（macOS 14+ 的 VNGenerateForegroundInstanceMaskRequest，即系统级前景分割模型）：
/// 1. 对整图跑前景实例分割，得到画面里的主体实例（人/动物/物体）；
/// 2. 逐实例生成「抠掉背景、裁到主体范围」的图；
/// 3. 对抠出的主体跑图像分类 + 动物检测，判定是人 / 鸟 / 其他。
///
/// 边界（如实）：
/// - 前景分割要求 macOS 14 及以上；低版本返回 nil，识别链退回原有规则，不硬猜；
/// - 动物检测分不清猫狗鸟：抠出的动物若分类认不出鸟种，只报「其他」，
///   不直接判拍鸟（避免公园拍狗被误判）；
/// - 最多看前 4 个主体实例，按分割面积从大到小（系统已按显著度排序）；
/// - 结果只用于题材识别，不影响合焦判定与星级。
enum AISubjectEngine {

    /// 动物检测门槛：与对焦点兜底一致（实测小飞鸟 66%）。
    private static let animalThreshold: Float = 0.40

    /// 从 RAW/JPG 载入缩略图后识别。供 Store 异步调用。
    static func detect(url: URL) -> AISubject? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1024
        ]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return detect(image: img)
    }

    static func detect(image: CGImage) -> AISubject? {
        if #available(macOS 14.0, *) {
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            let req = VNGenerateForegroundInstanceMaskRequest()
            try? handler.perform([req])
            let observations = req.results ?? []
            guard !observations.isEmpty else {
                return AISubject(kind: .none, reason: "AI 主体分割没找到明确前景主体", labels: [])
            }
            let ciContext = CIContext()
            for obs in observations.prefix(1) {
                // 每个观察包含全部前景实例；逐实例抠图分类，最多前 4 个。
                let instanceIDs = Array(obs.allInstances.prefix(4))
                for id in instanceIDs {
                    guard let masked = cropInstance(obs, id: id, handler: handler,
                                                    context: ciContext) else { continue }
                    let verdict = classify(masked)
                    if let verdict = verdict { return verdict }
                }
            }
            // 抠图分类全部失败时的整图兜底：深色鸟（鸦类）被抠成剪影后，
            // 分类器常给出 tool / people / material 这类乱标签（实测 JD5A9208~9215），
            // 但整图分类能看到 bird + raven 的一致信号。要求两个以上鸟标签同时
            // 达到门槛才采信：167 张人像/风光真值样本在此规则下 0 误报。
            let wholeTops = topLabels(in: image)
            if let hit = wholeImageBird(in: wholeTops) {
                return AISubject(
                    kind: .bird,
                    reason: "AI 主体分割没认出，但整图识别到：\(cnName(hit.identifier)) (\(Int((hit.confidence * 100).rounded()))%)",
                    labels: labelStrings(wholeTops))
            }
            // 整图动物检测兜底：抠出的主体可能被抠成剪影，导致抠图动物检测认不出
            // （实测兔片 JD5A9136/9140 抠图无达标检出，AI 只报 .other）；但整图里
            // 同一只动物仍能报出明确类别（实测 Cat 65~66%）。复用焦点引擎的类别
            // 感知检测，只有「明确非鸟动物」才据此定 .animal，交给 Score 落风光。
            // 真鸟片整图动物检测无检出（实测 97 张），不会被误改成动物。
            // Vision 报 Cat 就写「猫」，不臆造成兔。
            if let hit = FocusSemanticsEngine.topAnimal(in: image),
               hit.confidence >= Double(animalThreshold),
               FocusSemanticsEngine.isDefiniteNonBirdAnimal(hit.identifier) {
                return AISubject(
                    kind: .animal,
                    reason: "AI 主体分割没认出，但整图识别到动物：\(cnName(hit.identifier)) (\(Int((hit.confidence * 100).rounded()))%)",
                    labels: labelStrings(wholeTops))
            }
            // 分割到了但都认不出 —— 如实说，不硬猜。
            return AISubject(kind: .other,
                             reason: "AI 分割到 \(observations.count) 个前景主体，但分类认不出是什么",
                             labels: [])
        }
        return nil   // macOS 13 无前景分割 API，交回原有规则
    }

    /// 抠出单个实例：生成带遮罩的裁剪图（背景置黑），供分类使用。
    /// generateMaskedImage 直接返回像素缓冲（已裁到主体范围）。
    @available(macOS 14.0, *)
    private static func cropInstance(_ obs: Any, id: Int, handler: VNImageRequestHandler,
                                     context: CIContext) -> CGImage? {
        guard let observation = obs as? VNInstanceMaskObservation else { return nil }
        guard let buffer = try? observation.generateMaskedImage(
            ofInstances: IndexSet(integer: id),
            from: handler,
            croppedToInstancesExtent: true) else { return nil }
        let ciImage = CIImage(cvPixelBuffer: buffer)
        return context.createCGImage(ciImage, from: ciImage.extent)
    }

    /// 对抠出的主体分类：认出人 → face；认出鸟 → bird；认出具体动物 → animal；
    /// 认出花 → flower；只有笼统 animal 标签 → other；都不行 → nil（继续看下一个实例）。
    /// 顺序刻意是鸟 > 人 > 具体动物 > 花：马照里分类常混入低分 people，
    /// 不能让它抢在 horse 之前把马判成人。
    private static func classify(_ masked: CGImage) -> AISubject? {
        let topList = topLabels(in: masked)
        let labels = labelStrings(topList)

        if let hit = FocusSemanticsEngine.birdLabelConfidence(in: topList) {
            return AISubject(
                kind: .bird,
                reason: "AI 主体分割抠出主体，识别到：\(cnName(hit.identifier)) (\(Int((hit.confidence * 100).rounded()))%)",
                labels: labels)
        }
        if let hit = FocusSemanticsEngine.faceLabelConfidence(in: topList) {
            return AISubject(
                kind: .face,
                reason: "AI 主体分割抠出主体，识别到人 (\(Int((hit.confidence * 100).rounded()))%)",
                labels: labels)
        }
        if let hit = FocusSemanticsEngine.specificAnimalConfidence(in: topList) {
            return AISubject(
                kind: .animal,
                reason: "AI 主体分割抠出主体，识别到：\(cnName(hit.identifier)) (\(Int((hit.confidence * 100).rounded()))%)",
                labels: labels)
        }
        if let hit = FocusSemanticsEngine.flowerEvidence(in: topList) {
            return AISubject(
                kind: .flower,
                reason: "AI 主体分割抠出主体，识别到：\(cnName(hit.identifier))（低置信度 \(Int((hit.confidence * 100).rounded()))%，多个花标签互相印证）",
                labels: labels)
        }
        // 动物检测兜底：抠掉背景后小动物更容易被检出。
        // Vision 会把兔子竖耳剪影认成 Cat（实测兔片 59~62%），旧实现丢弃类别一律报
        // .other。现复用焦点引擎的类别感知检测：检出明确非鸟动物时如实报识别到的类别，
        // 让 Score 的 aiNonHumanLandscape 能把这类照片交回风光（否则会被超长焦 +
        // 极小前景主体规则硬判成拍鸟）。Vision 报 Cat 就写「猫」，不臆造成兔。
        if let hit = FocusSemanticsEngine.topAnimal(in: masked),
           hit.confidence >= Double(animalThreshold) {
            if FocusSemanticsEngine.isDefiniteNonBirdAnimal(hit.identifier) {
                return AISubject(
                    kind: .animal,
                    reason: "AI 主体分割抠出主体，识别到：\(cnName(hit.identifier)) (\(Int((hit.confidence * 100).rounded()))%)",
                    labels: labels)
            }
            // 类别为空/笼统或检出的是鸟：仍按「认不出具体是什么」处理，不判鸟。
            return AISubject(
                kind: .other,
                reason: "AI 主体分割抠出动物 (\(Int((hit.confidence * 100).rounded()))%)，但认不出具体是什么",
                labels: labels)
        }
        return nil
    }

    /// 取 top 分类标签（过滤掉 5% 以下的噪声），两处分类共用同一口径。
    private static func topLabels(in image: CGImage) -> [VNClassificationObservation] {
        let req = VNClassifyImageRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try? handler.perform([req])
        return Array((req.results ?? []).filter { $0.confidence >= 0.05 }.prefix(12))
    }

    /// 标签串格式化，供界面悬停 / 调试导出核对。
    private static func labelStrings(_ tops: [VNClassificationObservation]) -> [String] {
        tops.map { "\($0.identifier) \(Int(($0.confidence * 100).rounded()))%" }
    }

    /// 整图鸟类兜底的门槛。实测深色鸦类整图 bird/raven 在 11%~56% 之间波动，
    /// 0.10 + 多鸟标签一致能覆盖全部 5 帧；167 张人像/风光真值样本在此规则下 0 误报。
    private static let wholeBirdThreshold: Float = 0.10

    /// 整图兜底只认「多个鸟类标签同时达标」的情况：通用 bird 之外还要有
    /// raven / heron 之类的具体鸟种，避免单个低分标签把风景误判成鸟。
    private static func wholeImageBird(in tops: [VNClassificationObservation]) -> VNClassificationObservation? {
        let hits = tops.filter {
            FocusSemanticsEngine.isBirdLabel($0.identifier) && $0.confidence >= wholeBirdThreshold
        }
        guard hits.count >= 2 else { return nil }
        let specific = hits.filter { $0.identifier.lowercased() != "bird" }
        let pool = specific.isEmpty ? hits : specific
        return pool.max { $0.confidence < $1.confidence }
    }

    /// 常见标签中文名（与对焦点语义共用一张表，这里只补主体识别常用词）。
    private static func cnName(_ id: String) -> String {
        let map: [String: String] = [
            "bird": "鸟", "heron": "鹭", "egret": "白鹭", "eagle": "鹰", "duck": "鸭",
            "goose": "鹅", "swan": "天鹅", "gull": "鸥", "owl": "猫头鹰", "person": "人",
            "human": "人", "face": "人脸", "animal": "动物",
            "raven": "渡鸦", "crow": "乌鸦", "blackbird": "乌鸫", "jackdaw": "寒鸦",
            "rook": "秃鼻乌鸦", "cormorant": "鸬鹚", "swallow": "燕子", "swift": "雨燕",
            "starling": "椋鸟", "thrush": "鸫", "shrike": "伯劳", "bulbul": "鹎",
            "oriole": "黄鹂", "bunting": "鹀", "wagtail": "鹡鸰", "titmouse": "山雀",
            "chickadee": "山雀", "nuthatch": "䴓", "redstart": "红尾鸲",
            "flower": "花", "flowers": "花", "blossom": "花", "bloom": "花",
            "floral": "花", "petal": "花瓣", "daffodil": "水仙", "orchid": "兰花",
            "daisy": "雏菊", "sunflower": "向日葵", "rose": "玫瑰", "tulip": "郁金香",
            "iris": "鸢尾", "poppy": "虞美人", "lily": "百合", "clover": "三叶草",
            "horse": "马", "pony": "小马", "donkey": "驴", "cow": "牛", "bull": "公牛",
            "sheep": "羊", "goat": "山羊", "pig": "猪", "dog": "狗", "cat": "猫",
            "rabbit": "兔", "hare": "野兔", "deer": "鹿", "bear": "熊", "fox": "狐狸",
            "wolf": "狼", "tiger": "虎", "lion": "狮", "zebra": "斑马",
            "giraffe": "长颈鹿", "elephant": "大象", "kangaroo": "袋鼠",
            "monkey": "猴", "squirrel": "松鼠"
        ]
        let s = id.lowercased()
        if let v = map[s] { return v }
        for (k, v) in map where s.hasSuffix("_\(k)") { return v }
        return id
    }
}
