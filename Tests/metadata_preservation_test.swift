import AppKit
import Foundation

@main
struct MetadataPreservationTest {
    static func expectFailure(_ run: () throws -> Void) {
        do { try run(); fatalError("预期写入失败") } catch {}
    }

    static func main() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: dir) }
        let jpg = dir.appendingPathComponent("both.jpg")
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)!
        let original = bitmap.representation(using: .jpeg, properties: [:])!
        let embedded = MetadataWriter.freshXMP(note: "内嵌说明", labelColor: "内嵌标签")
        let side = MetadataWriter.freshXMP(note: "侧车说明", labelColor: "侧车标签")
        let sc = MetadataWriter.sidecar(jpg)
        try MetadataWriter.injectXMP(into: original, xmp: embedded).write(to: jpg)
        try side.write(to: sc, atomically: true, encoding: .utf8)
        _ = try MetadataWriter.setRating(to: jpg, rating: 4, backupDir: dir)
        _ = try MetadataWriter.setBirdLabel(to: jpg, bird: "黑鹳", backupDir: dir)
        _ = try MetadataWriter.setDescription(to: jpg, note: "测试", backupDir: dir)
        _ = try MetadataWriter.apply(to: jpg, reason: "测试", labelColor: nil, backupDir: dir)
        let writtenPhoto = try Data(contentsOf: jpg)
        let scanStart = original.range(of: Data([0xff, 0xda]))!.lowerBound
        precondition(writtenPhoto.suffix(original.count - scanStart) == original[scanStart...])
        let left = MetadataWriter.embeddedXMP(writtenPhoto)!
        let right = try String(contentsOf: sc, encoding: .utf8)
        for (packet, own, other) in [(left, "内嵌", "侧车"), (right, "侧车", "内嵌")] {
            precondition(packet.contains(own + "说明") && packet.contains(own + "标签"))
            precondition(!packet.contains(other + "说明") && packet.contains("黑鹳"))
        }

        let plainPhoto = try MetadataWriter.injectXMP(into: original, xmp: embedded)
        try plainPhoto.write(to: jpg)
        let sideBefore = try Data(contentsOf: sc)
        expectFailure { _ = try MetadataWriter.cleanup(to: jpg, backupDir: jpg) }
        let afterFailure = try Data(contentsOf: sc)
        precondition(afterFailure == sideBefore)
        let inode = try fm.attributesOfItem(atPath: jpg.path)[.systemFileNumber] as! NSNumber
        let cleaned = try MetadataWriter.cleanup(to: jpg, backupDir: dir)
        let afterClean = try Data(contentsOf: jpg)
        let inodeAfter = try fm.attributesOfItem(atPath: jpg.path)[.systemFileNumber] as! NSNumber
        precondition(cleaned.removed && afterClean == plainPhoto && inodeAfter == inode)

        let raw = dir.appendingPathComponent("broken.cr3")
        for bad in [Data(), Data([0xff, 0xfe, 0xff]), Data("<broken>".utf8),
                    Data("<rdf:Description xmlns:rdf='urn:test'><unclosed>".utf8)] {
            try bad.write(to: MetadataWriter.sidecar(raw))
            try bad.write(to: sc)
            for photo in [raw, jpg] {
                expectFailure { _ = try MetadataWriter.setRating(to: photo, rating: 3, backupDir: dir) }
                expectFailure { _ = try MetadataWriter.setBirdLabel(to: photo, bird: "黑鹳", backupDir: dir) }
                let after = try Data(contentsOf: MetadataWriter.sidecar(photo))
                precondition(after == bad)
            }
            let after = try Data(contentsOf: jpg)
            precondition(after == plainPhoto)
        }
        try side.write(to: sc, atomically: true, encoding: .utf8)
        let brokenPhoto = try MetadataWriter.injectXMP(into: original, xmp: "<broken>")
        try brokenPhoto.write(to: jpg)
        expectFailure { _ = try MetadataWriter.setRating(to: jpg, rating: 1, backupDir: dir) }
        let unchangedPhoto = try Data(contentsOf: jpg)
        let unchangedSide = try String(contentsOf: sc, encoding: .utf8)
        precondition(unchangedPhoto == brokenPhoto && unchangedSide == side)
        let attributePacket = """
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description xmlns:meta="http://ns.adobe.com/xap/1.0/" meta:Rating="4" meta:Label="Green"/>
        </rdf:RDF>
        """
        let rawSidecar = MetadataWriter.sidecar(raw)
        try attributePacket.write(to: rawSidecar, atomically: true, encoding: .utf8)
        precondition(MetadataWriter.snapshot(raw).rating == 4)
        let duplicatePacket = attributePacket.replacingOccurrences(of: "/>",
            with: "><meta:Rating>2</meta:Rating></rdf:Description>")
        try duplicatePacket.write(to: rawSidecar, atomically: true, encoding: .utf8)
        _ = try MetadataWriter.setRating(to: raw, rating: -1, backupDir: dir)
        let updated = try String(contentsOf: rawSidecar, encoding: .utf8)
        precondition(updated.contains("meta:Rating=\"-1\"") && !updated.contains("<meta:Rating>"))
        precondition(updated.contains("meta:Label=\"Green\"") && MetadataWriter.snapshot(raw).isRejected)
        precondition(MetadataWriter.snapshot(raw).label == "Green")
        _ = try MetadataWriter.apply(to: raw, reason: "复核", labelColor: "主体清晰", backupDir: dir)
        let assessed = try String(contentsOf: rawSidecar, encoding: .utf8)
        precondition(assessed.contains("meta:Label=\"Green\"") && !assessed.contains(":Label>"))
        _ = try MetadataWriter.setBirdLabel(to: raw, bird: "黑鹳", backupDir: dir)
        precondition(MetadataWriter.snapshot(raw).label.contains("Green / 黑鹳"))
        _ = try MetadataWriter.cleanup(to: raw, backupDir: dir)
        precondition(MetadataWriter.snapshot(raw).label == "Green")
        let duplicatedLabel = attributePacket.replacingOccurrences(of: "/>",
            with: "><meta:Label>主体清晰</meta:Label></rdf:Description>")
        try duplicatedLabel.write(to: rawSidecar, atomically: true, encoding: .utf8)
        _ = try MetadataWriter.cleanup(to: raw, backupDir: dir)
        let cleanedLabel = try String(contentsOf: rawSidecar, encoding: .utf8)
        precondition(cleanedLabel.contains("meta:Label=\"Green\"") && !cleanedLabel.contains(":Label>"))
        print("元数据保护回归通过")
    }
}
