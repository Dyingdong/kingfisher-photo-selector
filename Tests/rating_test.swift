import Foundation
import ImageIO
import CoreGraphics
import AppKit

@main
struct RatingTest {
    static func makeJPG(_ u: URL) throws {
        let size = CGSize(width: 64, height: 64)
        let img = NSImage(size: size)
        img.lockFocus()
        NSColor.blue.setFill()
        NSRect(origin: .zero, size: size).fill()
        img.unlockFocus()
        let tiff = img.tiffRepresentation!
        let rep = NSBitmapImageRep(data: tiff)!
        let data = rep.representation(using: .jpeg, properties: [:])!
        try data.write(to: u)
    }

    static func main() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("fs_rating_test")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let jpg = dir.appendingPathComponent("rating.jpg")
        try makeJPG(jpg)
        let backup = dir.appendingPathComponent("backup")

        print("--- 初始 ---")
        print("rating:", MetadataWriter.snapshot(jpg).rating as Any)

        print("--- 设 4 星 ---")
        _ = try MetadataWriter.setRating(to: jpg, rating: 4, backupDir: backup)
        let s4 = MetadataWriter.snapshot(jpg)
        print("rating:", s4.rating as Any, "rejected:", s4.isRejected)
        assert(s4.rating == 4, "4 星写入失败")

        print("--- 改 2 星 ---")
        _ = try MetadataWriter.setRating(to: jpg, rating: 2, backupDir: backup)
        let s2 = MetadataWriter.snapshot(jpg)
        print("rating:", s2.rating as Any)
        assert(s2.rating == 2, "改 2 星失败")

        print("--- 标记拒绝 ---")
        _ = try MetadataWriter.setRating(to: jpg, rating: -1, backupDir: backup)
        let sr = MetadataWriter.snapshot(jpg)
        print("rating:", sr.rating as Any, "rejected:", sr.isRejected)
        assert(sr.isRejected, "拒绝标记失败")

        print("--- 保留其它字段：先写入质检说明 + 关键词，再评分 ---")
        _ = try MetadataWriter.apply(to: jpg, reason: "主体未合焦", addLabel: true, backupDir: backup)
        _ = try MetadataWriter.setRating(to: jpg, rating: 5, backupDir: backup)
        let sm = MetadataWriter.snapshot(jpg)
        print("rating:", sm.rating as Any, "keywords:", sm.keywords, "label:", sm.label)
        assert(sm.rating == 5, "说明后评分丢失")
        assert(sm.keywords.contains("未合焦"), "评分覆盖掉了关键词")
        assert(sm.label == "Red", "评分覆盖掉了颜色标签")

        print("ALL OK")
    }
}
