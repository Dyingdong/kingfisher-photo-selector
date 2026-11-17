import Foundation
import ImageIO
import CoreGraphics

@main
struct MetaTest {
    static func sosOffset(_ data: Data) -> Int? {
        let b = [UInt8](data)
        var i = 2
        while i + 3 < b.count {
            if b[i] != 0xFF { return nil }
            let m = b[i + 1]
            if m == 0xDA { return i }
            if m == 0xD8 || (m >= 0xD0 && m <= 0xD7) { i += 2; continue }
            let len = (Int(b[i + 2]) << 8) | Int(b[i + 3])
            if len < 2 { return nil }
            i += 2 + len
        }
        return nil
    }

    static func readBackXMP(_ u: URL) -> String {
        if let src = CGImageSourceCreateWithURL(u as CFURL, nil),
           let md = CGImageSourceCopyMetadataAtIndex(src, 0, nil),
           let cf = CGImageMetadataCreateXMPData(md, nil) {
            let len = CFDataGetLength(cf)
            if let ptr = CFDataGetBytePtr(cf), len > 0,
               let s = String(data: Data(bytes: ptr, count: len), encoding: .utf8),
               !s.isEmpty { return s }
        }
        if let raw = try? Data(contentsOf: u), let s = MetadataWriter.embeddedXMP(raw) { return s }
        return ""
    }

    static func main() throws {
        let dir = URL(fileURLWithPath: "/tmp/fs_test")
        let backup = dir.appendingPathComponent("backup")
        let jpg = dir.appendingPathComponent("shot.jpg")

        print("--- 1. JPG 字节级写入 ---")
        let before = try Data(contentsOf: jpg)
        let bSOS = sosOffset(before)!
        let tailBefore = before.subdata(in: bSOS..<before.count)
        let r1 = try MetadataWriter.apply(to: jpg, reason: "主体区锐度/最锐区=0.08，焦点未落在主体",
                                          addLabel: true, backupDir: backup)
        let after = try Data(contentsOf: jpg)
        let aSOS = sosOffset(after)!
        let tailAfter = after.subdata(in: aSOS..<after.count)
        print("写入方式:", r1.method)
        print("图像数据(SOS 之后)字节完全不变:", tailBefore == tailAfter)
        print("文件增加字节:", after.count - before.count, "(仅新增 XMP APP1 段)")

        let back = readBackXMP(jpg)
        print("ImageIO 读回 XMP 成功:", !back.isEmpty)
        print("含关键词 未合焦:", back.contains(">未合焦<"))
        print("含判定原因:", back.contains("主体区锐度/最锐区=0.08"))
        print("含 IPTC Core 说明字段:", back.contains("dc:description") && back.contains("photoshop:Instructions"))
        print("含 Bridge 颜色标签:", back.contains("xmp:Label") && back.contains("Red"))

        print("--- 2. 重复写入不叠加 ---")
        _ = try MetadataWriter.apply(to: jpg, reason: "复核后仍未合焦", addLabel: true, backupDir: backup)
        let back2 = readBackXMP(jpg)
        let kwCount = back2.components(separatedBy: ">未合焦<").count - 1
        let noteCount = back2.components(separatedBy: MetadataWriter.notePrefix).count - 1
        print("关键词 未合焦 出现次数:", kwCount, "(应为 1)")
        print("原因出现次数:", noteCount, "(应为 2：说明 + Instructions)")
        print("新原因已生效:", back2.contains("复核后仍未合焦"))
        print("旧原因已替换:", !back2.contains("主体区锐度/最锐区=0.08"))

        print("--- 3. 已有元数据不覆盖 ---")
        let seeded = """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
          <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description rdf:about=""
              xmlns:dc="http://purl.org/dc/elements/1.1/"
              xmlns:xmp="http://ns.adobe.com/xap/1.0/"
              xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/">
              <dc:subject><rdf:Bag><rdf:li>旅行</rdf:li><rdf:li>黄山</rdf:li></rdf:Bag></dc:subject>
              <dc:description><rdf:Alt><rdf:li xml:lang="x-default">云海</rdf:li></rdf:Alt></dc:description>
              <photoshop:Instructions>勿裁切</photoshop:Instructions>
              <xmp:Label>Green</xmp:Label>
              <xmp:Rating>4</xmp:Rating>
            </rdf:Description>
          </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """
        let merged = try MetadataWriter.mergedXMP(existing: seeded,
                                                  note: MetadataWriter.makeNote("景深不足，未合焦"),
                                                  addLabel: true)
        for (name, token) in [("原关键词 旅行", ">旅行<"), ("原关键词 黄山", ">黄山<"),
                              ("原说明 云海", "云海"), ("原 Instructions", "勿裁切"),
                              ("原颜色标签 Green", "Green"), ("原星级 4", "4"),
                              ("新关键词 未合焦", ">未合焦<"), ("新原因", "景深不足")] {
            print("  保留/新增 \(name):", merged.contains(token))
        }
        print("  未覆盖已有颜色标签(无 Red):", !merged.contains(">Red<"))
        do { _ = try XMLDocument(data: Data(merged.utf8), options: []) }
        catch { print("  XML 解析错误:", error.localizedDescription) }
        try? merged.write(to: dir.appendingPathComponent("merged.xmp"), atomically: true, encoding: .utf8)
        print("  合并结果仍是合法 XML:", (try? XMLDocument(data: Data(merged.utf8), options: [])) != nil)

        print("--- 4. RAW 只写侧车，不碰原片 ---")
        let raw = dir.appendingPathComponent("IMG_0042.CR3")
        let rawBytes = Data(repeating: 0x5A, count: 4096)
        try rawBytes.write(to: raw)
        let r3 = try MetadataWriter.apply(to: raw, reason: "全片锐度偏低，整体未合焦",
                                          addLabel: false, backupDir: backup)
        let rawAfter = try Data(contentsOf: raw)
        let sc = MetadataWriter.sidecar(raw)
        let sideText = try String(contentsOf: sc, encoding: .utf8)
        print("写入方式:", r3.method)
        print("侧车文件名:", sc.lastPathComponent)
        print("RAW 原片字节完全不变:", rawAfter == rawBytes)
        print("侧车含关键词与原因:", sideText.contains("未合焦") && sideText.contains("整体未合焦"))
        print("侧车是合法 XML:", (try? XMLDocument(data: Data(sideText.utf8), options: [])) != nil)

        print("--- 5. 已有侧车增量合并 ---")
        _ = try MetadataWriter.apply(to: raw, reason: "复核：远景大面积偏软", addLabel: false, backupDir: backup)
        let side2 = try String(contentsOf: sc, encoding: .utf8)
        print("关键词仍只有一次:", side2.components(separatedBy: ">未合焦<").count - 1 == 1)
        print("原因已更新:", side2.contains("远景大面积偏软") && !side2.contains("全片锐度偏低"))
        print("ALL_TESTS_DONE")
    }
}
