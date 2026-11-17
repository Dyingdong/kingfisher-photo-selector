import Foundation
import ImageIO
import CoreGraphics

func grayStats(_ cg: CGImage, maxSide: Int = 1000) -> (w: Int, h: Int, mean: Double, sd: Double, bins: Int, lap: Double) {
    let scale = min(1.0, Double(maxSide) / Double(max(cg.width, cg.height)))
    let w = max(1, Int(Double(cg.width) * scale)), h = max(1, Int(Double(cg.height) * scale))
    var p = [UInt8](repeating: 0, count: w * h)
    guard let ctx = CGContext(data: &p, width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                              bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return (0,0,0,0,0,0) }
    ctx.interpolationQuality = .high
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    let mean = p.reduce(0.0) { $0 + Double($1) } / Double(p.count)
    var sumSq = 0.0
    for v in p { let d = Double(v) - mean; sumSq += d * d }
    let sd = sqrt(sumSq / Double(p.count))
    var hist = [Int](repeating: 0, count: 256)
    for x in p { hist[Int(x)] += 1 }
    var acc = 0.0, n = 0
    for y in 1..<(h - 1) { for x in 1..<(w - 1) {
        let c = Double(p[y * w + x])
        acc += abs(4 * c - Double(p[y * w + x - 1]) - Double(p[y * w + x + 1])
                   - Double(p[(y - 1) * w + x]) - Double(p[(y + 1) * w + x]))
        n += 1
    } }
    return (cg.width, cg.height, mean, sd, hist.filter { $0 > 0 }.count, acc / Double(max(n, 1)))
}

for path in Array(CommandLine.arguments.dropFirst()) {
    let u = URL(fileURLWithPath: path)
    let name = u.lastPathComponent
    print("\n===== \(name) =====")
    guard let src = CGImageSourceCreateWithURL(u as CFURL, nil) else { print("SOURCE_FAIL"); continue }
    print("uti=\((CGImageSourceGetType(src) as String?) ?? "?") count=\(CGImageSourceGetCount(src))")
    if let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] {
        let px = props[kCGImagePropertyPixelWidth as String] as? Int ?? -1
        let py = props[kCGImagePropertyPixelHeight as String] as? Int ?? -1
        let depth = props[kCGImagePropertyDepth as String] as? Int ?? -1
        let dng = props[kCGImagePropertyDNGDictionary as String] as? [String: Any] ?? [:]
        print("full=\(px)x\(py) depth=\(depth) dngVer=\(dng[kCGImagePropertyDNGVersion as String] ?? "-") "
            + "cam=\(dng[kCGImagePropertyDNGUniqueCameraModel as String] ?? "-") "
            + "sharp=\(dng[kCGImagePropertyDNGBaselineSharpness as String] ?? "-")")
        if let thumbs = props[kCGImagePropertyThumbnailImages as String] as? [[String: Any]] {
            print("embeddedThumbs=\(thumbs.count) " + thumbs.map { t in
                "\(t[kCGImagePropertyPixelWidth as String] ?? "?")x\(t[kCGImagePropertyPixelHeight as String] ?? "?")"
            }.joined(separator: ","))
        }
    }
    let strategies: [(String, [CFString: Any]?)] = [
        ("fullDecode", nil),
        ("thumb_from_image_always_1200", [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                          kCGImageSourceThumbnailMaxPixelSize: 1200,
                                          kCGImageSourceCreateThumbnailWithTransform: true]),
        ("thumb_if_absent_1200", [kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                                  kCGImageSourceThumbnailMaxPixelSize: 1200,
                                  kCGImageSourceCreateThumbnailWithTransform: true]),
        ("thumb_embedded_only", [kCGImageSourceCreateThumbnailFromImageAlways: false,
                                 kCGImageSourceThumbnailMaxPixelSize: 1200,
                                 kCGImageSourceCreateThumbnailWithTransform: true]),
        ("fullDecode_1200", [kCGImageSourceCreateThumbnailFromImageAlways: false,
                             kCGImageSourceThumbnailMaxPixelSize: 1200,
                             kCGImageSourceCreateThumbnailWithTransform: false])
    ]
    for (label, opts) in strategies {
        let cg: CGImage?
        if label == "fullDecode" {
            cg = CGImageSourceCreateImageAtIndex(src, 0, nil)
        } else if label == "fullDecode_1200" {
            guard let full = CGImageSourceCreateImageAtIndex(src, 0, nil) else { continue }
            cg = full
        } else {
            guard let o = opts else { continue }
            cg = CGImageSourceCreateThumbnailAtIndex(src, 0, o as CFDictionary)
        }
        guard let im = cg else { print("  \(label): FAIL"); continue }
        let s = grayStats(im)
        print(String(format: "  %-32@ src=%dx%d mean=%6.1f sd=%6.1f bins=%3d lapGrad=%8.2f",
                     label as NSString, s.w, s.h, s.mean, s.sd, s.bins, s.lap))
    }
}
