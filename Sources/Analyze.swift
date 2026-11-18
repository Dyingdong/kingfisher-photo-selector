import Foundation
import CoreGraphics
import ImageIO

enum Verdict: String {
    case pass = "合焦"
    case globalBlur = "全片未合焦"
    case subjectBlur = "主体未合焦"
    case depthIssue = "景深不足"
    case motionBlur = "运动模糊/拖影"
    case unreadable = "无法解码"

    var isSuspect: Bool {
        self == .globalBlur || self == .subjectBlur || self == .depthIssue
    }
}

struct PhotoMetrics {
    let url: URL
    let globalHi: Double
    /// 全图最锐的单个分块读数（最大值）。判定仍用 globalHi=P99，
    /// 但界面上"按最清楚的地方算100%"的百分比以它作分母：
    /// 极小主体（拍鸟）时 P99 会被大面积平坦背景拉到很低，主体块却很锐，
    /// 用 P99 作分母会算出 2159% 这种违反语义的爆表值。
    let peakBlock: Double
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

    /// 界面显示用：主体相对"全图最锐那一块"的比值，恒在 0~1，不会爆表。
    /// 判定仍用 ratio（对 P99），两者用途不同，不要混用。
    var displaySubjectRatio: Double {
        subjectScore / max(peakBlock, 1e-6)
    }
    /// 界面显示用：中心区相对最锐块的比值。centerRatio×globalHi 还原出中心块读数。
    var displayCenterRatio: Double {
        (centerRatio * globalHi) / max(peakBlock, 1e-6)
    }
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
            url: url, globalHi: hi, peakBlock: scores.max() ?? hi, subjectScore: s,
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
    /// 传入的 rect 是 Vision 坐标（y=0 在底部、y=1 在顶部），而 scores 的第 r 行
    /// r=0 是图像顶部（与热力图绘制一致）。因此比较前先把 rect 的 y 翻转成
    /// 「顶部为 0」，否则圈上方会算到下方、圈下方会算到上方（曾导致圈清晰主体却显示 0%）。
    static func rectRatio(_ m: PhotoMetrics, rect: CGRect) -> Double {
        var picked: [Double] = []
        let topMinY = 1 - rect.maxY
        let topMaxY = 1 - rect.minY
        for r in 0..<m.rows {
            for c in 0..<m.cols {
                let cx = (Double(c) + 0.5) / Double(m.cols)
                let cy = (Double(r) + 0.5) / Double(m.rows)
                if cx >= rect.minX, cx <= rect.maxX, cy >= topMinY, cy <= topMaxY {
                    picked.append(m.scores[r * m.cols + c])
                }
            }
        }
        return picked.isEmpty ? m.centerRatio
            : percentile(picked, 0.5) / max(m.globalHi, 1e-6)
    }

    /// 界面显示用：圈选区相对全图最锐块的比值，恒在 0~1。
    /// rectRatio（对 P99）留给判定/报告，避免影响已标定的判定。
    static func rectDisplayRatio(_ m: PhotoMetrics, rect: CGRect) -> Double {
        var picked: [Double] = []
        let topMinY = 1 - rect.maxY
        let topMaxY = 1 - rect.minY
        for r in 0..<m.rows {
            for c in 0..<m.cols {
                let cx = (Double(c) + 0.5) / Double(m.cols)
                let cy = (Double(r) + 0.5) / Double(m.rows)
                if cx >= rect.minX, cx <= rect.maxX, cy >= topMinY, cy <= topMaxY {
                    picked.append(m.scores[r * m.cols + c])
                }
            }
        }
        let base = picked.isEmpty ? (m.centerRatio * m.globalHi) : percentile(picked, 0.5)
        return base / max(m.peakBlock, 1e-6)
    }

    /// 只有前景分割/人脸这种可信定位，主体锐度比才算数；
    /// 显著性兜底时它往往框到背景，退回中心区比，避免把「主体未合焦/背景清晰」误放行。
    static func effectiveSubjectRatio(_ m: PhotoMetrics) -> Double {
        (m.subjectSource == "前景主体" || m.subjectSource == "人脸检测")
            ? m.ratio : m.centerRatio
    }

    /// 相机对焦点与 AI 主体区域的空间关系【仅界面提示，不参与判定】。
    /// 实测：焦点落在主体上并不等于合焦（9 张真废片里有 7 张焦点就在主体上），
    /// 所以这项只能当旁证/解释，绝不能拿它改判定。返回 (短标签, 说明)。
    static func afSubjectRelation(_ m: PhotoMetrics, af: AFInfo?) -> (String, String) {
        guard let af = af, let p = af.points.first, !af.points.isEmpty else {
            return ("无对焦点数据", "这张照片没有相机对焦点记录，本项仅供参考")
        }
        let fc = min(m.cols - 1, max(0, Int(p.cx * Double(m.cols))))
        let fr = min(m.rows - 1, max(0, Int(p.cy * Double(m.rows))))
        let onWeight = m.weights[fr * m.cols + fc]
        var minD = 1.0
        for r in 0..<m.rows {
            for c in 0..<m.cols where m.weights[r * m.cols + c] > 0.45 {
                let cc = (Double(c) + 0.5) / Double(m.cols)
                let cr = (Double(r) + 0.5) / Double(m.rows)
                minD = min(minD, hypot(cc - p.cx, cr - p.cy))
            }
        }
        let xPct = Int(p.cx * 100), yPct = Int(p.cy * 100)
        let pos = "横向\(xPct)%／纵向\(yPct)%"
        if m.subjectSource == "中心权重" {
            return ("主体靠推测", "AI 没识别出明确主体（位置靠中心推测），本项意义有限；焦点在\(pos)")
        }
        if onWeight > 0.45 || minD < 0.05 {
            return ("焦点在主体上", "相机对焦点（\(pos)）落在 AI 主体区，对焦意图正确；清不清楚仍以主体清晰度为准")
        }
        return ("焦点在主体外", "相机对焦点（\(pos)）在 AI 主体区外，留意焦点是否跑偏；仅作参考，判定仍看锐度")
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
        // 判定说明一律用大白话：让不懂「锐度比/重模糊比」的人也能一眼明白问题在哪。
        // 具体数值仍可在信息区的「判断依据」里查看，这里只给结论和原因。
        if m.anisotropy > 2.2 && (m.softRatio > 0.85 || m.globalHi < hiMin) {
            return (.motionBlur, "画面有明显的拖影或抖动痕迹，整张偏软")
        }
        if m.globalHi < hiMin {
            return (.globalBlur, "整张照片都不够清晰，像是整体没对上焦")
        }
        // 以下规则用 50 张真实 RAW + 人工真值标定（召回 13/13，误杀 1/37）。
        // 注意：这是经验规则，换机型/题材后必须重新标注标定，不要当成通用阈值。
        let f = subjectOverride ?? Self.effectiveSubjectRatio(m)
        let g = m.centerRatio, h = m.ratio
        if m.subjectSource == "前景主体" {
            // 中心区明显比主体区更锐 → 焦点大概率跑到了别处
            if g - f > 0.03 && f < 0.25 {
                return (.subjectBlur, "主体是虚的，反倒是画面中心更清楚——焦大概率对偏了")
            }
            // 主体本身很弱、再模糊一次几乎不掉细节 → 主体确实发虚
            if f < 0.10 && m.subjectReblur < 0.12 && m.softRatio < 0.85 {
                return (.subjectBlur, "主体本身发虚，看不清细节")
            }
        } else if m.subjectSource == "显著性区域" {
            // 显著性兜底时主体比反而偏高、且中心区偏软，真值中对应未合焦片
            if h > 0.105 && f < 0.25 {
                return (.subjectBlur, "主体不够清楚，焦点可能落在了别处")
            }
        } else if f < 0.35 {
            return (.subjectBlur, "主体明显偏软，焦点可能没落在主体上")
        }
        return (.pass, "主体清晰，对焦正常")
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


/// 手动对焦失误诊断【只提示、不改判定、不改评分】。
/// 场景：相机合焦点落在主体上（或主体附近），但那一点并不锐，画面别处却很锐——
/// 说明焦点落在了主体前后（手动对焦时没拧到位 / 自动对焦被前景骗了），主体自然虚。
/// 目的是让用户据此排除这类片子；故意虚化主体的照片也会命中，所以只给线索不自动delete。
struct FocusMissDiagnosis {
    let suspected: Bool      // 是否疑似对焦落点失误
    let short: String        // 短标签
    let detail: String       // 白话解释
    let focusMethod: String  // 对焦方式：手动 / 自动 / 未知（用户定义的判定）
}

/// 对焦方式判定（用户定义规则）：
/// - 没有镜头信息 → 一定是手动对焦（自动对焦相机一定会记录镜头）；
/// - 有镜头信息但没有对焦点数据 → 也是手动对焦（自动对焦会记录 AF 点）；
/// - 相机 AFAreaMode=0（ExifTool 的 Manual）→ 手动对焦；
/// - 其余 → 自动对焦。
/// 这是「这台相机当时是不是靠人拧焦环」的最可靠近似，用于解释为何主体会因
/// 手动拧偏而虚——不同自动对焦失败，手动对焦失误是可以靠提示排除的。
enum FocusMethod {
    static func judge(lens: String?, af: AFInfo?) -> (isManual: Bool, text: String) {
        if lens == nil || (lens?.isEmpty ?? true) {
            return (true, "手动对焦（没记录镜头信息，自动对焦相机会记录）")
        }
        guard let af = af else {
            return (true, "手动对焦（有镜头信息但没有对焦点记录）")
        }
        if af.mode == 0 {
            return (true, "手动对焦（相机记录为 Manual 对焦模式）")
        }
        return (false, "自动对焦（相机记录为「\(af.modeName)」）")
    }
}

enum FocusMiss {
    /// 判据（真值复盘后收紧）：
    /// 1. 必须有相机合焦点数据（无数据不能猜）；
    /// 2. 画面别处确实很锐（最锐块 ≥ 合格线，说明不是整体发虚）；
    /// 3. 对焦点处的锐度明显低于最锐处（< 35%，说明焦点没对到实处）；
    /// 4. 最锐块离合焦点有距离（≥ 8% 画幅，避免把对焦点附近的小抖动当失误）；
    /// 5. 主体本身不锐（显示锐度比 < 25%，确认主体确实虚了）。
    static func diagnose(_ m: PhotoMetrics, af: AFInfo?, verdict: Verdict,
                         lens: String? = nil) -> FocusMissDiagnosis {
        let method = FocusMethod.judge(lens: lens, af: af)
        let manualNote = method.isManual ? "；这张是手动对焦，焦点需人工拧准，失误更常见" : ""

        guard let af = af, let p = af.points.first, !af.points.isEmpty else {
            // 没有 AF 点：若是手动对焦，用「主体虚 + 别处锐」给一条更实用的提示。
            // 没有对焦点坐标，无法算焦点偏移，只能提示主体清晰度这一可核对信号。
            if method.isManual, verdict.isSuspect, m.peakBlock >= Analyzer.independentFloor,
               m.displaySubjectRatio < 0.25 {
                return FocusMissDiagnosis(
                    suspected: true, short: "手动对焦：主体偏虚",
                    detail: "\(method.text)。相机没有合焦点记录，无法判断焦点落在哪里；"
                          + "但主体清晰度只有最锐处的 \(Int(m.displaySubjectRatio * 100))%，"
                          + "而画面别处有清晰区域（最锐处 \(Int(m.peakBlock))）。"
                          + "像是手动对焦没拧到位。故意虚化主体的照片也会这样，请自行确认",
                                      focusMethod: method.text)
            }
            return FocusMissDiagnosis(suspected: false, short: method.isManual ? "手动对焦·无焦点数据" : "无对焦数据",
                                      detail: "\(method.text)。相机没有合焦点记录，无法判断对焦是否拧到位",
                                      focusMethod: method.text)
        }
        let xPct = Int(p.cx * 100), yPct = Int(p.cy * 100)
        let pos = "横向\(xPct)%／纵向\(yPct)%"
        let peak = m.peakBlock
        guard peak >= Analyzer.independentFloor, m.scores.count == m.cols * m.rows else {
            return FocusMissDiagnosis(suspected: false, short: "全片偏软",
                                      detail: "整张照片都不够锐（最锐处 \(Int(peak))），不像是对焦点拧偏，更像整体没对上\(manualNote)",
                                      focusMethod: method.text)
        }
        let fc = min(m.cols - 1, max(0, Int(p.cx * Double(m.cols))))
        let fr = min(m.rows - 1, max(0, Int(p.cy * Double(m.rows))))
        let focusSharp = m.scores[fr * m.cols + fc]
        let focusRatio = focusSharp / peak
        // 最锐块的位置
        var peakIdx = 0
        for i in 1..<m.scores.count where m.scores[i] > m.scores[peakIdx] { peakIdx = i }
        let pc = (Double(peakIdx % m.cols) + 0.5) / Double(m.cols)
        let pr = (Double(peakIdx / m.cols) + 0.5) / Double(m.rows)
        let dist = hypot(pc - p.cx, pr - p.cy)
        let subject = m.displaySubjectRatio

        let miss = verdict.isSuspect && focusRatio < 0.35 && dist >= 0.08 && subject < 0.25
        if miss {
            return FocusMissDiagnosis(
                suspected: true, short: "疑似对焦拧偏",
                detail: "合焦点在\(pos)，但那一点只有全图最锐处的 \(Int(focusRatio * 100))%；"
                      + "最锐的地方离合焦点约 \(Int(dist * 100))% 画幅，主体也只有 \(Int(subject * 100))%。"
                      + "像是手动对焦没拧到位（焦点落在主体前后）。注意：故意虚化主体的照片也会这样，请自行确认\(manualNote)",
                focusMethod: method.text)
        }
        return FocusMissDiagnosis(
            suspected: false, short: "未见明显拧偏",
            detail: "合焦点在\(pos)，焦点处锐度是最锐处的 \(Int(focusRatio * 100))%，"
                  + "离最锐处约 \(Int(dist * 100))% 画幅。没有明显的对焦点落空迹象\(manualNote)",
            focusMethod: method.text)
    }
}
