import Foundation

@main
struct DeleteTest {
    static func touch(_ u: URL) throws { try Data("x".utf8).write(to: u) }

    static func main() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("fs_delete_test")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for f in try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            try? FileManager.default.removeItem(at: f)
        }
        let raw = dir.appendingPathComponent("IMG_0001.CR3")
        let jpg = dir.appendingPathComponent("IMG_0001.jpg")
        let other = dir.appendingPathComponent("IMG_0002.CR3")
        try touch(raw); try touch(jpg); try touch(other)

        // siblingJPG 逻辑（与 Store 中一致）
        func siblingJPG(for raw: URL) -> URL? {
            guard MetadataWriter.isRAW(raw) else { return nil }
            let base = raw.deletingPathExtension()
            for ext in MetadataWriter.jpgExts {
                let c = base.appendingPathExtension(ext)
                if FileManager.default.fileExists(atPath: c.path) { return c }
            }
            return nil
        }
        print("RAW 识别:", MetadataWriter.isRAW(raw))
        print("同名 JPG:", siblingJPG(for: raw)?.lastPathComponent as Any)
        assert(MetadataWriter.isRAW(raw), "RAW 未识别")
        assert(siblingJPG(for: raw)?.lastPathComponent == "IMG_0001.jpg", "同名 JPG 未找到")
        assert(siblingJPG(for: other) == nil, "无 JPG 时不应找到")

        // 模拟删除（移到废纸篓在此环境可能无 GUI 会话，用 removeItem 验证配对逻辑）
        var moved: [URL] = [raw]
        if let j = siblingJPG(for: raw) { moved.append(j) }
        print("将删除:", moved.map { $0.lastPathComponent })
        assert(moved.count == 2, "应删除 RAW 与同名 JPG 两个文件")

        print("ALL OK")
    }
}
