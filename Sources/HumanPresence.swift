import Foundation
import Vision
import CoreGraphics
import ImageIO

/// 画面中是否有人（不依赖露脸）。只用于「题材自动识别」的兜底判断，
/// 不改变合焦判定与评分。理由可核对：检测到几个人体姿态、各有多少个关键点。
///
/// 为什么用人体姿态检测而不是图像分类 / 人体矩形：
/// - 图像分类把背影人像认成 clothing/jacket（见 JD5A8466），认不出「人」；
/// - VNDetectHumanRectanglesRequest 对坐姿/背影召回为 0；
/// - VNDetectHumanBodyPoseRequest 检测人体骨架关键点，实测背影人像检出 1 人 / 13 个关键点，
///   长焦风光与鸟类题材照片均为 0，能可靠区分（2026-11-18 实测）。
struct HumanPresence {
    let hasPerson: Bool          // 画面里检测到了人（不管大小）
    let isMainSubject: Bool      // 人是主体（占画面够大），而非风景里的点缀小人
    let count: Int
    let bodyHeightRatio: Double  // 人体关键点覆盖的包围盒高度 / 画面高度
    let reason: String           // 可核对文字

    static let none = HumanPresence(hasPerson: false, isMainSubject: false, count: 0,
                                    bodyHeightRatio: 0, reason: "未检测到人")
}

enum HumanPresenceEngine {
    /// 关键点置信度门槛：太低会把噪声当人。实测背影人像关键点 0.35~0.75。
    private static let pointConfidence: Float = 0.25
    /// 至少要有几个可靠关键点才算「一个人」，避免单个误检点。
    private static let minPoints = 4

    /// 人体高度占画面 ≥ 此值才算「人是主体」。实测：背影人像 0.53，
    /// 风景点缀小人 0.16~0.18，取 0.35 能干净分开。
    private static let mainSubjectHeight: Double = 0.35

    /// 从已加载的图检测。整图缩略图即可（1024 边长足够跑姿态）。
    static func detect(image: CGImage) -> HumanPresence {
        let req = VNDetectHumanBodyPoseRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try? handler.perform([req])
        var bestPoints = 0
        var bestHeight = 0.0
        var personCount = 0
        for obs in (req.results ?? []) {
            guard let pts = try? obs.recognizedPoints(.all) else { continue }
            let good = pts.values.filter { $0.confidence >= pointConfidence }
            guard good.count >= minPoints else { continue }
            personCount += 1
            bestPoints = max(bestPoints, good.count)
            let ys = good.map { Double($0.location.y) }
            bestHeight = max(bestHeight, (ys.max() ?? 0) - (ys.min() ?? 0))
        }
        guard personCount > 0 else { return personSegmentFallback(image) }
        let main = bestHeight >= mainSubjectHeight
        let why = main
            ? "检测到 \(personCount) 个人，人占画面较大（高度 \(Int(bestHeight * 100))%，背影/侧身也算）"
            : "检测到 \(personCount) 个人但很小（高度 \(Int(bestHeight * 100))%），更像风景里的人"
        return HumanPresence(hasPerson: true, isMainSubject: main, count: personCount,
                             bodyHeightRatio: bestHeight, reason: why)
    }

    /// 人体分割兜底：姿态关键点一个都没检出（人被芦苇/道具遮挡、低头蜷缩等）
    /// 时，用 VNGeneratePersonSegmentationRequest 再试一次。分割能认出「这里
    /// 有人形」，只是不知道具体关节。占画面 ≥30% 才算主体——门槛再低会把
    /// 风景里的大块岩石/雕塑误判成人。
    private static func personSegmentFallback(_ image: CGImage) -> HumanPresence {
        let req = VNGeneratePersonSegmentationRequest()
        req.qualityLevel = .accurate
        req.outputPixelFormat = kCVPixelFormatType_OneComponent8
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try? handler.perform([req])
        guard let buf = req.results?.first?.pixelBuffer,
              let ratio = maskRatio(buf) else { return .none }
        guard ratio >= 0.12 else { return .none }
        let main = ratio >= 0.30
        let why = main
            ? "人体分割检测到人，占画面 \(Int(ratio * 100))%（姿态关键点没检出，可能被遮挡）"
            : "人体分割检测到人但只占画面 \(Int(ratio * 100))%，更像风景里的人"
        return HumanPresence(hasPerson: true, isMainSubject: main, count: 1,
                             bodyHeightRatio: ratio, reason: why)
    }

    /// 统计单通道掩码里前景像素占比。
    private static func maskRatio(_ buf: CVPixelBuffer) -> Double? {
        let w = CVPixelBufferGetWidth(buf), h = CVPixelBufferGetHeight(buf)
        CVPixelBufferLockBaseAddress(buf, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buf) else { return nil }
        let bpr = CVPixelBufferGetBytesPerRow(buf)
        var sum = 0
        for row in 0..<h {
            let ptr = base.advanced(by: row * bpr)
            for col in 0..<w where ptr.load(fromByteOffset: col, as: UInt8.self) > 128 {
                sum += 1
            }
        }
        return Double(sum) / Double(w * h)
    }

    /// 从文件加载缩略图后检测，供 Store 异步调用。
    static func detect(url: URL) -> HumanPresence? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1024
        ]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return detect(image: img)
    }
}
