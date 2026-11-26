import Foundation

// MARK: - 鸟种样本日志
//
// 用户要求：日志放在照片根目录、文件名可见（不是隐藏文件），随照片一起走；
// 识别结果、云端候选、人工确认持续叠加；导出 CSV 必须带照片根目录绝对路径。
// 只读卷（例如直接读相机卡）写不进去时，回退到 Application Support 下的同名日志。

struct BirdRecord: Codable, Hashable {
    var time: String
    var file: String
    var name: String          // 最终采用的中文鸟名
    var latin: String
    var confidence: Double
    var source: String        // 本地识别 / 云端候选 / 人工确认
    var reason: String
    var root: String          // 照片根目录绝对路径
    var stars: Int
    var top3: String
}

enum BirdLog {
    static let fileName = "kingfisher-birds.log"

    static func url(in folder: URL) -> URL {
        folder.appendingPathComponent(fileName)
    }

    private static func fallbackURL() -> URL? {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Kingfisher-PhotoSelector")
        guard let base else { return nil }
        return base.appendingPathComponent(fileName)
    }

    /// 追加一条记录。写失败时回退 Application Support，返回实际写入位置。
    @discardableResult
    static func append(_ record: BirdRecord, in folder: URL) -> URL? {
        guard let data = try? JSONEncoder().encode(record) else { return nil }
        let line = (String(data: data, encoding: .utf8) ?? "") + "\n"
        let primary = url(in: folder)
        if write(line: line, to: primary) { return primary }
        if let fallback = fallbackURL() {
            try? FileManager.default.createDirectory(at: fallback.deletingLastPathComponent(), withIntermediateDirectories: true)
            if write(line: line, to: fallback) { return fallback }
        }
        return nil
    }

    private static func write(line: String, to url: URL) -> Bool {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            guard fm.createFile(atPath: url.path, contents: nil, attributes: nil) else { return false }
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return false }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
            return true
        } catch { return false }
    }

    static func load(in folder: URL) -> [BirdRecord] {
        var records: [BirdRecord] = []
        let primary = url(in: folder)
        var sources = [primary]
        if let fallback = fallbackURL(), fallback.path != primary.path { sources.append(fallback) }
        for u in sources {
            guard let text = try? String(contentsOf: u, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                guard let d = line.data(using: .utf8),
                      let r = try? JSONDecoder().decode(BirdRecord.self, from: d) else { continue }
                if u == primary || URL(fileURLWithPath: r.root).standardizedFileURL.path == folder.standardizedFileURL.path { records.append(r) }
            }
        }
        return records
    }

    /// 日志文件最后修改时间（主位置 + 回退位置取较新的），供 App 做内存缓存失效判断。
    static func stamp(in folder: URL) -> Date? {
        var newest: Date?
        for u in [url(in: folder), fallbackURL()].compactMap({ $0 }) {
            guard let d = try? FileManager.default.attributesOfItem(atPath: u.path)[.modificationDate] as? Date else { continue }
            if newest == nil || d > newest! { newest = d }
        }
        return newest
    }

    /// 取某张照片最新的鸟种记录（人工确认优先级最高）。
    /// minLocalConfidence>0 时忽略低于常规门槛的旧「本地识别」记录；
    /// 若传入 agreementConfidence + agreementReason，则 reason 含该标记的本地记录
    /// （整图与主体框 Top1 一致）可放宽到 agreementConfidence 采纳。
    /// 旧口径 0.25 放宽时期的 26%/27% 误认仍低于放宽下限，不会被读回来。
    static func latest(for file: String, in folder: URL,
                       minLocalConfidence: Double = 0,
                       agreementConfidence: Double = 0,
                       agreementReason: String = "") -> BirdRecord? {
        let rows = load(in: folder).filter {
            eligible($0, file: file, min: minLocalConfidence,
                     agreementMin: agreementConfidence, agreementReason: agreementReason)
        }
        return rows.last { $0.source == "人工确认" } ?? rows.last
    }

    /// 与 latest 同规则，但让调用方传入已缓存的 rows，避免每张照片重读整个日志。
    static func latest(in rows: [BirdRecord], for file: String,
                       minLocalConfidence: Double = 0,
                       agreementConfidence: Double = 0,
                       agreementReason: String = "") -> BirdRecord? {
        let matched = rows.filter {
            eligible($0, file: file, min: minLocalConfidence,
                     agreementMin: agreementConfidence, agreementReason: agreementReason)
        }
        return matched.last { $0.source == "人工确认" } ?? matched.last
    }

    private static func eligible(_ r: BirdRecord, file: String, min: Double,
                                 agreementMin: Double = 0,
                                 agreementReason: String = "") -> Bool {
        guard r.file == file else { return false }
        if r.source == "人工确认" || r.confidence >= min { return true }
        // 窄口径放宽：只对本地识别、且日志明确写了「互相印证」的记录生效。
        if agreementMin > 0, !agreementReason.isEmpty,
           r.source == "本地识别", r.confidence >= agreementMin,
           r.reason.contains(agreementReason) { return true }
        return false
    }

    static func csv(_ records: [BirdRecord]) -> String {
        var lines = ["时间,文件名,鸟种,拉丁名,置信,来源,依据,星级,Top3,照片根目录"]
        for r in records {
            lines.append([
                q(r.time), q(r.file), q(r.name), q(r.latin),
                String(format: "%.3f", r.confidence), q(r.source), q(r.reason),
                String(r.stars), q(r.top3), q(r.root)
            ].joined(separator: ","))
        }
        return "\u{FEFF}" + lines.joined(separator: "\n") + "\n"
    }

    private static func q(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
