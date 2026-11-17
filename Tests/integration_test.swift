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

        let suspects = results.filter { $0.verdict.isSuspect }
        let backup = dir.appendingPathComponent("backup")
        print("--- 写入 \(suspects.count) 张未合焦照片 ---")
        for r in suspects {
            let o = try MetadataWriter.apply(to: r.id, reason: r.reason,
                                             addLabel: true, backupDir: backup)
            print("  \(o.fileName) [\(o.method)] \(o.note)")
        }

        print("--- 读回校验 ---")
        for r in suspects {
            let s = MetadataWriter.snapshot(r.id)
            print("  \(r.id.lastPathComponent): 关键词=\(s.keywords.joined(separator: ","))"
                  + " 说明含原因=\(s.description.contains(MetadataWriter.notePrefix))"
                  + " Instructions含原因=\(s.instructions.contains(MetadataWriter.notePrefix))"
                  + " 颜色标签=\(s.label)")
        }

        let pass = results.filter { !$0.verdict.isSuspect }
        print("--- 合焦照片未被打标签:",
              pass.allSatisfy { MetadataWriter.snapshot($0.id).keywords.isEmpty })
        print("--- 写入前备份文件数:",
              (try? FileManager.default.contentsOfDirectory(atPath: backup.path))?.count ?? 0)
        print("INTEGRATION_DONE")
    }
}
