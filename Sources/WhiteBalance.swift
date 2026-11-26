import Foundation
import AppKit
import Vision
import ImageIO

/// 本地白平衡 / 曝光参考统计。
/// 注意：这是统计意义上的「偏色倾向」，不是相机 K 值，也不能替代校色软件。
struct WhiteBalanceStats: Codable {
    let meanR: Double
    let meanG: Double
    let meanB: Double
    let wholeCast: String
    let faceCast: String?
    let faceRG: Double?
    let faceBG: Double?
    let highlightClip: Double
    let shadowClip: Double

    var summary: String {
        var parts = ["全图 \(wholeCast)"]
        if let c = faceCast { parts.append("人脸区域 \(c)") }
        if highlightClip > 0.02 { parts.append(String(format: "高光裁剪 %.1f%%", highlightClip * 100)) }
        if shadowClip > 0.05 { parts.append(String(format: "死黑 %.1f%%", shadowClip * 100)) }
        return parts.joined(separator: " · ")
    }
}

enum WhiteBalance {
    private struct RGBSum {
        var r = 0.0, g = 0.0, b = 0.0, n = 0, hiClip = 0, loClip = 0

        mutating func add(_ p: UnsafeBufferPointer<UInt8>, _ idx: Int) {
            let rr = Double(p[idx]), gg = Double(p[idx + 1]), bb = Double(p[idx + 2])
            r += rr; g += gg; b += bb; n += 1
            if max(rr, gg, bb) >= 250 { hiClip += 1 }
            if max(rr, gg, bb) <= 6 { loClip += 1 }
        }

        var ratios: (rg: Double, bg: Double)? {
            guard n > 0, g > 0 else { return nil }
            return (r / g, b / g)
        }
    }

    static func analyze(_ url: URL, source: CGImageSource? = nil) -> WhiteBalanceStats? {
        guard let src = source ?? CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 600,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let w = thumb.width, h = thumb.height
        guard w > 0, h > 0 else { return nil }
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(thumb, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let base = ctx.data else { return nil }
        let p = UnsafeBufferPointer(start: base.assumingMemoryBound(to: UInt8.self), count: w * h * 4)

        var whole = RGBSum()
        var step = 1
        while w * h / step > 120_000 { step += 1 }
        for y in stride(from: 0, to: h, by: step) {
            for x in stride(from: 0, to: w, by: step) {
                whole.add(p, (y * w + x) * 4)
            }
        }
        guard let wr = whole.ratios else { return nil }

        let request = VNDetectFaceRectanglesRequest()
        try? VNImageRequestHandler(cgImage: thumb, options: [:]).perform([request])
        var face = RGBSum()
        for box in request.results ?? [] {
            let b = box.boundingBox
            // Vision 坐标左下原点；RGB 缓冲是左上原点。
            let x0 = max(0, Int(b.minX * CGFloat(w)))
            let x1 = min(w - 1, Int(b.maxX * CGFloat(w)))
            let y0 = max(0, Int((1.0 - b.maxY) * CGFloat(h)))
            let y1 = min(h - 1, Int((1.0 - b.minY) * CGFloat(h)))
            let fyStep = max(1, (y1 - y0) / 60)
            let fxStep = max(1, (x1 - x0) / 60)
            for y in stride(from: y0, through: y1, by: fyStep) {
                for x in stride(from: x0, through: x1, by: fxStep) {
                    face.add(p, (y * w + x) * 4)
                }
            }
        }
        let fr = face.ratios
        return WhiteBalanceStats(
            meanR: whole.r / Double(max(1, whole.n)),
            meanG: whole.g / Double(max(1, whole.n)),
            meanB: whole.b / Double(max(1, whole.n)),
            wholeCast: Self.cast(rg: wr.rg, bg: wr.bg),
            faceCast: fr.map { Self.cast(rg: $0.rg, bg: $0.bg) },
            faceRG: fr?.rg, faceBG: fr?.bg,
            highlightClip: Double(whole.hiClip) / Double(max(1, whole.n)),
            shadowClip: Double(whole.loClip) / Double(max(1, whole.n))
        )
    }

    private static func cast(rg: Double, bg: Double) -> String {
        if rg > 1.08, bg < rg * 0.90 { return "偏暖（R 高于 B）" }
        if bg > 1.08, rg < bg * 0.90 { return "偏冷（B 高于 R）" }
        if rg > 1.06, bg > 1.06 { return "偏洋红" }
        if rg < 0.96, bg < 0.96 { return "偏绿" }
        return "接近中性"
    }
}
