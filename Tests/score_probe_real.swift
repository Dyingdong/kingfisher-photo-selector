import Foundation

// 星级回归探针：用当前评分引擎跑带人工真值的照片，输出建议星级与维度分，
// 检查「好片高星、废片低星」是否符合人工直觉。仅开发期使用，不进 App。
//
// 用法（二选一）：
//   score_probe_real <真值csv> <照片目录>   —— 真值来自 CSV 的「文件名,人工真值」两列
//   score_probe_real <照片目录>             —— 真值按目录结构取：子文件夹名含「好片」=好、「废片」=废
// 照片目录会递归扫描（含子文件夹里的 RAW）。

@main
struct ScoreProbeReal {
    static func main() throws {
    let args = Array(CommandLine.arguments.dropFirst())
    guard let rootArg = args.last, args.count >= 1, args.count <= 2 else {
        FileHandle.standardError.write(("用法: score_probe_real <照片目录> [真值csv]\n").data(using: .utf8)!)
        exit(2)
    }
    let dir = rootArg
    let csvPath = args.count == 2 ? args[0] : nil

    // 真值来源 1：CSV（文件名 → 人工真值）
    var csvTruth: [String: String] = [:]
    if let csvPath {
        let csvText = try String(contentsOfFile: csvPath, encoding: .utf8)
        let rows = csvText.split(separator: "\n").dropFirst()
        for row in rows {
            let cols = String(row).split(separator: ",", omittingEmptySubsequences: false)
            // 用两列干净真值文件：第 0 列文件名，第 1 列人工真值
            if cols.count >= 2 {
                let name = String(cols[0]).trimmingCharacters(in: .whitespaces)
                csvTruth[name] = String(cols[1])
            }
        }
    }

    let fm = FileManager.default
    var files: [URL] = []
    if let e = fm.enumerator(at: URL(fileURLWithPath: dir),
                             includingPropertiesForKeys: nil,
                             options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
        for case let f as URL in e
        where MetadataWriter.rawExts.contains(f.pathExtension.lowercased()) {
            files.append(f)
        }
    }

    func truth(_ u: URL) -> String {
        if let t = csvTruth[u.lastPathComponent] { return t }
        // 真值来源 2：目录结构（好片/废片 子文件夹）
        let p = u.path
        if p.contains("/好片/") { return "好" }
        if p.contains("/废片/") { return "废" }
        return "?"
    }

    print("文件名,人工真值,题材,建议星级,总分,主体清晰度,整体锐度,对焦,白平衡,判定")
    var starGood = 0, goodCount = 0, starBad = 0, badCount = 0
    // 整片偏软档只轻压到 ≤3 星，是设计允许的例外；其余档废片仍必须 ≤2 星。
    var over2NonGlobal = [String]()
    for f in files.sorted(by: { $0.path < $1.path }) {
        guard let m = Analyzer.analyze(f) else { continue }
        let hiMin = Analyzer.independentThreshold()
        let (v, _) = Analyzer.classify(m, hiMin: hiMin)
        let r = PhotoResult(id: f, metrics: m, verdict: v, reason: "")
        let wb = WhiteBalance.analyze(f)
        let af = AFReader.read(f)
        let exif = ExifInfo.read(f)
        let focus = FocusSemanticsEngine.detect(url: f, subjectBoxes: m.bboxes)
        let human = HumanPresenceEngine.detect(url: f)
        let (genre, genreWhy) = ScoreEngine.guessGenre(m: m, af: af, wb: wb, exif: exif, focus: focus, human: human)
        let s = ScoreEngine.score(r, af: af, wb: wb, exif: exif, genre: genre,
                                  genreIsGuess: true, genreReason: genreWhy)
        func part(_ id: String) -> String {
            s.parts.first { $0.id == id }.map { String(Int($0.score)) } ?? "-"
        }
        let name = (f.lastPathComponent as NSString).deletingPathExtension
        let t = truth(f) != "?" ? truth(f) : (csvTruth[name] ?? "?")
        print("\(f.lastPathComponent),\(t),\(genre.rawValue),\(s.stars),\(Int(s.total.rounded())),\(part("clarity")),\(part("overall")),\(part("focus")),\(part("color")),\(v.rawValue),\(genreWhy)")
        if t.contains("废") {
            badCount += 1
            if s.stars <= 2 { starBad += 1 }
            else if v != .globalBlur {
                over2NonGlobal.append("\(f.lastPathComponent) 真值=废 星级=\(s.stars) 判定=\(v.rawValue) 总分=\(Int(s.total.rounded()))")
            }
        }
        else if t.contains("好") { goodCount += 1; if s.stars >= 3 { starGood += 1 } }
    }
    var summary = "\n好片 \(goodCount) 张：\(starGood) 张评 3 星以上；废片 \(badCount) 张：\(starBad) 张评 2 星以下\n"
    if over2NonGlobal.isEmpty {
        summary += "整片偏软档以外的废片全部 ≤2 星 ✓\n"
    } else {
        summary += "⚠ 以下废片星级超过 2 且判定不是整片偏软（需人工决策，见报告）：\n"
            + over2NonGlobal.joined(separator: "\n") + "\n"
    }
    FileHandle.standardError.write(summary.data(using: .utf8)!)

    }
}
