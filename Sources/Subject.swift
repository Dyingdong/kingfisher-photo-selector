import Foundation
import Vision
import CoreGraphics

struct SubjectRegion {
    let weights: [Double]
    let cols: Int
    let rows: Int
    let source: String
    let bboxes: [CGRect]
}

enum SubjectEngine {
    /// 主体区域按优先级降级：前景实例分割 → 人脸 → 显著性 → 中心权重。
    /// 前景分割能从「小鸟 + 大面积天空」这类稀疏主体照片里真正框出主体；
    /// 显著性框往往覆盖 20%~50% 画面，只作为没有更好结果时的兜底。
    static func region(for image: CGImage, cols: Int, rows: Int,
                       preferFaces: Bool) -> SubjectRegion {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let faces = VNDetectFaceRectanglesRequest()
        let sal = VNGenerateAttentionBasedSaliencyImageRequest()

        var boxes: [CGRect] = []
        var source = "中心权重"
        var fgWeights: [Double]?

        if #available(macOS 14.0, *) {
            let fg = VNGenerateForegroundInstanceMaskRequest()
            try? handler.perform([fg, faces, sal])
            if let obs = fg.results?.first {
                boxes = Self.foregroundBoxes(obs, cols: cols, rows: rows)
                if !boxes.isEmpty {
                    source = "前景主体"
                    fgWeights = Self.foregroundCoverage(obs, cols: cols, rows: rows)
                }
            }
        } else {
            try? handler.perform([faces, sal])
        }
        if boxes.isEmpty, preferFaces, let fs = faces.results, !fs.isEmpty {
            boxes = fs.map { $0.boundingBox }
            source = "人脸检测"
        }
        if boxes.isEmpty, let obs = sal.results?.first,
           let objs = obs.salientObjects, !objs.isEmpty {
            boxes = objs.map { $0.boundingBox }
            source = "显著性区域"
        }

        var weights = [Double](repeating: 0, count: cols * rows)
        if let cover = fgWeights {
            // mask 覆盖率直接决定权重：包围盒会把小鸟周围的大片背景算进主体，
            // 实测 JD5A7979 的包围盒锐度比只有 0.00，而真正被鸟占据的块很锐。
            return SubjectRegion(weights: cover, cols: cols, rows: rows,
                                 source: source, bboxes: boxes)
        }
        for r in 0..<rows {
            for c in 0..<cols {
                let cx = (Double(c) + 0.5) / Double(cols)
                let cy = (Double(r) + 0.5) / Double(rows)
                if !boxes.isEmpty {
                    var hit = false
                    for b in boxes {
                        let padX = 0.5 / Double(cols), padY = 0.5 / Double(rows)
                        if cx >= b.minX - padX, cx <= b.maxX + padX,
                           cy >= 1.0 - b.maxY - padY, cy <= 1.0 - b.minY + padY {
                            hit = true
                            break
                        }
                    }
                    weights[r * cols + c] = hit ? 1.0 : (source == "显著性区域" ? 0.05 : 0.0)
                    continue
                }
                let dx = (cx - 0.5) / 0.34
                let dy = (cy - 0.5) / 0.38
                let center = exp(-(dx * dx + dy * dy))
                var thirds = 0.0
                for tx in [1.0 / 3.0, 2.0 / 3.0] {
                    for ty in [1.0 / 3.0, 2.0 / 3.0] {
                        let ax = (cx - tx) / 0.20, ay = (cy - ty) / 0.24
                        thirds = max(thirds, exp(-(ax * ax + ay * ay)))
                    }
                }
                weights[r * cols + c] = max(center, 0.55 * thirds)
            }
        }
        return SubjectRegion(weights: weights, cols: cols, rows: rows,
                             source: source, bboxes: boxes)
    }

    /// 从实例 mask 反推每个实例的包围盒。mask 是 L008（每像素 1 字节实例编号），
    /// 像素坐标原点在左上，Vision 的 boundingBox 原点在左下，需要翻转 y。
    @available(macOS 14.0, *)
    private static func foregroundBoxes(_ obs: VNInstanceMaskObservation,
                                        cols: Int, rows: Int) -> [CGRect] {
        let mask = obs.instanceMask
        let w = CVPixelBufferGetWidth(mask), h = CVPixelBufferGetHeight(mask)
        guard w > 0, h > 0 else { return [] }
        let stride = CVPixelBufferGetBytesPerRow(mask)
        let is8 = CVPixelBufferGetPixelFormatType(mask) == kCVPixelFormatType_OneComponent8
        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(mask) else { return [] }

        var out: [CGRect] = []
        for id in obs.allInstances {
            var minX = w, maxX = 0, minY = h, maxY = 0, n = 0
            for y in 0..<h {
                let row8 = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
                let row32 = base.advanced(by: y * stride).assumingMemoryBound(to: UInt32.self)
                for x in 0..<w {
                    let v: UInt32 = is8 ? UInt32(row8[x]) : row32[x]
                    guard v == UInt32(id) else { continue }
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                    n += 1
                }
            }
            // 过滤 mask 边缘噪声；真实主体（哪怕一只小鸟）也远大于这个面积
            guard n > 0, Double(n) / Double(w * h) > 0.0003 else { continue }
            let bx = Double(minX) / Double(w)
            let by = 1.0 - Double(maxY + 1) / Double(h)
            let bw = Double(maxX - minX + 1) / Double(w)
            let bh = Double(maxY - minY + 1) / Double(h)
            out.append(CGRect(x: bx, y: by, width: bw, height: bh))
        }
        return out
    }

    /// 每个分析块被前景像素覆盖的比例，映射成 0~1 权重。
    /// 只评价「真的有主体像素」的块，避免小主体被包围盒里的背景稀释。
    @available(macOS 14.0, *)
    private static func foregroundCoverage(_ obs: VNInstanceMaskObservation,
                                           cols: Int, rows: Int) -> [Double] {
        let mask = obs.instanceMask
        let w = CVPixelBufferGetWidth(mask), h = CVPixelBufferGetHeight(mask)
        guard w > 0, h > 0 else { return [Double](repeating: 0, count: cols * rows) }
        let stride = CVPixelBufferGetBytesPerRow(mask)
        let is8 = CVPixelBufferGetPixelFormatType(mask) == kCVPixelFormatType_OneComponent8
        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(mask) else {
            return [Double](repeating: 0, count: cols * rows)
        }
        var counts = [Double](repeating: 0, count: cols * rows)
        for y in 0..<h {
            let row8 = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
            let row32 = base.advanced(by: y * stride).assumingMemoryBound(to: UInt32.self)
            let r = min(rows - 1, y * rows / h)
            for x in 0..<w {
                let v: UInt32 = is8 ? UInt32(row8[x]) : row32[x]
                guard v > 0 else { continue }
                let c = min(cols - 1, x * cols / w)
                counts[r * cols + c] += 1
            }
        }
        let blockArea = (Double(w) / Double(cols)) * (Double(h) / Double(rows))
        return counts.map { min(1.0, $0 / max(blockArea, 1) / 0.02) }
    }
}
