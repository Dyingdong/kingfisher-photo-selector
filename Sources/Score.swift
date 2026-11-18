import Foundation

// MARK: - 题材

/// 照片题材。评分权重按题材不同；自动识别后可人工覆盖。
enum PhotoGenre: String, CaseIterable, Identifiable, Codable {
    case bird       = "拍鸟"
    case landscape  = "风光"
    case portrait   = "人像"

    var id: String { rawValue }

    /// 该题材的一句话评分口径，界面上直接给用户看。
    var rule: String {
        switch self {
        case .bird:      return "看重主体清晰、锐度高"
        case .landscape: return "先看主体清晰度，再看整体锐度；构图看辅助线"
        case .portrait:  return "看对焦点在哪、人脸是否清晰、白平衡是否准"
        }
    }
}

// MARK: - 评分维度

/// 一个可解释的评分维度。分数与权重都公开，用户能自己核算。
struct ScorePart: Identifiable {
    let id: String
    let name: String
    let score: Double      // 0~100
    let weight: Double     // 0~1，界面显示百分比
    let detail: String     // 大白话依据 + 关键数值

    var contribution: Double { score * weight }
}

/// 一张照片的综合评分结果。
struct PhotoScore {
    let genre: PhotoGenre
    let genreIsGuess: Bool      // true = 软件自动识别，false = 用户手动指定
    let genreReason: String     // 自动识别依据（人看了能核对）
    let stars: Int              // 建议星级 1...5，直接对应现有 Bridge 5 星层
    let total: Double           // 0~100，加权总分
    let parts: [ScorePart]
    let headline: String        // 一句大白话总评
    let tips: [String]          // 题材相关的补充说明

    /// 主要短板（得分最低且权重不为零的维度），用于解释为什么不是更高星。
    var weakest: ScorePart? { parts.min { $0.score < $1.score } }

    /// 合焦判定决定的星级上限。失焦/拖影属于硬伤，其他维度再高也不能拿高星
    /// ——与慧眼识鸟「失焦直接降星」一致，也是选片时最直接的一道门槛。
    static func starCap(for v: Verdict) -> Int {
        switch v {
        case .pass:       return 5
        case .depthIssue: return 3
        case .subjectBlur: return 2
        case .globalBlur, .motionBlur, .unreadable: return 1
        }
    }
}

// MARK: - 评分引擎

/// 综合评分引擎。参考「慧眼识鸟」的双维度达标思路（清晰 + 整体质量都达标才算精品），
/// 但维度全部取自本项目已经可解释、可复核的指标，不引入无法验证的美学模型。
///
/// 重要边界：
/// - 相机对焦点只参与「人像」题材的评分微调，不改变原有的合焦判定；
///   实测 9 张真废片里 7 张焦点就在主体上，焦点位置不能等同合焦。
/// - 构图没有可靠的自动打分依据，不进入分数，交给九宫格/对角线辅助线人工判断。
/// - 所有阈值都是在这批 Canon EOS R6m2 / R7 样本上标定的经验值，换设备需重新标定。
enum ScoreEngine {

    // MARK: 题材自动识别

    /// 自动猜题材，返回 (题材, 识别依据)。依据会显示在界面上，方便核对为什么这么判。
    /// 规则按优先级（每条都不依赖主体定位方式，避免「长焦打鸟却因主体框大被判风光」）：
    /// 1) 明确的人脸信号 → 人像（优先，防止长焦人像被误判成鸟）；
    /// 2) 打鸟镜头 / 超长焦（≥300mm）→ 拍鸟；
    /// 3) 中长焦（200~300mm）且有识别主体 → 拍鸟；
    /// 4) 前景小主体 → 拍鸟；
    /// 5) 其余 → 风光。
    /// 只是「猜测」，界面明确标注并允许用户手动改。
    static func guessGenre(m: PhotoMetrics, af: AFInfo?, wb: WhiteBalanceStats?,
                           exif: ExifInfo?) -> (PhotoGenre, String) {
        var subjectArea = 0.0
        for b in m.bboxes { subjectArea += Double(b.width * b.height) }

        let focal = exif.flatMap { parseFocal($0.focalLength) } ?? 0
        let lensMax = exif.flatMap { $0.lens }.flatMap { parseLensMaxFocal($0) } ?? 0
        let hasForeground = m.subjectSource == "前景主体"
            || m.subjectSource == "人脸检测"
            || m.subjectSource == "显著性区域"

        // 1) 人脸优先：长焦也能拍人，先把人像摘出来。
        let faceMode = af?.modeName.contains("人脸") ?? false
        if wb?.faceRG != nil || m.subjectSource == "人脸检测" || faceMode {
            let why = faceMode ? "相机用人脸对焦模式" : "检测到人脸"
            return (.portrait, why)
        }

        // 2) 打鸟镜头或超长焦：RF200-800 / 100-500 / 150-600 这类，或实际焦距≥300mm。
        if lensMax >= 400 || focal >= 300 {
            let bits = [focal > 0 ? "焦距 \(Int(focal))mm" : nil,
                        exif?.lens].compactMap { $0 }
            return (.bird, bits.joined(separator: " · "))
        }

        // 3) 中长焦 200~300mm 且有主体：多数是生态/打鸟。
        if focal >= 200 && focal < 300 && hasForeground {
            return (.bird, "中长焦 \(Int(focal))mm 且有识别主体")
        }

        // 4) 前景小主体（小鸟占画面很小一块）。
        if m.subjectSource == "前景主体" && subjectArea > 0 && subjectArea < 0.25 {
            return (.bird, "前景主体只占画面 \(Int(subjectArea * 100))%")
        }

        return (.landscape, "无长焦/人脸的强信号")
    }

    /// 从格式化焦距串（如 "600mm" / "208mm"）取数值。
    private static func parseFocal(_ s: String?) -> Double? {
        guard let s = s else { return nil }
        let nums = s.split(whereSeparator: { !$0.isNumber && $0 != "." })
        for n in nums {
            if let v = Double(n), v >= 10 { return v }
        }
        return nil
    }

    /// 从镜头型号（如 "RF200-800mm F6.3-9 IS USM"）取最大焦距端，
    /// 用来识别打鸟镜头。取所有整数里的最大值：200-800→800，24-105→105。
    private static func parseLensMaxFocal(_ s: String) -> Double? {
        var best = 0.0
        var cur = ""
        func flush() {
            if let v = Double(cur), v >= 10 { best = max(best, v) }
            cur = ""
        }
        for ch in s {
            if ch.isNumber || ch == "." { cur.append(ch) }
            else { flush() }
        }
        flush()
        return best > 0 ? best : nil
    }

    // MARK: 各维度打分

    private static func clamp(_ x: Double, _ lo: Double = 0, _ hi: Double = 100) -> Double {
        min(hi, max(lo, x))
    }

    /// 主体清晰度：主体（或推测主体时的中心区）相对全图最锐块的比例。
    /// 达到 60% 即算满分——对焦准确时主体本就是最锐的一块。
    private static func clarityScore(_ m: PhotoMetrics) -> (Double, String) {
        let trusted = m.subjectSource == "前景主体" || m.subjectSource == "人脸检测"
        let rel = trusted ? m.displaySubjectRatio
                          : max(m.displaySubjectRatio, m.displayCenterRatio)
        let s = clamp(rel / 0.60 * 100)
        let who = trusted ? "主体" : "中心区（没识别出明确主体）"
        return (s, String(format: "%@清晰度是最锐处的 %.0f%%", who, rel * 100))
    }

    /// 整体锐度（热力图口径）：以固定合格线 400 为锚点，兼顾发虚区域占比。
    /// 400→60 分，1600→100 分；低于 400 线性下降。
    private static func overallScore(_ m: PhotoMetrics) -> (Double, String) {
        let g = m.globalHi
        let abs: Double
        if g <= 0 { abs = 0 }
        else if g < Analyzer.independentFloor {
            abs = 60 * g / Analyzer.independentFloor
        } else {
            let ratio = max(1, g / Analyzer.independentFloor)
            abs = 60 + 40 * clamp(log(ratio) / log(4), 0, 1)
        }
        let clean = clamp((1 - m.softRatio) / 0.30 * 100)
        let s = clamp(0.8 * abs + 0.2 * clean)
        return (s, String(format: "最锐区 %.0f（合格线 %.0f）· 发虚 %.0f%%",
                          g, Analyzer.independentFloor, m.softRatio * 100))
    }

    /// 合焦 / 对焦准确度：以已经标定的合焦判定为主，相机对焦点只做小幅微调。
    private static func focusScore(_ m: PhotoMetrics, verdict: Verdict,
                                   af: AFInfo?) -> (Double, String) {
        var s: Double
        switch verdict {
        case .pass:        s = 100
        case .depthIssue:  s = 55
        case .subjectBlur: s = 30
        case .globalBlur:  s = 15
        case .motionBlur:  s = 10
        case .unreadable:  s = 0
        }
        var note = verdict.rawValue
        if let af = af, !af.points.isEmpty {
            let rel = Analyzer.afSubjectRelation(m, af: af)
            if rel.0 == "焦点在主体上" {
                s = clamp(s + 5); note += " · 焦点落在主体上"
            } else if rel.0 == "焦点在主体外" {
                s = clamp(s - 10); note += " · 焦点落在主体外"
            }
        }
        return (s, note)
    }

    /// 白平衡 / 曝光：以人脸偏色优先（人像看肤色），再看高光与死黑占比。
    private static func wbScore(_ wb: WhiteBalanceStats?) -> (Double, String)? {
        guard let wb = wb else { return nil }
        let g = max(wb.meanG, 1)
        let rg = wb.faceRG ?? (wb.meanR / g)
        let bg = wb.faceBG ?? (wb.meanB / g)
        let dev = max(abs(rg - 1), abs(bg - 1))
        let scope = wb.faceRG != nil ? "人脸" : "全图"
        var s = 100 - clamp(dev / 0.30 * 100) * 0.5
        s -= clamp(wb.highlightClip * 100 * 2)
        s -= clamp(wb.shadowClip * 100)
        s = clamp(s)
        return (s, String(format: "%@红:蓝 %.2f:%.2f · 过曝 %.1f%% · 死黑 %.1f%%",
                          scope, rg, bg, wb.highlightClip * 100, wb.shadowClip * 100))
    }

    // MARK: 综合

    /// 主入口：算出建议星级与全部可解释维度。af / wb / exif 可为 nil（缺失的维度不参与加权）。
    static func score(_ r: PhotoResult, af: AFInfo?, wb: WhiteBalanceStats?,
                      exif: ExifInfo?, genre: PhotoGenre, genreIsGuess: Bool,
                      genreReason: String = "") -> PhotoScore {
        let m = r.metrics
        let clarity = clarityScore(m)
        let overall = overallScore(m)
        let focus = focusScore(m, verdict: r.verdict, af: af)
        let color = wbScore(wb)

        // 题材权重。参考慧眼识鸟「清晰 + 质量双达标」，清晰度始终是主轴。
        var weights: [String: Double]
        switch genre {
        case .bird:
            weights = ["clarity": 0.45, "overall": 0.30, "focus": 0.25, "color": 0]
        case .landscape:
            weights = ["clarity": 0.35, "overall": 0.45, "focus": 0.20, "color": 0]
        case .portrait:
            weights = ["clarity": 0.30, "overall": 0.10, "focus": 0.35, "color": 0.25]
        }
        if color == nil { weights["color"] = 0 }

        let sum = weights.values.reduce(0, +)
        if sum > 0 { for k in weights.keys { weights[k]! /= sum } }

        var parts: [ScorePart] = [
            ScorePart(id: "clarity", name: "主体清晰度", score: clarity.0,
                      weight: weights["clarity"] ?? 0, detail: clarity.1),
            ScorePart(id: "overall", name: "整体锐度（热力图）", score: overall.0,
                      weight: weights["overall"] ?? 0, detail: overall.1),
            ScorePart(id: "focus", name: "对焦准确度", score: focus.0,
                      weight: weights["focus"] ?? 0, detail: focus.1)
        ]
        if let c = color {
            parts.append(ScorePart(id: "color", name: "白平衡 / 曝光", score: c.0,
                                   weight: weights["color"] ?? 0, detail: c.1))
        }
        parts.sort { $0.weight > $1.weight }

        let total = parts.reduce(0) { $0 + $1.contribution }

        // 先按加权总分定星，再用合焦硬门槛压顶：失焦片不会靠「整体锐度高」拿高星。
        var stars = total >= 85 && clarity.0 >= 60 ? 5
                  : total >= 70 ? 4
                  : total >= 50 ? 3
                  : total >= 32 ? 2 : 1
        stars = min(stars, PhotoScore.starCap(for: r.verdict))

        let headline = Self.headline(stars: stars, verdict: r.verdict, weakest: parts.min {
            $0.score < $1.score
        })
        var tips: [String] = []
        switch genre {
        case .bird:
            tips.append("主体占比小、大面积虚化属正常，分数主要看主体与最锐处。")
        case .landscape:
            tips.append("构图不计入自动分：打开工具栏的九宫格/对角线，自己看主体是否压线。")
        case .portrait:
            tips.append("对焦位置只作评分参考，不改变原来的合焦判定。")
            if wb?.faceRG == nil { tips.append("没检测到人脸，白平衡按整张照片估算。") }
        }
        if genreIsGuess { tips.append("题材是软件猜的，不对的话在上面手动改成正确题材。") }

        return PhotoScore(genre: genre, genreIsGuess: genreIsGuess,
                          genreReason: genreReason, stars: stars,
                          total: total, parts: parts, headline: headline, tips: tips)
    }

    private static func headline(stars: Int, verdict: Verdict, weakest: ScorePart?) -> String {
        switch stars {
        case 5: return "主体清楚、整体锐利，是值得精修的一张。"
        case 4: return "整体清晰可用，个别地方还能再挑一挑。"
        case 3: return "能看，但清晰度和题材表现都只是一般。"
        case 2:
            if let w = weakest { return "主要差在「\(w.name)」，留作备选比较合适。" }
            return "画面明显偏软，留作备选。"
        default:
            if verdict == .motionBlur { return "有拖影或抖动痕迹，建议淘汰。" }
            return "失焦或画质太差，建议淘汰。"
        }
    }
}
