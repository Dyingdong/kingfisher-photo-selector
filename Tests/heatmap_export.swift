import Foundation
import CoreGraphics
import ImageIO
import AppKit

let block = 28

func decode(_ url: URL, maxSide: Int = 1200) -> (pixels: [UInt8], w: Int, h: Int, image: CGImage)? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let opts: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceThumbnailMaxPixelSize: maxSide,
        kCGImageSourceCreateThumbnailWithTransform: true
    ]
    guard let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
    let w = thumb.width, h = thumb.height
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                              bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
    ctx.interpolationQuality = .high
    ctx.draw(thumb, in: CGRect(x: 0, y: 0, width: w, height: h))
    guard let base = ctx.data else { return nil }
    return (Array(UnsafeBufferPointer(start: base.assumingMemoryBound(to: UInt8.self), count: w*h)), w, h, thumb)
}

func blockVariance(_ p: [UInt8], _ w: Int, _ x0: Int, _ y0: Int, _ bs: Int) -> Double {
    var sum = 0.0, sum2 = 0.0, n = 0
    for y in (y0+1)..<(y0+bs-1) {
        for x in (x0+1)..<(x0+bs-1) {
            let c = Double(p[y*w+x])
            let v = -4*c + Double(p[y*w-w+x]) + Double(p[y*w+w+x]) + Double(p[y*w+x-1]) + Double(p[y*w+x+1])
            sum += v; sum2 += v*v; n += 1
        }
    }
    guard n > 0 else { return 0 }
    return max(0, sum2/Double(n) - (sum/Double(n))*(sum/Double(n)))
}

func percentile(_ xs: [Double], _ q: Double) -> Double {
    let s = xs.sorted()
    return s[min(s.count-1, max(0, Int((Double(s.count-1)*q).rounded())))]
}

for path in Array(CommandLine.arguments.dropFirst()) {
    guard let d = decode(URL(fileURLWithPath: path)) else { continue }
    let cols = d.w/block, rows = d.h/block
    var scores = [Double](repeating: 0, count: cols*rows)
    for r in 0..<rows { for c in 0..<cols {
        scores[r*cols+c] = blockVariance(d.pixels, d.w, c*block, r*block, block)
    }}
    let hi = max(percentile(scores, 0.99), 1e-6)
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: nil, width: d.w, height: d.h, bitsPerComponent: 8,
                              bytesPerRow: d.w*4, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
    ctx.draw(d.image, in: CGRect(x: 0, y: 0, width: d.w, height: d.h))
    var green=0, yellow=0, red=0
    for r in 0..<rows { for c in 0..<cols {
        let v = scores[r*cols+c]/hi
        let (cr,cg,cb,a): (CGFloat,CGFloat,CGFloat,CGFloat)
        if v > 0.55 { green+=1; cr=0.20; cg=0.72; cb=0.55; a=0.30 }
        else if v > 0.22 { yellow+=1; cr=0.95; cg=0.72; cb=0.20; a=0.38 }
        else { red+=1; cr=0.90; cg=0.25; cb=0.25; a=0.46 }
        ctx.setFillColor(red: cr, green: cg, blue: cb, alpha: a)
        ctx.fill(CGRect(x: c*block, y: d.h-(r+1)*block, width: block, height: block))
    }}
    let out = ctx.makeImage()!
    let name = (path as NSString).lastPathComponent
    let dest = "/tmp/fs_test/hm_\((name as NSString).deletingPathExtension).png"
    try? NSBitmapImageRep(cgImage: out).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dest))
    let total = cols*rows
    print("\(name): \(cols)x\(rows)=\(total)块  绿\(green)(\(green*100/total)%) 黄\(yellow)(\(yellow*100/total)%) 红\(red)(\(red*100/total)%)  P99=\(hi)")
    print("  -> \(dest)")
}
