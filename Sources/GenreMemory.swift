import Foundation

/// 题材纠正记忆：用户手动改题材时，记录当时的识别特征；之后遇到特征相似的
/// 照片，优先按用户以往的纠正来判，并在识别依据里注明。存本地 JSON，可一键清空。
///
/// 边界（如实）：
/// - 不是重新训练识别模型（系统 Vision 模型无法在本机再训练），而是规则层的
///   经验积累——每个纠正样本都可直接查看，判错也能追查原因；
/// - 匹配按「对焦点分类标签签名」：top 标签一致且另有标签重合，或总重合 ≥3。
///   刻意不看镜头型号（用户选择「特征相似即套用」，覆盖面优先）；
/// - 焦距/镜头/主体来源一并记录，供日后诊断导出使用。
struct GenreCorrectionSample: Codable {
    var labels: [String]        // 对焦点分类标签名（小写、无置信度），最多前 8 个
    var topLabel: String        // 置信度最高的标签（匹配的主要锚点）
    var focal: Int              // 实际焦距 mm（0 = 无数据）
    var lensMax: Int            // 镜头长焦端 mm（0 = 无数据）
    var subjectSource: String   // 主体检测来源
    var machineGenre: String    // 机器当时判的题材
    var userGenre: String       // 用户改成的题材
    var date: Date
}

enum GenreMemory {

    // MARK: 存取

    static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FocusScreener", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("genre_corrections.json")
    }

    static func load() -> [GenreCorrectionSample] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([GenreCorrectionSample].self, from: data)) ?? []
    }

    static func append(_ sample: GenreCorrectionSample) {
        var all = load()
        all.append(sample)
        // 上限 500 条，最旧的先淘汰，避免无限增长。
        if all.count > 500 { all = Array(all.suffix(500)) }
        save(all)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    private static func save(_ samples: [GenreCorrectionSample]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(samples) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    // MARK: 特征签名

    /// 从界面上显示的标签串（"blue_sky 96%"）取标签名。
    static func parseLabel(_ display: String) -> String {
        let parts = display.split(separator: " ")
        return parts.count >= 2 ? String(parts[0]).lowercased()
                                : display.lowercased()
    }

    /// 匹配条件：top 标签一致且另有 ≥1 个标签重合，或总重合 ≥3 个。
    /// 返回 nil 表示没有足够相似的纠正样本。
    static func suggest(query: (top: String, labels: [String]),
                        samples: [GenreCorrectionSample]) -> (genre: String, count: Int)? {
        guard !query.labels.isEmpty else { return nil }
        let matched = samples.filter { s in
            let common = Set(s.labels).intersection(query.labels).count
            let topMatch = !s.topLabel.isEmpty && s.topLabel == query.top
            return (topMatch && common >= 1) || common >= 3
        }
        guard !matched.isEmpty else { return nil }
        // 按用户判的题材分组取多数；并列时取最近一次。
        var counts: [String: (n: Int, latest: Date)] = [:]
        for s in matched {
            var c = counts[s.userGenre] ?? (0, .distantPast)
            c.n += 1
            c.latest = max(c.latest, s.date)
            counts[s.userGenre] = c
        }
        let best = counts.max {
            $0.value.n != $1.value.n ? $0.value.n < $1.value.n
                                     : $0.value.latest < $1.value.latest
        }
        guard let best = best else { return nil }
        return (best.key, best.value.n)
    }

    // MARK: 从 EXIF 提取焦距（记录用，不参与匹配）

    /// 从「800mm」「RF100-400mm F5.6-8」这类串里取最大的数字。
    static func maxNumber(in s: String) -> Int {
        var best = 0, cur = ""
        func flush() {
            if let v = Int(cur), v >= 10 { best = max(best, v) }
            cur = ""
        }
        for ch in s {
            if ch.isNumber || ch == "." { cur.append(ch) } else { flush() }
        }
        flush()
        return best
    }
}
