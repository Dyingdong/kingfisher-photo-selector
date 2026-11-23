import Foundation

@main
struct IntegrationTest {
    static func main() throws {
        let dir = URL(fileURLWithPath: "/tmp/fs_test/e2e")
        let names = ["clear", "blur", "portrait", "misfocus", "motion"]
        let urls = names.map { dir.appendingPathComponent($0 + ".jpg") }
        let metrics = urls.compactMap { Analyzer.analyze($0) }
        let results = Analyzer.decide(metrics)

        print("--- 判定 ---")
        for r in results { print("  \(r.id.lastPathComponent) -> \(r.verdict.rawValue)") }

        let backup = dir.appendingPathComponent("backup")
        print("--- 写入 \(results.count) 张照片（判定词直接写 xmp:Label） ---")
        for r in results {
            // 标签规则与 App 一致：Verdict.bridgeLabel（判定词本身）
            let o = try MetadataWriter.apply(to: r.id, reason: r.reason,
                                             labelColor: r.verdict.bridgeLabel, backupDir: backup)
            print("  \(o.fileName) [\(o.method)] \(r.verdict.rawValue) → 标签=\(r.verdict.bridgeLabel ?? "无") | \(o.note)")
        }

        print("--- 读回校验（标签与判定档一致） ---")
        var labelOK = true
        for r in results {
            let s = MetadataWriter.snapshot(r.id)
            let want = r.verdict.bridgeLabel ?? ""
            let got = s.label
            print("  \(r.id.lastPathComponent): 判定=\(r.verdict.rawValue) 期望标签=\(want) 实际=\(got)"
                  + " 关键词=\(s.keywords.joined(separator: ","))"
                  + " 说明含原因=\(s.description.contains(MetadataWriter.notePrefix))")
            if got != want { labelOK = false }
        }
        print("标签与判定档全部一致:", labelOK)
        print("--- 写入前备份文件数:",
              (try? FileManager.default.contentsOfDirectory(atPath: backup.path))?.count ?? 0)
        print("INTEGRATION_DONE")
    }
}
