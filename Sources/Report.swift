import Foundation

/// App 与命令行工具共用同一份报告格式，避免「界面导出的」和「脚本验证的」对不上。
enum Report {
    static let columns = [
        "文件名", "判定",
        "最锐区P99", "批次基准", "基准余量", "判定用锐度比",
        "中心锐度比", "主体锐度比", "主体重模糊比", "偏软占比", "分布差", "重模糊比", "方向性",
        "宽", "高", "主体定位", "人工圈选", "灵敏度", "基准来源",
        "人工真值", "复核备注", "判定原因", "完整路径", "最锐块",
    ]

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
                    anchor: Double? = nil) -> String {
        var lines = [columns.joined(separator: ",")]
        for r in results {
            let m = r.metrics
            let fields = [
                q(r.id.lastPathComponent), q(r.verdict.rawValue),
                f(m.globalHi, 1), f(hiMin, 1),
                f(m.globalHi / max(hiMin, 1e-6)), f(effectiveRatio(r)),
                f(m.centerRatio), f(m.ratio), f(m.subjectReblur), f(m.softRatio), f(m.spread),
                f(m.reblurRatio), f(m.anisotropy, 2),
                String(m.width), String(m.height),
                q(m.subjectSource), r.overrideRect == nil ? "否" : "是",
                f(sensitivity, 2), q(anchor == nil ? "独立固定阈值" : "固定锚点"),
                "", "", q(r.reason), q(r.id.path), f(m.scores.max() ?? 0, 1)
            ]
            lines.append(fields.joined(separator: ","))
        }
        // BOM 让 Excel / Numbers 直接双击不乱码
        return "\u{FEFF}" + lines.joined(separator: "\n") + "\n"
    }
}
