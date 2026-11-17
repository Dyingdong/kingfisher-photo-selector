import Foundation
import Vision
import ImageIO
import CoreGraphics

@main
struct VisionProbeReal {
static func main() {
for p in Array(CommandLine.arguments.dropFirst()) {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: p) as CFURL, nil),
          let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 1200,
            kCGImageSourceCreateThumbnailWithTransform: true
          ] as CFDictionary) else { print("\(p): decode fail"); continue }
    print("\n\(URL(fileURLWithPath: p).lastPathComponent)")
    let h = VNImageRequestHandler(cgImage: cg, options: [:])
    let fg = VNGenerateForegroundInstanceMaskRequest()
    let sal = VNGenerateAttentionBasedSaliencyImageRequest()
    try? h.perform([fg, sal])
    if let r = fg.results?.first {
        let mask = r.instanceMask
        let ids = r.allInstances
        print("  foreground instances=\(ids.count)")
        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
        let w = CVPixelBufferGetWidth(mask), hh = CVPixelBufferGetHeight(mask)
        let fmt = CVPixelBufferGetPixelFormatType(mask)
        print(String(format: "  mask %dx%d fmt=%u", w, hh, fmt))
        let stride = CVPixelBufferGetBytesPerRow(mask)
        guard let base = CVPixelBufferGetBaseAddress(mask) else { continue }
            let is8 = fmt == kCVPixelFormatType_OneComponent8
            for id in ids {
                var minX = w, maxX = 0, minY = hh, maxY = 0, n = 0
                for y in 0..<hh {
                    let row8 = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
                    let row32 = base.advanced(by: y * stride).assumingMemoryBound(to: UInt32.self)
                    for x in 0..<w {
                        let v: UInt32 = is8 ? UInt32(row8[x]) : row32[x]
                        guard v == UInt32(id) else { continue }
                        minX = min(minX, x); maxX = max(maxX, x)
                        minY = min(minY, y); maxY = max(maxY, y); n += 1
                    }
                }
            if n > 0 {
                let area = Double(n) / Double(w * hh)
                print(String(format: "    id=%d px=%d area=%.4f bb=(%.3f,%.3f,%.3f,%.3f)",
                             id, n, area,
                             Double(minX)/Double(w), Double(minY)/Double(hh),
                             Double(maxX-minX)/Double(w), Double(maxY-minY)/Double(hh)))
            }
        }
    } else { print("  foreground: no result") }
    if let o = sal.results?.first, let objs = o.salientObjects {
        print("  salient objects=\(objs.count)")
        for (i, b) in objs.enumerated().prefix(4) {
            let bb = b.boundingBox
            print(String(format: "    #%d bb=(%.3f,%.3f,%.3f,%.3f) area=%.4f",
                         i, bb.minX, bb.minY, bb.width, bb.height, bb.width * bb.height))
        }
    }
}
}
}