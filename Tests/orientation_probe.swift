import Foundation
import CoreGraphics
import ImageIO
import AppKit

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
    let buf = UnsafeBufferPointer(start: base.assumingMemoryBound(to: UInt8.self), count: w * h)
    return (Array(buf), w, h, thumb)
}

// 造一张 120x120 图：上半全黑，下半全白
let w = 120, h = 120
let cs = CGColorSpaceCreateDeviceGray()
let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                  space: cs, bitmapInfo: CGImageAlphaInfo.none.rawValue)!
c.setFillColor(gray: 0, alpha: 1); c.fill(CGRect(x: 0, y: h/2, width: w, height: h/2))
c.setFillColor(gray: 1, alpha: 1); c.fill(CGRect(x: 0, y: 0, width: w, height: h/2))
let img = c.makeImage()!
let url = URL(fileURLWithPath: "/tmp/fs_test/orientation.png")
let rep = NSBitmapImageRep(cgImage: img)
try! rep.representation(using: .png, properties: [:])?.write(to: url)

let d = decode(url)!
func avg(_ p: [UInt8], _ w: Int, _ y0: Int, _ y1: Int) -> Double {
    var s = 0
    for y in y0..<y1 { for x in 0..<w { s += Int(p[y*w+x]) } }
    return Double(s) / Double((y1-y0)*w)
}
print("缓冲区前 1/4 行均值:", avg(d.pixels, d.w, 0, d.h/4))
print("缓冲区后 1/4 行均值:", avg(d.pixels, d.w, d.h*3/4, d.h))
print("判读: 若前段=0(黑) 说明缓冲区 row0 = 图像顶部; 若前段=255 说明 row0 = 图像底部")
