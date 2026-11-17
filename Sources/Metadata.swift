import Foundation

struct MetaSnapshot {
    var keywords: [String] = []
    var description: String = ""
    var instructions: String = ""
    var label: String = ""
    /// xmp:Rating，0~5 星；-1 表示 Bridge 的「拒绝」。nil 表示未评分。
    var rating: Int?
    var isRejected: Bool { rating == -1 }
    var hasSidecar = false
    var hasEmbeddedXMP = false
}

struct WriteOutcome {
    let fileName: String
    let method: String
    let note: String
}

enum MetaError: Error, LocalizedError {
    case jpegMalformed
    case xmpTooLarge
    case xmpUnreadable
    case unsupportedFormat(String)

    var errorDescription: String? {
        switch self {
        case .jpegMalformed: return "JPEG 结构无法解析，已跳过写入以保护原片"
        case .xmpTooLarge: return "XMP 数据超过 APP1 段上限"
        case .xmpUnreadable: return "已有 XMP 无法解析，为保护原元数据已跳过"
        case .unsupportedFormat(let e): return "暂不支持写入该格式：\(e)"
        }
    }
}

enum MetadataWriter {
    static let keyword = "未合焦"
    static let notePrefix = "[合焦质检]"
    static let headerBytes: [UInt8] = Array("http://ns.adobe.com/xap/1.0/".utf8) + [0x00]
    static let packetBegin = "<?xpacket begin=\"\u{FEFF}\" id=\"W5M0MpCehiHzreSzNTczkc9d\"?>"
    static let packetEnd = "<?xpacket end=\"w\"?>"

    static let jpgExts: Set<String> = ["jpg", "jpeg", "jpe", "jfif"]
    static let rawExts: Set<String> = [
        "arw", "arq", "sr2", "srf", "cr2", "cr3", "crw", "nef", "nrw", "dng",
        "raf", "rw2", "orf", "rwl", "3fr", "fff", "iiq", "pef", "srw", "x3f",
        "raw", "mos", "mrw", "k25", "kdc", "dcr", "erf", "mef", "pxn", "r3d"
    ]

    static func isJPEG(_ u: URL) -> Bool { jpgExts.contains(u.pathExtension.lowercased()) }
    static func isRAW(_ u: URL) -> Bool { rawExts.contains(u.pathExtension.lowercased()) }
    static func isSupported(_ u: URL) -> Bool { isJPEG(u) || isRAW(u) }
    static func sidecar(_ u: URL) -> URL { u.deletingPathExtension().appendingPathExtension("xmp") }

    static func makeNote(_ reason: String) -> String {
        "\(notePrefix) \(reason)"
    }

    // MARK: - 构造 / 合并 XMP

    static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func freshXMP(note: String, addLabel: Bool, rating: Int? = nil) -> String {
        let label = addLabel ? "  <xmp:Label>Red</xmp:Label>\n" : ""
        let ratingLine = rating.map { "  <xmp:Rating>\($0)</xmp:Rating>\n" } ?? ""
        let n = xmlEscape(note)
        return """
        \(packetBegin)
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="FocusScreener">
          <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description rdf:about=""
              xmlns:dc="http://purl.org/dc/elements/1.1/"
              xmlns:xmp="http://ns.adobe.com/xap/1.0/"
              xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/">
              <dc:subject><rdf:Bag><rdf:li>\(xmlEscape(keyword))</rdf:li></rdf:Bag></dc:subject>
              <dc:description><rdf:Alt><rdf:li xml:lang="x-default">\(n)</rdf:li></rdf:Alt></dc:description>
              <photoshop:Instructions>\(n)</photoshop:Instructions>
        \(label)\(ratingLine)    </rdf:Description>
          </rdf:RDF>
        </x:xmpmeta>
        \(packetEnd)
        """
    }

    static func child(_ el: XMLElement, _ local: String) -> XMLElement? {
        for case let c as XMLElement in (el.children ?? []) {
            if c.localName == local || c.name == local || c.name?.hasSuffix(":" + local) == true {
                return c
            }
        }
        return nil
    }

    static func firstDescription(_ node: XMLNode) -> XMLElement? {
        if let el = node as? XMLElement,
           el.localName == "Description" || el.name?.hasSuffix(":Description") == true { return el }
        for c in node.children ?? [] { if let f = firstDescription(c) { return f } }
        return nil
    }

    static func attributeNode(_ name: String, _ value: String) -> XMLNode {
        XMLNode.attribute(withName: name, stringValue: value) as! XMLNode
    }

    static func ensureNS(_ desc: XMLElement, _ prefix: String, _ uri: String) {
        let key = "xmlns:\(prefix)"
        if desc.attribute(forName: key) != nil { return }
        var node: XMLNode? = desc
        while let n = node {
            if let e = n as? XMLElement,
               let list = e.namespaces,
               list.contains(where: { $0.name == prefix }) { return }
            node = n.parent
        }
        desc.addAttribute(attributeNode(key, uri))
    }

    static func replaceOldNote(_ old: String, note: String, separator: String) -> String {
        let kept = old.components(separatedBy: separator)
            .filter { !$0.contains(notePrefix) }
            .joined(separator: separator)
        return kept.isEmpty ? note : kept + separator + note
    }

    static func mergedXMP(existing: String?, note: String, addLabel: Bool,
                          rating: Int? = nil) throws -> String {
        guard let existing, !existing.isEmpty else { return freshXMP(note: note, addLabel: addLabel, rating: rating) }
        guard let data = existing.data(using: .utf8),
              let doc = try? XMLDocument(data: data, options: []),
              let root = doc.rootElement(),
              let desc = firstDescription(root) else { throw MetaError.xmpUnreadable }

        ensureNS(desc, "dc", "http://purl.org/dc/elements/1.1/")
        ensureNS(desc, "xmp", "http://ns.adobe.com/xap/1.0/")
        ensureNS(desc, "photoshop", "http://ns.adobe.com/photoshop/1.0/")

        if let subject = child(desc, "subject"), let bag = child(subject, "Bag") {
            let current = (bag.children ?? []).compactMap { $0.stringValue }
            if !current.contains(keyword) {
                let li = XMLElement(name: "rdf:li")
                li.stringValue = keyword
                bag.addChild(li)
            }
        } else {
            let subject = XMLElement(name: "dc:subject")
            let bag = XMLElement(name: "rdf:Bag")
            let li = XMLElement(name: "rdf:li")
            li.stringValue = keyword
            bag.addChild(li)
            subject.addChild(bag)
            desc.addChild(subject)
        }

        if let d = child(desc, "description"), let alt = child(d, "Alt"),
           let li = (alt.children ?? []).compactMap({ $0 as? XMLElement }).first {
            li.stringValue = replaceOldNote(li.stringValue ?? "", note: note, separator: "\n")
        } else {
            let d = XMLElement(name: "dc:description")
            let alt = XMLElement(name: "rdf:Alt")
            let li = XMLElement(name: "rdf:li")
            li.addAttribute(attributeNode("xml:lang", "x-default"))
            li.stringValue = note
            alt.addChild(li)
            d.addChild(alt)
            desc.addChild(d)
        }

        if let ins = child(desc, "Instructions") {
            ins.stringValue = replaceOldNote(ins.stringValue ?? "", note: note, separator: " | ")
        } else {
            let ins = XMLElement(name: "photoshop:Instructions")
            ins.stringValue = note
            desc.addChild(ins)
        }

        if addLabel && child(desc, "Label") == nil {
            let l = XMLElement(name: "xmp:Label")
            l.stringValue = "Red"
            desc.addChild(l)
        }

        // xmp:Rating：0~5 星；-1 = Bridge 的「拒绝」。传入 nil 时保留原值。
        if let rating {
            if let node = child(desc, "Rating") {
                node.stringValue = String(rating)
            } else {
                let r = XMLElement(name: "xmp:Rating")
                r.stringValue = String(rating)
                desc.addChild(r)
            }
        }

        return packetBegin + "\n" + root.xmlString + "\n" + packetEnd
    }

    // MARK: - 读取已有元数据

    static func embeddedXMP(_ data: Data) -> String? {
        let b = [UInt8](data)
        guard b.count > 4, b[0] == 0xFF, b[1] == 0xD8 else { return nil }
        var i = 2
        while i + 3 < b.count {
            if b[i] != 0xFF { break }
            let m = b[i + 1]
            if m == 0xD8 || (m >= 0xD0 && m <= 0xD7) { i += 2; continue }
            if m == 0xDA || m == 0xD9 { break }
            let len = (Int(b[i + 2]) << 8) | Int(b[i + 3])
            if len < 2 { break }
            let end = i + 2 + len
            if end > b.count { break }
            if m == 0xE1 {
                let ps = i + 4
                if end - ps >= headerBytes.count,
                   Array(b[ps..<(ps + headerBytes.count)]) == headerBytes {
                    return String(bytes: b[(ps + headerBytes.count)..<end], encoding: .utf8)
                }
            }
            i = end
        }
        return nil
    }

    static func snapshot(_ u: URL) -> MetaSnapshot {
        var s = MetaSnapshot()
        let sc = sidecar(u)
        if FileManager.default.fileExists(atPath: sc.path) { s.hasSidecar = true }
        var existing: String?
        if isJPEG(u), let d = try? Data(contentsOf: u), let x = embeddedXMP(d) {
            s.hasEmbeddedXMP = true
            existing = x
        }
        if existing == nil, s.hasSidecar {
            existing = try? String(contentsOf: sc, encoding: .utf8)
        }
        guard let existing, let data = existing.data(using: .utf8),
              let doc = try? XMLDocument(data: data, options: []),
              let root = doc.rootElement(), let desc = firstDescription(root) else { return s }
        if let subject = child(desc, "subject"), let bag = child(subject, "Bag") {
            s.keywords = (bag.children ?? []).compactMap { $0.stringValue }
        }
        if let d = child(desc, "description"), let alt = child(d, "Alt") {
            s.description = (alt.children ?? []).compactMap { $0.stringValue }.joined(separator: " | ")
        }
        s.instructions = child(desc, "Instructions")?.stringValue ?? ""
        s.label = child(desc, "Label")?.stringValue ?? ""
        if let r = child(desc, "Rating")?.stringValue, let v = Int(r.trimmingCharacters(in: .whitespacesAndNewlines)) {
            s.rating = v
        }
        return s
    }

    /// 只改 xmp:Rating，不动说明/关键词/标签。rating 为 0~5 星，-1 表示拒绝。
    /// 与 apply 共用同一套读取、备份、写回路径，但不会追加质检说明。
    static func setRating(to u: URL, rating: Int, backupDir: URL) throws -> WriteOutcome {
        let fm = FileManager.default
        try fm.createDirectory(at: backupDir, withIntermediateDirectories: true)
        let backup = backupDir.appendingPathComponent(u.lastPathComponent + ".before-rating.xmp")
        let sc = sidecar(u)

        if isJPEG(u) {
            let data = try Data(contentsOf: u)
            let embedded = embeddedXMP(data)
            let side = fm.fileExists(atPath: sc.path) ? try? String(contentsOf: sc, encoding: .utf8) : nil
            var originals: [String] = []
            if let e = embedded { originals.append("EMBEDDED\n" + e) }
            if let s = side { originals.append("SIDECAR\n" + s) }
            try originals.joined(separator: "\n---\n").write(to: backup, atomically: true, encoding: .utf8)

            let xmp = try ratingOnlyXMP(existing: embedded ?? side, rating: rating)
            let newData = try injectXMP(into: data, xmp: xmp)
            try newData.write(to: u, options: .atomic)
            if side != nil { try xmp.write(to: sc, atomically: true, encoding: .utf8) }
            return WriteOutcome(fileName: u.lastPathComponent, method: "JPG 内嵌 XMP", note: "星级 \(rating)")
        }

        if isRAW(u) {
            let side = fm.fileExists(atPath: sc.path) ? try? String(contentsOf: sc, encoding: .utf8) : nil
            if let s = side { try s.write(to: backup, atomically: true, encoding: .utf8) }
            let xmp = try ratingOnlyXMP(existing: side, rating: rating)
            try xmp.write(to: sc, atomically: true, encoding: .utf8)
            return WriteOutcome(fileName: u.lastPathComponent, method: "同名 .xmp 侧车", note: "星级 \(rating)")
        }

        throw MetaError.unsupportedFormat(u.pathExtension)
    }

    /// 在已有 XMP 上只设置 Rating；没有现成 XMP 时生成一个最小合法包。
    private static func ratingOnlyXMP(existing: String?, rating: Int) throws -> String {
        guard let existing, !existing.isEmpty,
              let data = existing.data(using: .utf8),
              let doc = try? XMLDocument(data: data, options: []),
              let root = doc.rootElement(),
              let desc = firstDescription(root) else {
            return """
            \(packetBegin)
            <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="FocusScreener">
              <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
                <rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/">
                  <xmp:Rating>\(rating)</xmp:Rating>
                </rdf:Description>
              </rdf:RDF>
            </x:xmpmeta>
            \(packetEnd)
            """
        }
        ensureNS(desc, "xmp", "http://ns.adobe.com/xap/1.0/")
        if let node = child(desc, "Rating") {
            node.stringValue = String(rating)
        } else {
            let r = XMLElement(name: "xmp:Rating")
            r.stringValue = String(rating)
            desc.addChild(r)
        }
        return packetBegin + "\n" + root.xmlString + "\n" + packetEnd
    }

    // MARK: - JPEG 字节级写入（不重新编码图像数据）

    static func injectXMP(into data: Data, xmp: String) throws -> Data {
        let b = [UInt8](data)
        guard b.count > 4, b[0] == 0xFF, b[1] == 0xD8 else { throw MetaError.jpegMalformed }
        let payload = headerBytes + Array(xmp.utf8)
        let segLen = payload.count + 2
        guard segLen <= 0xFFFF else { throw MetaError.xmpTooLarge }
        let segment: [UInt8] = [0xFF, 0xE1, UInt8(segLen >> 8), UInt8(segLen & 0xFF)] + payload

        var i = 2
        var replace: Range<Int>?
        var insertAt: Int?
        while i + 3 < b.count {
            if b[i] != 0xFF { break }
            let m = b[i + 1]
            if m == 0xD8 || (m >= 0xD0 && m <= 0xD7) { i += 2; continue }
            if m == 0xDA || m == 0xD9 { break }
            let len = (Int(b[i + 2]) << 8) | Int(b[i + 3])
            if len < 2 { break }
            let end = i + 2 + len
            if end > b.count { break }
            if m == 0xE1 {
                let ps = i + 4
                if end - ps >= headerBytes.count,
                   Array(b[ps..<(ps + headerBytes.count)]) == headerBytes {
                    replace = i..<end
                }
            }
            if insertAt == nil && m != 0xE0 { insertAt = i }
            i = end
        }

        var out: [UInt8] = []
        if let r = replace {
            out += b[0..<r.lowerBound]
            out += segment
            out += b[r.upperBound..<b.count]
        } else {
            let at = insertAt ?? 2
            out += b[0..<at]
            out += segment
            out += b[at..<b.count]
        }
        return Data(out)
    }

    /// 写入前先做一次备份快照，返回备份文件路径；出错时不改动任何文件。
    static func apply(to u: URL, reason: String, addLabel: Bool,
                      backupDir: URL, rating: Int? = nil) throws -> WriteOutcome {
        let note = makeNote(reason)
        let sc = sidecar(u)
        let fm = FileManager.default
        try fm.createDirectory(at: backupDir, withIntermediateDirectories: true)
        let backup = backupDir.appendingPathComponent(u.lastPathComponent + ".before.xmp")
        var originals: [String] = []

        if isJPEG(u) {
            let data = try Data(contentsOf: u)
            let embedded = embeddedXMP(data)
            let side = fm.fileExists(atPath: sc.path) ? try? String(contentsOf: sc, encoding: .utf8) : nil
            if let e = embedded { originals.append("EMBEDDED\n" + e) }
            if let s = side { originals.append("SIDECAR\n" + s) }
            try originals.joined(separator: "\n---\n").write(to: backup, atomically: true, encoding: .utf8)

            let xmp = try mergedXMP(existing: embedded ?? side, note: note,
                                    addLabel: addLabel, rating: rating)
            let newData = try injectXMP(into: data, xmp: xmp)
            try newData.write(to: u, options: .atomic)
            if side != nil { try xmp.write(to: sc, atomically: true, encoding: .utf8) }
            return WriteOutcome(fileName: u.lastPathComponent, method: "JPG 内嵌 XMP", note: note)
        }

        if isRAW(u) {
            let side = fm.fileExists(atPath: sc.path) ? try? String(contentsOf: sc, encoding: .utf8) : nil
            if let s = side { try s.write(to: backup, atomically: true, encoding: .utf8) }
            let xmp = try mergedXMP(existing: side, note: note,
                                    addLabel: addLabel, rating: rating)
            try xmp.write(to: sc, atomically: true, encoding: .utf8)
            return WriteOutcome(fileName: u.lastPathComponent, method: "同名 .xmp 侧车", note: note)
        }

        throw MetaError.unsupportedFormat(u.pathExtension)
    }
}
