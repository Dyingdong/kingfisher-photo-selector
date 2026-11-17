import Foundation
import ImageIO
import CoreGraphics

// 只读探针：检查 ImageIO 解出的缩略图到底有没有内容
for path in Array(CommandLine.arguments.dropFirst()) {
    let u = URL(fileURLWithPath: path)
    let name = u.lastPathComponent
    guard let src = CGImageSourceCreateWithURL(u as CFURL, nil) else {
        print("\(name): SOURCE_FAIL")
        continue
    }
    let uti = (CGImageSourceGetType(src) as String?) ?? "?"
    let opts: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceThumbnailMaxPixelSize: 1200,
        kCGImageSourceCreateThumbnailWithTransform: true
    ]
    guard let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
        print("\(name): THUMB_FAIL uti=\(uti)")
        continue
    }
    let w = thumb.width, h = thumb.height
    guard w > 0, h > 0 else { print("\(name): ZERO_SIZE"); continue }
    var pixels = [UInt8](repeating: 0, count: w * h)
    guard let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                              bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
        print("\(name): CONTEXT_FAIL")
        continue
    }
    ctx.interpolationQuality = .high
    ctx.draw(thumb, in: CGRect(x: 0, y: 0, width: w, height: h))
    let mean = pixels.reduce(0.0) { $0 + Double($1) } / Double(pixels.count)
    let variance = pixels.reduce(0.0) { $0 + (Double($1) - mean) * (Double($1) - mean) } / Double(pixels.count)
    var hist = [Int](repeating: 0, count: 256)
    for p in pixels { hist[Int(p)] += 1 }
    let bins = hist.filter { $0 > 0 }.count
    let top3 = hist.enumerated().sorted { $0.element > $1.element }.prefix(3)
        .map { "[\($0.offset):\($0.element)]" }.joined(separator: " ")
    print(String(format: "%@ uti=%@ %dx%d mean=%.1f sd=%.1f min=%d max=%d bins=%d top=%@",
                 name as NSString, uti as NSString, w, h, mean, sqrt(variance),
                 pixels.min() ?? 0, pixels.max() ?? 0, bins, top3 as NSString))
}
