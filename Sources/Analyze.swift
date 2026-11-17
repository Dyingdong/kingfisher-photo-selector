import Foundation
import CoreGraphics
import ImageIO

enum Verdict: String {
    case pass = "通过"
    case globalBlur = "疑似全片模糊"
    case subjectBlur = "疑似主体失焦"
    case depthIssue = "疑似景深不足"
    case motionBlur = "运动模糊/拖影"
    case unreadable = "无法解码"

    var isSuspect: Bool {
        self == .globalBlur || self == .subjectBlur || self == .depthIssue
    }
}

struct PhotoMetrics {
    let url: URL
    let globalHi: Double
    let subjectScore: Double
    let ratio: Double
    let centerRatio: Double
    let anisotropy: Double
    let softRatio: Double
    let spread: Double
    let reblurRatio: Double
    let subjectReblur: Double
    let scores: [Double]
    /// 再模糊一次后的分块分数；热力图用它区分「细节被虚化」和「场景本来就没纹理」。
    let blurScores: [Double]
    let cols: Int
    let rows: Int
    let weights: [Double]
    let subjectSource: String
    let bboxes: [CGRect]
    let preview: CGImage?
    let width: Int
    let height: Int
}

struct PhotoResult: Identifiable {
    let id: URL
    let metrics: PhotoMetrics
    var verdict: Verdict
    var reason: String
    var overrideRect: CGRect?
}

enum Analyzer {
    static let block = 28

    static func percentile(_ xs: [Double], _ q: Double) -> Double {
        guard !xs.isEmpty else { return 0 }
        let s = xs.sorted()
        let i = min(s.count - 1, max(0, Int((Double(s.count - 1) * q).rounded())))
        return s[i]
    }

    /// 显示用原尺寸解码：只取当前选中照片，按原始像素上限解码，
    /// 让放大到 1× 以上时仍保留原始细节（与 macOS「预览」的缩放观感一致）。
    static func loadFullPreview(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let pw = (props?[kCGImagePropertyPixelWidth] as? Int) ?? 0
        let ph = (props?[kCGImagePropertyPixelHeight] as? Int) ?? 0
        let maxSide = max(pw, ph, 1200)
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    static func decode(_ url: URL, maxSide: Int = 1200) -> (pixels: [UInt8], w: Int, h: Int, image: CGImage)? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let w = thumb.width, h = thumb.height
        guard w > 0, h > 0 else { return nil }
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(thumb, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let base = ctx.data else { return nil }
        let buf = UnsafeBufferPointer(start: base.assumingMemoryBound(to: UInt8.self), count: w * h)
        return (Array(buf), w, h, thumb)
    }

    static func blockVariance(_ p: [UInt8], _ w: Int, _ x0: Int, _ y0: Int, _ bs: Int) -> Double {
        var sum = 0.0, sum2 = 0.0, n = 0
        for y in (y0 + 1)..<(y0 + bs - 1) {
            let r = y * w
            for x in (x0 + 1)..<(x0 + bs - 1) {
                let c = Double(p[r + x])
                let v = -4.0 * c + Double(p[r - w + x]) + Double(p[r + w + x])
                    + Double(p[r + x - 1]) + Double(p[r + x + 1])
                sum += v; sum2 += v * v; n += 1
            }
        }
        guard n > 0 else { return 0 }
        let m = sum / Double(n)
        return max(0, sum2 / Double(n) - m * m)
    }

    static func boxBlur(_ p: [UInt8], _ w: Int, _ h: Int) -> [UInt8] {
        var out = p
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                var s = 0
                for dy in -1...1 {
                    let row = (y + dy) * w
                    s += Int(p[row + x - 1]) + Int(p[row + x]) + Int(p[row + x + 1])
                }
                out[y * w + x] = UInt8(s / 9)
            }
        }
        return out
    }

    static func directionalRatio(_ p: [UInt8], _ w: Int, _ h: Int) -> Double {
        var gx = 0.0, gy = 0.0
        for y in stride(from: 1, to: h - 1, by: 2) {
            for x in stride(from: 1, to: w - 1, by: 2) {
                let c = Double(p[y * w + x])
                gx += abs(Double(p[y * w + x + 1]) - c)
                gy += abs(Double(p[(y + 1) * w + x]) - c)
            }
        }
        return max(gx, gy) / max(min(gx, gy), 1e-6)
    }

    static func analyze(_ url: URL, preferFaces: Bool = false) -> PhotoMetrics? {
        guard let d = decode(url) else { return nil }
        let bs = block
        let cols = d.w / bs, rows = d.h / bs
        guard cols >= 2, rows >= 2 else { return nil }

        var scores = [Double](repeating: 0, count: cols * rows)
        let blurred = boxBlur(d.pixels, d.w, d.h)
        var bScores = [Double](repeating: 0, count: cols * rows)
        for r in 0..<rows {
            for c in 0..<cols {
                let i = r * cols + c
                scores[i] = blockVariance(d.pixels, d.w, c * bs, r * bs, bs)
                bScores[i] = blockVariance(blurred, d.w, c * bs, r * bs, bs)
            }
        }

        // P90 在「小主体 + 大面积平坦背景」的照片里仍全是背景（实测 369A4577 P90=3.3、
        // P99=353、最大=2945），会把好片误判为全片模糊。改用 P99 取真正的锐区。
        let hi = percentile(scores, 0.99)
        let bHi = percentile(bScores, 0.99)
        let p10 = percentile(scores, 0.10)
        let spread = (hi - p10) / max(hi, 1e-6)
        let softThr = hi * 0.22
        let softRatio = Double(scores.filter { $0 < softThr }.count) / Double(scores.count)

        let region = SubjectEngine.region(for: d.image, cols: cols, rows: rows, preferFaces: preferFaces)
        let subj = scores.enumerated().compactMap { region.weights[$0.offset] > 0.45 ? $0.element : nil }
        // 前景分割框出小主体时，框内块数很少，用中位数比取 P90 更贴近主体本身
        let s = subj.isEmpty ? hi : percentile(subj, 0.5)

        let subjBlur = bScores.enumerated().compactMap { region.weights[$0.offset] > 0.45 ? $0.element : nil }
        let subjectReblur = subjBlur.isEmpty || s <= 0
            ? 1.0 : percentile(subjBlur, 0.5) / s

        var centerBlocks: [Double] = []
        for r in 0..<rows {
            for c in 0..<cols {
                let cx = (Double(c) + 0.5) / Double(cols)
                let cy = (Double(r) + 0.5) / Double(rows)
                let nx = (cx - 0.5) / 0.26, ny = (cy - 0.5) / 0.30
                if nx * nx + ny * ny <= 1.0 { centerBlocks.append(scores[r * cols + c]) }
            }
        }
        let centerScore = centerBlocks.isEmpty ? hi : percentile(centerBlocks, 0.5)
        let centerRatio = centerScore / max(hi, 1e-6)

        return PhotoMetrics(
            url: url, globalHi: hi, subjectScore: s,
            ratio: s / max(hi, 1e-6), centerRatio: centerRatio,
            anisotropy: directionalRatio(d.pixels, d.w, d.h),
            softRatio: softRatio, spread: spread,
            reblurRatio: bHi / max(hi, 1e-6),
            subjectReblur: subjectReblur,
            scores: scores, blurScores: bScores, cols: cols, rows: rows,
            weights: region.weights, subjectSource: region.source,
            bboxes: region.bboxes, preview: d.image,
            width: d.w, height: d.h
        )
    }

    /// 人工圈选主体后重算：返回该区域的锐度与最锐区之比。
    static func rectRatio(_ m: PhotoMetrics, rect: CGRect) -> Double {
        var picked: [Double] = []
        for r in 0..<m.rows {
            for c in 0..<m.cols {
                let cx = (Double(c) + 0.5) / Double(m.cols)
                let cy = (Double(r) + 0.5) / Double(m.rows)
                if cx >= rect.minX, cx <= rect.maxX, cy >= rect.minY, cy <= rect.maxY {
                    picked.append(m.scores[r * m.cols + c])
                }
            }
        }
        return picked.isEmpty ? m.centerRatio
            : percentile(picked, 0.5) / max(m.globalHi, 1e-6)
    }

    /// 只有前景分割/人脸这种可信定位，主体锐度比才算数；
    /// 显著性兜底时它往往框到背景，退回中心区比，避免把「主体失焦/背景清晰」误放行。
    static func effectiveSubjectRatio(_ m: PhotoMetrics) -> Double {
        (m.subjectSource == "前景主体" || m.subjectSource == "人脸检测")
            ? m.ratio : m.centerRatio
    }

    /// 独立判定基准：不再从本批照片里找 P75，每张照片用同一把固定标尺。
    /// 400 是在 Canon EOS R6m2/R7 的 50 张真值样本上标定的（对应旧版该批 P75×0.15=426），
    /// 只适用于同类机型/镜头/题材；换设备后需要用真值重新标定这把尺子。
    static let independentFloor = 400.0

    static func independentThreshold(sensitivity: Double = 1.0,
                                     anchor: Double? = nil) -> Double {
        if let a = anchor, a > 0 { return a * 0.15 * sensitivity }
        return independentFloor * sensitivity
    }

    /// 保留旧签名供命令行/报告兼容；参数 all 已不再参与计算。
    static func referenceThreshold(_ all: [PhotoMetrics], sensitivity: Double = 1.0,
                                   anchor: Double? = nil) -> Double {
        independentThreshold(sensitivity: sensitivity, anchor: anchor)
    }

    static func classify(_ m: PhotoMetrics, hiMin: Double,
                         subjectOverride: Double? = nil) -> (Verdict, String) {
        if m.globalHi <= 0 { return (.unreadable, "图像无法解析") }
        if m.anisotropy > 2.2 && (m.softRatio > 0.85 || m.globalHi < hiMin) {
            return (.motionBlur,
                    String(format: "方向性 %.1f、偏软占比 %.0f%%，更像运动模糊/拖影，未计入失焦",
                           m.anisotropy, m.softRatio * 100))
        }
        if m.globalHi < hiMin {
            return (.globalBlur,
                    String(format: "全片最锐区 %.0f，低于批次基准 %.0f，疑似整体脱焦/衍射", m.globalHi, hiMin))
        }
        // 以下规则用 50 张真实 RAW + 人工真值标定（召回 13/13，误杀 1/37）。
        // 注意：这是经验规则，换机型/题材后必须重新标注标定，不要当成通用阈值。
        let f = subjectOverride ?? Self.effectiveSubjectRatio(m)
        let g = m.centerRatio, h = m.ratio
        if m.subjectSource == "前景主体" {
            // 中心区明显比主体区更锐 → 焦点大概率跑到了别处
            if g - f > 0.03 && f < 0.25 {
                return (.subjectBlur,
                        String(format: "中心区锐度 %.2f 高于主体区 %.2f，疑似焦点跑偏", g, f))
            }
            // 主体本身很弱、再模糊一次几乎不掉细节 → 主体确实发虚
            if f < 0.10 && m.subjectReblur < 0.12 && m.softRatio < 0.85 {
                return (.subjectBlur,
                        String(format: "主体锐度比 %.2f 且重模糊比 %.2f，疑似主体失焦", f, m.subjectReblur))
            }
        } else if m.subjectSource == "显著性区域" {
            // 显著性兜底时主体比反而偏高、且中心区偏软，真值中对应失焦片
            if h > 0.105 && f < 0.25 {
                return (.subjectBlur,
                        String(format: "主体区锐度比 %.2f 而中心区仅 %.2f，疑似焦点跑偏", h, f))
            }
        } else if f < 0.35 {
            return (.subjectBlur,
                    String(format: "主体区锐度仅为最锐区的 %.0f%%，疑似焦点跑偏", f * 100))
        }
        return (.pass, "主体区锐度与画面最锐区接近，未见明显失焦")
    }

    static func decide(_ all: [PhotoMetrics], sensitivity: Double = 1.0,
                       anchor: Double? = nil) -> [PhotoResult] {
        let hiMin = referenceThreshold(all, sensitivity: sensitivity, anchor: anchor)
        return all.map { m in
            let (v, why) = classify(m, hiMin: hiMin)
            return PhotoResult(id: m.url, metrics: m, verdict: v, reason: why)
        }
    }
}
