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
        case other      // 有明确主体但认不出是不是鸟（如动物但非鸟标签）
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
            // 分割到了但都认不出 —— 如实说，不硬猜。
            return AISubject(kind: .other,
                             reason: "AI 分割到 \(observations.count) 个前景主体，但分类认不出是人还是鸟",
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

    /// 对抠出的主体分类：认出人 → face；认出鸟 → bird；
    /// 动物检测检出但认不出鸟种 → other；都不行 → nil（继续看下一个实例）。
    private static func classify(_ masked: CGImage) -> AISubject? {
        let req = VNClassifyImageRequest()
        let handler = VNImageRequestHandler(cgImage: masked, options: [:])
        try? handler.perform([req])
        let tops = (req.results ?? []).filter { $0.confidence >= 0.05 }.prefix(12)
        let topList = Array(tops)
        let labels = topList.map {
            "\($0.identifier) \(Int(($0.confidence * 100).rounded()))%"
        }

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
        // 动物检测兜底：抠掉背景后小动物更容易被检出。
        let animal = VNRecognizeAnimalsRequest()
        try? handler.perform([animal])
        if let best = (animal.results ?? []).map({ $0.confidence }).max(), best >= animalThreshold {
            return AISubject(
                kind: .other,
                reason: "AI 主体分割抠出动物 (\(Int((best * 100).rounded()))%)，但认不出是不是鸟",
                labels: labels)
        }
        return nil
    }

    /// 常见标签中文名（与对焦点语义共用一张表，这里只补主体识别常用词）。
    private static func cnName(_ id: String) -> String {
        let map: [String: String] = [
            "bird": "鸟", "heron": "鹭", "egret": "白鹭", "eagle": "鹰", "duck": "鸭",
            "goose": "鹅", "swan": "天鹅", "gull": "鸥", "owl": "猫头鹰", "person": "人",
            "human": "人", "face": "人脸", "animal": "动物"
        ]
        let s = id.lowercased()
        if let v = map[s] { return v }
        for (k, v) in map where s.hasSuffix("_\(k)") { return v }
        return id
    }
}
