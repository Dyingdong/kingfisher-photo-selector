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

    // 同一侧车的读取、备份与原子替换共用锁。固定锁池避免按照片永久持有锁。
    private static let writeLocks = (0..<64).map { _ in NSLock() }
    private static func writeLock(for url: URL) -> NSLock {
        let path = sidecar(url).resolvingSymlinksInPath().standardizedFileURL.path.lowercased()
        return writeLocks[Int(UInt(bitPattern: path.hashValue) % UInt(writeLocks.count))]
    }

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

    private static let xmpNamespace = "http://ns.adobe.com/xap/1.0/"

    private static func xmpNodes(_ property: String, in root: XMLNode) -> [XMLNode] {
        var nodes: [XMLNode] = []
        if let element = root as? XMLElement,
           element.localName == "Description",
           element.uri == "http://www.w3.org/1999/02/22-rdf-syntax-ns#" {
            nodes = (element.attributes ?? []) + (element.children ?? [])
            return nodes.filter { $0.localName == property && $0.uri == xmpNamespace }
        }
        return (root.children ?? []).flatMap { xmpNodes(property, in: $0) }
    }

    private static func updateRating(_ rating: Int, root: XMLElement, description: XMLElement) {
        let nodes = xmpNodes("Rating", in: root)
        if let first = nodes.first {
            first.stringValue = String(rating)
            for duplicate in nodes.dropFirst() { duplicate.detach() }
        } else {
            ensureNS(description, "xmp", xmpNamespace)
            let node = XMLElement(name: "xmp:Rating", stringValue: String(rating))
            description.addChild(node)
        }
    }

    private static func labelParts(in nodes: [XMLNode]) -> [String] {
        var seen = Set<String>()
        return nodes.flatMap { labelParts($0.stringValue) }.filter { seen.insert($0).inserted }
    }

    private static func updateLabel(_ value: String?, nodes: [XMLNode], description: XMLElement) {
        if let value, let first = nodes.first {
            first.stringValue = value
            for duplicate in nodes.dropFirst() { duplicate.detach() }
        } else if let value {
            ensureNS(description, "xmp", xmpNamespace)
            description.addChild(XMLElement(name: "xmp:Label", stringValue: value))
        } else {
            for node in nodes { node.detach() }
        }
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

    private static func parseForWriting(_ existing: String) throws -> (XMLElement, XMLElement) {
        let data = Data(existing.utf8)
        let parser = XMLParser(data: data)
        guard parser.parse(), parser.parserError == nil,
              let doc = try? XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever]),
              let root = doc.rootElement(), let desc = firstDescription(root) else {
            throw MetaError.xmpUnreadable
        }
        return (root, desc)
    }

    /// 合并写入：判定原因写入 dc:description / photoshop:Instructions。
    /// labelColor 非 nil 且已有标签时追加 xmp:Label=<判定词>（判定词由调用方按
    /// Verdict.bridgeLabel 决定：主体清晰/焦点正常/整片偏软/景深不足/主体偏软/主体拖影）。
    /// 用户已有的关键词、说明、星级、标签全部保留，不覆盖。
    static func mergedXMP(existing: String?, note: String, labelColor: String?,
                          rating: Int? = nil) throws -> String {
        guard let existing
        else { return freshXMP(note: note, labelColor: labelColor, rating: rating) }
        let (root, desc) = try parseForWriting(existing)

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
            let labels = xmpNodes("Label", in: root)
            var parts = labelParts(in: labels)
            if labels.isEmpty || (child(desc, "BirdSpecies") != nil && !parts.contains(where: ownedLabels.contains)) {
                parts.insert(color, at: 0)
                updateLabel(parts.joined(separator: birdSeparator), nodes: labels, description: desc)
            } else if labels.count > 1 {
                updateLabel(parts.isEmpty ? nil : parts.joined(separator: birdSeparator), nodes: labels, description: desc)
            }
        }

        // xmp:Rating：0~5 星；-1 = Bridge 的「拒绝」。传入 nil 时保留原值。
        if let rating { updateRating(rating, root: root, description: desc) }

        return packetBegin + "\n" + root.xmlString + "\n" + packetEnd
    }

    // MARK: - 读取已有元数据

    static func embeddedXMP(_ data: Data) -> String? {
        try? readEmbeddedXMP(data)
    }

    /// 同一套 JPEG 段边界用于读取和替换。遇到重复的标准 XMP 包时无法确定应改哪一份。
    private static func jpegXMPLocation(_ bytes: [UInt8]) throws -> (packet: Range<Int>?, insertAt: Int) {
        guard bytes.starts(with: [0xFF, 0xD8]) else { throw MetaError.jpegMalformed }
        var i = 2
        var packet: Range<Int>?
        var insertAt: Int?
        while i + 1 < bytes.count {
            guard bytes[i] == 0xFF else { throw MetaError.jpegMalformed }
            let marker = bytes[i + 1]
            if marker == 0xFF { i += 1; continue }
            if marker == 0xDA || marker == 0xD9 { return (packet, insertAt ?? i) }
            if marker == 0x01 || (0xD0...0xD7).contains(marker) { i += 2; continue }
            guard marker != 0, i + 3 < bytes.count else { throw MetaError.jpegMalformed }
            let length = (Int(bytes[i + 2]) << 8) | Int(bytes[i + 3])
            let end = i + 2 + length
            guard length >= 2, end <= bytes.count else { throw MetaError.jpegMalformed }
            if marker == 0xE1, bytes[(i + 4)..<end].starts(with: headerBytes) {
                guard packet == nil else { throw MetaError.xmpUnreadable }
                packet = i..<end
            }
            if insertAt == nil && marker != 0xE0 { insertAt = i }
            i = end
        }
        throw MetaError.jpegMalformed
    }

    private static func readEmbeddedXMP(_ data: Data) throws -> String? {
        let bytes = [UInt8](data)
        guard let packet = try jpegXMPLocation(bytes).packet else { return nil }
        let start = packet.lowerBound + 4 + headerBytes.count
        guard let value = String(bytes: bytes[start..<packet.upperBound], encoding: .utf8) else {
            throw MetaError.xmpUnreadable
        }
        return value
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
        s.label = labelParts(in: xmpNodes("Label", in: root)).joined(separator: birdSeparator)
        s.bird = child(desc, "BirdSpecies")?.stringValue
        if let r = xmpNodes("Rating", in: root).last?.stringValue,
           let v = Int(r.trimmingCharacters(in: .whitespacesAndNewlines)), (-1...5).contains(v) {
            s.rating = v
        }
        return s
    }

    /// 只改 xmp:Rating，不动说明/关键词/标签。rating 为 0~5 星，-1 表示拒绝。
    /// 与 apply 共用同一套读取、备份、写回路径，但不会追加质检说明。
    static func setRating(to u: URL, rating: Int, backupDir: URL) throws -> WriteOutcome {
        let lock = writeLock(for: u)
        lock.lock()
        defer { lock.unlock() }

        let backup = backupDir.appendingPathComponent(u.lastPathComponent + ".before-rating.xmp")
        return try writeMetadata(to: u, backup: backup, note: "星级 \(rating)") {
            try ratingOnlyXMP(existing: $0, rating: rating)
        }
    }

    /// 在已有 XMP 上只设置 Rating；没有现成 XMP 时生成一个最小合法包。
    private static func ratingOnlyXMP(existing: String?, rating: Int) throws -> String {
        guard let existing else {
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
        let (root, desc) = try parseForWriting(existing)
        updateRating(rating, root: root, description: desc)
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
        guard let existing else {
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
        let (root, desc) = try parseForWriting(existing)
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
        let lock = writeLock(for: u)
        lock.lock()
        defer { lock.unlock() }

        return try writeDescription(to: u, note: note, backupDir: backupDir)
    }

    static func setDescriptionIfEmpty(to u: URL, note: String, backupDir: URL) throws -> Bool {
        let lock = writeLock(for: u)
        lock.lock()
        defer { lock.unlock() }
        guard snapshot(u).description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        _ = try writeDescription(to: u, note: note, backupDir: backupDir)
        return true
    }

    private static func writeDescription(to u: URL, note: String, backupDir: URL) throws -> WriteOutcome {
        let backup = backupDir.appendingPathComponent(u.lastPathComponent + ".before-desc.xmp")
        return try writeMetadata(to: u, backup: backup, note: "说明") {
            try descriptionOnlyXMP(existing: $0, note: note)
        }
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
        guard let existing else {
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
        let (root, desc) = try parseForWriting(existing)
        ensureNS(desc, "xmp", "http://ns.adobe.com/xap/1.0/")
        ensureNS(desc, "kf", birdNamespace)
        let oldBird = child(desc, "BirdSpecies")?.stringValue
        let labels = xmpNodes("Label", in: root)
        let kept = updatedBirdLabel(current: labelParts(in: labels).joined(separator: birdSeparator),
                                    oldBird: oldBird, newBird: bird)
        updateLabel(kept, nodes: labels, description: desc)
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
        let lock = writeLock(for: u)
        lock.lock()
        defer { lock.unlock() }

        let backup = backupDir.appendingPathComponent(u.lastPathComponent + ".before-bird.xmp")
        return try writeMetadata(to: u, backup: backup, note: bird.map { "鸟种标签 \($0)" } ?? "清除鸟种标签") {
            try birdOnlyXMP(existing: $0, bird: bird)
        }
    }

    // MARK: - JPEG 字节级写入（不重新编码图像数据）

    static func injectXMP(into data: Data, xmp: String) throws -> Data {
        let b = [UInt8](data)
        guard b.count > 4, b[0] == 0xFF, b[1] == 0xD8 else { throw MetaError.jpegMalformed }
        let payload = headerBytes + Array(xmp.utf8)
        let segLen = payload.count + 2
        guard segLen <= 0xFFFF else { throw MetaError.xmpTooLarge }
        let segment: [UInt8] = [0xFF, 0xE1, UInt8(segLen >> 8), UInt8(segLen & 0xFF)] + payload

        let location = try jpegXMPLocation(b)
        let range = location.packet ?? (location.insertAt..<location.insertAt)
        var out = Data()
        out.reserveCapacity(b.count - range.count + segment.count)
        out.append(contentsOf: b[..<range.lowerBound])
        out.append(contentsOf: segment)
        out.append(contentsOf: b[range.upperBound...])
        return out
    }

    /// 写入前先做一次备份快照，返回备份文件路径；出错时不改动任何文件。
    /// 批量写入判定结论：原因进说明字段，labelColor 非 nil 时写对应标签。
    /// 不再写任何关键词（dc:subject 完全停用）；已有元数据全部保留。
    /// 备份放到照片所在目录（backupDir 由调用方传照片父目录）；
    /// 已有备份时不覆盖——永远保留第一次写入前的原始状态（2026-11-20 用户要求）。
    static func apply(to u: URL, reason: String, labelColor: String?,
                      backupDir: URL, rating: Int? = nil) throws -> WriteOutcome {
        let lock = writeLock(for: u)
        lock.lock()
        defer { lock.unlock() }

        let backup = backupDir.appendingPathComponent(u.lastPathComponent + ".before.xmp")
        return try writeMetadata(to: u, backup: backup, note: makeNote(reason)) {
            try mergedXMP(existing: $0, note: makeNote(reason), labelColor: labelColor, rating: rating)
        }
    }

    private static func readSidecar(_ url: URL) throws -> String? {
        do { return try String(contentsOf: url, encoding: .utf8) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
    }

    private static func writeMetadata(to url: URL, backup: URL, note: String,
                                      update: (String?) throws -> String) throws -> WriteOutcome {
        guard isSupported(url) else { throw MetaError.unsupportedFormat(url.pathExtension) }
        let sc = sidecar(url)
        let side = try readSidecar(sc)
        if isJPEG(url) {
            let original = try Data(contentsOf: url)
            let embedded = try readEmbeddedXMP(original)
            let updated = try update(embedded ?? side)
            let updatedSide = try side.map { try update($0) }
            let photo = try injectXMP(into: original, xmp: updated)
            try backupJPEG(embedded: embedded, side: side, to: backup)
            try writeJPEG(photo, original: original, to: url, side: updatedSide)
            return WriteOutcome(fileName: url.lastPathComponent, method: "JPG 内嵌 XMP", note: note)
        }
        let updated = try update(side)
        if let side { try writeBackupIfMissing(side, to: backup) }
        try updated.write(to: sc, atomically: true, encoding: .utf8)
        return WriteOutcome(fileName: url.lastPathComponent, method: "同名 .xmp 侧车", note: note)
    }

    private static func backupJPEG(embedded: String?, side: String?, to backup: URL) throws {
        let originals = [embedded.map { "EMBEDDED\n" + $0 }, side.map { "SIDECAR\n" + $0 }].compactMap { $0 }
        if !originals.isEmpty { try writeBackupIfMissing(originals.joined(separator: "\n---\n"), to: backup) }
    }

    private static func writeJPEG(_ photo: Data?, original: Data, to url: URL, side: String?) throws {
        if let photo { try photo.write(to: url, options: .atomic) }
        do { try side?.write(to: sidecar(url), atomically: true, encoding: .utf8) }
        catch {
            if photo != nil { try original.write(to: url, options: .atomic) }
            throw error
        }
    }

    /// 备份原始元数据：**已存在时不覆盖**——永远保留第一次写入前的原始状态，
    /// 避免反复写入时把最初备份冲掉（备份随照片放在同目录，2026-11-20 用户要求）。
    private static func writeBackupIfMissing(_ content: String, to url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var directory: ObjCBool = false
        if fm.fileExists(atPath: url.path, isDirectory: &directory) {
            if directory.boolValue { throw CocoaError(.fileWriteFileExists) }
            return
        }
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
        let (root, desc) = try parseForWriting(existing)

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

        let labels = xmpNodes("Label", in: root)
        let parts = labelParts(in: labels)
        let birdNode = child(desc, "BirdSpecies")
        let kept = parts.filter { $0 != birdNode?.stringValue && !ownedLabels.contains($0) }
        if kept != parts {
            updateLabel(kept.isEmpty ? nil : kept.joined(separator: birdSeparator),
                        nodes: labels, description: desc)
            changed = true
        }
        if let birdNode {
            detach(birdNode)
            changed = true
        }

        guard changed else { return nil }
        return packetBegin + "\n" + root.xmlString + "\n" + packetEnd
    }

    /// 清除一张照片上本软件写入的标记。用户原有元数据一律不动；
    /// 没有任何本软件标记时不写文件（removed=false）；
    /// 有标记时先备份（沿用「已有备份不覆盖」规则）再写回。JPG 内嵌 + 侧车都清。
    static func cleanup(to u: URL, backupDir: URL) throws
        -> (fileName: String, method: String, removed: Bool) {
        let lock = writeLock(for: u)
        lock.lock()
        defer { lock.unlock() }

        let sc = sidecar(u)
        let side = try readSidecar(sc)

        if isJPEG(u) {
            let data = try Data(contentsOf: u)
            let embedded = try readEmbeddedXMP(data)
            let newPhoto = try embedded.flatMap { try cleanedXMP(existing: $0) }
                .map { try injectXMP(into: data, xmp: $0) }
            let newSide = try side.flatMap { try cleanedXMP(existing: $0) }
            guard newPhoto != nil || newSide != nil else { return (u.lastPathComponent, "JPG 内嵌 XMP", false) }
            try backupJPEG(embedded: embedded, side: side,
                           to: backupDir.appendingPathComponent(u.lastPathComponent + ".before.xmp"))
            try writeJPEG(newPhoto, original: data, to: u, side: newSide)
            return (u.lastPathComponent, "JPG 内嵌 XMP", true)
        }

        if isRAW(u) {
            guard let s = side else {
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
