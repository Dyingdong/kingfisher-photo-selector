import Foundation

// 评分复核探针：用当前评分引擎跑带人工真值的 50 张，输出建议星级与维度分，
// 检查「好片高星、废片低星」是否符合人工直觉。仅开发期使用，不进 App。

let args = Array(CommandLine.arguments.dropFirst())
guard let csvPath = args.first else {
    FileHandle.standardError.write(("用法: score_probe <真值csv>\n").data(using: .utf8)!)
    exit(2)
}
let csvText = try String(contentsOfFile: csvPath, encoding: .utf8)
let rows = csvText.split(separator: "\n").dropFirst()
var truth: [String: String] = [:]
for row in rows {
    let cols = String(row).split(separator: ",", omittingEmptySubsequences: false)
    // 用两列干净真值文件：第 0 列文件名，第 1 列人工真值
    if cols.count >= 2 {
        let name = String(cols[0]).trimmingCharacters(in: .whitespaces)
        truth[name] = String(cols[1])
    }
}
let dir = "/Users/dyingdong/Downloads/test"
let fm = FileManager.default
let files = (try? fm.contentsOfDirectory(atPath: dir))?.filter {
    MetadataWriter.rawExts.contains(($0 as NSString).pathExtension.lowercased())
}.sorted() ?? []

print("文件名,人工真值,题材,建议星级,总分,主体清晰度,整体锐度,对焦,白平衡,判定")
var starGood = 0, goodCount = 0, starBad = 0, badCount = 0
for f in files {
    let url = URL(fileURLWithPath: (dir as NSString).appendingPathComponent(f))
    guard let m = Analyzer.analyze(url) else { continue }
    let hiMin = Analyzer.independentThreshold()
    let (v, _) = Analyzer.classify(m, hiMin: hiMin)
    let r = PhotoResult(id: url, metrics: m, verdict: v, reason: "")
    let wb = WhiteBalance.analyze(url)
    let af = AFReader.read(url)
    let exif = ExifInfo.read(url)
    let (genre, genreWhy) = ScoreEngine.guessGenre(m: m, af: af, wb: wb, exif: exif)
    let s = ScoreEngine.score(r, af: af, wb: wb, exif: exif, genre: genre,
                              genreIsGuess: true, genreReason: genreWhy)
    func part(_ id: String) -> String {
        s.parts.first { $0.id == id }.map { String(Int($0.score)) } ?? "-"
    }
    let name = (f as NSString).deletingPathExtension
    let t = truth[f] ?? truth[name] ?? "?"
    print("\(f),\(t),\(genre.rawValue),\(s.stars),\(Int(s.total.rounded())),\(part("clarity")),\(part("overall")),\(part("focus")),\(part("color")),\(v.rawValue),\(genreWhy)")
    if t.contains("废") { badCount += 1; if s.stars <= 2 { starBad += 1 } }
    else if t.contains("好") { goodCount += 1; if s.stars >= 3 { starGood += 1 } }
}
FileHandle.standardError.write("\n好片 \(goodCount) 张：\(starGood) 张评 3 星以上；废片 \(badCount) 张：\(starBad) 张评 2 星以下\n".data(using: .utf8)!)
