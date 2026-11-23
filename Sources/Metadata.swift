import Foundation

struct MetaSnapshot {
    var keywords: [String] = []
    var description: String = ""
    var instructions: String = ""
    var label: String = ""
    /// 本软件写入的鸟种（kf:BirdSpecies 辅助字段），用于精确更新/清除 xmp:Label 里的鸟种段。
    var bird: String?
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
    /// 历史遗留的关键词值（旧版本曾向 dc:subject 写「未合焦」）。
    /// 2026-11 起**完全停止写关键词**：关键词会干扰用户在 Bridge 里已有的关键词体系。
    /// 保留该常量仅供测试/迁移脚本识别旧数据，写入路径不再引用它。
    static let legacyKeyword = "未合焦"
    static let notePrefix = "[合焦质检]"
    /// xmp:Label 里「判定词 / 鸟种」的分隔符。鸟种永远是最后一段，人工修正时只替换它。
    static let birdSeparator = " / "
    private static let birdNamespace = "http://workbuddy.local/kingfisher/1.0/"
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

    /// 构造全新的 XMP 包。**不写 dc:subject 关键词**（用户要求：关键词全部不写，
    /// 避免干扰他现有的 Bridge 关键词体系）；标记改用 xmp:Label 颜色标签，
    /// 颜色由调用方按判定档决定（labelColor 传 nil 则不写标签）。
    static func freshXMP(note: String, labelColor: String?, rating: Int? = nil) -> String {
        let label = labelColor.map { "  <xmp:Label>\($0)</xmp:Label>\n" } ?? ""
        let ratingLine = rating.map { "  <xmp:Rating>\($0)</xmp:Rating>\n" } ?? ""
        let n = xmlEscape(note)
        return """
        \(packetBegin)
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Kingfisher-PhotoSelector">
          <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description rdf:about=""
              xmlns:dc="http://purl.org/dc/elements/1.1/"
              xmlns:xmp="http://ns.adobe.com/xap/1.0/"
              xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/">
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

    /// 合并写入：判定原因写入 dc:description / photoshop:Instructions，
    /// labelColor 非 nil 且已有标签时追加 xmp:Label=<判定词>（判定词由调用方按
    /// Verdict.bridgeLabel 决定：主体清晰/焦点正常/整片偏软/景深不足/主体偏软/主体拖影）。
    /// 用户已有的关键词、说明、星级、标签全部保留，不覆盖。
    static func mergedXMP(existing: String?, note: String, labelColor: String?,
                          rating: Int? = nil) throws -> String {
        guard let existing, !existing.isEmpty
        else { return freshXMP(note: note, labelColor: labelColor, rating: rating) }
        guard let data = existing.data(using: .utf8),
              let doc = try? XMLDocument(data: data, options: []),
              let root = doc.rootElement(),
              let desc = firstDescription(root) else { throw MetaError.xmpUnreadable }

        ensureNS(desc, "dc", "http://purl.org/dc/elements/1.1/")
        ensureNS(desc, "xmp", "http://ns.adobe.com/xap/1.0/")
        ensureNS(desc, "photoshop", "http://ns.adobe.com/photoshop/1.0/")

        // 注意：不再向 dc:subject 写任何关键词（2026-11 起停用）。
        // 用户已有的关键词（可能来自 Bridge 或旧版本写入）原样保留、不清理、不追加。

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

        if let color = labelColor {
            if let l = child(desc, "Label") {
                // 已写鸟种但还没有判定词时把判定词补到最前面（用户已有标签仍不覆盖）
                if child(desc, "BirdSpecies") != nil {
                    let parts = labelParts(l.stringValue)
                    if !parts.contains(where: { ownedLabels.contains($0) }) {
                        l.stringValue = ([color] + parts).joined(separator: birdSeparator)
                    }
                }
            } else {
                let l = XMLElement(name: "xmp:Label")
                l.stringValue = color
                desc.addChild(l)
            }
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
        s.bird = child(desc, "BirdSpecies")?.stringValue
        if let r = child(desc, "Rating")?.stringValue, let v = Int(r.trimmingCharacters(in: .whitespacesAndNewlines)) {
            s.rating = v
        }
        return s
    }

    /// 只改 xmp:Rating，不动说明/关键词/标签。rating 为 0~5 星，-1 表示拒绝。
    /// 与 apply 共用同一套读取、备份、写回路径，但不会追加质检说明。
    static func setRating(to u: URL, rating: Int, backupDir: URL) throws -> WriteOutcome {
        let fm = FileManager.default
        let backup = backupDir.appendingPathComponent(u.lastPathComponent + ".before-rating.xmp")
        let sc = sidecar(u)

        if isJPEG(u) {
            let data = try Data(contentsOf: u)
            let embedded = embeddedXMP(data)
            let side = fm.fileExists(atPath: sc.path) ? try? String(contentsOf: sc, encoding: .utf8) : nil
            var originals: [String] = []
            if let e = embedded { originals.append("EMBEDDED\n" + e) }
            if let s = side { originals.append("SIDECAR\n" + s) }
            if !originals.isEmpty { try writeBackupIfMissing(originals.joined(separator: "\n---\n"), to: backup) }

            let xmp = try ratingOnlyXMP(existing: embedded ?? side, rating: rating)
            let newData = try injectXMP(into: data, xmp: xmp)
            try newData.write(to: u, options: .atomic)
            if side != nil { try xmp.write(to: sc, atomically: true, encoding: .utf8) }
            return WriteOutcome(fileName: u.lastPathComponent, method: "JPG 内嵌 XMP", note: "星级 \(rating)")
        }

        if isRAW(u) {
            let side = fm.fileExists(atPath: sc.path) ? try? String(contentsOf: sc, encoding: .utf8) : nil
            if let s = side { try writeBackupIfMissing(s, to: backup) }
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
            <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Kingfisher-PhotoSelector">
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

    // MARK: - 只写「说明」（dc:description），其余元数据一律不动

    /// 本软件写入说明时的段落标记，刷新时只替换这一段，用户自己的说明原样保留。
    /// 更名历史：FocusScreener → PhotoSelector → Kingfisher-PhotoSelector。
    /// legacyInfoTags 里的旧段落也会被识别并清理，已写入过的照片说明不会残留多段。
    static let infoTag = "[Kingfisher-PhotoSelector]"
    private static let legacyInfoTags = ["[PhotoSelector]", "[FocusScreener]"]

    /// 拼新的说明：保留用户原有说明（剔除本软件新旧段落），末尾追加本软件新内容。
    static func composeDescription(old: String, info: String) -> String {
        let kept = old.components(separatedBy: "\n")
            .filter { line in
                !line.contains(infoTag) && !legacyInfoTags.contains { line.contains($0) }
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return kept.isEmpty ? "\(infoTag) \(info)" : kept + "\n\(infoTag) \(info)"
    }

    /// 在已有 XMP 上只设置 dc:description（Bridge 的「说明」）；
    /// 没有现成 XMP 时生成一个只含说明的最小合法包；已有但解析不了时抛错保护，绝不覆盖。
    private static func descriptionOnlyXMP(existing: String?, note: String) throws -> String {
        guard let existing, !existing.isEmpty else {
            let n = xmlEscape(composeDescription(old: "", info: note))
            return """
            \(packetBegin)
            <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Kingfisher-PhotoSelector">
              <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
                <rdf:Description rdf:about=""
                  xmlns:dc="http://purl.org/dc/elements/1.1/">
                  <dc:description><rdf:Alt><rdf:li xml:lang="x-default">\(n)</rdf:li></rdf:Alt></dc:description>
                </rdf:Description>
              </rdf:RDF>
            </x:xmpmeta>
            \(packetEnd)
            """
        }
        guard let data = existing.data(using: .utf8),
              let doc = try? XMLDocument(data: data, options: []),
              let root = doc.rootElement(),
              let desc = firstDescription(root) else { throw MetaError.xmpUnreadable }
        ensureNS(desc, "dc", "http://purl.org/dc/elements/1.1/")
        if let d = child(desc, "description"), let alt = child(d, "Alt"),
           let li = (alt.children ?? []).compactMap({ $0 as? XMLElement }).first {
            li.stringValue = composeDescription(old: li.stringValue ?? "", info: note)
        } else {
            let d = XMLElement(name: "dc:description")
            let alt = XMLElement(name: "rdf:Alt")
            let li = XMLElement(name: "rdf:li")
            li.addAttribute(attributeNode("xml:lang", "x-default"))
            li.stringValue = composeDescription(old: "", info: note)
            alt.addChild(li)
            d.addChild(alt)
            desc.addChild(d)
        }
        return packetBegin + "\n" + root.xmlString + "\n" + packetEnd
    }

    /// 只写「说明」字段：关键词、星级、颜色标签、Instructions 等全部不动。
    /// RAW 走同名 .xmp 侧车（Bridge 标准方式，不改原片）；JPG 内嵌 XMP。
    static func setDescription(to u: URL, note: String, backupDir: URL) throws -> WriteOutcome {
        let fm = FileManager.default
        let backup = backupDir.appendingPathComponent(u.lastPathComponent + ".before-desc.xmp")
        let sc = sidecar(u)

        if isJPEG(u) {
            let data = try Data(contentsOf: u)
            let embedded = embeddedXMP(data)
            let side = fm.fileExists(atPath: sc.path) ? try? String(contentsOf: sc, encoding: .utf8) : nil
            var originals: [String] = []
            if let e = embedded { originals.append("EMBEDDED\n" + e) }
            if let s = side { originals.append("SIDECAR\n" + s) }
            if !originals.isEmpty { try writeBackupIfMissing(originals.joined(separator: "\n---\n"), to: backup) }

            let xmp = try descriptionOnlyXMP(existing: embedded ?? side, note: note)
            let newData = try injectXMP(into: data, xmp: xmp)
            try newData.write(to: u, options: .atomic)
            if side != nil { try xmp.write(to: sc, atomically: true, encoding: .utf8) }
            return WriteOutcome(fileName: u.lastPathComponent, method: "JPG 内嵌 XMP", note: "说明")
        }

        if isRAW(u) {
            let side = fm.fileExists(atPath: sc.path) ? try? String(contentsOf: sc, encoding: .utf8) : nil
            if let s = side { try writeBackupIfMissing(s, to: backup) }
            let xmp = try descriptionOnlyXMP(existing: side, note: note)
            try xmp.write(to: sc, atomically: true, encoding: .utf8)
            return WriteOutcome(fileName: u.lastPathComponent, method: "同名 .xmp 侧车", note: "说明")
        }

        throw MetaError.unsupportedFormat(u.pathExtension)
    }

    // MARK: - 鸟种标签（追加在 xmp:Label 判定词之后）

    private static func labelParts(_ s: String?) -> [String] {
        (s ?? "").components(separatedBy: birdSeparator)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// 替换标签里的鸟种段；newBird=nil 表示清除。返回 nil 表示整个 Label 都该删掉。
    static func updatedBirdLabel(current: String?, oldBird: String?, newBird: String?) -> String? {
        var parts = labelParts(current)
        if let oldBird, !oldBird.isEmpty { parts.removeAll { $0 == oldBird } }
        if let newBird, !newBird.isEmpty {
            parts.removeAll { $0 == newBird }
            parts.append(newBird)
        }
        return parts.isEmpty ? nil : parts.joined(separator: birdSeparator)
    }

    private static func birdOnlyXMP(existing: String?, bird: String?) throws -> String {
        guard let existing, !existing.isEmpty,
              let data = existing.data(using: .utf8),
              let doc = try? XMLDocument(data: data, options: []),
              let root = doc.rootElement(),
              let desc = firstDescription(root) else {
            let value = bird.map { xmlEscape($0) } ?? ""
            let label = bird.map { "  <xmp:Label>\(xmlEscape($0))</xmp:Label>\n" } ?? ""
            let birdLine = bird.map { _ in "  <kf:BirdSpecies>\(value)</kf:BirdSpecies>\n" } ?? ""
            return """
            \(packetBegin)
            <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Kingfisher-PhotoSelector">
              <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
                <rdf:Description rdf:about=""
                  xmlns:xmp="http://ns.adobe.com/xap/1.0/"
                  xmlns:kf="\(birdNamespace)">
            \(label)\(birdLine)    </rdf:Description>
              </rdf:RDF>
            </x:xmpmeta>
            \(packetEnd)
            """
        }
        ensureNS(desc, "xmp", "http://ns.adobe.com/xap/1.0/")
        ensureNS(desc, "kf", birdNamespace)
        let oldBird = child(desc, "BirdSpecies")?.stringValue
        let kept = updatedBirdLabel(current: child(desc, "Label")?.stringValue,
                                    oldBird: oldBird, newBird: bird)
        if let labelNode = child(desc, "Label") {
            if let kept { labelNode.stringValue = kept } else { detach(labelNode) }
        } else if let kept {
            let l = XMLElement(name: "xmp:Label")
            l.stringValue = kept
            desc.addChild(l)
        }
        if let bird, !bird.isEmpty {
            let e = child(desc, "BirdSpecies") ?? {
                let n = XMLElement(name: "kf:BirdSpecies")
                desc.addChild(n)
                return n
            }()
            e.stringValue = bird
        } else if let e = child(desc, "BirdSpecies") {
            detach(e)
        }
        return packetBegin + "\n" + root.xmlString + "\n" + packetEnd
    }

    /// 只写鸟种标签：判定词、说明、关键词、星级全部保留。bird=nil 清除本软件写的鸟种。
    static func setBirdLabel(to u: URL, bird: String?, backupDir: URL) throws -> WriteOutcome {
        let fm = FileManager.default
        let backup = backupDir.appendingPathComponent(u.lastPathComponent + ".before-bird.xmp")
        let sc = sidecar(u)
        let note = bird.map { "鸟种标签 \($0)" } ?? "清除鸟种标签"

        if isJPEG(u) {
            let data = try Data(contentsOf: u)
            let embedded = embeddedXMP(data)
            let side = fm.fileExists(atPath: sc.path) ? try? String(contentsOf: sc, encoding: .utf8) : nil
            var originals: [String] = []
            if let e = embedded { originals.append("EMBEDDED\n" + e) }
            if let s = side { originals.append("SIDECAR\n" + s) }
            if !originals.isEmpty { try writeBackupIfMissing(originals.joined(separator: "\n---\n"), to: backup) }
            let xmp = try birdOnlyXMP(existing: embedded ?? side, bird: bird)
            let newData = try injectXMP(into: data, xmp: xmp)
            try newData.write(to: u, options: .atomic)
            if side != nil { try xmp.write(to: sc, atomically: true, encoding: .utf8) }
            return WriteOutcome(fileName: u.lastPathComponent, method: "JPG 内嵌 XMP", note: note)
        }

        if isRAW(u) {
            let side = fm.fileExists(atPath: sc.path) ? try? String(contentsOf: sc, encoding: .utf8) : nil
            if let s = side { try writeBackupIfMissing(s, to: backup) }
            let xmp = try birdOnlyXMP(existing: side, bird: bird)
            try xmp.write(to: sc, atomically: true, encoding: .utf8)
            return WriteOutcome(fileName: u.lastPathComponent, method: "同名 .xmp 侧车", note: note)
        }

        throw MetaError.unsupportedFormat(u.pathExtension)
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
    /// 批量写入判定结论：原因进说明字段，labelColor 非 nil 时写对应标签。
    /// 不再写任何关键词（dc:subject 完全停用）；已有元数据全部保留。
    /// 备份放到照片所在目录（backupDir 由调用方传照片父目录）；
    /// 已有备份时不覆盖——永远保留第一次写入前的原始状态（2026-11-20 用户要求）。
    static func apply(to u: URL, reason: String, labelColor: String?,
                      backupDir: URL, rating: Int? = nil) throws -> WriteOutcome {
        let note = makeNote(reason)
        let sc = sidecar(u)
        let fm = FileManager.default
        let backup = backupDir.appendingPathComponent(u.lastPathComponent + ".before.xmp")
        var originals: [String] = []

        if isJPEG(u) {
            let data = try Data(contentsOf: u)
            let embedded = embeddedXMP(data)
            let side = fm.fileExists(atPath: sc.path) ? try? String(contentsOf: sc, encoding: .utf8) : nil
            if let e = embedded { originals.append("EMBEDDED\n" + e) }
            if let s = side { originals.append("SIDECAR\n" + s) }
            if !originals.isEmpty { try writeBackupIfMissing(originals.joined(separator: "\n---\n"), to: backup) }

            let xmp = try mergedXMP(existing: embedded ?? side, note: note,
                                    labelColor: labelColor, rating: rating)
            let newData = try injectXMP(into: data, xmp: xmp)
            try newData.write(to: u, options: .atomic)
            if side != nil { try xmp.write(to: sc, atomically: true, encoding: .utf8) }
            return WriteOutcome(fileName: u.lastPathComponent, method: "JPG 内嵌 XMP", note: note)
        }

        if isRAW(u) {
            let side = fm.fileExists(atPath: sc.path) ? try? String(contentsOf: sc, encoding: .utf8) : nil
            if let s = side { try writeBackupIfMissing(s, to: backup) }
            let xmp = try mergedXMP(existing: side, note: note,
                                    labelColor: labelColor, rating: rating)
            try xmp.write(to: sc, atomically: true, encoding: .utf8)
            return WriteOutcome(fileName: u.lastPathComponent, method: "同名 .xmp 侧车", note: note)
        }

        throw MetaError.unsupportedFormat(u.pathExtension)
    }

    /// 备份原始元数据：**已存在时不覆盖**——永远保留第一次写入前的原始状态，
    /// 避免反复写入时把最初备份冲掉（备份随照片放在同目录，2026-11-20 用户要求）。
    private static func writeBackupIfMissing(_ content: String, to url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard !fm.fileExists(atPath: url.path) else { return }
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - 清除本软件写入的标记（2026-11-20 用户要求的一键清除）

    /// 本软件写过的所有标记文本（现行 + 历史）：判定原因、切换照片写的说明段。
    /// 清除时只删含这些标记的行/段，用户自己的说明、关键词、星级、拒绝标记、
    /// 其他来源的标签一律不动。
    static var ownedTags: [String] { [notePrefix, infoTag] + legacyInfoTags }
    /// 本软件写过的 xmp:Label 值（判定词体系，2026-11 起启用）。
    static var ownedLabels: Set<String> { Set(Verdict.allCases.map(\.rawValue)) }

    private static func lineIsOwned(_ line: String) -> Bool {
        ownedTags.contains { line.contains($0) }
    }

    /// 从父节点摘除一个子节点（Foundation XMLNode 用 detach）。
    private static func detach(_ el: XMLElement) {
        el.detach()
    }

    /// 在已有 XMP 上清除本软件标记：说明/Instructions 里删掉本软件的段落，
    /// 标签若是本软件写的判定词则整个移除。没有任何本软件标记时返回 nil（无需写回）。
    private static func cleanedXMP(existing: String) throws -> String? {
        guard let data = existing.data(using: .utf8),
              let doc = try? XMLDocument(data: data, options: []),
              let root = doc.rootElement(),
              let desc = firstDescription(root) else { throw MetaError.xmpUnreadable }

        var changed = false

        if let d = child(desc, "description"), let alt = child(d, "Alt"),
           let li = (alt.children ?? []).compactMap({ $0 as? XMLElement }).first {
            let old = li.stringValue ?? ""
            let kept = old.components(separatedBy: "\n")
                .filter { !lineIsOwned($0) }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if kept != old {
                changed = true
                if kept.isEmpty { detach(d) } else { li.stringValue = kept }
            }
        }

        if let ins = child(desc, "Instructions") {
            let old = ins.stringValue ?? ""
            let kept = old.components(separatedBy: " | ")
                .filter { !lineIsOwned($0) }
                .joined(separator: " | ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if kept != old {
                changed = true
                if kept.isEmpty { detach(ins) } else { ins.stringValue = kept }
            }
        }

        // 鸟种段先精确摘除，判定词段随后按 ownedLabels 摘除；用户自己的标签原样保留。
        if let birdNode = child(desc, "BirdSpecies") {
            let oldBird = birdNode.stringValue
            if let l = child(desc, "Label") {
                if let kept = updatedBirdLabel(current: l.stringValue, oldBird: oldBird, newBird: nil) {
                    if kept != (l.stringValue ?? "") { l.stringValue = kept; changed = true }
                } else {
                    detach(l)
                    changed = true
                }
            }
            detach(birdNode)
            changed = true
        }
        if let l = child(desc, "Label") {
            let parts = labelParts(l.stringValue)
            let kept = parts.filter { !ownedLabels.contains($0) }
            if kept.count != parts.count {
                if kept.isEmpty { detach(l) } else { l.stringValue = kept.joined(separator: birdSeparator) }
                changed = true
            }
        }

        guard changed else { return nil }
        return packetBegin + "\n" + root.xmlString + "\n" + packetEnd
    }

    /// 清除一张照片上本软件写入的标记。用户原有元数据一律不动；
    /// 没有任何本软件标记时不写文件（removed=false）；
    /// 有标记时先备份（沿用「已有备份不覆盖」规则）再写回。JPG 内嵌 + 侧车都清。
    static func cleanup(to u: URL, backupDir: URL) throws
        -> (fileName: String, method: String, removed: Bool) {
        let fm = FileManager.default
        let sc = sidecar(u)

        if isJPEG(u) {
            let data = try Data(contentsOf: u)
            let embedded = embeddedXMP(data)
            let side = fm.fileExists(atPath: sc.path) ? try? String(contentsOf: sc, encoding: .utf8) : nil
            guard embedded != nil || side != nil else {
                return (u.lastPathComponent, "JPG 内嵌 XMP", false)
            }
            var changed = false
            var newData = data
            if let e = embedded, let cleaned = try cleanedXMP(existing: e) {
                newData = try injectXMP(into: data, xmp: cleaned)
                changed = true
            }
            if let s = side, let cleaned = try cleanedXMP(existing: s) {
                try cleaned.write(to: sc, atomically: true, encoding: .utf8)
                changed = true
            }
            guard changed else { return (u.lastPathComponent, "JPG 内嵌 XMP", false) }
            var originals: [String] = []
            if let e = embedded { originals.append("EMBEDDED\n" + e) }
            if let s = side { originals.append("SIDECAR\n" + s) }
            try writeBackupIfMissing(originals.joined(separator: "\n---\n"),
                                     to: backupDir.appendingPathComponent(u.lastPathComponent + ".before.xmp"))
            try newData.write(to: u, options: .atomic)
            return (u.lastPathComponent, "JPG 内嵌 XMP", true)
        }

        if isRAW(u) {
            guard fm.fileExists(atPath: sc.path),
                  let s = try? String(contentsOf: sc, encoding: .utf8), !s.isEmpty else {
                return (u.lastPathComponent, "同名 .xmp 侧车", false)
            }
            guard let cleaned = try cleanedXMP(existing: s) else {
                return (u.lastPathComponent, "同名 .xmp 侧车", false)
            }
            try writeBackupIfMissing(s, to: backupDir.appendingPathComponent(u.lastPathComponent + ".before.xmp"))
            try cleaned.write(to: sc, atomically: true, encoding: .utf8)
            return (u.lastPathComponent, "同名 .xmp 侧车", true)
        }

        throw MetaError.unsupportedFormat(u.pathExtension)
    }
}
