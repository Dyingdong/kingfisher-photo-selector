import Foundation

/// App 与命令行工具共用同一份报告格式，避免「界面导出的」和「脚本验证的」对不上。
enum Report {
    static let columns = [
        "文件名", "判定",
        "最锐区P99", "批次基准", "基准余量", "判定用锐度比",
        "中心锐度比", "主体锐度比", "主体重模糊比", "偏软占比", "分布差", "重模糊比", "方向性",
        "宽", "高", "主体定位", "人工圈选", "灵敏度", "基准来源",
        "人工真值", "复核备注", "判定原因", "完整路径", "最锐块",
        // 题材与评分（App 导出时填写；命令行工具没算题材则为空）。
        // 刻意追加在末尾，不打乱前面列的顺序——verify.py / score 探针按列号读人工真值。
        "自动题材", "题材依据", "最终题材", "人工指定", "建议星级", "综合分",
        // 对焦失误提示（只提示、不改判定）：疑似焦点拧偏时给出线索，供人工排除。
        "对焦失误提示", "对焦失误说明",
        // 主体占画幅比例（最大实例包围盒面积）。追加在末尾，不影响 verify.py 的列号。
        "主体面积",
        // 最大主体框坐标（归一化、左下原点：x|y|w|h），供离线裁剪实验用；无框为空。
        "主体框",
        // 鸟种识别（继续追加在末尾，不打乱旧列号）。
        "识别鸟种", "鸟种置信", "鸟种来源", "鸟种依据", "鸟种Top3",
    ]

    /// 每张照片的题材/评分摘要，由 App 在导出前算好传入。
    struct GenreRecord {
        let autoGenre: String      // 纯规则识别（不含纠正记忆与人工指定）
        let reason: String         // 最终采用的识别依据（含纠正记忆套用说明）
        let finalGenre: String     // 实际生效的题材
        let manualGenre: String?   // 用户手动指定的题材（nil = 没改过）
        let stars: Int
        let total: Int
    }

    /// 鸟种摘要，由 App 从鸟种日志取最终采用值传入；命令行工具不填。
    struct BirdInfo {
        let name: String
        let confidence: Double
        let source: String
        let reason: String
        let top3: String
    }

    static func q(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func f(_ x: Double, _ digits: Int = 3) -> String {
        String(format: "%.\(digits)f", x)
    }

    /// 「判定用锐度比」记录真正参与判定的那个值（人工圈选后会被替换），
    /// 便于离线重算灵敏度、复现判定，而不是只看到一个结果标签。
    static func effectiveRatio(_ r: PhotoResult) -> Double {
        if let rect = r.overrideRect {
            return Analyzer.rectRatio(r.metrics, rect: rect)
        }
        return Analyzer.effectiveSubjectRatio(r.metrics)
    }

    static func csv(_ results: [PhotoResult], hiMin: Double, sensitivity: Double,
                    anchor: Double? = nil,
                    genres: [URL: GenreRecord] = [:],
                    focusMiss: [URL: FocusMissDiagnosis] = [:],
                    birds: [URL: BirdInfo] = [:]) -> String {
        var lines = [columns.joined(separator: ",")]
        for r in results {
            let m = r.metrics
            let g = genres[r.id]
            let b = birds[r.id]
            let fields = [
                q(r.id.lastPathComponent), q(r.verdict.rawValue),
                f(m.globalHi, 1), f(hiMin, 1),
                f(m.globalHi / max(hiMin, 1e-6)), f(effectiveRatio(r)),
                f(m.centerRatio), f(m.ratio), f(m.subjectReblur), f(m.softRatio), f(m.spread),
                f(m.reblurRatio), f(m.anisotropy, 2),
                String(m.width), String(m.height),
                q(m.subjectSource), r.overrideRect == nil ? "否" : "是",
                f(sensitivity, 2), q(anchor == nil ? "独立固定阈值" : "固定锚点"),
                "", "", q(r.reason), q(r.id.path), f(m.scores.max() ?? 0, 1),
                q(g?.autoGenre ?? ""), q(g?.reason ?? ""), q(g?.finalGenre ?? ""),
                q(g?.manualGenre ?? ""),
                g.map { String($0.stars) } ?? "", g.map { String($0.total) } ?? "",
                q(focusMiss[r.id]?.short ?? ""), q(focusMiss[r.id]?.detail ?? ""),
                f(m.bboxes.map { $0.width * $0.height }.max() ?? 0),
                q(m.bboxes.max { $0.width * $0.height < $1.width * $1.height }
                    .map { [ $0.origin.x, $0.origin.y, $0.width, $0.height ]
                        .map { f($0, 4) }.joined(separator: "|") } ?? ""),
                q(b?.name ?? ""), b.map { f($0.confidence, 3) } ?? "",
                q(b?.source ?? ""), q(b?.reason ?? ""), q(b?.top3 ?? ""),
            ]
            lines.append(fields.joined(separator: ","))
        }
        // BOM 让 Excel / Numbers 直接双击不乱码
        return "\u{FEFF}" + lines.joined(separator: "\n") + "\n"
    }
}
