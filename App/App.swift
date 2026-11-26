import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Foundation
import CoreGraphics
import ImageIO

// MARK: - 导入后题材选择

/// 导入文件夹后让用户整批指定题材；auto = 保持逐张自动识别。
enum FolderGenreChoice: String, CaseIterable, Identifiable {
    case auto, bird, landscape, portrait

    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto:      return "自动识别题材"
        case .bird:      return "鸟类摄影"
        case .landscape: return "风光摄影"
        case .portrait:  return "人像摄影"
        }
    }
    var detail: String {
        switch self {
        case .auto:      return "每张照片单独判断"
        case .bird:      return "看重主体清晰、锐度高"
        case .landscape: return "先看主体清晰，再看整体锐度"
        case .portrait:  return "看对焦点、人脸清晰与白平衡"
        }
    }
    var genre: PhotoGenre? {
        switch self {
        case .auto:      return nil
        case .bird:      return .bird
        case .landscape: return .landscape
        case .portrait:  return .portrait
        }
    }
}

// MARK: - 快捷键配置

/// 可用于框选手势的修饰键。
enum ModifierKey: String, CaseIterable, Identifiable, Codable {
    case command, control, option, shift

    var id: String { rawValue }
    var label: String {
        switch self {
        case .command: return "⌘ Command"
        case .control: return "⌃ Control"
        case .option:  return "⌥ Option"
        case .shift:   return "⇧ Shift"
        }
    }
    var symbol: String {
        switch self {
        case .command: return "⌘"
        case .control: return "⌃"
        case .option:  return "⌥"
        case .shift:   return "⇧"
        }
    }
    var flag: NSEvent.ModifierFlags {
        switch self {
        case .command: return .command
        case .control: return .control
        case .option:  return .option
        case .shift:   return .shift
        }
    }
}

/// 左键手势的意图。
enum DragAction {
    case zoom      // 框选放大
    case subject   // 圈选主体重判
    case pan       // 平移画面（按住左键拖动 / 空格）
    case divider   // 拖动分隔条（在预览区外、下方的 8pt 区域）
}

/// 预览工具栏里可切换显示的辅助项。快捷键与一键隐藏/恢复都按这个列表走。
enum OverlayItem: String, CaseIterable, Identifiable {
    case heatmap, afPoints, thirds, diagonals, aiBox, manualBox

    var id: String { rawValue }
    var label: String {
        switch self {
        case .heatmap:   return "锐度热力图"
        case .afPoints:  return "对焦点"
        case .thirds:    return "九宫格"
        case .diagonals: return "对角线"
        case .aiBox:     return "AI主体蓝框"
        case .manualBox: return "自选主体黄框"
        }
    }
}

/// 一个按键组合：key 是小写字母/符号（如 "h"、"/"），modifiers 是需要的修饰键。
/// 空 modifiers 表示直接按字母；空 key 表示未设置（不响应）。
struct KeyCombo: Codable, Equatable, Hashable {
    var key: String
    var modifiers: [ModifierKey]

    init(_ key: String = "", _ modifiers: [ModifierKey] = []) {
        self.key = KeyCombo.normalize(key)
        self.modifiers = modifiers
    }

    private enum CodingKeys: String, CodingKey { case key, modifiers }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = KeyCombo.normalize(try c.decodeIfPresent(String.self, forKey: .key) ?? "")
        modifiers = try c.decodeIfPresent([ModifierKey].self, forKey: .modifiers) ?? []
    }

    /// 中文输入法下「、」和「/」是同一个物理键，统一成 "/"，这样 ⌘/ 与 ⌘、 都生效。
    static func normalize(_ s: String) -> String {
        switch s {
        case "、", "／": return "/"
        default: return s.lowercased()
        }
    }

    /// 显示用：⌃⌥⇧⌘ + 大写按键，例如 "H"、"⌘/"。
    var display: String {
        let ordered: [ModifierKey] = [.control, .option, .shift, .command]
        let prefix = ordered.compactMap { modifiers.contains($0) ? $0.symbol : nil }.joined()
        return prefix + key.uppercased()
    }

    var flags: NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        for m in modifiers { f.insert(m.flag) }
        return f
    }

    /// 是否与这次按键事件匹配；修饰键必须完全一致，避免 ⌘H 触发 H。
    func matches(_ e: NSEvent) -> Bool {
        guard !key.isEmpty else { return false }
        let pressed = e.modifierFlags.intersection([.command, .control, .option, .shift])
        guard pressed == flags else { return false }
        if let ch = e.characters?.first {
            return KeyCombo.normalize(String(ch)) == key
        }
        // 中文输入法偶发 characters 为空：42 是美式键盘的 "/" 键码，给一键隐藏兜底。
        if key == "/", e.keyCode == 42 { return true }
        return false
    }
}

/// 用户可自定义的快捷键，持久化到 UserDefaults。
struct ShortcutSettings: Codable, Equatable {
    var zoom: ModifierKey = .command       // 框选放大，默认 ⌘
    var subject: ModifierKey = .control    // 圈选主体，默认 ⌃(Control)

    // 六个辅助项的显示/隐藏快捷键（2026-11-23 用户要求，可自定义）。
    var heatmap = KeyCombo("h")
    var afPoints = KeyCombo("f")
    var thirds = KeyCombo("g")
    var diagonals = KeyCombo("d")
    var aiBox = KeyCombo("b")              // AI 主体蓝框
    var manualBox = KeyCombo("y")          // 自选主体黄框
    /// 一键隐藏当前勾选的辅助项 / 再按一次恢复（默认 ⌘/，中文输入法下 ⌘、 等效）。
    var overlayToggle = KeyCombo("/", [.command])

    private enum CodingKeys: String, CodingKey {
        case zoom, subject, heatmap, afPoints, thirds, diagonals, aiBox, manualBox, overlayToggle
    }
    /// 显式无参构造：自定义 init(from:) 后保留 ShortcutSettings() 用法。
    init() {}
    /// 老版本保存的 JSON 只有 zoom/subject，缺失字段用默认值补齐，不丢用户原来的修饰键设置。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        zoom = try c.decodeIfPresent(ModifierKey.self, forKey: .zoom) ?? .command
        subject = try c.decodeIfPresent(ModifierKey.self, forKey: .subject) ?? .control
        heatmap = try c.decodeIfPresent(KeyCombo.self, forKey: .heatmap) ?? KeyCombo("h")
        afPoints = try c.decodeIfPresent(KeyCombo.self, forKey: .afPoints) ?? KeyCombo("f")
        thirds = try c.decodeIfPresent(KeyCombo.self, forKey: .thirds) ?? KeyCombo("g")
        diagonals = try c.decodeIfPresent(KeyCombo.self, forKey: .diagonals) ?? KeyCombo("d")
        aiBox = try c.decodeIfPresent(KeyCombo.self, forKey: .aiBox) ?? KeyCombo("b")
        manualBox = try c.decodeIfPresent(KeyCombo.self, forKey: .manualBox) ?? KeyCombo("y")
        overlayToggle = try c.decodeIfPresent(KeyCombo.self, forKey: .overlayToggle) ?? KeyCombo("/", [.command])
    }

    private static let storeKey = "Kingfisher-PhotoSelector.shortcuts.v1"
    /// 更名前的旧存储 key（FocusScreener / PhotoSelector 时代），只用于一次性迁移读取。
    private static let legacyStoreKeys = ["PhotoSelector.shortcuts.v1",
                                          "FocusScreener.shortcuts.v1"]

    static func load() -> ShortcutSettings {
        if let data = UserDefaults.standard.data(forKey: storeKey),
           let s = try? JSONDecoder().decode(ShortcutSettings.self, from: data) {
            return s
        }
        // 旧版本迁移：读到旧 key 的设置就搬到新 key，用户自定义过的手势不丢。
        for key in legacyStoreKeys {
            if let data = UserDefaults.standard.data(forKey: key),
               let s = try? JSONDecoder().decode(ShortcutSettings.self, from: data) {
                UserDefaults.standard.set(data, forKey: storeKey)
                UserDefaults.standard.removeObject(forKey: key)
                return s
            }
        }
        return ShortcutSettings()
    }
    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.storeKey)
        }
    }
    func combo(for item: OverlayItem) -> KeyCombo {
        switch item {
        case .heatmap:   return heatmap
        case .afPoints:  return afPoints
        case .thirds:    return thirds
        case .diagonals: return diagonals
        case .aiBox:     return aiBox
        case .manualBox: return manualBox
        }
    }
    mutating func setCombo(_ combo: KeyCombo, for item: OverlayItem) {
        switch item {
        case .heatmap:   heatmap = combo
        case .afPoints:  afPoints = combo
        case .thirds:    thirds = combo
        case .diagonals: diagonals = combo
        case .aiBox:     aiBox = combo
        case .manualBox: manualBox = combo
        }
    }
    /// 所有按键组合，供设置面板查重；空 key（未设置）不参与查重。
    var allCombos: [(name: String, combo: KeyCombo)] {
        var list = OverlayItem.allCases.map { (name: $0.label, combo: combo(for: $0)) }
        list.append((name: "一键隐藏/恢复辅助项", combo: overlayToggle))
        return list.filter { !$0.combo.key.isEmpty }
    }
    /// 判断当前按下的修饰键对应哪个框选动作；无匹配返回 nil（交给平移/复位）。
    func action(for flags: NSEvent.ModifierFlags) -> DragAction? {
        let f = flags.intersection([.command, .control, .option, .shift])
        if f.contains(zoom.flag) { return .zoom }
        if f.contains(subject.flag) { return .subject }
        return nil
    }
}

/// 左侧目录缩略图档位。默认档（normal）就是原先的 46×34，老用户升级后外观不变。
/// 缓存统一按 192px 解码再交给 SwiftUI 缩放，切换档位不需要重建缓存，也不会串尺寸。
enum ListThumbnailScale: Int, CaseIterable, Identifiable {
    case small = 0
    case normal = 1
    case large = 2
    case huge = 3

    var id: Int { rawValue }

    /// 保持原 46:34 的横图比例。
    var size: CGSize {
        switch self {
        case .small:  return CGSize(width: 34, height: 25)
        case .normal: return CGSize(width: 46, height: 34)
        case .large:  return CGSize(width: 64, height: 47)
        case .huge:   return CGSize(width: 88, height: 65)
        }
    }

    /// 相对默认档的百分比，工具栏直接显示。
    var percent: Int {
        switch self {
        case .small:  74
        case .normal: 100
        case .large:  139
        case .huge:   191
        }
    }

    /// 行高估算 = 缩略图高 + 上下 padding 与列表行间距（Shift 边缘滚动换算可见行数用）。
    var rowHeight: CGFloat { size.height + 12 }

    private static let storeKey = "Kingfisher-PhotoSelector.thumbnailScale.v1"

    static func load() -> ListThumbnailScale {
        guard let raw = UserDefaults.standard.object(forKey: storeKey) as? Int,
              let value = ListThumbnailScale(rawValue: raw) else { return .normal }
        return value
    }

    func save() {
        UserDefaults.standard.set(rawValue, forKey: Self.storeKey)
    }
}

// MARK: - 分析用缩略图

extension Analyzer {
    /// 信息区分析共用的 1024px 彩色缩略图，与 HumanPresenceEngine.detect(url:) /
    /// AISubjectEngine.detect(url:) 内部参数完全一致，只是解码一次供两者复用。
    static func analysisThumbnail(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1024
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }
}

// MARK: - 中间层预览缓存（屏幕自适应分辨率，落盘可重建）

/// 导入分析阶段生成的「按屏幕自适应分辨率」彩色 JPEG 预览，写入 App Support
/// 下的专用缓存目录（派生数据，不写进用户照片文件夹、不进 Git，可整体删除重建）。
/// 显示链为双层：原尺寸未就位时先显示**本张**的中间层（同一张照片，不是上一张），
/// 原尺寸解码完成后无缝替换——恢复 v1.0 的清晰且快的体验，但中间层落盘可重建，
/// 不再有 1200px 全量常驻内存的负担。
///
/// 目录结构：App Support/Kingfisher-PhotoSelector/PreviewCache/<文件夹路径哈希>/
/// 文件名 = <照片名>-<源文件 mtime>-<源文件 size>.jpg——源文件重新分析/被替换后
/// mtime/size 变化，文件名自然指向新文件，旧 stamp 文件在生成时顺手清理。
private enum MidPreviewCache {
    static let jpegQuality: CGFloat = 0.9
    static let maxSideCap = 3840
    static let minSideFloor = 1600

    static var rootDir: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask)[0]
        return support.appendingPathComponent("Kingfisher-PhotoSelector/PreviewCache",
                                              isDirectory: true)
    }

    /// FNV-1a 路径哈希（与 SessionCache.legacyFile 同风格），做子目录名。
    static func folderHash(_ folder: URL) -> String {
        var h: UInt64 = 1469598103934665603
        for b in folder.standardizedFileURL.path.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return String(h, radix: 36)
    }

    static func dir(for url: URL) -> URL {
        rootDir.appendingPathComponent(folderHash(url.deletingLastPathComponent()),
                                       isDirectory: true)
    }

    /// 源文件 mtime+size 校验值；读不到返回 nil（调用方跳过生成）。
    static func stamp(for url: URL) -> (mtime: Int64, size: Int64)? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let m = attrs[.modificationDate] as? Date,
              let s = attrs[.size] as? NSNumber else { return nil }
        return (Int64(m.timeIntervalSince1970.rounded()), s.int64Value)
    }

    static func file(for url: URL, stamp: (mtime: Int64, size: Int64)) -> URL {
        let stem = url.deletingPathExtension().lastPathComponent
        return dir(for: url).appendingPathComponent("\(stem)-\(stamp.mtime)-\(stamp.size).jpg")
    }

    /// 屏幕自适应目标像素：主屏逻辑分辨率 × backingScale（Retina 下铺满预览区
    /// 仍然锐利），钳制到 [1600, 3840] 合理区间。
    /// NSScreen 是 AppKit 主线程对象，生成在后台队列跑：Store.init（主线程）
    /// 先调 warmScreenMetrics 预热，后台只读缓存值；未预热时用保守默认。
    private static let metricsLock = NSLock()
    private static var cachedMaxSide = 0
    /// 未预热（理论上只出现在极早期）时的保守值：27 寸 5K 屏预览区的常用需求。
    private static let fallbackSide = 2560

    /// 只在主线程调用（Store.init）。
    static func warmScreenMetrics() {
        let screen = NSScreen.main
        let scale = screen?.backingScaleFactor ?? 2
        let longSide = max(screen?.frame.width ?? 1920, screen?.frame.height ?? 1080)
        let px = Int((Double(longSide) * max(scale, 1)).rounded())
        let v = min(max(px, minSideFloor), maxSideCap)
        metricsLock.lock()
        cachedMaxSide = v
        metricsLock.unlock()
    }

    static var adaptiveMaxSide: Int {
        metricsLock.lock()
        defer { metricsLock.unlock() }
        return cachedMaxSide > 0 ? cachedMaxSide : fallbackSide
    }

    /// 生成中间层预览（磁盘上已有同 stamp 文件则跳过）。返回是否生成了新文件。
    /// 历史恢复路径复用它做增量补：只给缓存缺失的照片生成。
    @discardableResult
    static func generateIfNeeded(for url: URL, existingNames: [String]? = nil, source: CGImageSource? = nil) -> Bool {
        guard let st = stamp(for: url) else { return false }
        let target = file(for: url, stamp: st)
        let fm = FileManager.default
        if fm.fileExists(atPath: target.path) { return false }
        let preview = (source ?? CGImageSourceCreateWithURL(url as CFURL, nil))
            .flatMap { Analyzer.thumbnail($0, maxSide: adaptiveMaxSide) }
        guard let img = preview else { return false }
        let rep = NSBitmapImageRep(cgImage: img)
        guard let data = rep.representation(using: .jpeg,
                                            properties: [.compressionFactor: jpegQuality])
        else { return false }
        do {
            try fm.createDirectory(at: dir(for: url), withIntermediateDirectories: true)
            try data.write(to: target, options: .atomic)
        } catch { return false }
        // 批量调用传入目录快照，避免每生成一张都重新枚举缓存目录。
        removeFiles(for: url, keeping: target.lastPathComponent, existingNames: existingNames)
        return true
    }

    /// 读取并解码缓存 JPEG（供显示链中间层使用；stamp 不符时文件名对不上，
    /// 自然返回 nil → 上层走原尺寸解码兜底）。
    static func load(for url: URL) -> CGImage? {
        guard let st = stamp(for: url) else { return nil }
        guard let src = CGImageSourceCreateWithURL(file(for: url, stamp: st) as CFURL, nil)
        else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(
            src, 0, [kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
    }

    /// 列表缩略图专用：直接从已落盘的中间层 JPEG 解到目标尺寸。
    /// JPEG 是已解码好的派生图，解 160px 只要几毫秒；原 CR3 解 160px 实测
    /// 260~500ms 且需要全幅解码。2026-11-25 修复「拖动滚动条后整屏灰块」：
    /// 导入/历史补算阶段已经为每张生成了中间层，列表没有理由再去碰 RAW。
    static func thumbnail(for url: URL, maxSide: Int) -> CGImage? {
        guard let st = stamp(for: url) else { return nil }
        guard let src = CGImageSourceCreateWithURL(file(for: url, stamp: st) as CFURL, nil)
        else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    /// 删除这张照片的缓存文件（QA 边缘项 2：精确匹配自己的缓存名
    /// <照片名>-<mtime>-<size>.jpg）。只按 <照片名>- 前缀会误删同目录
    /// 「DSC_1-2.jpg」这类照片（stem 更长）的缓存，必须校验完整名格式。
    static func removeFiles(for url: URL, keeping: String? = nil, existingNames: [String]? = nil) {
        let fm = FileManager.default
        let d = dir(for: url)
        let stem = url.deletingPathExtension().lastPathComponent
        let prefix = stem + "-"
        guard let re = try? NSRegularExpression(pattern:
            "^" + NSRegularExpression.escapedPattern(for: stem) + "-\\d+-\\d+\\.jpg$")
        else { return }
        let names = existingNames ?? (try? fm.contentsOfDirectory(atPath: d.path)) ?? []
        for n in names where n != keeping && n.hasPrefix(prefix) {
            let full = NSRange(n.startIndex..., in: n)
            if re.firstMatch(in: n, range: full) != nil {
                try? fm.removeItem(at: d.appendingPathComponent(n))
            }
        }
    }
}

// MARK: - 预取复查门

/// 预取任务的只读快照。只在主线程 update，后台通过 allows 读不可变副本；
/// NSLock 保证 epoch / current / near 在同一次临界区内读取，避免 torn read。
/// 锁内绝不调用 Store 的任何方法（尤其 shown 会写 shownCache），杜绝竞态与死锁。
private final class PrefetchGate {
    private let lock = NSLock()
    private var epoch: UInt = 0
    private var current: URL?
    private var near: Set<URL> = []

    func update(epoch: UInt, current: URL?, near: Set<URL>) {
        lock.lock()
        self.epoch = epoch
        self.current = current
        self.near = near
        lock.unlock()
    }

    /// 当前图无条件放行（世代再旧也要写缓存，否则快速连翻会饿死当前图）；
    /// 其余要求世代一致且仍在近端集合内。
    func allows(_ url: URL, for epoch: UInt) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if url == current { return true }
        guard self.epoch == epoch else { return false }
        return near.contains(url)
    }

    /// 撤销标记后的重试判断：仍在近端集合（或已是当前图）才重排。
    func isNear(_ url: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return url == current || near.contains(url)
    }
}

// MARK: - 状态

final class Store: ObservableObject {
    init() {
        // 主线程预热屏幕度量（NSScreen 是 AppKit 主线程对象）：
        // 后台分析/生成线程只读缓存值，不在后台碰 AppKit。
        MidPreviewCache.warmScreenMetrics()
        // 鸟种识别默认关闭；用户此前在题材弹窗勾选过则沿用（2026-11-25 要求）。
        birdRecognitionEnabled = UserDefaults.standard.bool(
            forKey: "Kingfisher-PhotoSelector.birdRecognitionEnabled")
    }
    /// results 整体替换时让派生快照失效（元素原地改 verdict 的两处另行显式失效）。
    /// 1458 张规模下 shown / displayName 每次现算都会重复扫全表，放大切图开销。
    @Published var results: [PhotoResult] = [] {
        didSet { invalidateDerivedCaches() }
    }
    private var suspectCache: [PhotoResult]?
    /// shown 的派生快照：列表 + 「id → 下标」索引。两者必须同生同灭，所以合成一个值。
    private struct ShownSnapshot {
        let list: [PhotoResult]
        let index: [URL: Int]
    }
    private var shownCache: ShownSnapshot?
    private var displayNameCache: [URL: String] = [:]
    /// 底部工具栏每次 body 重算都要数「写入/清除/删除」目标，原实现扫全表 3 次；
    /// 方向键切图会连续触发多次 @Published 广播，1458 张时明显拖慢。按 results/excluded 失效。
    private var writableCache: [PhotoResult]?
    /// results 的「id → 下标」索引（2026-11-25 索引化）。results 整体替换时失效重建；
    /// 原地改 verdict/reason/overrideRect 不改 id 集合，索引保持有效。
    /// 背景：全量列表 1350 张时，每次切图有 20 多处 `results.first(where:)` /
    /// `shown.firstIndex(where:)` 线性扫描在主线程跑；「只看需留意」列表短所以扫得快，
    /// 这是两种模式流畅度差异里与缓存无关的那一部分。
    private var resultIndexCache: [URL: Int]?
    private var resultIndex: [URL: Int] {
        if let c = resultIndexCache { return c }
        var m = [URL: Int](minimumCapacity: results.count)
        for (i, r) in results.enumerated() { m[r.id] = i }
        resultIndexCache = m
        return m
    }
    /// O(1) 按 id 取照片；不在当前结果里返回 nil。替代 `results.first(where:)`。
    func result(for url: URL) -> PhotoResult? {
        guard let i = resultIndex[url] else { return nil }
        return results[i]
    }
    /// O(1) 照片是否还在结果里。替代 `results.contains(where:)`。
    func containsResult(_ url: URL) -> Bool { resultIndex[url] != nil }
    private func invalidateDerivedCaches() {
        suspectCache = nil
        shownCache = nil
        displayNameCache = [:]
        writableCache = nil
        resultIndexCache = nil
    }
    /// 信息区高度（像素）。默认 = 刚好显示到清晰度判定结论；用户拖分隔条调整。
    /// 同一序列内切照片/重算都不改它，导入新素材时重置为默认值。
    @Published var infoHeight: CGFloat = Store.defaultInfoHeight
    /// 默认信息区高度：让「评分 / 拍摄参数 / 清晰度判定」可见，白平衡需滚动。
    static let defaultInfoHeight: CGFloat = 300
    @Published var processing = false
    @Published var done = 0
    @Published var total = 0
    /// 进度条旁的阶段标注：区分「读取历史数据」与「新素材分析」，避免误以为每次都在重算。
    @Published var sessionPhase = ""
    /// 后台正在读会话日志（读文件 + JSON 解码）。为真时工具栏显示明确提示，
    /// 让用户知道这几百毫秒的停顿是在读历史日志，而不是界面卡死。
    @Published var historyReading = false
    @Published var status = "把照片文件夹拖进窗口，或点「选择文件夹」开始"
    @Published var selected: URL? {
        didSet {
            // 切换照片时做两件事：
            // 1) 把上一张的评星依据、清晰度判定信息（含鸟类识别）写进该照片元数据的「说明」
            //    ——用户 2026-11-19 要求，且只动说明字段，其他元数据一律不碰；
            //    可用「切换时自动写说明」开关关闭（配合一键清除标记使用）；
            // 2) 缩放/平移复位；人工圈选记录按照片持久保留，切走再切回来仍在。
            guard oldValue != selected else { return }
            navigationRevision &+= 1
            showingReference = false
            if heldRatingURL != nil { heldRatingURL = nil; shownCache = nil }
            // 说明改为导入/读取完成时批量写（2026-11-23）：原来切一张写一张 XMP，
            // 选片时每张都落盘会卡顿。切照片这里不再写盘，只管缩放复位。
            // 锁定缩放开启时切换照片保留当前放大倍数/位置，便于连续看同一区域。
            if !lockZoom { resetZoom() }
            // 同步把新图的中间层顶上（2026-11-25 切图卡修复）：原来只在
            // DetailView.onChange 里做，晚一帧且要等 SwiftUI 更新，鼠标点选后
            // 先空一帧再显示「正在加载预览…」。这里在 didSet 里同步执行，
            // 中间层已在内存时立即出图；没有才异步读盘/解码。有内部去重不重复跑。
            if let sel = selected { ensureFullPreview(for: sel) }
            // 相邻照片预热：当前图的信息区照常按需加载，同时把上一张/下一张的
            // EXIF、白平衡、对焦点等提前算好，避免按方向键切过去后才现等。
            scheduleNeighborPrefetch()
        }
    }
    /// 左侧列表多选（⌘/⇧ 与访达一致）：预览始终跟随最新选中的那张。
    /// 单张点击 / ⌘+点击新增 = 预览切到刚点的那张；Shift+方向键区间 = moveSelection
    /// 已自行设好最新一张，这里用标志位避免被 Set 的无序 first 抢走。
    @Published var selections: Set<URL> = [] {
        didSet {
            guard selections != oldValue else { return }
            defer { settingSelectionFromRange = false }
            if settingSelectionFromRange {
                if selections.count <= 1 { shiftAnchor = nil; shiftCursor = nil }
                return
            }
            // 多选期间保留 Shift+方向键的区间锚点；退回单选/清空时重置。
            if selections.count <= 1 { shiftAnchor = nil; shiftCursor = nil }
            // 鼠标新点的那张（相对旧集合新增的）＝最新选择，预览跟着走。
            let added = selections.subtracting(oldValue)
            if let newest = added.first {
                selected = newest
            } else if selections.count == 1, let only = selections.first {
                selected = only
            } else if let cur = selected, !selections.contains(cur) {
                // 从多选里取消掉当前预览图时，预览切到剩下的一张（若还有）。
                selected = selections.first
            }
        }
    }
    /// Shift+↑/↓ 连续多选的区间起点与当前游标（列表下标）。非 @Published，纯内部状态。
    private var shiftAnchor: Int?
    private var shiftCursor: Int?
    /// moveSelection 的 Shift 分支在写 selections 前置位，避免 didSet 用 Set.first 抢预览。
    private var settingSelectionFromRange = false
    /// 批量删除/操作的目标：有多选就整组，否则当前预览那张。
    var deleteTargets: [URL] {
        let live = Set(results.map { $0.id })
        let picked = selections.isEmpty ? (selected.map { [$0] } ?? []) : Array(selections)
        return picked.filter { live.contains($0) }
    }
    @Published var onlySuspect = true { didSet { reconcileFilter() } }
    @Published var ratingFilter: Int? { didSet { reconcileFilter() } }
    @Published var advanceAfterRating = false
    private var heldRatingURL: URL?
    private var navigationRevision: UInt = 0
    private var ratingRevision: UInt = 0
    private var ratingRequests: [URL: UInt] = [:]
    @Published private var requestedRatings: [URL: Int] = [:]
    private let ratingWriteQueue = DispatchQueue(label: "kingfisher.rating.write", qos: .userInitiated)
    func displayedRating(_ url: URL) -> Int? { requestedRatings[url] ?? ratingCache[url] }

    private func reconcileFilter() {
        navigationRevision &+= 1
        heldRatingURL = nil
        shownCache = nil
        guard !processing else { return }
        let remaining = selections.filter { shownContains($0) }
        let next = selected.flatMap { shownContains($0) ? $0 : nil } ?? remaining.first ?? shown.first?.id
        selections = remaining.isEmpty ? Set(next.map { [$0] } ?? []) : remaining
        selected = next
    }

    @Published var reference: (url: URL, image: CGImage)?
    @Published var showingReference = false
    func pinReference(_ url: URL) {
        guard fullPreviewURL == url, let image = fullPreview else { return }
        reference = (url, image)
        showingReference = false
    }
    @Published var sensitivity: Double = 1.0
    @Published var preferFaces = false
    @Published var addColorLabel = true
    /// 切换照片时自动把上一张的判定信息写进其说明字段（用户 2026-11-19 要求；可关）。
    @Published var autoWriteDescription = true
    /// 是否在分析阶段批量识别鸟种（2026-11-25 用户要求：默认不识别，导入文件夹时
    /// 在题材弹窗里显式勾选才跑）。手动圈主体 / 手动改题材的单张识别不受此开关限制。
    @Published var birdRecognitionEnabled = false {
        didSet { UserDefaults.standard.set(birdRecognitionEnabled, forKey: "Kingfisher-PhotoSelector.birdRecognitionEnabled") }
    }
    @Published var confirmWrite = false
    @Published var confirmCleanup = false
    @Published var confirmDelete = false
    @Published var deleteURLs: [URL] = []
    /// 导入文件夹后的一次性题材选择（每个文件夹每次启动只问一次）。
    @Published var showGenrePrompt = false
    @Published var genrePromptFolder: URL?
    private var genrePromptAsked: Set<URL> = []
    /// 题材弹窗先于读取/分析出现：用户答完后才真正开始扫描，
    /// 选择先暂存，等新一批 results 填好再整批应用（避免改到上一批照片）。
    private var pendingScan: (folder: URL, files: [URL], forceReload: Bool)?
    private var pendingGenreChoice: FolderGenreChoice?
    private var pendingGenreResolved = false
    /// 当前批次导入时选的整批题材，写进会话缓存（含 auto）。
    /// 下次导入同一文件夹时若 log 里已有它，就不再弹题材选择框。
    private var folderGenreChoice: FolderGenreChoice?
    /// 缓存被判定与本批照片无关时的说明，拼到完成状态里，方便判断是否真的读了历史。
    private var scanNote = ""
    /// 写入前备份所在的照片目录（备份已随照片放到各自文件夹，可能多个目录）。
    @Published var backupDirs: [String] = []
    @Published var dropTarget = false
    /// 热力图默认关闭（2026-11-23 用户要求）；需要时按 H 或勾工具栏。
    @Published var showHeatmap = false
    /// 锁定缩放：开启后切换照片不再复位放大/平移，方便逐张对比同一区域。
    @Published var lockZoom = false
    /// 拖框的即时几何（起点/当前点/是否放大）已从 Store 移到 DetailView 私有的
    /// DragBoxState：鼠标每帧写这里只让那一个小 overlay 重绘，不再广播整个 Store
    /// 连带 1458 行目录和全部面板 body 重算——这是"圈选主体很卡"的主因。
    /// dragAction/didDrag 仍在 Store：只在手势开始/结束写，低频广播保留。
    /// 当前左键拖动意图（⌘=放大 / ⌃=圈选主体 / 无修饰键=平移）；nil 表示未在拖动。
    @Published var dragAction: DragAction?
    @Published var didDrag = false
    @Published var excluded: Set<URL> = [] {
        didSet { writableCache = nil }
    }
    @Published var anchorHi: Double?
    @Published var zoom: CGFloat = 1
    @Published var zoomCenter = CGPoint(x: 0.5, y: 0.5)
    /// 人工圈选记录：按照片 URL 索引，切照片/复位缩放都不清。
    /// 与 overrideRect（单张重判结果）并存，互不覆盖——青框 AI 主体照常显示。
    @Published var selectionRects: [URL: CGRect] = [:]
    /// 以下三项按「当前选中照片」从 selectionRects 实时派生：
    /// 黄框、评分用的 manualSubjectRatio、信息区指标格始终同一来源，
    /// 切走再切回来不会出现「框还在、参数却回退到自动识别」。
    var selectionRect: CGRect? {
        guard let url = selected else { return nil }
        return selectionRects[url]
    }
    /// 判定用的历史字段（对 P99），当前无读者；保留派生语义避免状态分叉。
    var selectionRatio: Double? {
        guard let url = selected, let rect = selectionRects[url],
              let m = metrics.first(where: { $0.url == url }) else { return nil }
        return Analyzer.rectRatio(m, rect: rect)
    }
    /// 圈选区相对"最锐块"的显示百分比（恒<=1），传给评分当 manualSubjectRatio。
    var selectionDisplayRatio: Double? {
        guard let url = selected, let rect = selectionRects[url],
              let m = metrics.first(where: { $0.url == url }) else { return nil }
        return Analyzer.rectDisplayRatio(m, rect: rect)
    }
    @Published var wbCache: [URL: WhiteBalanceStats] = [:]
    @Published var afCache: [URL: AFInfo] = [:]
    /// 对焦点读取状态：loading 驱动"读取中"提示；attempted 避免 nil 结果反复跑 exiftool。
    @Published var afLoading: Set<URL> = []
    /// 只被 ensureAF 读写，没有视图观察；非 @Published 避免每次切图广播全树重算。
    var afAttempted: Set<URL> = []
    @Published var exifCache: [URL: ExifInfo] = [:]
    /// 对焦点处语义（人脸/鸟/其他），用于题材识别；随 AF 加载后异步算一次。
    @Published var focusCache: [URL: FocusSemantics] = [:]
    /// 画面中是否有人（不依赖露脸，人体姿态检测），用于无脸人像的题材兜底。
    @Published var humanCache: [URL: HumanPresence] = [:]
    /// AI 主体识别缓存：分割+分类较慢，异步算一次；nil 占位表示「进行中」。
    @Published var aiCache: [URL: AISubject?] = [:]
    /// Bridge 星级：-1 = 拒绝，0~5 = 星级，nil = 未评分。
    @Published var ratingCache: [URL: Int] = [:] { didSet { if ratingFilter != nil { shownCache = nil } } }
    /// 分析任务「已经跑过」标记（非 @Published）。WB / EXIF / 对焦点语义 / 人体 /
    /// 缩略图的结果都可能是 nil；nil 写不进字典，若只按缓存判空，每次切回这张照片
    /// 都会重新解码 RAW、重跑 exiftool 与 Vision —— 这是切图卡顿的主因。
    private var wbAttempted: Set<URL> = []
    private var exifAttempted: Set<URL> = []
    private var focusAttempted: Set<URL> = []
    private var humanAttempted: Set<URL> = []
    private var thumbAttempted: Set<URL> = []
    /// 目录逐行读星级时把结果攒成一批再写：ratingCache 是 @Published，
    /// 97 行各自回写会让整个目录/信息区重绘 97 轮，导入后明显卡顿。
    private var pendingRatings: [URL: Int] = [:]
    private var ratingLoading: Set<URL> = []
    private var ratingFlushWork: DispatchWorkItem?

    // MARK: - 信息全量分析阶段（导入/历史补算）
    /// 分析核心（判定/评分的 RAW 分析）进行中：saveSession 的准入条件。
    /// processing 覆盖到信息阶段与鸟种批量，但那些阶段 results 已定型、可以安全落盘。
    private var analysisCoreActive = false
    /// 信息字段批量补算的世代：导入新文件夹/读历史时自增，作废旧批次的在途写入。
    private var infoPhaseGeneration: UInt = 0
    private var infoPhasePending: [URL] = []
    private var infoPhaseInflight = 0
    private let infoPhaseMaxInflight = 3
    // 并行读取 exiftool 与侧车，图像解码和识别沿用串行路径。
    private let infoPhaseImageLock = NSLock()
    private var infoPhaseFinishing: (() -> Void)?
    /// 信息全量阶段的工作队列（限 3 并发由 infoPhaseInflight 自己控制）：
    /// WB(600px)/AF(exiftool)/EXIF 之外，Focus 用 2048px 解码、Human+AI 共享
    /// 一次 1024px 彩色解码——与按需 ensure* 路径完全同一套引擎与口径。
    private let infoPhaseQueue = DispatchQueue(label: "kingfisher.info.full", qos: .utility,
                                               attributes: .concurrent)
    /// 鸟种批量队列：串行低优先级（识别内部还有原尺寸解码，串行避免打满 CPU）。
    private let birdBatchQueue = DispatchQueue(label: "kingfisher.bird.batch", qos: .utility)

    // MARK: - Shift 区间多选的边缘滚动（参考访达）
    /// ResultRow 上报的当前可见行（非 @Published；滚动复用会上报乱序/延迟，
    /// 决策时用集合推导 min/max 下标区间，天然容错）。
    var visibleRowURLs: Set<URL> = []
    /// 列表可视高度（GeometryReader 每帧写入，非 @Published 避免布局反馈循环）。
    /// 与 visibleRowURLs 一起推导「半屏对应几行」，供 Shift 边缘滚动自适应。
    var listViewportHeight: CGFloat = 0
    /// 左侧目录缩略图档位（工具栏 −/+ 调整，持久化到 UserDefaults）。
    @Published var thumbnailScale: ListThumbnailScale = ListThumbnailScale.load() {
        didSet { thumbnailScale.save() }
    }

    func stepThumbnailScale(_ delta: Int) {
        let raw = max(ListThumbnailScale.small.rawValue,
                      min(ListThumbnailScale.huge.rawValue, thumbnailScale.rawValue + delta))
        if let next = ListThumbnailScale(rawValue: raw) { thumbnailScale = next }
    }

    /// 当前窗口能看见的行数：优先用 ResultRow 实际上报的集合，几何估算作兜底/放大。
    var visibleRowCount: Int {
        // 优先按可视高度 / 当前档行高算，直接对应用户说的"列表高度一半"；
        // 首帧几何还没上报时才退回 ResultRow 实际上报的行数。
        if listViewportHeight > 0 {
            return max(1, Int((listViewportHeight / thumbnailScale.rowHeight).rounded(.down)))
        }
        return max(1, visibleRowURLs.count)
    }

    /// moveSelection 的 Shift 分支置位：下一次 selected 变化按「边缘滚动」规则
    /// 处理（仅选中到可视边缘才滚动露出隐藏照片；未到边缘列表完全不动）。
    var pendingShiftEdgeScroll = false
    /// 上次边缘滚动时间：滚动后的 onAppear/onDisappear 上报有延迟/噪声，
    /// 短窗口内不再连发，避免抖动循环。
    private var lastEdgeScrollAt = Date.distantPast

    func rowAppeared(_ url: URL) {
        visibleRowURLs.insert(url)
        scheduleThumbnailPrefetch()
    }
    func rowDisappeared(_ url: URL) { visibleRowURLs.remove(url) }

    /// 相邻照片元数据预取。信息区全部按 URL 缓存，切到新照片时缓存是空的：
    /// EXIF / RAW 解码 / 对焦点语义 / 鸟种模型都要现跑，录屏里表现为切图后参数区空白、
    /// 鸟种区等待。方向键连翻时提前把 ±1 张的这些结果跑进缓存，翻到就有内容。
    /// 串行队列避免同时给多张照片各解码 4~5 次 RAW 抢 CPU（那会让当前图也跟着卡）。
    /// 轻队列只放 EXIF / 对焦点 / 白平衡 / 星级，重队列放语义（鸟种走并发 utility）：
    /// 否则一次耗时的 Vision 预取会把下一张最显眼的 EXIF 堵在后面。
    private let prefetchQueue = DispatchQueue(label: "kingfisher.meta.prefetch", qos: .utility)
    private let prefetchHeavyQueue = DispatchQueue(label: "kingfisher.meta.prefetch.heavy", qos: .background)

    /// 预取世代：每次 selected 变化自增；与当前图、近端集合一起同步写进 gate。
    /// 任务开始前只读 gate 快照复查——连翻时旧批次直接跳过，不再把用户早已
    /// 翻过的照片堆进串行队列（旧实现连按方向键会积压上百个 RAW / Vision 任务，
    /// 当前图的解码被迫和它们抢 CPU，表现为"越翻越卡"）。
    private var prefetchEpoch: UInt = 0
    private let prefetchGate = PrefetchGate()

    /// 信息区批量刷新。WB / AF / EXIF / Focus / Human / AI 各自完成就写一次
    /// @Published 字典，一张图连发十几遍 objectWillChange，1458 行目录和整个
    /// 信息区每遍都要重算 body。这里把 60ms 内落地的结果合并为一次主线程写入，
    /// 视图刷新次数下降一个量级，但字段值与实时性都不变。
    private var pendingInfoApplies: [() -> Void] = []
    private var infoFlushWork: DispatchWorkItem?

    private func stageInfoUpdate(_ apply: @escaping () -> Void) {
        pendingInfoApplies.append(apply)
        guard infoFlushWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.flushInfoUpdates() }
        infoFlushWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: work)
    }

    private func flushInfoUpdates() {
        infoFlushWork?.cancel()
        infoFlushWork = nil
        let batch = pendingInfoApplies
        pendingInfoApplies = []
        for apply in batch { apply() }
    }

    /// 过期任务被 gate 拒绝后的重试入口。撤销 attempted / loading / 占位后调用：
    /// 若该 URL 仍在新近端集合里就立刻按原有队列重排；若已不在，则等用户下次
    /// 翻到它时由 InfoView.onChange 触发按需加载。两条路径都不会留下"死图"。
    /// 只从主线程调用；ensure* 内部的 attempted 去重保证不会重复入队。
    private func reschedulePrefetchedInfo(for url: URL) {
        guard prefetchGate.isNear(url),
              let r = result(for: url) else { return }
        ensureWB(for: url, on: prefetchQueue)
        ensureAF(for: url, on: prefetchQueue)
        ensureExif(for: url, on: prefetchQueue)
        ensureRating(for: url, on: prefetchQueue)
        ensureFocus(for: url, subjectBoxes: r.metrics.bboxes, on: prefetchHeavyQueue)
        ensureHuman(for: url, on: prefetchHeavyQueue)
        ensureAI(for: url, on: prefetchHeavyQueue)
    }

    /// Human 与 AI 两个引擎的 URL 入口原本各自解码同一张 RAW（各 1024px）。
    /// 这里解一次彩色缩略图给两者复用：每张照片少一次 RAW 解码，
    /// 切图后信息区"等参数"的时间明显缩短，结果与原 URL 入口完全一致。
    private let analysisDecodeQueue = DispatchQueue(label: "kingfisher.analysis.decode", qos: .utility)
    private var analysisDecodeCache: [URL: CGImage] = [:]
    private var analysisDecodeOrder: [URL] = []
    private var analysisDecodeLoading: Set<URL> = []
    private var analysisDecodeWaiters: [URL: [(CGImage?) -> Void]] = [:]
    private let analysisDecodeMax = 6

    func requestAnalysisThumbnail(for url: URL, then: @escaping (CGImage?) -> Void) {
        if let hit = analysisDecodeCache[url] { then(hit); return }
        analysisDecodeWaiters[url, default: []].append(then)
        guard !analysisDecodeLoading.contains(url) else { return }
        analysisDecodeLoading.insert(url)
        analysisDecodeQueue.async { [weak self] in
            let img = Analyzer.analysisThumbnail(url)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.analysisDecodeLoading.remove(url)
                if let img {
                    self.analysisDecodeCache[url] = img
                    if let i = self.analysisDecodeOrder.firstIndex(of: url) {
                        self.analysisDecodeOrder.remove(at: i)
                    }
                    self.analysisDecodeOrder.append(url)
                    while self.analysisDecodeOrder.count > self.analysisDecodeMax,
                          let victim = self.analysisDecodeOrder.first(where: { $0 != url }) {
                        self.analysisDecodeOrder.removeAll { $0 == victim }
                        self.analysisDecodeCache[victim] = nil
                    }
                }
                let waiters = self.analysisDecodeWaiters.removeValue(forKey: url) ?? []
                for waiter in waiters { waiter(img) }
            }
        }
    }

    // MARK: - 鸟种识别（BioCLIP 2 本地，纯离线）
    /// 当前采用的鸟种（BioCLIP 2 本地识别 / 人工确认；人工确认优先）。
    @Published var birdCache: [URL: BirdSpeciesGuess] = [:]
    @Published var birdTop3: [URL: String] = [:]
    @Published var birdSource: [URL: String] = [:]
    @Published var birdReason: [URL: String] = [:]
    /// 人工确认输入框内容，按照片保存。
    @Published var birdConfirm: [URL: String] = [:]
    /// 用户主动清除标签后，本次会话不再自动重认这张。
    @Published var birdDismissed: Set<URL> = []
    /// 本地模型把握不足（或历史日志只有低置信误认）：不再反复重跑，也不显示候选鸟名。
    @Published var birdUnreliable: Set<URL> = []
    @Published var birdLoading: Set<URL> = []
    @Published var birdMessage: [URL: String] = [:]
    /// 首启预热状态：580MB 本地模型首次载入要 5～6 秒，放进后台做，避免点开照片才等。
    @Published var birdModelWarming = false
    /// 每次重新启动识别自增；旧任务完成时 token 对不上就丢弃，避免圈选后旧结果覆盖新结果。
    /// 纯内部令牌：没有任何视图读取，非 @Published，避免识别中反复广播全树重算。
    private var birdTaskToken: [URL: Int] = [:]
    /// QA A2：token 改为全局单调递增。原来按 URL 从 1 起算，删除/换代把
    /// birdTaskToken[url] 清 nil 后，同一路径重新导入 token 又回到 1，
    /// 120 秒内旧看门狗会误命中新任务提前判"超时"。全局序号不可能重复。
    private var birdTaskSerial: Int = 0
    /// 鸟种批量队列（主线程状态）：只排队 URL，轮到哪张才置 loading，避免几百张
    /// 同时挂在「识别中」。现在批量完全在分析阶段跑完，筛选阶段不再有点开插队
    /// 的路径；手动圈主体后的单张刷新靠 ensureBird(forceLocal:) 走 token 换代。
    private var birdBatchPending: [URL] = []
    private var birdBatchActive = false
    private var birdBatchTotal = 0
    private var birdBatchSettled = 0
    private var birdBatchCompletion: (() -> Void)?
    private var birdBatchGeneration: UInt = 0
    /// 本批是否只读历史日志、不推理（用户默认关闭鸟种识别）。
    /// 鸟种日志按根目录缓存在内存里，靠文件修改时间失效；切照片不再反复读盘。
    private var birdLogMemory: [URL: (stamp: Date?, rows: [BirdRecord])] = [:]

    @Published var showAFPoints = true
    /// 主体框显示开关（2026-11-23 用户要求，工具栏可勾选）：
    /// AI 主体框＝自动识别的青框；自选主体框＝人工圈选的黄框。
    /// 仅控制画面里画不画框，不影响判定/评分/圈选记录本身。
    @Published var showAISubjectBox = true
    @Published var showManualSubjectBox = true
    /// 构图辅助线：九宫格与对角线。默认开启（2026-11-19 用户要求），
    /// 线条画得很淡（见 CompositionGuides），不影响看图。
    @Published var showThirds = true
    @Published var showDiagonals = true
    /// 一键隐藏时的勾选快照：再按一次只恢复这些项，不动用户原本没勾的项。
    private var hiddenOverlaySnapshot: Set<OverlayItem>?

    /// 辅助项开关：快捷键和一键隐藏/恢复都从这里走，状态栏给出文字提示。
    func isOverlayOn(_ item: OverlayItem) -> Bool {
        switch item {
        case .heatmap:   return showHeatmap
        case .afPoints:  return showAFPoints
        case .thirds:    return showThirds
        case .diagonals: return showDiagonals
        case .aiBox:     return showAISubjectBox
        case .manualBox: return showManualSubjectBox
        }
    }
    private func setOverlay(_ item: OverlayItem, _ on: Bool) {
        switch item {
        case .heatmap:   showHeatmap = on
        case .afPoints:  showAFPoints = on
        case .thirds:    showThirds = on
        case .diagonals: showDiagonals = on
        case .aiBox:     showAISubjectBox = on
        case .manualBox: showManualSubjectBox = on
        }
    }
    private func overlayLabels(_ items: Set<OverlayItem>) -> String {
        OverlayItem.allCases.filter { items.contains($0) }.map(\.label).joined(separator: "、")
    }
    func toggleOverlay(_ item: OverlayItem) {
        let on = !isOverlayOn(item)
        setOverlay(item, on)
        status = "\(on ? "已显示" : "已隐藏")\(item.label)（快捷键 \(shortcuts.combo(for: item).display)）"
    }
    /// 一键隐藏当前勾选的辅助项；再按一次按快照恢复，不会把原本没勾的项打开。
    func toggleAllOverlays() {
        let key = shortcuts.overlayToggle.display
        if let snapshot = hiddenOverlaySnapshot {
            for item in OverlayItem.allCases { setOverlay(item, snapshot.contains(item)) }
            hiddenOverlaySnapshot = nil
            status = "已恢复 \(snapshot.count) 个辅助项：\(overlayLabels(snapshot))（\(key) 再按隐藏）"
            return
        }
        let onItems = Set(OverlayItem.allCases.filter { isOverlayOn($0) })
        guard !onItems.isEmpty else {
            status = "当前没有显示中的辅助项可隐藏"
            return
        }
        hiddenOverlaySnapshot = onItems
        for item in onItems { setOverlay(item, false) }
        status = "已隐藏 \(onItems.count) 个辅助项：\(overlayLabels(onItems))（\(key) 恢复）"
    }
    /// 信息区位置：true=画面最右侧竖排（默认）；false=预览下方（原布局，可切回）。
    /// 右侧竖排窄栏时用紧凑尺寸；默认下方布局保持原样。
    /// 默认改为右侧布局（2026-11-18 用户要求），可在顶部按钮切回下方。
    @Published var infoOnRight = true
    /// 右侧布局时信息区的宽度：默认固定值，拖动分隔条可调小/调大，批内记住。
    @Published var infoWidth: CGFloat = 380
    /// 题材人工覆盖：用户改过题材的照片存这里；没有覆盖的自动识别。
    @Published var genreOverride: [URL: PhotoGenre] = [:]
    /// 题材纠正记忆：用户手动改题材时自动记录特征样本，特征相似的照片
    /// 以后按用户的判断优先。存本地 JSON（GenreMemory），可一键清空。
    @Published var memory: [GenreCorrectionSample] = GenreMemory.load()
    /// 分隔条拖动基准：按下时记录当前信息区高度，作为绝对基准。
    @Published var dividerStartHeight: CGFloat = 0
    /// 正在拖动分隔条：左键桥接据此放行事件，避免把分隔条拖动误判为平移。
    @Published var isDividerDragging = false
    /// 分隔条拖动上下文：由外层 GeometryReader 每帧写入，供 AppKit 事件桥接读取。
    /// 非 @Published —— 写值不触发 body 重算，避免布局/事件互相反馈。
    /// axis 决定拖动的是高度（下方布局，用鼠标 y）还是宽度（右侧布局，用鼠标 x）。
    enum DividerAxis { case height, width }
    var dividerAxis: DividerAxis = .height
    var dividerValue: CGFloat = Store.defaultInfoHeight
    var dividerMin: CGFloat = 170
    var dividerMax: CGFloat = 2000
    /// 外层布局每帧写入分隔条的当前几何，供左键桥接做绝对坐标换算。
    /// 非 @Published：写值本身不触发 UI 重算。
    func setDividerContext(axis: DividerAxis, value: CGFloat, min: CGFloat, max: CGFloat) {
        dividerAxis = axis
        dividerValue = value
        dividerMin = min
        dividerMax = max
    }
    /// 可自定义的快捷键（框选放大 / 圈选主体的修饰键）。
    @Published var shortcuts = ShortcutSettings.load()
    /// 快捷键设置面板是否显示。
    @Published var showShortcuts = false
    /// 当前选中照片的预览；分析用小图只用于缩略图与打分。
    /// 显示链为双层（v1.0 结构回归 + 落盘可重建）：fullPreview 始终是「本张」的
    /// 图——原尺寸命中直接显示；否则显示本张的中间层（屏幕自适应分辨率，从磁盘
    /// 缓存读回，Retina 下铺满预览区仍然锐利），原尺寸后台解码完成后替换。
    /// 不再保留上一张的清晰图做过渡（中间层显示的就是这张照片，体验更好）。
    @Published var fullPreview: CGImage?
    /// fullPreview 每次换成不同 CGImage 就自增；baseCache 用它做 token，
    /// 保证中间层→原尺寸的两跳替换中旧图立刻失效，绝不串图。
    private var fullPreviewToken: UInt = 0
    /// 仅供 Store 内部判断"这张的预览是否已加载"；视图只看 fullPreview，非 @Published。
    var fullPreviewURL: URL?
    /// 原尺寸预览 LRU。2026-11-24 修复"切图先虚化后清晰"：以前每次切图都把
    /// fullPreview 置 nil 再异步重解，主预览在解码期间回退到 160px 列表缩略图；
    /// 命中缓存时同步赋清晰图，零延迟、无低清中间帧。容量 3→5：目录里点非相邻
    /// 照片（滚动后点选 / ⇧ 区间跳转）时命中率偏低，5 张能覆盖来回翻看的常见路径，
    /// 内存上界约 5 张原尺寸位图，仍在可接受范围。
    private var fullPreviewCache: [URL: CGImage] = [:]
    private var fullPreviewOrder: [URL] = []
    private var fullPreviewJobs: [URL: FullPreviewJob] = [:]

    private final class FullPreviewJob {
        private let lock = NSLock()
        private var claimed = false

        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !claimed else { return false }
            claimed = true
            return true
        }
    }
    /// 原图解码失败的照片：DetailView 用它显示明确提示，避免"进度提示消失后永久空白"。
    /// 非 @Published；失败发生在当前图时由 objectWillChange 主动刷新一次。
    private var previewFailed: Set<URL> = []
    /// 被删除照片的 per-URL 失效标记：只丢弃这些 URL 的在途解码，
    /// 不能用全局 generation++（会把同时预取的其他照片也一起作废，
    /// 导致切到那张时 loading 被去重挡住、旧结果又被丢弃 → 永久空白）。
    private var invalidatedPreviewURLs: Set<URL> = []
    /// 换文件夹/导入新会话时自增，丢弃整批旧任务结果；删除照片不走这里。
    private var fullPreviewGeneration: UInt = 0
    private let fullPreviewMax = 5
    /// 当前图与相邻图的解码分开排队：当前图优先，预取不抢它的 CPU。
    private let fullPreviewQueue = DispatchQueue(label: "kingfisher.fullpreview.decode", qos: .userInitiated)
    private let fullPreviewPrefetchQueue = DispatchQueue(label: "kingfisher.fullpreview.prefetch", qos: .utility)
    // MARK: 中间层预览（屏幕自适应分辨率，磁盘缓存 + 内存 LRU）
    /// 内存 LRU：JPEG 解码后的中间层图像（单张约为主尺寸的 1/4~1/9 位图），
    /// 容量 36 张（2026-11-25 从 12 提升：要能留住一屏可见行 + 上下各 4 行，
    /// 否则刚预热的图立刻被互相挤掉，点选仍要现读盘）；正在显示的那张绝不被驱逐。
    /// 原尺寸解码完成替换后，中间层继续留在缓存里（下次回看更快）。
    private var midPreviewCache: [URL: CGImage] = [:]
    private var midPreviewOrder: [URL] = []
    private var midPreviewLoading: [URL: UInt] = [:]
    private var midPreviewRequestID: UInt = 0
    /// 磁盘缓存读取失败的 URL（stamp 对不上/文件缺失）：不再反复读盘，
    /// 原尺寸解码照常兜底；导入分析阶段会按新 stamp 重建。
    private var midPreviewFailed: Set<URL> = []
    private let midPreviewMax = 36
    private let midPreviewQueue = DispatchQueue(label: "kingfisher.midpreview", qos: .userInitiated)
    /// 可见行批量预热专用：与当前图的 midPreviewQueue 分开，避免一次滚动把
    /// 几十张可见照片排在队首、点选时当前图反而要排队（点选要等一秒的原因之一）。
    private let midPreviewPrefetchQueue = DispatchQueue(label: "kingfisher.midpreview.prefetch", qos: .utility)
    @Published var panOffset = CGSize.zero
    @Published var panStart: CGPoint?
    @Published var panBegin = CGSize.zero

    /// 渲染缓存：拖动分隔条/缩放窗口会反复触发 body 重算，热力图按块绘制很重。
    /// 缓存后 body 重算只取现成 NSImage 做 GPU 缩放，避免画面跳动。
    /// 非 @Published：生成结果不需要触发 UI 刷新；选中图/基准变化时按 key 自动失效。
    private var heatCache: [URL: (floor: Double, img: NSImage)] = [:]
    /// token = 生成 baseImage 时的 fullPreviewToken；换图后 token 变化自动失效，
    /// 避免过渡期把上一张的清晰图缓存到新照片名下造成串图。
    private var baseCache: [URL: (token: UInt, full: Bool, img: NSImage)] = [:]
    /// 左侧列表缩略图缓存。历史加载时不逐张解 RAW（太慢），这里按需解小图。
    /// 非 @Published：ResultRow 在 onAppear 触发解码，解好后写回并局部刷新。
    private var thumbnailCache: [URL: CGImage] = [:]
    private var thumbLoading: Set<URL> = []
    /// 可见行优先、预取靠后：两条并发队列分开，避免历史恢复时后到的预取任务
    /// 把用户正在看的那几行挤在队尾（拖动滚动条整屏灰块的直接原因之一）。
    private let thumbnailQueue = DispatchQueue(label: "kingfisher.thumbnail.visible",
                                               qos: .userInitiated, attributes: .concurrent)
    private let thumbnailPrefetchQueue = DispatchQueue(label: "kingfisher.thumbnail.prefetch",
                                                       qos: .utility, attributes: .concurrent)
    private var thumbPrefetchWork: DispatchWorkItem?
    /// QA 防御项：换文件夹时已 async 出去的缩略图解码无法取消，靠 generation
    /// 在回写点丢弃旧任务结果（否则旧内容会以同一 URL 写进新会话的缓存，
    /// 且 thumbAttempted 已置位不会再重解）。
    private var thumbnailGeneration: UInt = 0
    /// 所有显示档共用一份解码结果：按最大档 88pt @2x = 176px 取 192px，
    /// 缩放交给 SwiftUI，天然不会串尺寸。
    static let thumbnailDecodeSide = 192

    func heatmapImage(for r: PhotoResult) -> NSImage {
        let floor = heatFloor
        if let c = heatCache[r.id], c.floor == floor { return c.img }
        let img = makeHeatmap(r.metrics, floor: floor)
        heatCache[r.id] = (floor, img)
        return img
    }

    /// 列表缩略图：历史恢复时 preview=nil，这里按需解码小图并缓存。
    /// 2026-11-25 修复「拖动滚动条后整屏灰块」：优先从分析阶段已落盘的中间层
    /// JPEG 直接解到目标尺寸（毫秒级），只有中间层缺失时才退回 CR3 解码。
    /// 可见行走 userInitiated 队列，预取走 utility 队列，互不抢队。
    func ensureThumbnail(for url: URL, highPriority: Bool = true) {
        // 解不出图时也记「已尝试」：否则每次滚动到这行都重解一次 RAW（约 260ms）。
        guard thumbnailCache[url] == nil, !thumbLoading.contains(url),
              !thumbAttempted.contains(url) else { return }
        thumbLoading.insert(url)
        thumbAttempted.insert(url)
        let generation = thumbnailGeneration
        let queue = highPriority ? thumbnailQueue : thumbnailPrefetchQueue
        queue.async { [weak self] in
            let img = MidPreviewCache.thumbnail(for: url, maxSide: Self.thumbnailDecodeSide)
                ?? Analyzer.decode(url, maxSide: Self.thumbnailDecodeSide)?.image
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                // 换文件夹/重新导入：旧代次的解码结果一律丢弃，但 loading 要配对清掉。
                guard self.thumbnailGeneration == generation else {
                    self.thumbLoading.remove(url)
                    return
                }
                self.thumbLoading.remove(url)
                if let img {
                    self.thumbnailCache[url] = img
                    self.baseCache[url] = nil   // 让主图/列表重取带缩略图的新状态
                }
            }
        }
    }

    /// 滚动稳定后按当前可视区间上下各补 4 行缩略图。防抖 180ms，拖动滚动条时
    /// 不会把路过的几十行都排进解码队列（旧版整屏灰块的原因之一）。
    func scheduleThumbnailPrefetch() {
        thumbPrefetchWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let items = self.shown
            let offsets = items.enumerated().compactMap {
                self.visibleRowURLs.contains($0.element.id) ? $0.offset : nil
            }
            guard let lo = offsets.min(), let hi = offsets.max() else { return }
            let range = max(0, lo - 4)...min(items.count - 1, hi + 4)
            var midURLs: [URL] = []
            for j in range {
                self.ensureThumbnail(for: items[j].id, highPriority: false)
                midURLs.append(items[j].id)
            }
            // 可见行（含上下各 4 行缓冲）的中间层一并预热：鼠标点选列表里任意
            // 一张时主预览立即命中本张中间层，不再等 CR3 原图解码（点选要等一秒
            // 的主因）。走独立 utility 队列，不影响当前图与相邻图的解码优先级。
            if !self.processing {
                self.preloadVisibleMidPreviews(midURLs)
            }
        }
        thumbPrefetchWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }

    func thumbnail(for url: URL, fallback: CGImage?) -> CGImage? {
        thumbnailCache[url] ?? fallback
    }

    /// 主预览图：fullPreview 始终是「本张」的最佳可用图（原尺寸命中 = 原尺寸；
    /// 否则 = 本张的中间层；都没有 = 空占位）。绝不回退 160px 缩略图（消除"虚化一下"），
    /// 也绝不显示上一张的图（中间层显示的就是当前照片）。token 保证中间层→原尺寸
    /// 两跳替换时缓存立即失效，不串图。
    func baseImage(for r: PhotoResult) -> NSImage {
        let useFull = r.id == selected && fullPreviewURL == r.id && fullPreview != nil
        let token = fullPreviewToken
        if let c = baseCache[r.id], c.token == token && c.full == useFull { return c.img }
        let img: NSImage
        if useFull, let cg = fullPreview {
            img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        } else {
            img = NSImage()
        }
        baseCache[r.id] = (token, useFull, img)
        return img
    }

    /// 统一替换当前清晰图：换图即自增 token，让 baseCache 中旧图立刻失效。
    private func replaceFullPreview(_ img: CGImage?) {
        guard fullPreview !== img else { return }
        baseCache.removeAll()
        fullPreview = img
        fullPreviewToken &+= 1
    }

    private var metrics: [PhotoMetrics] = []
    private var hiMin: Double = 0

    /// 需留意的照片（列表默认筛选、状态栏计数口径）：主体偏软 / 整片偏软 / 景深不足。
    /// 主体拖影是橙色独立档，不算「需留意」，但要打红色标签（见 Verdict.bridgeLabelColor）。
    var suspects: [PhotoResult] {
        if let c = suspectCache { return c }
        let c = results.filter { $0.verdict.isSuspect }
        suspectCache = c
        return c
    }
    /// 批量写元数据的目标（2026-11-20 起为全部照片）：每张照片把判定词写入 xmp:Label
    /// （主体清晰/焦点正常/整片偏软/景深不足/主体偏软/主体拖影），原因写说明字段。
    var writableTargets: [PhotoResult] {
        if let c = writableCache { return c }
        let c = results.filter { !excluded.contains($0.id) && $0.verdict != .unreadable }
        writableCache = c
        return c
    }
    var shown: [PhotoResult] { shownSnapshot.list }
    private var shownSnapshot: ShownSnapshot {
        if let c = shownCache { return c }
        let base = onlySuspect ? suspects : results
        let list = ratingFilter.map { filter in base.filter { $0.id == heldRatingURL || ratingCache[$0.id] == filter } } ?? base
        var m = [URL: Int](minimumCapacity: list.count)
        for (i, r) in list.enumerated() { m[r.id] = i }
        let c = ShownSnapshot(list: list, index: m)
        shownCache = c
        return c
    }
    /// O(1) 某张在当前（过滤后）列表里的下标；不在返回 nil。
    /// 替代 `shown.firstIndex(where:)`——切图预取、方向键、滚动跟随每次都要查。
    func shownIndex(of url: URL) -> Int? { shownSnapshot.index[url] }
    /// O(1) 某张是否在当前列表里。替代 `shown.contains(where:)`。
    func shownContains(_ url: URL) -> Bool { shownSnapshot.index[url] != nil }

    /// ↑/↓ 在当前列表（含"只看需留意"过滤）内切换照片，与列表顺序一致。
    /// 2026-11-23： Shift+↑/↓ 连续多选区间，并把预览跟着切到刚选中的那张。
    func moveSelection(by delta: Int, shift: Bool = false) {
        let items = shown
        guard !items.isEmpty else { return }
        let base: Int
        if shift, let cursor = shiftCursor {
            base = cursor
        } else if let cur = selected, let i = shownIndex(of: cur) {
            base = i
        } else {
            // 当前照片不在过滤列表里：向下从头开始，向上从尾开始。
            base = delta >= 0 ? -1 : items.count
        }
        let target = max(0, min(items.count - 1, base + delta))
        let next = items[target].id
        if shift {
            // 第一次按 Shift+方向键时，以当前预览图为区间起点。
            // 注意 base 可能是 -1/count 哨兵（当前图不在过滤列表里），必须钳到合法下标。
            let anchor: Int
            if let a = shiftAnchor {
                anchor = max(0, min(items.count - 1, a))
            } else if let cur = selected, let i = shownIndex(of: cur) {
                anchor = i
            } else {
                anchor = target
            }
            shiftAnchor = anchor
            shiftCursor = target
            let lo = min(anchor, target), hi = max(anchor, target)
            // 先设 selected 再设 selections：置标志位让 didSet 不按 Set.first 抢预览，
            // 这样区间多选中仍显示刚按方向键选到的那张。
            // 边缘滚动标志：仅 Shift 区间多选路径启用（Finder 式：选中到列表可视
            // 边缘才自动滚动露出几张隐藏照片，未到边缘列表完全不动）。
            if next != selected { pendingShiftEdgeScroll = true }
            selected = next
            settingSelectionFromRange = true
            selections = Set(items[lo...hi].map { $0.id }.filter { shownContains($0) })
            status = "已连续选中 \(hi - lo + 1) 张，当前显示：\(displayName(next))"
        } else {
            shiftAnchor = nil; shiftCursor = nil
            pendingShiftEdgeScroll = false
            selected = next
            selections = [next]
        }
    }

    /// Shift 区间多选时的边缘滚动决策。返回 nil = 未到边缘（列表完全不动）
    /// 或处于防抖窗口内；否则返回要滚到的目标行与对齐锚点。
    /// 2026-11-25 用户要求：滚动长度 = **当前列表可视高度的一半**对应的行数，
    /// 随窗口大小自适应（可见 20 行 → 滚 10 行；可见 6 行 → 滚 3 行）。
    /// 可见行数来自 ResultRow 实际上报集合 + GeometryReader 的可视高度/行高估算，
    /// 集合推导 min/max 同时用于边缘判定，容错滚动复用导致的乱序/抖动。
    func shiftEdgeScrollTarget(for id: URL) -> (target: URL, anchor: UnitPoint)? {
        let items = shown
        guard let idx = shownIndex(of: id) else { return nil }
        let visible = items.enumerated()
            .compactMap { visibleRowURLs.contains($0.element.id) ? $0.offset : nil }
        guard let first = visible.min(), let last = visible.max() else { return nil }
        // 防抖：onDisappear 上报有延迟/噪声，刚触发过边缘滚动时不再连发，
        // 避免滚动↔上报互相反馈形成抖动循环。
        guard Date().timeIntervalSince(lastEdgeScrollAt) > 0.12 else { return nil }
        // 半屏行数：窗口越高一次露出越多，窗口矮则少露；至少 1 行。
        let step = max(1, visibleRowCount / 2)
        // 选中到可视下缘（差 1 行内）且下方还有照片 → 向下露出半屏隐藏照片。
        if idx >= last - 1, idx + 1 < items.count {
            let t = min(idx + step, items.count - 1)
            lastEdgeScrollAt = Date()
            return (items[t].id, .bottom)
        }
        // 上缘对称。
        if idx <= first + 1, idx > 0 {
            let t = max(idx - step, 0)
            lastEdgeScrollAt = Date()
            return (items[t].id, .top)
        }
        return nil
    }

    /// 热力图的固定标尺：有锚点用锚点，否则用本批 P75。
    /// 与判定共用同一个基准，避免「全糊的图按自己 P99 归一化后满屏绿」。
    var heatFloor: Double {
        Analyzer.independentThreshold(sensitivity: 1.0, anchor: anchorHi)
    }
    var anchorName: String {
        anchorHi == nil ? "独立阈值 \(Int(Analyzer.independentFloor))" : "固定锚点"
    }

    func displayName(_ u: URL) -> String {
        if let cached = displayNameCache[u] { return cached }
        let stem = u.deletingPathExtension().lastPathComponent
        let same = results.filter { $0.id.deletingPathExtension().lastPathComponent == stem }.count
        let name = same > 1 ? u.lastPathComponent : stem
        displayNameCache[u] = name
        return name
    }

    /// 导入素材根文件夹名（取扫描目录最后一段），用于导出 CSV 的默认文件名。
    /// 扫描成功（找到照片）时记录；非 @Published：不进 UI，不触发重算。
    private(set) var importFolderName = "未命名"

    /// 从扫描根目录提取可用于文件名的文件夹名：取最后一段路径，
    /// 清理文件系统非法字符（/ \ : 等），根目录（"/"）或空名兜底为「未命名」。
    private static func folderName(from url: URL) -> String {
        var name = url.lastPathComponent
        if url.path == "/" || name.isEmpty { name = "未命名" }
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        name = name.components(separatedBy: invalid).joined(separator: "_")
            .trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "未命名" : name
    }

    func toggleExclude(_ u: URL) {
        if excluded.contains(u) { excluded.remove(u) } else { excluded.insert(u) }
    }

    func scan(folder: URL) {
        scan(folder: folder, forceReload: false)
    }

    /// 会话缓存优先当前文件夹，找不到就逐级向上找（最多 4 层）。
    /// 用户可能导入 .../拍鸟/好片 这样的子文件夹，而缓存写在 .../拍鸟 根目录。
    /// 2026-11-23 修正两个误判：
    /// ① 日志就在导入文件夹里时以日志为准——文件夹被移动/拷贝后快照里的绝对路径会过期，
    ///    不能因此拒绝使用随文件夹一起走的历史数据；
    /// ② 上级日志只有在本批照片确实有文件名重合时才借用，否则新文件夹会被错标成
    ///    「读取历史数据」却实际逐张重新分析。
    private func cachedSession(for folder: URL, files: [URL]) -> SessionSnapshot? {
        var cur = folder.standardizedFileURL
        for _ in 0..<4 {
            if let snap = SessionCache.load(folder: cur),
               let matched = SessionCache.matched(snap, source: cur, folder: folder, files: files) {
                return matched
            }
            if cur.pathComponents.count <= 2 { break }
            cur = cur.deletingLastPathComponent().standardizedFileURL
        }
        // 再向下汇总：用户可能把「拍鸟 / 风光 / 人像」放在一个大文件夹里分别处理过，
        // 每批的 log 写在各自子目录。导入大文件夹时应按文件名合并这些快照，
        // 已判定的直接恢复，只有真正新增的才分析（智慧识鸟式的"直接进入处理结果"）。
        return mergedChildSession(for: folder, files: files)
    }

    /// 向下扫描导入目录里的所有会话日志，按文件名合并成一份虚拟快照。
    /// 只取与本批照片有交集的日志，避免把无关子目录的历史混进来。
    private func mergedChildSession(for folder: URL, files: [URL]) -> SessionSnapshot? {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: folder, includingPropertiesForKeys: nil,
                                    options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return nil }
        var candidates: [SessionSnapshot] = []
        for case let f as URL in e where f.lastPathComponent == SessionCache.fileName {
            guard let data = try? Data(contentsOf: f),
                  let snap = try? JSONDecoder().decode(SessionSnapshot.self, from: data),
                  // v1/v2 都可读：v1 缺信息字段（解码 nil，读取后由补算阶段升到 v2）。
                  snap.version >= 1, snap.version <= SessionCache.version else { continue }
            if let matched = SessionCache.matched(snap, source: f.deletingLastPathComponent(),
                                                  folder: folder, files: files) {
                candidates.append(matched)
            }
        }
        guard !candidates.isEmpty else { return nil }
        // 从旧到新覆盖，同一文件以最新保存的记录为准。
        candidates.sort { $0.savedAt < $1.savedAt }
        var merged: [String: CachedPhoto] = [:]
        var exclusions = Set<String>()
        for snap in candidates {
            for p in snap.photos {
                merged[p.file] = p
                exclusions.remove(p.file)
            }
            exclusions.formUnion(snap.excludedFiles)
        }
        guard var snap = candidates.last, !merged.isEmpty else { return nil }
        snap.folderPath = folder.standardizedFileURL.path
        snap.excludedFiles = exclusions.sorted()
        snap.photos = merged.values.sorted { $0.file < $1.file }
        return snap
    }

    /// 当前素材根文件夹（scan(folder:) 记录）；「重新分析」按钮和会话缓存都靠它定位。
    private(set) var currentFolder: URL?

    /// 扫描文件夹。forceReload=false 时先查会话缓存：命中就直接加载历史判定，
    /// 只有缓存里没有的照片（新增）才真正分析（用户 2026-11-22 要求）。
    func scan(folder: URL, forceReload: Bool) {
        guard !processing else { return }
        let fm = FileManager.default
        var files: [URL] = []
        let allowed = MetadataWriter.rawExts
        if let e = fm.enumerator(at: folder, includingPropertiesForKeys: [.isDirectoryKey],
                                 options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
            for case let u as URL in e where allowed.contains(u.pathExtension.lowercased()) {
                files.append(u)
            }
        }
        guard !files.isEmpty else {
            currentFolder = folder
            resetBirdState()
            process([])
            return
        }
        importFolderName = Self.folderName(from: folder)
        let sorted = files.sorted { $0.lastPathComponent < $1.lastPathComponent }
        pendingScan = (folder, sorted, forceReload)
        pendingGenreChoice = nil
        pendingGenreResolved = false
        pendingHistorySnapshot = nil
        // 「重新分析」强制全量重算，不读历史日志，也就不该显示历史读取提示。
        guard !forceReload else {
            historyReadToken += 1   // 作废可能在途的旧读取回调
            endHistoryRead()
            pendingGenreResolved = true
            startPendingScan()
            return
        }
        // 2026-11-24：读历史日志（读文件 + JSON 解码）放后台，期间显示进度提示。
        // 大文件夹（上千张、含子目录日志）的日志解码在主线程会卡住界面，用户会以为死机。
        // 用 token 杜绝竞态：用户在读盘期间又导入别的文件夹时，旧的后台结果直接丢弃。
        historyReadToken += 1
        let token = historyReadToken
        beginHistoryRead("正在读取历史日志文件…")
        DispatchQueue.global(qos: .userInitiated).async {
            // 两件事一次读完：题材是否记过 + 完整历史快照，避免读两遍盘。
            let snap = self.cachedSession(for: folder, files: sorted)
            let choice = snap.flatMap { s -> FolderGenreChoice? in
                guard let raw = s.folderGenreChoice else { return nil }
                return FolderGenreChoice(rawValue: raw)
            }
            DispatchQueue.main.async {
                guard token == self.historyReadToken else { return }
                self.endHistoryRead()
                self.pendingHistorySnapshot = snap
                // 2026-11-23：题材选择提前到"读取历史数据/分析"之前，用户答完才真正开扫。
                // 但如果 log 里已经记着这批的题材选择（说明之前导入过），就不再打扰用户。
                if !self.genrePromptAsked.contains(folder) {
                    self.genrePromptAsked.insert(folder)
                    if choice != nil {
                        self.pendingGenreResolved = true
                        self.startPendingScan()
                        return
                    }
                    self.genrePromptFolder = folder
                    self.showGenrePrompt = true
                    return
                }
                self.pendingGenreResolved = true
                self.startPendingScan()
            }
        }
    }

    /// 用户答完题材弹窗（或无需提问）后才真正开始读缓存/分析。
    /// 历史快照已在 scan(folder:) 后台读好并存 pendingHistorySnapshot，这里直接复用，不再同步读盘。
    private func startPendingScan() {
        guard let job = pendingScan, pendingGenreResolved else { return }
        showGenrePrompt = false
        genrePromptFolder = nil
        currentFolder = job.folder
        resetBirdState()
        scanNote = ""
        let snap = job.forceReload ? nil : pendingHistorySnapshot
        pendingHistorySnapshot = nil
        if let snap {
            apply(snapshot: snap, files: job.files)
            return
        }
        process(job.files)
    }

    /// 读历史日志的代次与暂存快照。代次用于丢弃过期后台结果；
    /// 快照在题材弹窗等待期间暂存，弹窗答完后由 startPendingScan 直接复用。
    private var historyReadToken = 0
    private var pendingHistorySnapshot: SessionSnapshot?

    /// 标记「正在读历史日志」：进度提示 + 阶段文案，让主线程界面立即刷新出提示。
    private func beginHistoryRead(_ message: String) {
        historyReading = true
        sessionPhase = "读取历史数据"
        status = message
    }

    private func endHistoryRead() {
        historyReading = false
    }

    func scan(files: [URL]) {
        guard !processing else { return }
        historyReadToken += 1
        historyReading = false
        pendingScan = nil
        pendingHistorySnapshot = nil
        pendingGenreChoice = nil
        // 散拖文件没有明确的扫描根目录：清掉 currentFolder，
        // 避免这批结果的会话缓存覆盖到上一个文件夹的缓存上。
        currentFolder = nil
        resetBirdState()
        let allowed = MetadataWriter.rawExts
        let kept = files.filter { allowed.contains($0.pathExtension.lowercased()) }
        // 散拖多张文件时没有扫描目录，用第一张所在文件夹名兜底。
        if let first = kept.first { importFolderName = Self.folderName(from: first.deletingLastPathComponent()) }
        process(kept.sorted { $0.lastPathComponent < $1.lastPathComponent })
    }

    private func process(_ files: [URL]) {
        guard !files.isEmpty else {
            status = "没有找到可处理的 RAW 照片"
            return
        }
        processing = true
        selected = nil
        selections = []
        reference = nil
        showingReference = false
        heldRatingURL = nil
        requestedRatings = [:]
        ratingRequests = [:]
        lastDeleted = []
        deletedRecords = [:]
        analysisCoreActive = true
        done = 0
        total = files.count
        results = []
        wbCache = [:]
        afCache = [:]
        afLoading = []
        afAttempted = []
        exifCache = [:]
        focusCache = [:]
        humanCache = [:]
        aiCache = [:]
        ratingCache = [:]
        genreOverride = [:]
        heatCache = [:]
        baseCache = [:]
        thumbnailCache = [:]
        thumbLoading = []
        thumbPrefetchWork?.cancel(); thumbPrefetchWork = nil
        thumbnailGeneration &+= 1   // 丢弃在途缩略图回写（generation 守卫在回写点）
        // 原尺寸预览是重量级缓存：换文件夹必须整批失效，并让在途解码作废。
        resetFullPreviewCache()
        wbAttempted = []; exifAttempted = []; focusAttempted = []
        humanAttempted = []; thumbAttempted = []
        pendingRatings = [:]; ratingLoading = []
        ratingFlushWork?.cancel(); ratingFlushWork = nil
        pendingInfoApplies = []
        infoFlushWork?.cancel(); infoFlushWork = nil
        // 信息阶段作废（可能在途的旧批次写入）+ 可见行集合重置。
        infoPhaseGeneration &+= 1
        infoPhasePending = []
        infoPhaseInflight = 0
        visibleRowURLs = []
        pendingShiftEdgeScroll = false
        sessionPhase = "正在分析清晰度与拍摄信息"
        let generation = infoPhaseGeneration
        status = "新文件夹：正在分析…"
        let faces = preferFaces
        let anchor = anchorHi
        let sensitivity = self.sensitivity
        DispatchQueue.global(qos: .userInitiated).async {
            let (found, completed) = self.analyzePhotos(files, preferFaces: faces, generation: generation)
            let min = Analyzer.referenceThreshold(found, sensitivity: sensitivity, anchor: anchor)
            let list = found.map { m -> PhotoResult in
                let (v, why) = Analyzer.classify(m, hiMin: min)
                return PhotoResult(id: m.url, metrics: m, verdict: v, reason: why)
            }
            DispatchQueue.main.async {
                guard self.infoPhaseGeneration == generation else { return }
                self.mergeAnalyzedInfo(completed)
                self.metrics = found
                self.hiMin = min
                // 新素材序列：信息区高度重置为默认（显示到清晰度判定）；同一序列内切照片不动它。
                self.infoHeight = Store.defaultInfoHeight
                self.analysisCoreActive = false
                self.results = list
                self.applyPendingGenre()
                self.finishImportAfterInfo(newCount: found.count)
            }
        }
    }

    private func mergeAnalyzedInfo(_ completed: [URL: PhotoInfoSnapshot]) {
        let attempted = completed.keys
        afAttempted.formUnion(attempted)
        exifAttempted.formUnion(attempted)
        wbAttempted.formUnion(attempted)
        focusAttempted.formUnion(attempted)
        humanAttempted.formUnion(attempted)
        afCache.merge(completed.compactMapValues(\.af)) { _, new in new }
        exifCache.merge(completed.compactMapValues(\.exif)) { _, new in new }
        wbCache.merge(completed.compactMapValues(\.wb)) { _, new in new }
        focusCache.merge(completed.compactMapValues(\.focus)) { _, new in new }
        humanCache.merge(completed.compactMapValues(\.human)) { _, new in new }
        aiCache.merge(completed.compactMapValues(\.ai)) { _, new in new }
        ratingCache.merge(completed.compactMapValues(\.rating)) { _, new in new }
    }

    private static func analyzeInfo(_ metrics: PhotoMetrics, source: CGImageSource, af: AFInfo?) -> PhotoInfoSnapshot {
        let url = metrics.url
        let exif = ExifInfo.read(url, source: source)
        let wb = WhiteBalance.analyze(url, source: source)
        let focus = FocusSemanticsEngine.detect(url: url, subjectBoxes: metrics.bboxes,
                                                source: source, metadata: { (af, exif) })
        let thumb = Analyzer.thumbnail(source, maxSide: 1024)
        let human = thumb.flatMap { HumanPresenceEngine.detect(image: $0) }
        let ai = thumb.flatMap { AISubjectEngine.detect(image: $0) } ?? AISubject(
            kind: .none, reason: thumb == nil ? "原图读取失败" : "本机系统不支持前景分割（需 macOS 14+）",
            labels: [])
        return PhotoInfoSnapshot(wb: wb, af: af, exif: exif, focus: focus,
            human: human, ai: ai, rating: MetadataWriter.snapshot(url).rating ?? 0)
    }

    /// 每张只开一个 ImageIO 源，同一轮内完成清晰度、预览与拍摄信息。
    private func analyzePhotos(_ files: [URL], preferFaces: Bool, generation: UInt)
        -> ([PhotoMetrics], [URL: PhotoInfoSnapshot]) {
        let directories = Set(files.map { $0.deletingLastPathComponent() })
        let cacheNames = Dictionary(uniqueKeysWithValues: directories.map { folder in
            let representative = folder.appendingPathComponent("preview")
            let names = try? FileManager.default.contentsOfDirectory(atPath: MidPreviewCache.dir(for: representative).path)
            return (folder, names ?? [])
        })
        var output: [PhotoMetrics] = []
        var information: [URL: PhotoInfoSnapshot] = [:]
        var focusPoints: [String: AFInfo] = [:]
        let batchSize = 16
        for (index, url) in files.enumerated() {
            if index.isMultiple(of: batchSize) {
                focusPoints = AFReader.readBatch(Array(files[index..<min(files.count, index + batchSize)]))
            }
            autoreleasepool {
                if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                   let metrics = Analyzer.analyze(url, preferFaces: preferFaces, source: source,
                                                  previewMaxSide: Self.thumbnailDecodeSide) {
                    output.append(metrics)
                    MidPreviewCache.generateIfNeeded(for: url, existingNames: cacheNames[url.deletingLastPathComponent()], source: source)
                    information[url] = Self.analyzeInfo(metrics, source: source, af: focusPoints[url.path])
                }
            }
            let progress = index + 1
            if progress.isMultiple(of: 8) || progress == files.count {
                DispatchQueue.main.async {
                    guard self.infoPhaseGeneration == generation else { return }
                    self.done = progress
                }
            }
        }
        return (output, information)
    }

    private func showScreening(backfill files: [URL] = []) {
        if let first = shown.first {
            selected = first.id
            selections = [first.id]
        }
        processing = false
        sessionPhase = ""
        scheduleIdleFullPreviewWarmup()
        if !files.isEmpty { backfillMidPreviews(files: files) }
    }

    /// 信息全量分析完成后的收尾：解除 processing、终态文案、落盘 v2、批量写说明
    /// （评星依据按完整数据计算）、空闲预解前几张，然后后台跑鸟种批量。
    private func finishImportAfterInfo(newCount: Int) {
        // 鸟种识别并入分析阶段（用户 2026-11-25 明确要求）：processing 保持 true
        // 直到批量跑完才结束分析、进入筛选。这样筛选阶段鸟种已全部就绪，切图
        // 不会现算、不会转圈；之后只有手动圈主体才单张重认。
        let note = scanNote
        status = note + "新素材分析完成：\(newCount) 张，需留意 \(suspects.count) 张；正在识别鸟种…"
        saveSession()
        writeAllDescriptions()
        scanNote = ""
        runBirdBatch { [weak self] in
            guard let self else { return }
            self.status = note + "新素材分析完成：\(newCount) 张，需留意 \(self.suspects.count) 张，拍摄信息与鸟种已就绪"
            self.showScreening()
        }
    }

    /// 加载历史会话缓存（scan(folder:) 的快速路径）：
    /// 缓存里有的照片直接重建判定结果与指标（预览图重新解码，很快），
    /// 缓存里没有的（新增照片）照常分析；缓存里有但文件夹里没有的（已删除）丢弃。
    /// v2 log：信息字段（WB/AF/EXIF/Focus/Human/AI/Rating）直接还原，纯读零现算；
    /// v1 老 log（缺字段）：瞬时恢复入口不变，后台静默补算信息字段并回写 v2。
    private func apply(snapshot: SessionSnapshot, files: [URL]) {
        processing = true
        selected = nil
        selections = []
        reference = nil
        showingReference = false
        heldRatingURL = nil
        requestedRatings = [:]
        ratingRequests = [:]
        lastDeleted = []
        deletedRecords = [:]
        analysisCoreActive = true
        done = 0
        total = files.count
        results = []
        wbCache = [:]
        afCache = [:]
        afLoading = []
        afAttempted = []
        exifCache = [:]
        focusCache = [:]
        humanCache = [:]
        aiCache = [:]
        ratingCache = [:]
        genreOverride = [:]
        heatCache = [:]
        baseCache = [:]
        thumbnailCache = [:]
        thumbLoading = []
        thumbPrefetchWork?.cancel(); thumbPrefetchWork = nil
        thumbnailGeneration &+= 1   // 丢弃在途缩略图回写（generation 守卫在回写点）
        // 原尺寸预览是重量级缓存：换文件夹必须整批失效，并让在途解码作废。
        resetFullPreviewCache()
        wbAttempted = []; exifAttempted = []; focusAttempted = []
        humanAttempted = []; thumbAttempted = []
        pendingRatings = [:]; ratingLoading = []
        ratingFlushWork?.cancel(); ratingFlushWork = nil
        pendingInfoApplies = []
        infoFlushWork?.cancel(); infoFlushWork = nil
        infoPhaseGeneration &+= 1
        infoPhasePending = []
        infoPhaseInflight = 0
        visibleRowURLs = []
        pendingShiftEdgeScroll = false
        selectionRects = [:]
        excluded = []
        sessionPhase = "读取历史数据"
        status = "正在读取历史数据…"
        let root = URL(fileURLWithPath: snapshot.folderPath)
        let byName = Dictionary(uniqueKeysWithValues: snapshot.photos.map { ($0.file, $0) })
        // 2026-11-23 瞬时化：判定数值全在 log 里，恢复不需要解码 RAW。
        // 原实现对每张都调 Analyzer.decode（单张 CR3 260~500ms），
        // 45 张要爬十几秒进度条，看起来像在重新分析。现在同步重建，
        // preview 留 nil，缩略图交给 ResultRow.onAppear 按需解 160px 小图。
        var found: [PhotoMetrics] = []
        var list: [PhotoResult] = []
        var cachedSelections: [URL: CGRect] = [:]
        var cachedGenres: [URL: PhotoGenre] = [:]
        var newFiles: [URL] = []
        // v1 老日志（信息字段缺失）待补算的照片。
        var pendingInfo: [URL] = []
        // v2 信息字段先攒局部字典，恢复完一次性赋值（@Published 只广播一轮）。
        var restoredWB: [URL: WhiteBalanceStats] = [:]
        var restoredAF: [URL: AFInfo] = [:]
        var restoredExif: [URL: ExifInfo] = [:]
        var restoredFocus: [URL: FocusSemantics] = [:]
        var restoredHuman: [URL: HumanPresence] = [:]
        var restoredAI: [URL: AISubject] = [:]
        var cachedOverrides: [URL: CGRect] = [:]
        var ratingURLs: [URL] = []
        for u in files {
            if let c = byName[SessionCache.relativePath(u, in: root)] {
                cachedSelections[u] = c.selectionRect
                cachedGenres[u] = c.genreOverride.flatMap { PhotoGenre(rawValue: $0) }
                cachedOverrides[u] = c.overrideRect
                guard let m = SessionCache.metrics(from: c, url: u, decodePreview: false) else {
                    newFiles.append(u)
                    continue
                }
                let v = Verdict(rawValue: c.verdict) ?? .unreadable
                var r = PhotoResult(id: u, metrics: m, verdict: v, reason: c.reason)
                r.overrideRect = c.overrideRect
                found.append(m)
                list.append(r)
                // 信息字段还原：rating 非 nil ⇒ 这张的信息已算过（导入阶段每张都会
                // 算出星级快照，星级恒有值）；wb/af 等为 nil 是「算过但无数据」，
                // attempted 标记防止切图时重复现算。v1 缺字段 → 进补算队列。
                if c.rating != nil {
                    if let wb = c.wb { restoredWB[u] = wb }
                    if let af = c.af { restoredAF[u] = af }
                    if let exif = c.exif { restoredExif[u] = exif }
                    if let focus = c.focus { restoredFocus[u] = focus }
                    if let human = c.human { restoredHuman[u] = human }
                    if let ai = c.ai { restoredAI[u] = ai }
                    ratingURLs.append(u)
                    wbAttempted.insert(u); exifAttempted.insert(u)
                    afAttempted.insert(u); focusAttempted.insert(u)
                    humanAttempted.insert(u)
                } else {
                    pendingInfo.append(u)
                }
            } else {
                newFiles.append(u)
            }
        }
        let generation = infoPhaseGeneration
        func restore(adding additions: [PhotoMetrics], information: [URL: PhotoInfoSnapshot], ratings: [URL: Int]) {
            guard self.infoPhaseGeneration == generation else { return }
            for m in additions {
                let rect = cachedOverrides[m.url]
                let (v, why) = Analyzer.classify(m, hiMin: snapshot.hiMin,
                                                subjectOverride: rect.map { Analyzer.rectRatio(m, rect: $0) })
                found.append(m)
                var result = PhotoResult(id: m.url, metrics: m, verdict: v,
                                         reason: rect == nil ? why : why + "（人工圈选）")
                result.overrideRect = rect
                list.append(result)
            }
            self.metrics = found
            self.hiMin = snapshot.hiMin
            self.sensitivity = snapshot.sensitivity
            self.anchorHi = snapshot.anchorHi
            self.folderGenreChoice = snapshot.folderGenreChoice.flatMap { FolderGenreChoice(rawValue: $0) }
            self.infoHeight = Store.defaultInfoHeight
            self.analysisCoreActive = false
            self.results = list
            self.selectionRects = cachedSelections
            self.genreOverride = cachedGenres
            self.excluded = Set(snapshot.excludedFiles.map { root.appendingPathComponent($0) })
            self.wbCache = restoredWB
            self.afCache = restoredAF
            self.exifCache = restoredExif
            self.focusCache = restoredFocus
            self.humanCache = restoredHuman
            if !restoredAI.isEmpty {
                var mergedAI: [URL: AISubject?] = [:]
                for (u, ai) in restoredAI { mergedAI[u] = ai }
                self.aiCache = mergedAI   // 一次性赋值，@Published 只广播一轮
            }
            self.ratingCache = ratings
            self.mergeAnalyzedInfo(information)
            self.done = files.count
            let df = DateFormatter()
            df.dateFormat = "M-d HH:mm"
            let savedText = df.string(from: snapshot.savedAt)
            self.applyPendingGenre()
            self.saveSession()
            if pendingInfo.isEmpty && newFiles.isEmpty {
                // v2 全量命中：信息区零现算瞬时恢复；鸟种同样在读取阶段一次性从
                // kingfisher-birds.log 批量还原（纯读，不解码原图、不推理），完成后
                // 才结束 processing。筛选阶段鸟种已全在内存，切图不再现算/转圈。
                let note = self.scanNote
                self.scanNote = ""
                self.writeAllDescriptions()
                self.runBirdBatch { [weak self] in
                    guard let self else { return }
                    self.status = note + "已读取历史数据（\(list.count) 张，保存于 \(savedText)），拍摄信息与鸟种已就绪。点「重新分析」可全量重算"
                    self.showScreening(backfill: files)
                }
            } else {
                // 旧日志和新增照片共用信息补算队列。
                let pending = pendingInfo
                self.status = self.scanNote + "已读取历史数据（\(list.count - additions.count) 张，保存于 \(savedText)）；正在后台补算拍摄信息"
                self.scanNote = ""
                self.startInfoPhase(pending: pending, phaseText: "2/2 · 正在补算拍摄信息") { [weak self] in
                    self?.finishHistoryBackfill(restoredCount: list.count - additions.count,
                                                 savedText: savedText, files: files)
                }
            }
        }

        sessionPhase = newFiles.isEmpty ? "正在核对照片评级" : "正在分析新增照片"
        total = newFiles.count
        let pending = newFiles
        let cachedRatingURLs = ratingURLs
        let faces = preferFaces
        ratingWriteQueue.async {
            var ratings: [URL: Int] = [:]
            for url in cachedRatingURLs {
                ratings[url] = autoreleasepool { MetadataWriter.snapshot(url).rating ?? 0 }
            }
            let refreshed = ratings
            DispatchQueue.global(qos: .userInitiated).async {
                let (additions, information) = self.analyzePhotos(pending, preferFaces: faces, generation: generation)
                DispatchQueue.main.async { restore(adding: additions, information: information, ratings: refreshed) }
            }
        }
    }

    /// 历史 v1 补算完成后的收尾：回写 v2（不丢已恢复的圈选/题材/排除——saveSession
    /// 全量重写当前状态），终态文案、写说明、空闲预解，然后后台跑鸟种批量。
    private func finishHistoryBackfill(restoredCount: Int, savedText: String, files: [URL]) {
        // 同新素材：鸟种并入分析阶段，processing 覆盖到批量完成才进入筛选。
        saveSession()
        status = "已读取历史数据（\(restoredCount) 张，保存于 \(savedText)）；正在识别鸟种…"
        writeAllDescriptions()
        runBirdBatch { [weak self] in
            guard let self else { return }
            self.status = "已读取历史数据（\(restoredCount) 张，保存于 \(savedText)）；拍摄信息与鸟种已就绪"
            self.showScreening(backfill: files)
        }
    }

    /// 把当前文件夹的判定状态落盘（会话缓存）。照片全部删除后清掉缓存文件。
    /// v2：信息区字段（WB/AF/EXIF/Focus/Human/AI/Rating）一起落盘——rating 已读到的
    /// 张视为「信息就绪」整组写入；AI 在途占位（识别进行中）不写，下次按需重算。
    /// 准入条件用 analysisCoreActive（判定分析核心）而非 processing：信息阶段/
    /// 鸟种批量期间 results 已定型，可以安全落盘（崩溃也不丢判定）。
    /// 最近一次成功序列化的会话数据。2026-11-25 修复退出卡死：
    /// willTerminateNotification 过去直接调 saveSession()，在**主线程**现编
    /// 845 张照片的 v2 JSON（每张含 scores/blurScores/weights 等上千个数字，
    /// 整包可达数十 MB），叠加后台鸟种批量与原图解码争抢资源，App 长时间无响应。
    /// 现在正常 saveSession 时顺手缓存编码结果，退出只写这一份 Data。
    private var lastSessionSave: (folder: URL, data: Data)?
    /// 保护 lastSessionSave 的跨队列读写：后台 sessionSaveQueue 写，
    /// willTerminate 在主线程读。锁内只做值拷贝，绝不做编码/写盘（无死锁风险）。
    private let sessionCacheLock = NSLock()

    func saveSession() {
        guard let folder = currentFolder, !analysisCoreActive, !results.isEmpty else { return }
        var info: [URL: PhotoInfoSnapshot] = [:]
        for r in results {
            guard ratingCache[r.id] != nil else { continue }
            var ai: AISubject?
            if let maybe = aiCache[r.id], let settled = maybe,
               !settled.reason.contains("进行中") {
                ai = settled
            }
            info[r.id] = PhotoInfoSnapshot(wb: wbCache[r.id], af: afCache[r.id],
                                           exif: exifCache[r.id], focus: focusCache[r.id],
                                           human: humanCache[r.id], ai: ai,
                                           rating: ratingCache[r.id])
        }
        // 序列化和写盘都放到后台：845 张 v2 快照在主线程编码会让界面明显停顿。
        // 判定结果在调度的瞬间快照下来，之后后台只读这些不可变副本。
        let snap = SessionSaveJob(folder: folder, sensitivity: sensitivity, anchorHi: anchorHi,
                                  hiMin: hiMin, excluded: excluded, results: results,
                                  metrics: metrics, selectionRects: selectionRects,
                                  genreOverride: genreOverride,
                                  folderGenreChoice: folderGenreChoice?.rawValue, info: info)
        sessionSaveQueue.async { [weak self] in
            guard let self else { return }
            guard let data = snap.encode() else { return }
            // QA P2 顺序反转修复：缓存更新与写盘都在同一后台队列内完成，
            // 不再经 DispatchQueue.main.async 回写（旧版在"新数据已落盘"与
            // "主线程更新缓存"之间退出时，会用旧 Data 盖掉刚写好的新数据）。
            // URL/Data 都是值类型，锁内只做赋值，绝不持锁做编码/写盘。
            // 写盘前先更新缓存：这样即便退出恰好发生在 writeEncoded 执行中，
            // 退出侧也会写同一份新 Data，彻底没有"新盘数据 + 旧缓存"的窗口。
            self.sessionCacheLock.lock()
            self.lastSessionSave = (snap.folder, data)
            self.sessionCacheLock.unlock()
            SessionCache.writeEncoded(data, for: snap.folder)
            // 写盘后再确认一次缓存（同队列、同一份不可变 Data；幂等）。
            self.sessionCacheLock.lock()
            self.lastSessionSave = (snap.folder, data)
            self.sessionCacheLock.unlock()
        }
    }

    /// 退出专用：只写已编码好的快照，绝不在 willTerminate 里做重编码。
    /// 从没正常保存过（极早期退出）时跳过——判定/鸟种/XMP 都已随写随落。
    func saveSessionOnExit() {
        // 与后台写入方用同一把锁，读一份值快照后立即解锁；
        // writeEncoded 在锁外执行，退出路径绝不编码 845 张 v2 JSON。
        sessionCacheLock.lock()
        let hit = lastSessionSave
        sessionCacheLock.unlock()
        guard let hit else { return }
        SessionCache.writeEncoded(hit.data, for: hit.folder)
    }

    private let sessionSaveQueue = DispatchQueue(label: "kingfisher.session.save", qos: .utility)

    /// 线程安全的会话保存快照：主线程收集，后台队列序列化 + 写盘。
    private struct SessionSaveJob {
        let folder: URL
        let sensitivity: Double
        let anchorHi: Double?
        let hiMin: Double
        let excluded: Set<URL>
        let results: [PhotoResult]
        let metrics: [PhotoMetrics]
        let selectionRects: [URL: CGRect]
        let genreOverride: [URL: PhotoGenre]
        let folderGenreChoice: String?
        let info: [URL: PhotoInfoSnapshot]

        func encode() -> Data? {
            let byURL = Dictionary(uniqueKeysWithValues: metrics.map { ($0.url, $0) })
            let photos: [CachedPhoto] = results.compactMap { r in
                guard let m = byURL[r.id] else { return nil }
                let i = info[r.id]
                return CachedPhoto(
                    file: SessionCache.relativePath(r.id, in: folder),
                    verdict: r.verdict.rawValue, reason: r.reason,
                    overrideRect: r.overrideRect, selectionRect: selectionRects[r.id],
                    genreOverride: genreOverride[r.id]?.rawValue,
                    globalHi: m.globalHi, peakBlock: m.peakBlock, subjectScore: m.subjectScore,
                    ratio: m.ratio, centerRatio: m.centerRatio, anisotropy: m.anisotropy,
                    softRatio: m.softRatio, spread: m.spread,
                    reblurRatio: m.reblurRatio, subjectReblur: m.subjectReblur,
                    scores: m.scores, blurScores: m.blurScores,
                    cols: m.cols, rows: m.rows, weights: m.weights,
                    subjectSource: m.subjectSource, bboxes: m.bboxes,
                    width: m.width, height: m.height,
                    wb: i?.wb, af: i?.af, exif: i?.exif, focus: i?.focus,
                    human: i?.human, ai: i?.ai, rating: i?.rating)
            }
            guard !photos.isEmpty else { return nil }
            let snap = SessionSnapshot(version: SessionCache.version, folderPath: folder.path,
                                       savedAt: Date(), sensitivity: sensitivity,
                                       anchorHi: anchorHi, hiMin: hiMin,
                                       excludedFiles: excluded.map { SessionCache.relativePath($0, in: folder) }.sorted(),
                                       photos: photos, folderGenreChoice: folderGenreChoice)
            return try? JSONEncoder().encode(snap)
        }
    }

    func recompute() {
        guard !metrics.isEmpty else { return }
        hiMin = Analyzer.referenceThreshold(metrics, sensitivity: sensitivity, anchor: anchorHi)
        let old = Dictionary(uniqueKeysWithValues: results.map { ($0.id, $0.overrideRect) })
        results = metrics.map { m in
            let cr = old[m.url]?.flatMap { Optional(Analyzer.rectRatio(m, rect: $0)) }
            let (v, why) = Analyzer.classify(m, hiMin: hiMin, subjectOverride: cr)
            var r = PhotoResult(id: m.url, metrics: m, verdict: v,
                                reason: cr == nil ? why : why + "（人工圈选）")
            r.overrideRect = old[m.url] ?? nil
            return r
        }
        status = "已按新灵敏度重算，需留意 \(suspects.count) 张"
        saveSession()
    }

    func recheck(id: URL, rect: CGRect) {
        guard let idx = resultIndex[id],
              let m = metrics.first(where: { $0.url == id }) else { return }
        // 2026-11-23：记录重判前的「只看需留意」列表顺序。若圈选后这张不再需留意、
        // 从过滤列表消失，就自动选中它原来的下一张（仍在列表里的），并明确提示，
        // 避免界面停在已消失的照片上、用户找不到下一张该处理的。
        let wasFiltered = onlySuspect
        let oldShown = shown
        let oldIndex = oldShown.firstIndex(where: { $0.id == id })
        let wasSelected = selected == id

        let cr = Analyzer.rectRatio(m, rect: rect)
        let (v, why) = Analyzer.classify(m, hiMin: hiMin, subjectOverride: cr)
        objectWillChange.send()
        results[idx].verdict = v
        results[idx].reason = why + "（人工圈选）"
        results[idx].overrideRect = rect
        // 元素原地改动不触发 results 的 didSet，手动失效派生快照。
        suspectCache = nil; shownCache = nil; writableCache = nil
        // 同时持久记录显示用圈选框：切照片/复位缩放后仍按这张照片恢复。
        selectionRects[id] = rect

        var msg = "已按圈选区域重判 \(id.deletingPathExtension().lastPathComponent)：\(v.rawValue)"
        if wasFiltered && wasSelected && !v.isSuspect {
            // 当前这张已不在「只看需留意」列表里——找接替者并提示
            var next: URL?
            if let i = oldIndex {
                // 从原位置往后找第一张仍在过滤列表里的
                for j in (i + 1)..<oldShown.count where shownContains(oldShown[j].id) {
                    next = oldShown[j].id
                    break
                }
                if next == nil {
                    for j in (0..<i).reversed() where shownContains(oldShown[j].id) {
                        next = oldShown[j].id
                        break
                    }
                }
            }
            if let n = next {
                selected = n
                selections = [n]
                msg += "；已不再需留意，自动跳到下一张：\(displayName(n))"
            } else {
                // 过滤列表已空
                msg += "；已不再需留意，需留意列表已空"
            }
        }
        status = msg
        // 拍鸟题材：用新圈选的主体框重新识别鸟种（人工确认结果不覆盖）。
        refreshBirdAfterSubjectSelection(for: id)
        saveSession()
    }

    /// 取消这张照片的人工圈选：清掉黄框和单张重判结果，恢复按自动识别主体判定/评分。
    /// 只影响当前照片；其他照片的圈选记录不动，鸟种结果与人工确认也不动。
    func clearManualSubject(for id: URL) {
        guard let idx = resultIndex[id],
              let m = metrics.first(where: { $0.url == id }),
              selectionRects[id] != nil || results[idx].overrideRect != nil else { return }
        let (v, why) = Analyzer.classify(m, hiMin: hiMin, subjectOverride: nil)
        objectWillChange.send()
        results[idx].verdict = v
        results[idx].reason = why
        results[idx].overrideRect = nil
        suspectCache = nil; shownCache = nil; writableCache = nil
        selectionRects.removeValue(forKey: id)
        resetZoom()
        status = "已取消 \(id.deletingPathExtension().lastPathComponent) 的自选主体，恢复自动判定"
        saveSession()
    }

    func setAnchor(_ url: URL) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let m = Analyzer.analyze(url) else {
                DispatchQueue.main.async { self.status = "锚点照片无法解析：\(url.lastPathComponent)" }
                return
            }
            DispatchQueue.main.async {
                self.anchorHi = m.globalHi
                self.recompute()
                self.status = "清晰基准已设为 \(url.deletingPathExtension().lastPathComponent)（最锐区 \(Int(m.globalHi))）"
            }
        }
    }

    func clearAnchor() {
        anchorHi = nil
        recompute()
        status = "已恢复独立固定阈值，每张照片单独判定"
    }

    /// - Parameter relevant: 仅供预取传入的复查闭包，内部只读 NSLock 保护的
    ///   PrefetchGate 快照，不碰 Store 状态。视图按需加载不传（恒真）。
    ///   被拒绝时在回到主线程后恢复标记并调 reschedulePrefetchedInfo 留重试路径。
    func ensureWB(for url: URL, on queue: DispatchQueue = .global(qos: .utility),
                  relevant: (() -> Bool)? = nil) {
        // analyze 返回 nil 时字典里不会留下值，靠 attempted 防止反复解码 RAW。
        guard wbCache[url] == nil, !wbAttempted.contains(url) else { return }
        wbAttempted.insert(url)
        queue.async {
            guard relevant?() ?? true else {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.wbAttempted.remove(url)
                    self.reschedulePrefetchedInfo(for: url)
                }
                return
            }
            let s = WhiteBalance.analyze(url)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.stageInfoUpdate { self.wbCache[url] = s }
            }
        }
    }

    func ensureAF(for url: URL, on queue: DispatchQueue = .global(qos: .utility),
                  relevant: (() -> Bool)? = nil) {
        // attempted 同时覆盖"读到数据"与"确认无数据"，避免无数据的图反复跑 exiftool。
        guard !afAttempted.contains(url) else { return }
        afAttempted.insert(url)
        afLoading.insert(url)
        queue.async {
            guard relevant?() ?? true else {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.afAttempted.remove(url)
                    self.afLoading.remove(url)
                    self.reschedulePrefetchedInfo(for: url)
                }
                return
            }
            let info = AFReader.read(url)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.stageInfoUpdate {
                    self.afLoading.remove(url)
                    if let info { self.afCache[url] = info }
                }
            }
        }
    }

    func ensureExif(for url: URL, on queue: DispatchQueue = .global(qos: .utility),
                    relevant: (() -> Bool)? = nil) {
        guard exifCache[url] == nil, !exifAttempted.contains(url) else { return }
        exifAttempted.insert(url)
        queue.async {
            guard relevant?() ?? true else {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.exifAttempted.remove(url)
                    self.reschedulePrefetchedInfo(for: url)
                }
                return
            }
            let info = ExifInfo.read(url)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.stageInfoUpdate { self.exifCache[url] = info }
            }
        }
    }

    /// 对焦点语义：算一次缓存住。结果只影响题材识别，不算出来也能用原有规则。
    /// 传入主体检测框：对焦点没认出鸟时，拿主体框再复核一次能不能认出鸟。
    func ensureFocus(for url: URL, subjectBoxes: [CGRect] = [],
                     on queue: DispatchQueue = .global(qos: .utility),
                     relevant: (() -> Bool)? = nil) {
        // detect 内部会解码 2048px 缩略图、跑 exiftool 与 Vision，nil 时不能重跑。
        guard focusCache[url] == nil, !focusAttempted.contains(url) else { return }
        focusAttempted.insert(url)
        queue.async {
            guard relevant?() ?? true else {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.focusAttempted.remove(url)
                    self.reschedulePrefetchedInfo(for: url)
                }
                return
            }
            let s = FocusSemanticsEngine.detect(url: url, subjectBoxes: subjectBoxes)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.stageInfoUpdate { self.focusCache[url] = s }
            }
        }
    }

    /// 人体存在检测（背影/侧身也算人）：算一次缓存住。只影响题材识别的兜底判断。
    /// 与 ensureAI 共用一次 1024px 解码，避免同一张 RAW 连解两次。
    func ensureHuman(for url: URL, on queue: DispatchQueue = .global(qos: .utility),
                     relevant: (() -> Bool)? = nil) {
        guard humanCache[url] == nil, !humanAttempted.contains(url) else { return }
        humanAttempted.insert(url)
        requestAnalysisThumbnail(for: url) { [weak self] img in
            guard let self else { return }
            guard relevant?() ?? true else {
                self.humanAttempted.remove(url)
                self.reschedulePrefetchedInfo(for: url)
                return
            }
            queue.async {
                let h = img.flatMap { HumanPresenceEngine.detect(image: $0) }
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.stageInfoUpdate { self.humanCache[url] = h }
                }
            }
        }
    }

    /// AI 主体识别（前景实例分割 + 逐主体分类）：算一次缓存住。
    /// 与对焦点语义互补——对焦点认不出时看画面主体本身是什么。
    /// macOS 14 以下没有分割 API，结果是 nil，识别链退回原有规则。
    func ensureAI(for url: URL, on queue: DispatchQueue = .global(qos: .utility),
                  relevant: (() -> Bool)? = nil) {
        guard aiCache[url] == nil else { return }
        aiCache[url] = AISubject(kind: .none, reason: "AI 主体识别进行中…", labels: [])
        requestAnalysisThumbnail(for: url) { [weak self] img in
            guard let self else { return }
            guard relevant?() ?? true else {
                self.aiCache[url] = nil   // 撤销占位，回到附近时还能正常加载
                self.reschedulePrefetchedInfo(for: url)
                return
            }
            queue.async {
                let s = img.flatMap { AISubjectEngine.detect(image: $0) }
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.stageInfoUpdate {
                        self.aiCache[url] = s ?? AISubject(kind: .none,
                            reason: img == nil ? "原图读取失败" : "本机系统不支持前景分割（需 macOS 14+）",
                            labels: [])
                    }
                }
            }
        }
    }

    func ensureRating(for url: URL, on queue: DispatchQueue = .global(qos: .utility),
                      relevant: (() -> Bool)? = nil) {
        guard ratingCache[url] == nil, pendingRatings[url] == nil,
              !ratingLoading.contains(url) else { return }
        ratingLoading.insert(url)
        queue.async {
            guard relevant?() ?? true else {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.ratingLoading.remove(url)
                    self.reschedulePrefetchedInfo(for: url)
                }
                return
            }
            let rating = MetadataWriter.snapshot(url).rating ?? 0
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.ratingLoading.remove(url)
                // 读取期间用户可能已经用快捷键改了星级，别用旧值盖掉新评分。
                guard self.ratingCache[url] == nil, self.pendingRatings[url] == nil else { return }
                self.pendingRatings[url] = rating
                self.scheduleRatingFlush()
            }
        }
    }

    /// 短延时把这一批星级合并成一次字典赋值，@Published 只发一次通知。
    private func scheduleRatingFlush() {
        guard ratingFlushWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.flushRatings() }
        ratingFlushWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private func flushRatings() {
        ratingFlushWork?.cancel()
        ratingFlushWork = nil
        let batch = pendingRatings
        pendingRatings = [:]
        guard !batch.isEmpty else { return }
        var updated = ratingCache
        for (url, rating) in batch where updated[url] == nil { updated[url] = rating }
        ratingCache = updated
    }

    // MARK: - 信息全量分析（导入 / 历史补算共用）

    /// 把 pending 列表照片的信息字段（WB/AF/EXIF/Focus/Human/AI/Rating）全部算完。
    /// 这是「把能放到分析阶段的东西全放到分析阶段」的核心：分析阶段算完落盘 v2，
    /// 筛选阶段信息区零现算（老 log / 字段缺失时按需 ensure* 保留作兜底）。
    /// 设计要点：
    /// - 统一进度页等待清晰度与拍摄信息分析，筛选界面待分析结束再挂载；
    /// - 并发限 3（infoPhaseInflight 自控），QoS utility；
    /// - 去重安全：与按需 ensure* 共用 attempted 标记，同一字段同一张只算一次；
    /// - 世代作废：导入新文件夹时 infoPhaseGeneration 自增，旧批次在途写入丢弃。
    private func startInfoPhase(pending: [URL], phaseText: String,
                                completion: @escaping () -> Void) {
        infoPhaseGeneration &+= 1
        let gen = infoPhaseGeneration
        infoPhaseInflight = 0
        guard !pending.isEmpty else { completion(); return }
        infoPhasePending = pending
        done = 0
        total = pending.count
        sessionPhase = phaseText
        infoPhaseFinishing = { [weak self] in
            guard let self, self.infoPhaseGeneration == gen else { return }
            completion()
        }
        for _ in 0..<min(infoPhaseMaxInflight, pending.count) { infoPhaseScheduleNext() }
    }

    /// 调度下一步：维持最多 3 张在算，完成后每张回填时再补位。
    /// 只在主线程调用（读缓存/attempted/selected 都是非线程安全状态）。
    private func infoPhaseScheduleNext() {
        if infoPhasePending.isEmpty && infoPhaseInflight == 0 {
            let finish = infoPhaseFinishing
            infoPhaseFinishing = nil
            flushInfoUpdates()
            flushRatings()
            finish?()
            return
        }
        guard infoPhaseInflight < infoPhaseMaxInflight, !infoPhasePending.isEmpty else { return }
        let url = infoPhasePending.removeFirst()
        infoPhaseInflight += 1
        let boxes = result(for: url)?.metrics.bboxes ?? []
        // 只算「缓存里没有、也没有在途任务」的字段——用户按需路径可能已算/在算。
        let needWB = wbCache[url] == nil && !wbAttempted.contains(url)
        let needAF = !afAttempted.contains(url)
        let needExif = exifCache[url] == nil && !exifAttempted.contains(url)
        let needFocus = focusCache[url] == nil && !focusAttempted.contains(url)
        let needHuman = humanCache[url] == nil && !humanAttempted.contains(url)
        let needAI = aiCache[url] == nil
        let needRating = ratingCache[url] == nil && pendingRatings[url] == nil
            && !ratingLoading.contains(url)
        if needWB { wbAttempted.insert(url) }
        if needAF {
            afAttempted.insert(url)
            // afLoading 只对「正在看这张」有意义（驱动画面角落提示），避免无谓广播。
            if url == selected { afLoading.insert(url) }
        }
        if needExif { exifAttempted.insert(url) }
        if needFocus { focusAttempted.insert(url) }
        if needHuman { humanAttempted.insert(url) }
        if needRating { ratingLoading.insert(url) }
        let afExisting = afCache[url]
        let exifExisting = exifCache[url]
        let gen = infoPhaseGeneration
        infoPhaseQueue.async {
            // 引擎与口径与按需 ensure* 完全一致：WB 600px / AF exiftool / EXIF
            // ImageIO / Focus 2048px / Human+AI 共享一次 1024px 彩色解码。
            let af = needAF ? AFReader.read(url) : afExisting
            let rating = needRating ? (MetadataWriter.snapshot(url).rating ?? 0) : nil
            self.infoPhaseImageLock.lock()
            let wb = needWB ? WhiteBalance.analyze(url) : nil
            let exif = needExif ? ExifInfo.read(url) : exifExisting
            let focus = needFocus
                ? FocusSemanticsEngine.detect(url: url, subjectBoxes: boxes, metadata: { (af, exif) }) : nil
            var human: HumanPresence? = nil
            var ai: AISubject? = nil
            var decoded = false
            if needHuman || needAI {
                if let thumb = Analyzer.analysisThumbnail(url) {
                    decoded = true
                    if needHuman { human = HumanPresenceEngine.detect(image: thumb) }
                    if needAI { ai = AISubjectEngine.detect(image: thumb) }
                }
            }
            self.infoPhaseImageLock.unlock()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.infoPhaseGeneration == gen else { return }
                self.stageInfoUpdate {
                    if let wb { self.wbCache[url] = wb }
                    if needAF { self.afLoading.remove(url) }
                    if let af { self.afCache[url] = af }
                    if let exif { self.exifCache[url] = exif }
                    if let focus { self.focusCache[url] = focus }
                    if let human { self.humanCache[url] = human }
                    if needAI {
                        // 与 ensureAI 同口径：解码失败/系统不支持都如实记录，不反复重跑。
                        self.aiCache[url] = ai ?? AISubject(
                            kind: .none,
                            reason: decoded ? "本机系统不支持前景分割（需 macOS 14+）" : "原图读取失败",
                            labels: [])
                    }
                }
                if let rating {
                    // 读取期间用户可能已经改了星级：走 pendingRatings 合并路径，
                    // 已有值时不会被旧快照盖掉（scheduleRatingFlush 内保护）。
                    self.pendingRatings[url] = rating
                    self.scheduleRatingFlush()
                }
                if needRating { self.ratingLoading.remove(url) }
                self.done += 1
                self.infoPhaseInflight -= 1
                self.infoPhaseScheduleNext()
            }
        }
    }

    /// 分析阶段的最后一步：把全部拍鸟题材的照片批量识别完（用户 2026-11-25 明确
    /// 要求）。非拍鸟题材不跑；串行、低优先级、带进度提示；processing 覆盖到批量
    /// 完成才结束，因此进入筛选阶段时鸟种已全部就绪，切图不再现算/转圈。
    /// 之后只有手动圈主体（refreshBirdAfterSubjectSelection）才单张重认。
    /// 四重去重全部保留：人工确认（日志优先读取）、birdDismissed、
    /// birdUnreliable、birdTaskToken/birdLoading 在途去重；结果落盘走
    /// ensureBird → commitBird → kingfisher-birds.log（含 Top3/置信/来源/依据）。
    private func runBirdBatch(completion: @escaping () -> Void) {
        // 新旧批次交替：上一批排队中的 URL 直接作废，避免两批同时跑重复推理。
        birdBatchGeneration &+= 1
        // QA 防御项：上一批可能没经过 resetBirdState 就结束了（例如 completion 路径），
        // 若不复位 active，新批的 pumpBirdBatch 会被旧标志挡住而永远不启动。
        birdBatchActive = false
        birdBatchPending = []
        birdBatchTotal = 0
        birdBatchSettled = 0
        birdBatchCompletion = nil
        // 默认不跑模型：只把历史日志里已有的可靠结果读回内存显示（纯读、很快）。
        // 用户显式开启「识别鸟种」才在批量里真正推理。只读模式模型不可用时照样能还原。
        let logOnly = !birdRecognitionEnabled
        guard BirdSpeciesEngine.available || logOnly else { completion(); return }
        let targets = results
            .filter { genre(for: $0).0 == .bird }
            .filter { birdCache[$0.id] == nil && !birdLoading.contains($0.id)
                      && !birdDismissed.contains($0.id) && !birdUnreliable.contains($0.id) }
            .map { $0.id }
        guard !targets.isEmpty else { completion(); return }
        sessionPhase = logOnly ? "读取鸟种记录" : "识别鸟种中"
        // 进度条此前借用信息阶段的 done/total，出现「识别鸟种中 1350/1350」满格
        // 却没结果的假象。这里重置为鸟种批量自己的计数，随每张完成推进。
        done = 0
        total = targets.count
        status = logOnly
            ? "分析阶段：正在读取历史鸟种记录（共 \(targets.count) 张）…"
            : "分析阶段：正在批量识别鸟种（共 \(targets.count) 张）…"
        if logOnly {
            restoreBirdLogs(for: targets, completion: completion)
            return
        }
        birdBatchPending = Array(targets.reversed())
        birdBatchTotal = targets.count
        birdBatchCompletion = completion
        pumpBirdBatch()
    }

    private func restoreBirdLogs(for targets: [URL], completion: @escaping () -> Void) {
        let generation = birdBatchGeneration
        let folder = currentFolder
        birdBatchQueue.async {
            var byDirectory: [URL: URL] = [:]
            var indices: [URL: [String: [BirdRecord]]] = [:]
            var records: [URL: BirdRecord] = [:]
            var unreliable = Set<URL>()
            for url in targets {
                let base = folder ?? url.deletingLastPathComponent()
                let root = byDirectory[base] ?? Self.birdLogRoot(from: base)
                byDirectory[base] = root
                if indices[root] == nil {
                    indices[root] = Dictionary(grouping: BirdLog.load(in: root), by: { $0.file })
                }
                let name = url.lastPathComponent
                guard let rows = indices[root]?[name] else { continue }
                if let record = BirdLog.latest(in: rows, for: name,
                                               minLocalConfidence: BirdSpeciesEngine.localAcceptThreshold,
                                               agreementConfidence: BirdSpeciesEngine.localAgreementThreshold,
                                               agreementReason: BirdSpeciesEngine.agreementReasonToken) {
                    records[url] = record
                } else {
                    unreliable.insert(url)
                }
            }
            let restored = records
            let ignored = unreliable
            func applyBatch(start: Int) {
                guard self.birdBatchGeneration == generation else { return }
                let end = min(start + 32, targets.count)
                for url in targets[start..<end] {
                    if let record = restored[url] { self.applyBirdRecord(record, to: url, writeLabel: false) }
                    else if ignored.contains(url) {
                        self.birdUnreliable.insert(url)
                        self.birdMessage[url] = "历史本地识别把握不足，已忽略结果"
                    }
                }
                self.done = end
                if end == targets.count { completion() }
                else { DispatchQueue.main.async { applyBatch(start: end) } }
            }
            DispatchQueue.main.async { applyBatch(start: 0) }
        }
    }

    /// 批量泵：只在主线程调用。一次只启动一张，且**启动前**不做任何 @Published 写入，
    /// 这样用户点开的照片能立即走 userInitiated 队列识别，不必排在串行队尾。
    private func pumpBirdBatch() {
        guard !birdBatchActive else { return }
        while !birdBatchPending.isEmpty {
            let url = birdBatchPending.removeLast()
            // 排队期间可能已被用户识别/人工确认/清除/判为不可靠：跳过即可。
            if birdCache[url] != nil || birdLoading.contains(url)
                || birdDismissed.contains(url) || birdUnreliable.contains(url) {
                noteBirdBatchSettled()
                continue
            }
            birdBatchActive = true
            let gen = birdBatchGeneration
            ensureBird(for: url, on: birdBatchQueue) { [weak self] in
                guard let self else { return }
                guard self.birdBatchGeneration == gen else {
                    // 新批的 active 状态由新批维护。
                    return
                }
                self.birdBatchActive = false
                self.noteBirdBatchSettled()
                DispatchQueue.main.async {
                    guard self.birdBatchGeneration == gen else { return }
                    self.pumpBirdBatch()
                }
            }
            return
        }
        let done = birdBatchCompletion
        birdBatchCompletion = nil
        done?()
    }

    private func noteBirdBatchSettled() {
        birdBatchSettled += 1
        done = birdBatchSettled   // 进度条读它，必须随鸟种批量推进（不能停在信息阶段的旧值）
        if birdBatchSettled % 10 == 0 || birdBatchSettled >= birdBatchTotal {
            status = "分析阶段：正在批量识别鸟种（\(birdBatchSettled)/\(birdBatchTotal)）…"
        }
    }

    /// 历史恢复路径的中间层预览增量补：磁盘缓存已存在的跳过（0 成本），
    /// 缺失的后台低优先级生成，不阻塞界面。
    private func backfillMidPreviews(files: [URL]) {
        let generation = fullPreviewGeneration
        DispatchQueue.global(qos: .utility).async {
            for url in files where MidPreviewCache.generateIfNeeded(for: url) {
                DispatchQueue.main.async {
                    guard self.fullPreviewGeneration == generation, self.containsResult(url) else { return }
                    self.midPreviewFailed.remove(url)
                    self.midPreviewLoading[url] = nil
                    if self.fullPreviewURL == url, self.fullPreviewCache[url] == nil {
                        self.requestMidPreview(for: url)
                    }
                }
            }
        }
    }

    /// 导入/历史恢复完成后的空闲时机：低优先级预解当前选中 ±2 的原尺寸
    /// （用户总是从第一张开始看，翻过去时命中 LRU 直接显示清晰原图）、
    /// ±3 的中间层。scheduleNeighborPrefetch 已覆盖浏览中的 ±1。
    private func scheduleIdleFullPreviewWarmup() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, !self.processing, let cur = self.selected else { return }
            let items = self.shown
            guard let i = shownIndex(of: cur) else { return }
            for j in max(0, i - 2)...min(items.count - 1, i + 2) {
                self.preloadFullPreview(for: items[j].id)
            }
            for j in max(0, i - 3)...min(items.count - 1, i + 3) {
                self.preloadMidPreview(for: items[j].id)
            }
        }
    }

    /// 切图时预取相邻照片的信息区数据（selected.didSet 调用，方向键与鼠标点选都覆盖）。
    ///
    /// 第三次复盘发现的两个真实瓶颈：
    /// 1) 旧实现每次切图都给 ±1 各排 8 个重任务，连翻时旧任务不取消、串行队列持续堆积，
    ///    当前图的解码和信息加载被迫跟几十个已失效的任务抢 CPU；
    /// 2) 旧版鸟种预取固定延时 0.6s 且要求 selected 仍是锚点，连翻时几乎必然被跳过。
    /// 现在：±1 全字段、±2 只补轻字段；世代/当前图/近端集合同步写进 NSLock 保护的
    /// gate，后台只读快照复查（当前图无条件放行），不碰 Store 主线程状态；
    /// 鸟种不在这里触发——它属于分析阶段，筛选阶段只读做好的结果。
    func scheduleNeighborPrefetch() {
        guard let anchor = selected else { return }
        prefetchEpoch &+= 1
        let epoch = prefetchEpoch
        // 关键：current 必须在 selected.didSet 触发后立刻同步写入 gate，不能拖到
        // main.async——A→B 时旧任务出队判定 gate.current 必须已经是 B（QA Bug#1）。
        // 放在 processing 判断之前，分析期间切图也不会留下过期 current。
        prefetchGate.update(epoch: epoch, current: anchor, near: [])
        guard !processing else { return }
        // 放到下一个 runloop，避免在 didSet（SwiftUI 更新过程中）做列表查找。
        DispatchQueue.main.async { [weak self] in
            guard let self, self.prefetchEpoch == epoch, self.selected == anchor else { return }
            let items = self.shown
            guard let idx = shownIndex(of: anchor) else { return }
            var near: [URL] = []
            var farther: [URL] = []
            if idx + 1 < items.count { near.append(items[idx + 1].id) }
            if idx > 0 { near.append(items[idx - 1].id) }
            if idx + 2 < items.count { farther.append(items[idx + 2].id) }
            if idx > 1 { farther.append(items[idx - 2].id) }
            // 近端集合一次性算全（±1 全字段 + ±2 轻字段），后台只比对这个不可变副本。
            self.prefetchGate.update(epoch: epoch, current: anchor,
                                     near: Set(near).union(farther))

            func guardFor(_ url: URL) -> () -> Bool {
                { [weak self] in self?.prefetchGate.allows(url, for: epoch) ?? false }
            }

            for url in near {
                guard let r = self.result(for: url) else { continue }
                let ok = guardFor(url)
                // 先读盘回填相邻两张的中间层（毫秒级）：点选时立即有本张的清晰
                // 预览；原尺寸解码慢，排在后面，完成后无缝替换。
                self.preloadMidPreview(for: url)
                self.preloadFullPreview(for: url)
                self.ensureExif(for: url, on: self.prefetchQueue, relevant: ok)
                self.ensureAF(for: url, on: self.prefetchQueue, relevant: ok)
                self.ensureWB(for: url, on: self.prefetchQueue, relevant: ok)
                self.ensureRating(for: url, on: self.prefetchQueue, relevant: ok)
                self.ensureFocus(for: url, subjectBoxes: r.metrics.bboxes,
                                 on: self.prefetchHeavyQueue, relevant: ok)
                self.ensureHuman(for: url, on: self.prefetchHeavyQueue, relevant: ok)
                self.ensureAI(for: url, on: self.prefetchHeavyQueue, relevant: ok)
            }
            // ±2 只补轻字段：提高连翻命中率，又不把 Vision / Core ML 任务排成长队。
            // 中间层预览也顺带预取（读盘+解码便宜），回看更快。
            for url in farther {
                let ok = guardFor(url)
                self.preloadMidPreview(for: url)
                self.ensureExif(for: url, on: self.prefetchQueue, relevant: ok)
                self.ensureAF(for: url, on: self.prefetchQueue, relevant: ok)
                self.ensureWB(for: url, on: self.prefetchQueue, relevant: ok)
                self.ensureRating(for: url, on: self.prefetchQueue, relevant: ok)
            }
            // 鸟种不在此补触发：分析阶段已整批完成，切图只读缓存不现算。
        }
    }

    /// 设置星级：0~5 星，-1 为 Bridge 的「拒绝」。
    /// 快捷键与列表立即显示待写评级；筛选与会话使用已成功落盘的评级。
    func setRating(_ url: URL, rating: Int) {
        let revision = navigationRevision
        let generation = infoPhaseGeneration
        ratingRevision &+= 1
        let request = ratingRevision
        ratingRequests[url] = request
        pendingRatings[url] = nil
        requestedRatings[url] = rating
        let dir = url.deletingLastPathComponent()
        let name = url.deletingPathExtension().lastPathComponent
        // 0 = 未评分：既是取消星级，也是取消拒绝（-1）。文案别写成「0 星」误导。
        let label = rating == -1 ? "拒绝" : rating == 0 ? "取消评级（星级/拒绝）" : "\(rating) 星"
        status = "已设 \(name) 为\(label)，正在写入元数据…"
        ratingWriteQueue.async {
            let outcome = Result { try MetadataWriter.setRating(to: url, rating: rating, backupDir: dir) }
            DispatchQueue.main.async {
                guard self.infoPhaseGeneration == generation, self.containsResult(url) else { return }
                let latest = self.ratingRequests[url] == request
                let active = latest && self.navigationRevision == revision && self.selected == url
                let index = self.shownIndex(of: url)
                if latest {
                    self.requestedRatings[url] = nil
                    self.ratingRequests[url] = nil
                }
                switch outcome {
                case .success:
                    if self.selected == url {
                        self.heldRatingURL = self.ratingFilter != nil && self.ratingFilter != rating ? url : nil
                    }
                    self.ratingCache[url] = rating
                    if !self.backupDirs.contains(dir.path) { self.backupDirs.append(dir.path) }
                    if latest { self.status = "已设 \(name) 为\(label)，并写入元数据" }
                    if active, self.advanceAfterRating, let index {
                        let leaves = self.ratingFilter.map { $0 != rating } ?? false
                        self.heldRatingURL = nil
                        self.shownCache = nil
                        let items = self.shown
                        let next = items.isEmpty ? nil : items[min(index + (leaves ? 0 : 1), items.count - 1)].id
                        self.selections = Set(next.map { [$0] } ?? [])
                        self.selected = next
                    }
                    self.saveSession()
                case .failure(let error):
                    if latest { self.status = "评分写入失败：\(error.localizedDescription)" }
                }
            }
        }
    }

    // MARK: - 综合评分

    /// 当前题材：用户改过用覆盖值，否则自动识别（先查纠正记忆，再走规则）。
    /// 返回 (题材, 是否自动, 识别依据)。
    func genre(for r: PhotoResult) -> (PhotoGenre, Bool, String) {
        if let g = genreOverride[r.id] { return (g, false, "手动指定") }
        let (g, why) = ScoreEngine.guessGenre(m: r.metrics, af: afCache[r.id],
                                              wb: wbCache[r.id], exif: exifCache[r.id],
                                              focus: focusCache[r.id], human: humanCache[r.id],
                                              ai: aiCache[r.id].flatMap { $0 })
        // 纠正记忆：算法只在「没有任何强信号、纯兜底判风光」时才让位给记忆。
        // 权衡原则：算法明确认出东西（人脸/鸟/焦距/对焦点语义）时，那是可复核的证据，
        // 不能被几条同标签的纠正推翻——真值复盘里一次纠正曾污染 44 张本该自动判的照片。
        // 而且只在同一机器误判模式下套用（见 GenreMemory.suggest）。
        if let focusLabels = focusCache[r.id]?.labels, !focusLabels.isEmpty,
           why.contains("无长焦/人脸的强信号") {
            let names = focusLabels.map { GenreMemory.parseLabel($0) }
            let query = (top: names.first ?? "", labels: names,
                         machineGenre: g.rawValue)
            if let sug = GenreMemory.suggest(query: query, samples: memory),
               let genre = PhotoGenre(rawValue: sug.genre), genre != g {
                return (genre, true,
                        "算法没找到明确信号，参考了你以往 \(sug.count) 次同特征纠正（判\(sug.genre)）")
            }
        }
        return (g, true, why)
    }

    /// 立即算一张照片的综合评分。af/wb/exif 若尚未读到，用它当时已有的数据算，
    /// 读到后 InfoView 会随 @Published 变化自动重算，无需缓存。
    /// 用户圈选过主体时，把圈选区清晰度传进去——主体清晰度按圈选算，否则圈选后不变化。
    func score(for r: PhotoResult) -> PhotoScore {
        let (g, guess, why) = genre(for: r)
        return ScoreEngine.score(r, af: afCache[r.id], wb: wbCache[r.id],
                                 exif: exifCache[r.id], genre: g,
                                 genreIsGuess: guess, genreReason: why,
                                 manualSubjectRatio: selectionRects[r.id].map { Analyzer.rectDisplayRatio(r.metrics, rect: $0) },
                                 focus: focusCache[r.id])
    }

    func setGenre(_ g: PhotoGenre?, for url: URL) {
        if let g = g {
            genreOverride[url] = g
            recordGenreCorrection(for: url, userGenre: g)
        } else {
            genreOverride.removeValue(forKey: url)
        }
        saveSession()   // 手动改题材也要落盘，下次恢复会话时保留
        // 手动改成鸟类：分析阶段按旧题材没跑过这张，属于用户主动更新，补一次单张
        // 识别（人工确认/dismissed 由 ensureBird 内部保护）。切图/筛选阶段不自动触发。
        if g == .bird { ensureBird(for: url, forceLocal: true, ignoreGenre: true) }
    }

    /// 题目在扫描前就问；这里只暂存答案，真正应用等新一批 results 填好后做。
    func applyFolderGenre(_ choice: FolderGenreChoice) {
        pendingGenreChoice = choice
        pendingGenreResolved = true
        startPendingScan()
    }

    /// 用户点「暂不设置」：不改题材，但照常开始扫描。
    func closeGenrePrompt() {
        pendingGenreChoice = nil
        pendingGenreResolved = true
        startPendingScan()
    }

    /// 新一批结果落地后套用导入前选的题材，再统一落盘。
    /// 这样弹窗在读取历史数据之前出现，也不会把选择错应用到上一批照片。
    private func applyPendingGenre() {
        guard let job = pendingScan else { return }
        if let choice = pendingGenreChoice {
            folderGenreChoice = choice   // 记下来，写进 log，下次导入同文件夹不再弹窗
            let prefix = job.folder.standardizedFileURL.path + "/"
            let inFolder = results.filter { $0.id.standardizedFileURL.path.hasPrefix(prefix) }
            let name = Self.folderName(from: job.folder)
            if let g = choice.genre {
                for r in inFolder { genreOverride[r.id] = g }
                status += "；已把「\(name)」的 \(inFolder.count) 张设为\(g.display)"
            } else {
                for r in inFolder { genreOverride[r.id] = nil }
                status += "；「\(name)」已恢复逐张识别题材"
            }
        }
        pendingScan = nil
        pendingGenreChoice = nil
        pendingGenreResolved = false
    }

    /// 记住一次题材纠正：机器判错的瞬间是最宝贵的监督信号。
    /// 记录对焦点标签签名 + 焦距/镜头/主体来源，特征相似的照片以后按此优先。
    private func recordGenreCorrection(for url: URL, userGenre: PhotoGenre) {
        guard let r = result(for: url) else { return }
        let machine = ScoreEngine.guessGenre(m: r.metrics, af: afCache[url],
                                             wb: wbCache[url], exif: exifCache[url],
                                             focus: focusCache[url],
                                             human: humanCache[url]).0
        // 与机器一致不算纠正（没有新信息），避免重复记录撑爆记忆。
        guard machine != userGenre else { return }
        let exif = exifCache[url]
        let labels = (focusCache[url]?.labels ?? []).map { GenreMemory.parseLabel($0) }
        let sample = GenreCorrectionSample(
            labels: Array(labels.prefix(8)),
            topLabel: labels.first ?? "",
            focal: exif.flatMap { $0.focalLength.map { GenreMemory.maxNumber(in: $0) } } ?? 0,
            lensMax: exif.flatMap { $0.lens.map { GenreMemory.maxNumber(in: $0) } } ?? 0,
            subjectSource: r.metrics.subjectSource,
            machineGenre: machine.rawValue,
            userGenre: userGenre.rawValue,
            date: Date())
        GenreMemory.append(sample)
        memory = GenreMemory.load()
        status = "已记住这次题材纠正（共 \(memory.count) 条），特征相似的照片会参考你的判断"
    }

    /// 清空纠正记忆：识别回到纯自动规则。
    func clearGenreMemory() {
        GenreMemory.clear()
        memory = []
        status = "已清空题材纠正记忆"
    }

    /// 切到新照片时请求原尺寸预览。显示链为双层（v1.0 结构回归）：
    /// 1) 原尺寸 LRU 命中 → 同步显示原尺寸，零延迟；
    /// 2) 中间层内存命中 → 立即显示**本张**的中间层（屏幕自适应分辨率，Retina 下
    ///    铺满预览区仍然锐利），同时后台解码原尺寸，完成后无缝替换；
    /// 3) 都未命中 → 后台读中间层磁盘缓存（读盘+解码很快），读回即显示；
    ///    原尺寸解码并行在途，谁先回来谁先顶上（同一张照片，不存在串图）。
    /// 「暂显上一张」机制已移除：中间层显示的就是这张照片，体验更好。
    /// token + generation 双保险防串图：快速连点 A→B→C 时，中间层与原尺寸的
    /// 替换都只落在 fullPreviewURL 当前指向的目标上。
    func ensureFullPreview(for url: URL) {
        // 目标已就位（中间层或原尺寸），或原尺寸正在解码（此时 fullPreview 是这张
        // 的中间层）——不动，等解码完成/失败分支收尾。
        // 解码失败的图不早返回：保留这条路径让 requestFullPreview 有机会重试。
        if fullPreviewURL == url, fullPreview != nil, !previewFailed.contains(url) {
            return
        }
        // 只取消尚未开工的旧任务。已开始的结果仍可用于回看。
        for (other, job) in Array(fullPreviewJobs) where other != url && other != reference?.url && job.claim() {
            fullPreviewJobs[other] = nil
        }
        fullPreviewURL = url
        if let cached = fullPreviewCache[url] {
            touchFullPreview(url)
            replaceFullPreview(cached)
            return
        }
        if let mid = midPreviewCache[url] {
            touchMidPreview(url)
            replaceFullPreview(mid)
            requestFullPreview(for: url, prefetch: false)
            return
        }
        // 中间层与原尺寸并行在途；期间显示占位（首次进入/缓存全缺失时很短）。
        replaceFullPreview(nil)
        requestMidPreview(for: url)
        requestFullPreview(for: url, prefetch: false)
    }

    /// 预取相邻照片的原尺寸预览：方向键连翻时基本都能命中缓存，切图零延迟。
    /// 与当前图分队列，避免预取抢正在显示那张的解码资源。
    func preloadFullPreview(for url: URL) {
        guard fullPreviewCache[url] == nil else { return }
        requestFullPreview(for: url, prefetch: true)
    }

    /// 预取相邻照片的中间层（读盘+解码很便宜）：±2 提前回填，回看更快。
    func preloadMidPreview(for url: URL) {
        guard midPreviewCache[url] == nil else { return }
        requestMidPreview(for: url)
    }

    /// 左侧目录可见行的中间层预热（2026-11-25）：把列表里正显示的那批照片
    /// 的中间层 JPEG 读进内存 LRU，鼠标点选其中任意一张都能立即命中本张图，
    /// 无需等原尺寸从 CR3 解码。走独立的 utility 队列，不占用当前图的解码队列。
    func preloadVisibleMidPreviews(_ urls: [URL]) {
        for url in urls {
            guard midPreviewCache[url] == nil, midPreviewLoading[url] == nil,
                  !midPreviewFailed.contains(url) else { continue }
            requestMidPreview(for: url, prefetch: true)
        }
    }

    /// 当前图是否还在解码原图（DetailView 用它决定占位提示，避免空白无反馈）。
    func isPreviewLoading(for url: URL) -> Bool {
        fullPreviewURL == url && fullPreviewJobs[url] != nil
    }

    /// 当前图的原图是否解码失败（DetailView 用它显示失败提示，不再留下无解释的空白）。
    func isPreviewFailed(for url: URL) -> Bool {
        fullPreviewURL == url && previewFailed.contains(url)
    }

    /// 画面叠加框（AI 主体蓝框 / 相机对焦点 / 人工圈选黄框 / 热力图）是否就绪。
    /// 2026-11-25 修复「快速切图时框先虚晃一下」：
    /// SwiftUI 在 selected 变化后先用新 r 算一遍 body，而 .onChange 里才把
    /// fullPreview 换成新图；那一帧会把新照片的框画在旧照片上。这里要求
    /// 主预览确实属于本张才画框——切图瞬间整组隐藏，图像与框同帧出现，
    /// 既不串图也不会有空框浮在加载占位上。数据未就绪时宁可不画。
    func overlaysReady(for url: URL) -> Bool {
        fullPreviewURL == url && fullPreview != nil
    }

    /// 后台解码原尺寸预览并写入 LRU。同一 URL 只跑一次（onAppear / onChange
    /// 可能都触发 ensureFullPreview，旧版会重复解码两次 RAW）。
    private func requestFullPreview(for url: URL, prefetch: Bool) {
        guard fullPreviewCache[url] == nil else { return }
        let job: FullPreviewJob
        if let pending = fullPreviewJobs[url] {
            guard !prefetch else { return }
            // 当前图与预取争抢同一个开工资格，任一队列先到就复用其结果。
            job = pending
        } else {
            job = FullPreviewJob()
            fullPreviewJobs[url] = job
            previewFailed.remove(url)
            invalidatedPreviewURLs.remove(url)
        }
        let generation = fullPreviewGeneration
        let queue = prefetch ? fullPreviewPrefetchQueue : fullPreviewQueue
        queue.async {
            guard job.claim() else { return }
            let img = autoreleasepool { Analyzer.loadFullPreview(url) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.fullPreviewGeneration == generation,
                      self.fullPreviewJobs[url] === job else { return }
                self.fullPreviewJobs[url] = nil
                guard !self.invalidatedPreviewURLs.contains(url) else { return }
                guard let img else {
                    self.previewFailed.insert(url)
                    // 当前图解码失败：若中间层在显则 DetailView 退化为小字说明；
                    // 否则显示明确的失败提示，避免"提示消失后留下无解释的空白"。
                    if self.fullPreviewURL == url {
                        self.objectWillChange.send()
                    }
                    return
                }
                self.previewFailed.remove(url)
                self.cacheFullPreview(img, for: url)
                if self.reference?.url == url { self.reference = (url, img) }
                if self.fullPreviewURL == url {
                    self.replaceFullPreview(img)
                }
            }
        }
    }

    /// 后台读中间层磁盘缓存并解码，写入内存 LRU；当前目标尚未显示原尺寸时
    /// 先把中间层顶上（与 requestFullPreview 并行在途，谁先回来谁先显示——
    /// 都是同一张照片的图，配合 fullPreviewURL 检查不串图）。
    private func requestMidPreview(for url: URL, prefetch: Bool = false) {
        guard midPreviewCache[url] == nil, midPreviewLoading[url] == nil,
              !midPreviewFailed.contains(url) else { return }
        midPreviewRequestID &+= 1
        let requestID = midPreviewRequestID
        midPreviewLoading[url] = requestID
        // 与 requestFullPreview 同一语义（QA 边缘项 1）：撤销删除后重新发出的
        // 中间层请求要清掉上次删除留下的失效标记，否则读回会被误作废并
        // 置 midPreviewFailed（本会话该张中间层不再显示）。删除前已发出的
        // 在途请求不受影响——deletePhotos 在请求之后重新插入标记，完成回调
        // 的 guard 照常丢弃，"删除时不该回写"的语义保持不变。
        invalidatedPreviewURLs.remove(url)
        let generation = fullPreviewGeneration
        let queue = prefetch ? midPreviewPrefetchQueue : midPreviewQueue
        queue.async { [weak self] in
            let img = MidPreviewCache.load(for: url)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard self.fullPreviewGeneration == generation,
                      self.midPreviewLoading[url] == requestID else { return }
                self.midPreviewLoading[url] = nil
                // 删除照片：只丢弃这张被删图的在途结果，不误伤其他照片。
                guard !self.invalidatedPreviewURLs.contains(url) else { return }
                guard let img else {
                    self.midPreviewFailed.insert(url)
                    if self.fullPreviewURL == url { self.objectWillChange.send() }
                    return
                }
                self.midPreviewFailed.remove(url)
                self.cacheMidPreview(img, for: url)
                // 中间层只顶到「原尺寸还没落地」的目标上；原尺寸已就位则不覆盖
                // （requestFullPreview 的完成分支负责显示）。
                if self.fullPreviewURL == url, self.fullPreviewCache[url] == nil {
                    self.replaceFullPreview(img)
                }
            }
        }
    }

    private func touchMidPreview(_ url: URL) {
        if let i = midPreviewOrder.firstIndex(of: url) { midPreviewOrder.remove(at: i) }
        midPreviewOrder.append(url)
    }

    private func cacheMidPreview(_ img: CGImage, for url: URL) {
        midPreviewCache[url] = img
        touchMidPreview(url)
        // 容量 36：正在显示的那张（fullPreviewURL）绝不能被驱逐。
        while midPreviewOrder.count > midPreviewMax,
              let victim = midPreviewOrder.first(where: { $0 != fullPreviewURL }) {
            midPreviewOrder.removeAll { $0 == victim }
            midPreviewCache[victim] = nil
        }
    }

    private func touchFullPreview(_ url: URL) {
        if let i = fullPreviewOrder.firstIndex(of: url) { fullPreviewOrder.remove(at: i) }
        fullPreviewOrder.append(url)
    }

    private func cacheFullPreview(_ img: CGImage, for url: URL) {
        fullPreviewCache[url] = img
        touchFullPreview(url)
        // 最多留 3 张（上一张/当前/下一张）；正在显示的那张绝不能被驱逐。
        while fullPreviewOrder.count > fullPreviewMax,
              let victimIndex = fullPreviewOrder.firstIndex(where: { $0 != fullPreviewURL }) {
            let victim = fullPreviewOrder.remove(at: victimIndex)
            fullPreviewCache[victim] = nil
            baseCache[victim] = nil
        }
    }

    /// 换序列 / 删除照片后清空原图预览缓存，防止旧图被当作新会话的结果显示。
    /// 中间层一起失效（generation 共用，在途的中间层读回也会被丢弃）。
    private func resetFullPreviewCache() {
        fullPreviewGeneration &+= 1
        fullPreviewCache = [:]
        fullPreviewOrder = []
        for job in fullPreviewJobs.values { _ = job.claim() }
        fullPreviewJobs = [:]
        previewFailed = []
        invalidatedPreviewURLs.removeAll()
        fullPreviewURL = nil
        midPreviewCache = [:]
        midPreviewOrder = []
        midPreviewLoading = [:]
        midPreviewFailed = []
        replaceFullPreview(nil)
    }

    func resetZoom() {
        zoom = 1
        zoomCenter = CGPoint(x: 0.5, y: 0.5)
        panOffset = .zero
        panStart = nil
        dragAction = nil
        // 复位只针对放大/平移：人工圈选记录（黄框 + 评分参数）按照片保留。
    }

    func zoomIn() { zoom = min(8, zoom * 1.5) }
    func zoomOut() { zoom = max(1, zoom / 1.5) }

    func writeMetadata() {
        let targets = writableTargets
        guard !targets.isEmpty else { return }
        var ok = 0
        var failed: [String] = []
        var dirs = Set<String>()
        for r in targets {
            do {
                // 备份随照片放同目录（用户 2026-11-20 要求，不再写进软件目录）。
                let dir = r.id.deletingLastPathComponent()
                dirs.insert(dir.path)
                // 直接把判定词写入 xmp:Label（2026-11-20 用户拍板，不写英文颜色值）。
                // 照片已有颜色标签时不覆盖（mergedXMP 里保护）。
                _ = try MetadataWriter.apply(to: r.id, reason: r.reason,
                                             labelColor: addColorLabel ? r.verdict.bridgeLabel : nil,
                                             backupDir: dir)
                ok += 1
            } catch {
                failed.append("\(r.id.lastPathComponent)：\(error.localizedDescription)")
            }
        }
        backupDirs = Array(dirs).sorted()
        status = "已写入 \(ok) 张照片的 Bridge 元数据" +
                 (failed.isEmpty ? "" : "，\(failed.count) 张失败：\(failed.joined(separator: "；"))")
    }

    /// 一键清除本软件写入的标记（判定说明段、判定词标签）；用户原有元数据一律不动。
    func cleanupMetadata() {
        let targets = writableTargets
        guard !targets.isEmpty else { return }
        var ok = 0
        var clean = 0
        var failed: [String] = []
        for r in targets {
            do {
                let res = try MetadataWriter.cleanup(to: r.id, backupDir: r.id.deletingLastPathComponent())
                if res.removed { ok += 1 } else { clean += 1 }
            } catch {
                failed.append("\(r.id.lastPathComponent)：\(error.localizedDescription)")
            }
        }
        status = "已清除 \(ok) 张照片的本软件标记（\(clean) 张原本就没有）；"
                 + "用户原有说明/星级/关键词均未动。注意：开着「切换时自动写说明」的话，切照片会重新写入说明。"
                 + (failed.isEmpty ? "" : " \(failed.count) 张失败：\(failed.joined(separator: "；"))")
    }

    /// 与 RAW 同目录、同文件名（不同扩展名）的 JPG；存在才返回。
    func siblingJPG(for raw: URL) -> URL? {
        guard MetadataWriter.isRAW(raw) else { return nil }
        let base = raw.deletingPathExtension()
        for ext in MetadataWriter.jpgExts {
            let c = base.appendingPathExtension(ext)
            if FileManager.default.fileExists(atPath: c.path) { return c }
        }
        return nil
    }

    private var deletionInProgress = false

    /// 文件移到废纸篓成功后，才从当前会话移除对应的记录。
    func deletePhotos(_ urls: [URL], completion: @escaping (String) -> Void) {
        guard !deletionInProgress else { completion("正在处理上一次删除"); return }
        deletionInProgress = true
        let generation = infoPhaseGeneration
        var seen: Set<URL> = []
        let targets = urls.flatMap { url in [url] + (siblingJPG(for: url).map { [$0] } ?? []) }
            .filter { seen.insert($0).inserted }
        DispatchQueue.global(qos: .userInitiated).async {
            var moved: [URL] = []
            var failed: [String] = []
            var pairs: [(trash: URL, original: URL)] = []
            for url in targets {
                do {
                    var destination: NSURL?
                    try FileManager.default.trashItem(at: url, resultingItemURL: &destination)
                    moved.append(url)
                    if let destination { pairs.append((destination as URL, url)) }
                    MidPreviewCache.removeFiles(for: url)
                } catch {
                    failed.append("\(url.lastPathComponent)：\(error.localizedDescription)")
                }
            }
            DispatchQueue.main.async {
                self.deletionInProgress = false
                if self.infoPhaseGeneration == generation, !moved.isEmpty {
                    self.lastDeleted = pairs
                    self.deletedRecords = [:]
                    for pair in pairs {
                        let url = pair.original
                        guard let result = self.result(for: url) else { continue }
                        self.deletedRecords[url] = DeletedRecord(result: result, selection: self.selectionRects[url],
                            genre: self.genreOverride[url], excluded: self.excluded.contains(url),
                            info: PhotoInfoSnapshot(wb: self.wbCache[url], af: self.afCache[url],
                                exif: self.exifCache[url], focus: self.focusCache[url], human: self.humanCache[url],
                                ai: self.aiCache[url].flatMap { $0 }, rating: self.ratingCache[url]))
                    }
                    self.removeTrashedRecords(Set(moved))
                }
                var messages: [String] = []
                if !moved.isEmpty {
                    messages.append("已移到废纸篓：" + moved.map(\.lastPathComponent).joined(separator: "、"))
                }
                if !failed.isEmpty { messages.append("失败：" + failed.joined(separator: "；")) }
                completion(messages.joined(separator: "；"))
            }
        }
    }

    private func removeTrashedRecords(_ removed: Set<URL>) {
        if let reference, removed.contains(reference.url) { self.reference = nil; showingReference = false }
        let oldShown = shown
        let nextID = oldShown.lastIndex(where: { removed.contains($0.id) }).flatMap { index in
            oldShown.dropFirst(index + 1).first?.id
                ?? oldShown.prefix(index).last(where: { !removed.contains($0.id) })?.id
        }
        // 注意这里不能用 fullPreviewGeneration &+= 1 全局作废：
        // 同时预取的其他照片在途任务也会被丢弃，切过去时 loading 去重挡住重发、
        // 旧结果又被作废，界面会停在空白。改为在删除循环里按 URL 精确失效（见下）。

        // 主线程：一次性清内存，只触发一次 UI 刷新
        objectWillChange.send()
        results.removeAll { removed.contains($0.id) }
        metrics.removeAll { removed.contains($0.url) }
        for key in removed {
            requestedRatings[key] = nil
            ratingRequests[key] = nil
            wbCache[key] = nil; afCache[key] = nil; exifCache[key] = nil; ratingCache[key] = nil
            focusCache[key] = nil; humanCache[key] = nil; aiCache[key] = nil
            genreOverride[key] = nil
            afLoading.remove(key); afAttempted.remove(key)
            wbAttempted.remove(key); exifAttempted.remove(key); focusAttempted.remove(key)
            humanAttempted.remove(key); thumbAttempted.remove(key)
            pendingRatings[key] = nil; ratingLoading.remove(key)
            thumbnailCache[key] = nil; thumbLoading.remove(key)
            fullPreviewCache[key] = nil
            if let i = fullPreviewOrder.firstIndex(of: key) { fullPreviewOrder.remove(at: i) }
            _ = fullPreviewJobs.removeValue(forKey: key)?.claim()
            previewFailed.remove(key)
            // 中间层：内存缓存项同步清，磁盘文件在后台搬家循环里一并删除。
            midPreviewCache[key] = nil
            if let i = midPreviewOrder.firstIndex(of: key) { midPreviewOrder.remove(at: i) }
            midPreviewLoading[key] = nil
            midPreviewFailed.remove(key)
            // 只对被删 URL 失效：在途任务回写时精确丢弃，其他照片的预取照常落地。
            invalidatedPreviewURLs.insert(key)
            if fullPreviewURL == key {
                fullPreviewURL = nil
                replaceFullPreview(nil)
            }
            heatCache[key] = nil; baseCache[key] = nil
            selectionRects[key] = nil
            birdCache[key] = nil; birdTop3[key] = nil; birdSource[key] = nil
            birdReason[key] = nil; birdConfirm[key] = nil; birdMessage[key] = nil
            birdLoading.remove(key); birdTaskToken[key] = nil
            birdDismissed.remove(key); birdUnreliable.remove(key)
        }
        excluded = excluded.subtracting(removed)
        let remaining = selections.subtracting(removed)
        if !remaining.isEmpty {
            selections = remaining
        } else {
            let next = nextID ?? shown.first?.id
            selections = Set(next.map { [$0] } ?? [])
            selected = next
        }
        if results.isEmpty, let folder = currentFolder {
            sessionSaveQueue.async {
                self.sessionCacheLock.lock()
                if self.lastSessionSave?.folder == folder { self.lastSessionSave = nil }
                self.sessionCacheLock.unlock()
                SessionCache.remove(folder: folder)
            }
        } else {
            saveSession()
        }
    }

    /// 最近一次删除的记录（废纸篓位置 ↔ 原位置），⌘Z 撤销用。
    var lastDeleted: [(trash: URL, original: URL)] = []
    private struct DeletedRecord {
        let result: PhotoResult
        let selection: CGRect?
        let genre: PhotoGenre?
        let excluded: Bool
        let info: PhotoInfoSnapshot
    }
    private var deletedRecords: [URL: DeletedRecord] = [:]

    /// 从废纸篓原样搬回文件，并恢复删除前的筛片记录。
    func undoDelete() {
        guard !deletionInProgress else { status = "正在处理上一次删除"; return }
        let generation = infoPhaseGeneration
        let pairs = lastDeleted
        guard !pairs.isEmpty else {
            status = "没有可撤销的删除"
            return
        }
        lastDeleted = []
        let records = deletedRecords
        deletionInProgress = true
        DispatchQueue.global(qos: .userInitiated).async {
            var retry: [(trash: URL, original: URL)] = []
            var restored: [URL] = []
            var failed: String?
            for p in pairs {
                let dir = p.original.deletingLastPathComponent()
                if !FileManager.default.fileExists(atPath: dir.path) {
                    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                }
                do {
                    try FileManager.default.moveItem(at: p.trash, to: p.original)
                    restored.append(p.original)
                } catch {
                    retry.append(p)
                    failed = "\(p.original.lastPathComponent)：\(error.localizedDescription)"
                }
            }
            var information: [URL: PhotoInfoSnapshot] = [:]
            for url in restored {
                if let record = records[url] {
                    var info = record.info
                    info.rating = MetadataWriter.snapshot(url).rating ?? 0
                    information[url] = info
                    MidPreviewCache.generateIfNeeded(for: url)
                }
            }
            let restoredInfo = information
            DispatchQueue.main.async {
                self.deletionInProgress = false
                guard self.infoPhaseGeneration == generation else { return }
                self.lastDeleted = retry
                if restored.isEmpty {
                    self.status = "撤销删除失败\(failed.map { "：\($0)" } ?? "")"
                    return
                }
                let newResults = restored.compactMap { url -> PhotoResult? in
                    defer { self.deletedRecords[url] = nil }
                    guard let record = records[url], !self.containsResult(url) else { return nil }
                    self.selectionRects[url] = record.selection
                    self.genreOverride[url] = record.genre
                    if record.excluded { self.excluded.insert(url) }
                    return record.result
                }
                self.mergeAnalyzedInfo(restoredInfo)
                self.metrics.append(contentsOf: newResults.map { $0.metrics })
                self.results.append(contentsOf: newResults)
                self.status = "已撤销删除：\(restored.map { $0.lastPathComponent }.joined(separator: "、"))" +
                    (failed.map { "；失败：\($0)" } ?? "")
                if let first = newResults.first(where: { self.shownContains($0.id) }) {
                    self.selected = first.id
                    self.selections = [first.id]
                }
                self.saveSession()
            }
        }
    }

    // MARK: - 「说明」元数据写入（切照片时自动执行）

    /// 组一张照片的「说明」内容：鸟类类别（首位）→ 评星依据 → 清晰度判定。
    /// 什么数据都没有（还没分析完）返回 nil，不写。
    private func describeNote(for url: URL) -> String? {
        guard let r = result(for: url) else { return nil }
        let s = score(for: r)
        var seg: [String] = []
        if let g = birdCache[url] {
            seg.append("鸟种：\(g.chinese)（\(birdSource[url] ?? "未标注来源")）")
        } else if let bird = birdCategory(for: url) { seg.append("鸟类：\(bird)") }
        var scoreDesc = "建议 \(s.stars) 星（总分 \(Int(s.total))）"
        if let w = s.weakest, w.weight > 0 { scoreDesc += "，短板：\(w.name) \(Int(w.score)) 分" }
        seg.append("评星依据：\(scoreDesc)")
        seg.append("清晰判定：\(r.verdict.rawValue)——\(r.reason)")
        return seg.joined(separator: "；")
    }

    /// 鸟类类别：优先 AI 主体识别（分割+分类，更准），其次对焦点语义。
    /// 能认出鸟种给中文名；只认出「鸟」认不出种也如实说。
    /// 注意：雄雌差别（繁殖羽/羽色）系统分类器分不出来，不硬猜。
    private func birdCategory(for url: URL) -> String? {
        if let ai = aiCache[url], ai?.kind == .bird, let ai = ai {
            return FocusSemanticsEngine.speciesName(fromLabels: ai.labels)
                ?? "识别到鸟（具体鸟种认不出）"
        }
        if let f = focusCache[url], f.kind == .bird {
            return FocusSemanticsEngine.speciesName(fromLabels: f.labels)
                ?? "识别到鸟（具体鸟种认不出）"
        }
        return nil
    }

    /// 导入/读取完成后的批量写说明：主线程取齐内容，后台顺序写盘。
    /// 选片切照片不再触发任何 XMP 写入；已有说明的照片跳过（保留旧的鸟种段与用户内容，
    /// 也避免导入时鸟种尚未识别就把带鸟种的旧说明覆盖成空鸟种版）。
    func writeAllDescriptions() {
        guard autoWriteDescription else { return }
        // 阶段一（主线程）：只算内容，不碰磁盘。describeNote 只读主线程状态。
        var notes: [(URL, String)] = []
        for r in writableTargets {
            guard let note = describeNote(for: r.id) else { continue }
            notes.append((r.id, note))
        }
        guard !notes.isEmpty else { return }
        // 阶段二（后台）：读现有说明决定跳过，再写盘；全程不碰主线程状态。
        DispatchQueue.global(qos: .utility).async {
            var written = 0, failed = 0
            for (url, note) in notes {
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                // 已有说明（含用户自己的或上一版带鸟种的）不动。
                do {
                    if try MetadataWriter.setDescriptionIfEmpty(
                        to: url, note: note, backupDir: url.deletingLastPathComponent()) {
                        written += 1
                    }
                } catch {
                    failed += 1
                }
            }
            DispatchQueue.main.async {
                self.status = "已写入 \(written) 张照片的说明" +
                    (failed == 0 ? "" : "（\(failed) 张写入失败）")
            }
        }
    }

    // MARK: - 鸟种识别：BioCLIP 2 本地 → 人工确认（纯离线）

    private func resetBirdState() {
        // 2026-11-23：模型不再随文件夹切换卸载。首次载入 580MB 要 5～6 秒，
        // 每次换文件夹都丢掉会让每张新素材又卡一次；改为常驻到 App 退出。
        birdCache = [:]
        birdTop3 = [:]
        birdSource = [:]
        birdReason = [:]
        birdConfirm = [:]
        birdDismissed = []
        birdUnreliable = []
        birdMessage = [:]
        birdLoading = []
        birdTaskToken = [:]
        // 换文件夹/重新导入：作废旧批次排队，避免拿新 results 里的 URL 跑老任务。
        birdBatchPending = []
        birdBatchActive = false
        birdBatchTotal = 0
        birdBatchSettled = 0
        birdBatchCompletion = nil
        birdBatchGeneration &+= 1
    }

    /// 日志与 XMP 标签都随照片走。若用户导入的是子文件夹（如 .../拍鸟/好片），
    /// 日志实际在上级根目录 .../拍鸟，这里向上找几层，避免"明明有 log 却没读到"。
    private func birdRoot(for url: URL) -> URL {
        Self.birdLogRoot(from: currentFolder ?? url.deletingLastPathComponent())
    }

    private static func birdLogRoot(from folder: URL) -> URL {
        let base = folder.standardizedFileURL
        var cur = base
        for _ in 0..<4 {
            if FileManager.default.fileExists(atPath: BirdLog.url(in: cur).path) { return cur }
            if cur.pathComponents.count <= 2 { break }
            cur = cur.deletingLastPathComponent().standardizedFileURL
        }
        return base
    }

    /// 读取（并按修改时间缓存）某个根目录的鸟种日志行。
    private func birdRows(in root: URL) -> [BirdRecord] {
        let stamp = BirdLog.stamp(in: root)
        if let hit = birdLogMemory[root], hit.stamp == stamp { return hit.rows }
        let rows = BirdLog.load(in: root)
        birdLogMemory[root] = (stamp, rows)
        return rows
    }

    /// 自动兜底的星级口径：Bridge 人工星级与建议星级取高者。
    private func birdStars(for url: URL) -> Int {
        var n = ratingCache[url] ?? 0
        if let r = result(for: url) { n = max(n, score(for: r).stars) }
        return n
    }

    private func birdImage(for url: URL) -> CGImage? {
        guard let r = result(for: url) else { return nil }
        return baseImage(for: r).cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    /// 识别裁剪框：用户手动圈选优先（左下原点归一化），否则退回最大自动主体框。
    /// 2026-11-23 用户要求：圈选主体后自动识别也要跟着刷新，用他画的框去认。
    private func birdCrop(for url: URL) -> CGRect? {
        if let manual = selectionRects[url], manual.width > 0, manual.height > 0 {
            return BirdSpeciesEngine.paddedCrop(manual)
        }
        guard let r = result(for: url),
              let box = r.metrics.bboxes.max(by: { $0.width * $0.height < $1.width * $1.height })
        else { return nil }
        return BirdSpeciesEngine.paddedCrop(box)
    }

    private func birdTop3Text(_ list: [BirdSpeciesGuess]) -> String {
        list.map { "\($0.chinese) \(Int($0.confidence * 100))%" }.joined(separator: " > ")
    }

    /// 后台预热本地模型：软件启动后立即低优先级加载，用户点照片时通常已经就绪。
    /// 放在后台队列，不阻塞界面和照片分析；与按需加载由模型内部锁串行化。
    func prewarmBirdModel() {
        // 2026-11-25 修复：旧版在这行读 isLoaded 会抢模型加载锁，主线程最长被卡
        // 5～6 秒（580MB Core ML 加载期间），表现为"用一会儿 App 未响应"。
        // 现在 isLoaded/isLoading 只读细粒度状态锁，主线程零等待。
        guard BirdSpeciesEngine.available, !BirdSpeciesEngine.isLoaded,
              !BirdSpeciesEngine.isLoading, !birdModelWarming else { return }
        birdModelWarming = true
        DispatchQueue.global(qos: .utility).async {
            let ok = BirdSpeciesEngine.loadIfNeeded()
            DispatchQueue.main.async {
                self.birdModelWarming = false
                if !ok { self.status = "本地鸟种模型加载失败，请检查安装包内的模型文件" }
            }
        }
    }

    /// 鸟种识别的一次性 settle 器：所有成功/失败/换代/超时路径共用，
    /// 保证批量识别的 onSettled 恰好回调一次（旧版 token 失配的早返回漏调，
    /// 导致批量进度永远凑不齐、该张 birdLoading 永不清除 → 永久转圈）。
    private final class BirdSettleBox {
        private var action: (() -> Void)?
        init(_ action: (() -> Void)?) { self.action = action }
        func call() {
            guard let a = action else { return }
            action = nil
            a()
        }
    }

    /// 拍鸟题材照片被点开时自动显示识别结果；风光 / 人像不识别、不显示。
    /// 先读可见日志（人工确认优先），否则跑本地 BioCLIP 2。
    /// forceLocal=true 用于圈选主体后刷新：跳过日志旧结果，强制按新裁剪框重认。
    /// onSettled：这张「识别有了结果」（含日志命中/把握不足/失败）时回主线程回调，
    /// 供导入后的鸟种批量统计进度；单张按需调用不传。
    func ensureBird(for url: URL, forceLocal: Bool = false,
                    ignoreGenre: Bool = false,
                    on queue: DispatchQueue = .global(qos: .userInitiated),
                    onSettled: (() -> Void)? = nil) {
        // 所有出口（含 guard 早返回、换代失效、原图读失败、超时）都经过 settle，
        // 批量进度不会漏计；同一张的多次调用互不干扰。
        let settle = BirdSettleBox(onSettled)
        guard !birdDismissed.contains(url), !birdUnreliable.contains(url) else { settle.call(); return }
        guard let r = result(for: url),
              ignoreGenre || genre(for: r).0 == .bird else {
            settle.call()
            return
        }
        guard BirdSpeciesEngine.available else {
            birdMessage[url] = "鸟种模型未随软件分发"
            settle.call()
            return
        }
        guard birdCache[url] == nil, !birdLoading.contains(url) else { settle.call(); return }

        if !forceLocal {
            let rows = birdRows(in: birdRoot(for: url))
            if let rec = BirdLog.latest(in: rows, for: url.lastPathComponent,
                                        minLocalConfidence: BirdSpeciesEngine.localAcceptThreshold,
                                        agreementConfidence: BirdSpeciesEngine.localAgreementThreshold,
                                        agreementReason: BirdSpeciesEngine.agreementReasonToken) {
                applyBirdRecord(rec, to: url, writeLabel: false)
                settle.call()
                return
            }
            // 历史日志里只有低置信本地猜测：不读回来、不显示、不重跑；
            // 顺手清掉旧版写进 xmp:Label 的鸟名（写入前仍有 .before-bird.xmp 备份）。
            if rows.contains(where: { $0.file == url.lastPathComponent && $0.source != "人工确认" }) {
                birdUnreliable.insert(url)
                birdMessage[url] = "历史本地识别把握不足，已忽略结果；请放大原图后人工确认"
                let dir = url.deletingLastPathComponent()
                DispatchQueue.global(qos: .utility).async {
                    _ = try? MetadataWriter.setBirdLabel(to: url, bird: nil, backupDir: dir)
                }
                settle.call()
                return
            }
        }

        // 先触发预热；主线程只读细粒度状态位，抢不到模型加载锁也绝不停顿。
        prewarmBirdModel()
        let needsFirstLoad = birdModelWarming || BirdSpeciesEngine.isLoading || !BirdSpeciesEngine.isLoaded
        birdTaskSerial &+= 1
        let token = birdTaskSerial
        birdTaskToken[url] = token
        birdLoading.insert(url)
        birdMessage[url] = needsFirstLoad
            ? "首次加载本地模型…（约 5 秒，之后秒出）" : "读取原图…"
        let crop = birdCrop(for: url)
        // 用原尺寸预览而非分析小图：小图里面临小主体信息不足，会和验证口径不一致。
        // 直接查 LRU：相邻图预取后鸟种任务不必再解一次 RAW（原来只认当前图）。
        let preferred = fullPreviewCache[url]
        // 兜底看门狗：任何未预料的失败路径（后台队列被系统回收、CoreML 异常等）
        // 都不能把这张永久挂在"识别中"。换代后 token 失配的旧看门狗自然失效。
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self] in
            guard let self, self.birdTaskToken[url] == token,
                  self.birdLoading.contains(url) else { return }
            self.birdLoading.remove(url)
            self.birdMessage[url] = "鸟种识别超时，重新点开照片可重试"
            settle.call()
        }
        queue.async {
            guard let cg = preferred ?? Analyzer.loadFullPreview(url) else {
                DispatchQueue.main.async {
                    // 旧任务被换代：不能清掉新任务拥有的 loading，但必须让批量继续。
                    guard self.birdTaskToken[url] == token else { settle.call(); return }
                    self.birdLoading.remove(url)
                    self.birdMessage[url] = "原图读取失败，重新点开照片可重试"
                    settle.call()
                }
                return
            }
            let loaded = BirdSpeciesEngine.loadIfNeeded()
            DispatchQueue.main.async {
                // 2026-11-25 QA Bug#1：这里旧版把 token / loading 写在一条 guard 里，
                // 任一失配就直接 return 而没有 settle.call()，批量泵会永久卡在
                // birdBatchActive=true。两条分开，两个出口都让批量继续（一次性 box 幂等）。
                guard self.birdTaskToken[url] == token else { settle.call(); return }
                guard self.birdLoading.contains(url) else { settle.call(); return }
                self.birdMessage[url] = "识别中…"
            }
            // 整图与主体框各跑一次，取置信更高的；两者 Top1 一致也算互相印证。
            let whole = loaded ? BirdSpeciesEngine.guess(image: cg, crop: nil) : nil
            let cropped = loaded ? crop.flatMap { BirdSpeciesEngine.guess(image: cg, crop: $0) } : nil
            let top = [whole, cropped].compactMap { $0 }.max {
                ($0.first?.confidence ?? 0) < ($1.first?.confidence ?? 0)
            }
            let agree: Bool
            if let a = whole?.first, let b = cropped?.first {
                agree = a.chinese == b.chinese
            } else { agree = false }
            let topText = top.map { self.birdTop3Text($0) } ?? ""
            DispatchQueue.main.async {
                // 圈选后可能已经启动新一轮识别：旧任务的结果全部丢弃，但批量要继续计数。
                guard self.birdTaskToken[url] == token else { settle.call(); return }
                // QA Bug#1：看门狗超时清过 loading 后，迟到的旧结果不得再写回
                // （否则"超时"文案刚显示就被旧结果覆盖，且并发人工确认可能被冲掉）。
                guard self.birdLoading.contains(url) else { settle.call(); return }
                self.birdLoading.remove(url)
                // 识别期间用户可能已人工确认（或日志回填了人工确认结果）：
                // 已有结果一律采用现有值，本地识别绝不覆盖（人工确认优先不变式；
                // 批量识别让这个并发窗口变大，必须显式保护）。
                if self.birdCache[url] != nil { settle.call(); return }
                guard let top, let first = top.first else {
                    self.birdMessage[url] = "本地没认出来"
                    settle.call()
                    return
                }
                // 窄口径放宽：常规门槛 0.50 直接采纳；只有整图与主体框 Top1 一致时，
                // 才允许低到 0.45（恢复大山雀 49.3%）。旧口径 0.25 太松，暗光/空画面
                // 两路会稳定给出同一个错误鸟名（实测黑胸鸫 26.8%、普通翠鸟 26.2%），
                // 那两张仍低于 0.45，继续拒识。
                let usable = first.confidence >= BirdSpeciesEngine.localAcceptThreshold
                    || (agree && first.confidence >= BirdSpeciesEngine.localAgreementThreshold)
                if usable {
                    self.birdMessage[url] = ""
                    let how = agree ? "BioCLIP 2 本地识别（整图与主体框互相印证）"
                                    : "BioCLIP 2 本地识别"
                    self.commitBird(name: first.chinese, latin: first.latin,
                                    confidence: first.confidence, source: "本地识别",
                                    reason: how, top3: topText, for: url)
                } else {
                    // 把握不足：鸟名、置信度、Top3 一概不显示，也不写标签/日志。
                    self.birdUnreliable.insert(url)
                    self.birdCache[url] = nil
                    self.birdSource[url] = nil
                    self.birdTop3[url] = nil
                    self.birdReason[url] = nil
                    self.birdMessage[url] = "本地模型没有可靠结果，未添加鸟种；请放大原图后人工确认"
                }
                settle.call()
            }
        }
    }

    /// 手动圈选主体后重认鸟种：清掉旧候选/旧任务，按新框强制跑一次本地识别。
    /// 人工确认的结果不动，避免把用户核实过的鸟名覆盖掉。
    func refreshBirdAfterSubjectSelection(for url: URL) {
        guard birdSource[url] != "人工确认" else { return }
        // 手动圈主体后即使用户导入时没开「识别鸟种」，也允许对这一张单独识别。
        guard containsResult(url) else { return }
        birdCache[url] = nil
        birdTop3[url] = nil
        birdSource[url] = nil
        birdReason[url] = nil
        birdMessage[url] = ""
        birdUnreliable.remove(url)     // 换了裁剪框，允许重新判断一次
        birdDismissed.remove(url)      // 用户重新框了主体，允许再次自动识别
        birdLoading.remove(url)        // 旧任务靠 token 失效，不让它占着"识别中"
        ensureBird(for: url, forceLocal: true, ignoreGenre: true)
    }

    /// 采用一个鸟种结果：更新界面 + 追加可见日志 + 写 XMP 标签（追加在判定词之后）。
    func commitBird(name: String, latin: String, confidence: Double, source: String,
                    reason: String, top3: String, for url: URL) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        birdCache[url] = BirdSpeciesGuess(chinese: clean, latin: latin, confidence: confidence)
        birdSource[url] = source
        birdReason[url] = reason
        birdTop3[url] = top3
        birdMessage[url] = ""
        let root = birdRoot(for: url)
        let rec = BirdRecord(time: ISO8601DateFormatter().string(from: Date()),
                             file: url.lastPathComponent, name: clean, latin: latin,
                             confidence: confidence, source: source, reason: reason,
                             root: root.path, stars: birdStars(for: url), top3: top3)
        BirdLog.append(rec, in: root)
        let dir = url.deletingLastPathComponent()
        DispatchQueue.global(qos: .utility).async {
            do {
                _ = try MetadataWriter.setBirdLabel(to: url, bird: clean, backupDir: dir)
            } catch {
                DispatchQueue.main.async { self.status = "鸟种标签写入失败：\(error.localizedDescription)" }
            }
        }
    }

    private func applyBirdRecord(_ rec: BirdRecord, to url: URL, writeLabel: Bool) {
        birdCache[url] = BirdSpeciesGuess(chinese: rec.name, latin: rec.latin, confidence: rec.confidence)
        birdSource[url] = rec.source
        birdReason[url] = rec.reason
        birdTop3[url] = rec.top3
        birdMessage[url] = ""
        guard writeLabel else { return }
        DispatchQueue.global(qos: .utility).async {
            _ = try? MetadataWriter.setBirdLabel(to: url, bird: rec.name,
                                                  backupDir: url.deletingLastPathComponent())
        }
    }

    func confirmBird(for url: URL) {
        let name = (birdConfirm[url] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        commitBird(name: name, latin: "", confidence: 1, source: "人工确认",
                   reason: "用户放大原图后确认", top3: birdTop3[url] ?? "", for: url)
    }

    func clearBirdLabel(for url: URL) {
        birdCache[url] = nil
        birdSource[url] = nil
        birdReason[url] = nil
        birdTop3[url] = nil
        birdMessage[url] = ""
        birdConfirm[url] = ""
        birdDismissed.insert(url)   // 本次会话不再自动重认，避免清掉又被写回
        DispatchQueue.global(qos: .utility).async {
            _ = try? MetadataWriter.setBirdLabel(to: url, bird: nil,
                                                  backupDir: url.deletingLastPathComponent())
        }
    }

    /// 鸟种日志导出：CSV 带照片根目录绝对路径，供后续统计与换模型复用。
    func exportBirdLog() {
        let root = currentFolder ?? results.first?.id.deletingLastPathComponent()
        let records = root.map { BirdLog.load(in: $0) } ?? []
        guard !records.isEmpty else { status = "当前文件夹还没有鸟种识别记录"; return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = csvDefaultFileName(prefix: "鸟种识别记录")
        panel.directoryURL = Store.defaultExportDirectory
        panel.allowedContentTypes = [UTType.commaSeparatedText]
        guard panel.runModal() == .OK, let u = panel.url else { return }
        do {
            try BirdLog.csv(records).write(to: u, atomically: true, encoding: .utf8)
            status = "鸟种记录已导出：\(u.path)（共 \(records.count) 条）"
        } catch { status = "导出失败：\(error.localizedDescription)" }
    }

    /// 导出 CSV 默认文件名：前缀-导入文件夹名-日期（到日）。
    /// 例：导入 ~/Downloads/test2 → 「摄影筛选报告-test2-2026-11-20.csv」。
    private func csvDefaultFileName(prefix: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return "\(prefix)-\(importFolderName)-\(formatter.string(from: Date())).csv"
    }

    /// NSSavePanel 默认目录：系统「下载」文件夹。
    static var defaultExportDirectory: URL? {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
    }

    func exportCSV() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = csvDefaultFileName(prefix: "摄影筛选报告")
        panel.directoryURL = Store.defaultExportDirectory
        panel.allowedContentTypes = [UTType.commaSeparatedText]
        guard panel.runModal() == .OK, let u = panel.url else { return }
        // 题材记录：纯规则识别 + 最终生效题材 + 是否人工改过，供复核与调规则。
        var genres: [URL: Report.GenreRecord] = [:]
        var focusMiss: [URL: FocusMissDiagnosis] = [:]
        for r in results {
            let pure = ScoreEngine.guessGenre(m: r.metrics, af: afCache[r.id],
                                              wb: wbCache[r.id], exif: exifCache[r.id],
                                              focus: focusCache[r.id], human: humanCache[r.id],
                                              ai: aiCache[r.id].flatMap { $0 })
            let (final, _, why) = genre(for: r)
            let s = score(for: r)
            genres[r.id] = Report.GenreRecord(autoGenre: pure.0.rawValue, reason: why,
                                              finalGenre: final.rawValue,
                                              manualGenre: genreOverride[r.id]?.rawValue,
                                              stars: s.stars, total: Int(s.total.rounded()))
            focusMiss[r.id] = FocusMiss.diagnose(r.metrics, af: afCache[r.id], verdict: r.verdict,
                                                  lens: exifCache[r.id]?.lens,
                                                  shutter: exifCache[r.id]?.shutterSafety)
        }
        var birds: [URL: Report.BirdInfo] = [:]
        for r in results {
            if let g = birdCache[r.id] {
                birds[r.id] = Report.BirdInfo(name: g.chinese, confidence: g.confidence,
                                              source: birdSource[r.id] ?? "",
                                              reason: birdReason[r.id] ?? "",
                                              top3: birdTop3[r.id] ?? "")
            }
        }
        let csv = Report.csv(results, hiMin: hiMin, sensitivity: sensitivity,
                             anchor: anchorHi, genres: genres, focusMiss: focusMiss, birds: birds)
        do {
            try csv.write(to: u, atomically: true, encoding: .utf8)
            status = "报告已导出：\(u.path)（可填「人工真值」列后用 verify.py 复核）"
        } catch { status = "导出失败：\(error.localizedDescription)" }
    }

    // MARK: 开发模式调试导出

    /// 开发模式：设置环境变量 KINGFISHER_DEV=1 启动才显示「导出调试 CSV」。
    /// 发布版没有这个按钮，也不写任何调试文件。
    let devMode = ProcessInfo.processInfo.environment["KINGFISHER_DEV"] == "1"

    /// 调试 CSV：每张照片的全部中间参数（清晰度判定依据、各维度分数与依据、
    /// 对焦点语义标签、人体检测、题材判定链），用于对照真值调阈值。
    func exportDebugCSV() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = csvDefaultFileName(prefix: "调试记录")
        panel.directoryURL = Store.defaultExportDirectory
        panel.allowedContentTypes = [UTType.commaSeparatedText]
        guard panel.runModal() == .OK, let u = panel.url else { return }
        let header = ["文件名", "判定", "判定原因", "建议星级", "综合分",
                      "主体清晰度分", "主体清晰度依据", "整体锐度分", "整体锐度依据",
                      "对焦准确度分", "对焦准确度依据", "白平衡分", "白平衡依据",
                      "热力图合格线", "最锐区P99", "最清楚处", "偏软占比", "重模糊比",
                      "拖影", "主体虚化", "主体定位", "主体清晰度显示值", "中心清晰度显示值",
                      "对焦点数", "对焦模式", "对焦点语义", "语义依据", "语义top标签",
                      "人体主体", "人体依据",
                      "自动题材", "题材依据", "最终题材", "人工指定",
                      "AI主体识别", "AI依据", "AI标签",
                      "纠正记忆条数", "对焦失误提示", "对焦失误说明", "完整路径"]
        var lines = [header.joined(separator: ",")]
        for r in results {
            let m = r.metrics
            let s = score(for: r)
            let pure = ScoreEngine.guessGenre(m: m, af: afCache[r.id], wb: wbCache[r.id],
                                              exif: exifCache[r.id], focus: focusCache[r.id],
                                              human: humanCache[r.id],
                                              ai: aiCache[r.id].flatMap { $0 })
            let (final, _, why) = genre(for: r)
            let af = afCache[r.id]
            let focus = focusCache[r.id]
            let human = humanCache[r.id]
            let ai = aiCache[r.id].flatMap { $0 }
            // 各维度分与依据按固定列位取（白平衡在非人像题材可能缺失）。
            func part(_ id: String) -> (String, String) {
                if let p = s.parts.first(where: { $0.id == id }) {
                    return (String(Int(p.score.rounded())), Report.q(p.detail))
                }
                return ("", Report.q("该题材未计此维度"))
            }
            let row = [
                Report.q(r.id.lastPathComponent), Report.q(r.verdict.rawValue), Report.q(r.reason),
                String(s.stars), String(Int(s.total.rounded())),
                part("clarity").0, part("clarity").1,
                part("overall").0, part("overall").1,
                part("focus").0, part("focus").1,
                part("color").0, part("color").1,
                Report.f(Analyzer.referenceThreshold(metrics, sensitivity: sensitivity, anchor: anchorHi), 1),
                Report.f(m.globalHi, 1), Report.f(m.scores.max() ?? 0, 1),
                Report.f(m.softRatio), Report.f(m.reblurRatio), Report.f(m.anisotropy, 2), Report.f(m.subjectReblur),
                Report.q(m.subjectSource),
                Report.f(m.displaySubjectRatio), Report.f(m.displayCenterRatio),
                String(af?.points.count ?? 0), Report.q(af?.modeName ?? ""),
                Report.q(focus.map { "\($0.kind)" } ?? "未识别"),
                Report.q(focus?.reason ?? ""),
                Report.q(focus?.labels.prefix(5).joined(separator: " | ") ?? ""),
                Report.q(human.map { $0.isMainSubject ? "是" : "否" } ?? "未检测"),
                Report.q(human?.reason ?? ""),
                Report.q(pure.0.rawValue), Report.q(why), Report.q(final.rawValue),
                Report.q(genreOverride[r.id]?.rawValue ?? ""),
                Report.q(ai.map { "\($0.kind)" } ?? "未识别"), Report.q(ai?.reason ?? ""),
                Report.q(ai?.labels.prefix(5).joined(separator: " | ") ?? ""),
                String(memory.count),
                Report.q(FocusMiss.diagnose(m, af: af, verdict: r.verdict,
                                            lens: exifCache[r.id]?.lens,
                                            shutter: exifCache[r.id]?.shutterSafety).short),
                Report.q(FocusMiss.diagnose(m, af: af, verdict: r.verdict,
                                            lens: exifCache[r.id]?.lens,
                                            shutter: exifCache[r.id]?.shutterSafety).detail),
                Report.q(r.id.path),
            ]
            lines.append(row.joined(separator: ","))
        }
        let csv = "\u{FEFF}" + lines.joined(separator: "\n") + "\n"
        do {
            try csv.write(to: u, atomically: true, encoding: .utf8)
            status = "调试记录已导出：\(u.path)"
        } catch { status = "导出失败：\(error.localizedDescription)" }
    }
}

// MARK: - 热力图

func verdictColor(_ v: Verdict) -> Color {
    switch v {
    case .pass, .passUnverified: return .secondary
    case .globalBlur, .subjectBlur, .depthIssue: return .red
    case .motionBlur: return .orange
    case .unreadable: return .gray
    }
}

/// 热力图标尺说明：
/// - 分母不再用「本图 P99」，而是本图最锐区与批次基准的较大者；全糊图不会满屏绿。
/// - 再模糊一次几乎不掉分的块视为「低纹理，无法判断」，画成灰色而不是红色。
/// - 主体掩膜内的块加深显示，便于直接看想要的主体是否锐利。
func makeHeatmap(_ m: PhotoMetrics, floor: Double) -> NSImage {
    let size = NSSize(width: m.width, height: m.height)
    let img = NSImage(size: size)
    img.lockFocus()
    let denom = max(m.globalHi, floor * 1.2, 1e-6)
    let globallyBlurred = m.globalHi < floor
    for r in 0..<m.rows {
        for c in 0..<m.cols {
            let i = r * m.cols + c
            let s = m.scores[i]
            let drop = m.blurScores[i] / max(s, 1e-6)
            let v = s / denom
            let lowDetail = drop > 0.88 && s < denom * 0.15
            let subject = m.weights[i] > 0.45
            let color: NSColor
            if globallyBlurred {
                color = NSColor(srgbRed: 0.90, green: 0.25, blue: 0.25, alpha: 0.46)
            } else if lowDetail {
                color = NSColor(srgbRed: 0.50, green: 0.50, blue: 0.50, alpha: 0.14)
            } else if v >= 0.45 {
                color = NSColor(srgbRed: 0.20, green: 0.72, blue: 0.55,
                                alpha: subject ? 0.46 : 0.28)
            } else if v >= 0.18 {
                color = NSColor(srgbRed: 0.95, green: 0.72, blue: 0.20,
                                alpha: subject ? 0.52 : 0.34)
            } else {
                color = NSColor(srgbRed: 0.90, green: 0.25, blue: 0.25,
                                alpha: subject ? 0.58 : 0.42)
            }
            color.setFill()
            // 按"整幅图均分成 cols×rows 份"来定位每块，最后一块自动铺到图像边缘。
            // 之前每块固定画 bs×bs，整除丢掉的余数（右侧/底部 <28px）没被覆盖，
            // 露出底下的原图背景——即截图里右侧/底部的蓝紫色空条。
            let cw = size.width / CGFloat(m.cols)
            let ch = size.height / CGFloat(m.rows)
            let rect = NSRect(x: CGFloat(c) * cw,
                              y: size.height - CGFloat(r + 1) * ch,
                              width: cw, height: ch)
            NSBezierPath(rect: rect).fill()
        }
    }
    img.unlockFocus()
    return img
}

// MARK: - 滚轮缩放桥接
// 滚轮事件 SwiftUI 拿不到，用 AppKit 本地监听。约定：向下滚（deltaY<0）放大，向上滚缩小。

struct ScrollWheelBridge: NSViewRepresentable {
    /// 回调传滚动量与鼠标位置（容器左上原点坐标，和 DragGesture 的 location 一致）。
    var onScroll: (CGFloat, CGPoint) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView {
        let v = ScrollWheelNSView()
        v.coordinator = context.coordinator
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        guard let v = nsView as? ScrollWheelNSView else { return }
        v.coordinator?.onScroll = onScroll
    }
    final class Coordinator { var onScroll: ((CGFloat, CGPoint) -> Void)? }

    final class ScrollWheelNSView: NSView {
        weak var coordinator: Coordinator?
        private var monitor: Any?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); install() }
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil { remove() }
            super.viewWillMove(toWindow: newWindow)
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        private func install() {
            guard monitor == nil, window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] e in
                guard let self, let win = self.window, e.window === win else { return e }
                // 用桥接视图自身的 bounds 判断：它铺满预览区，范围严格等于 GeometryReader，
                // 不会误吞分隔条/信息区的事件；坐标转成左上原点后与 fitW/fitH 同一基准。
                let p = self.convert(e.locationInWindow, from: nil)
                guard self.bounds.width > 0, self.bounds.contains(p) else { return e }
                let topLeft = CGPoint(x: p.x, y: self.bounds.height - p.y)
                self.coordinator?.onScroll?(e.scrollingDeltaY, topLeft)
                return nil
            }
        }
        private func remove() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
        deinit { remove() }
    }
}

// MARK: - 左侧目录

/// 列表可视高度上报键（只写 Store 的非 @Published 字段，不触发布局反馈）。
private struct ListViewportHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct ResultRow: View {
    @EnvironmentObject var store: Store
    let r: PhotoResult
    var body: some View {
        // 档位只改显示 frame，解码统一 192px；行高随缩略图高度联动。
        let thumbSize = store.thumbnailScale.size
        HStack(spacing: 8) {
            if let cg = store.thumbnail(for: r.id, fallback: r.metrics.preview) {
                Image(nsImage: NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)))
                    .resizable().aspectRatio(contentMode: .fill)
                    .frame(width: thumbSize.width, height: thumbSize.height)
                    .clipped().cornerRadius(3)
            } else {
                Rectangle().fill(Color.gray.opacity(0.15))
                    .frame(width: thumbSize.width, height: thumbSize.height).cornerRadius(3)
                // 历史恢复时 preview=nil：行出现才解小图，且不阻塞进入页面。
                .task { store.ensureThumbnail(for: r.id, highPriority: true) }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(store.displayName(r.id)).lineLimit(1).font(.body)
                HStack(spacing: 6) {
                    Text(r.verdict.rawValue).font(.caption2).foregroundColor(verdictColor(r.verdict))
                    if store.excluded.contains(r.id) {
                        Text("排除写入").font(.caption2).foregroundColor(.orange)
                    }
                    // 目录星级：和信息区评分行共用 ratingCache，右侧改星后这里同步更新。
                    if let rating = store.displayedRating(r.id) {
                        if rating == -1 {
                            Text("拒绝").font(.caption2).foregroundColor(.red)
                        } else if rating > 0 {
                            Text(String(repeating: "★", count: rating)
                                 + String(repeating: "☆", count: 5 - rating))
                                .font(.caption2).foregroundColor(.orange)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .help(r.id.path)
        .task { store.ensureRating(for: r.id) }
        // 可见行上报：供 Shift 区间多选的边缘滚动推导可视区间（集合容错复用乱序）。
        .onAppear { store.rowAppeared(r.id) }
        .onDisappear { store.rowDisappeared(r.id) }
        .padding(.vertical, 2)
    }
}

// MARK: - 右键拖框桥接
// SwiftUI 的 DragGesture 只接左键。这里用一个透明的 AppKit 视图装本地事件监听，
// 只处理右键按下/拖动/抬起，左键仍然交给 SwiftUI，从而实现「右键拖框 = 放大选区」。

struct RightDragBridge: NSViewRepresentable {
    var onStart: (CGPoint) -> Void
    var onMove: (CGPoint) -> Void
    var onEnd: (CGPoint) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let v = RightDragNSView()
        v.coordinator = context.coordinator
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let v = nsView as? RightDragNSView else { return }
        v.coordinator?.onStart = onStart
        v.coordinator?.onMove = onMove
        v.coordinator?.onEnd = onEnd
    }

    final class Coordinator {
        var onStart: ((CGPoint) -> Void)?
        var onMove: ((CGPoint) -> Void)?
        var onEnd: ((CGPoint) -> Void)?
    }

    final class RightDragNSView: NSView {
        weak var coordinator: Coordinator?
        private var monitor: Any?

        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); install() }
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil { remove() }
            super.viewWillMove(toWindow: newWindow)
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        private func install() {
            guard monitor == nil, window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(
                matching: [.rightMouseDown, .rightMouseDragged, .rightMouseUp]
            ) { [weak self] event in
                guard let self, let win = self.window, event.window === win else { return event }
                let p = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.width > 0, self.bounds.contains(p) else { return event }
                let topLeft = CGPoint(x: p.x, y: self.bounds.height - p.y)
                switch event.type {
                case .rightMouseDown: self.coordinator?.onStart?(topLeft)
                case .rightMouseDragged: self.coordinator?.onMove?(topLeft)
                case .rightMouseUp: self.coordinator?.onEnd?(topLeft)
                default: break
                }
                return nil // 吞掉右键，避免弹出菜单打断拖框
            }
        }

        private func remove() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        deinit { remove() }
    }
}

// MARK: - 左键手势桥接（统一接管）
// 所有左键手势（框选放大 / 圈选主体 / 拖动平移 / 单击复位）都在这里判定，
// 不再混用 SwiftUI DragGesture，避免两套监听互相吞事件导致平移失效/跳动。
// 空格键仍可平移作为兼容：按住空格时强制走平移。

/// 左键手势的阶段事件，交给 DetailView 处理具体几何。
enum LeftMouseGesture {
    case began(DragAction, CGPoint)  // 动作类型 + 起点
    case moved(CGPoint)              // 当前点
    case ended(CGPoint)              // 终点
    case tap                         // 单击（无有效位移）→ 复位
    case doubleTap(CGPoint)          // 双击 → 以点击位置为中心放大（位置为预览区左上原点坐标）
}

struct LeftMouseBridge: NSViewRepresentable {
    var zoomFlag: NSEvent.ModifierFlags
    var subjectFlag: NSEvent.ModifierFlags
    /// 返回 true 时完全放行左键事件，避免误判为平移。
    var isSuppressed: () -> Bool = { false }
    /// 分隔条拖动：按下时返回当前信息区高度/宽度作为绝对基准。
    var dividerBegin: () -> CGFloat = { 0 }
    /// 当前分隔条方向：true=垂直条（右侧布局，拖宽度用鼠标 x）；false=水平条（下方布局，拖高度用鼠标 y）。
    var dividerIsVertical: () -> Bool = { false }
    /// 传入由鼠标绝对位移算出的目标高度/宽度，外部负责 clamp 并写入状态。
    var dividerDrag: (CGFloat) -> Void = { _ in }
    var dividerEnd: () -> Void = {}
    var onGesture: (LeftMouseGesture) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView {
        let v = LeftMouseNSView()
        v.coordinator = context.coordinator
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        guard let v = nsView as? LeftMouseNSView else { return }
        let c = v.coordinator
        c?.zoomFlag = zoomFlag
        c?.subjectFlag = subjectFlag
        c?.isSuppressed = isSuppressed
        c?.onGesture = onGesture
        c?.dividerBegin = dividerBegin
        c?.dividerIsVertical = dividerIsVertical
        c?.dividerDrag = dividerDrag
        c?.dividerEnd = dividerEnd
    }

    final class Coordinator {
        var zoomFlag: NSEvent.ModifierFlags = .command
        var subjectFlag: NSEvent.ModifierFlags = .control
        var isSuppressed: (() -> Bool)?
        var onGesture: ((LeftMouseGesture) -> Void)?
        var dividerBegin: (() -> CGFloat)?
        var dividerIsVertical: (() -> Bool)?
        var dividerDrag: ((CGFloat) -> Void)?
        var dividerEnd: (() -> Void)?
    }

    final class LeftMouseNSView: NSView {
        weak var coordinator: Coordinator?
        private var keyDownMonitor: Any?
        private var keyUpMonitor: Any?
        private var mouseMonitor: Any?
        private var spaceHeld = false
        private var action: DragAction?
        private var start: CGPoint?
        private var last: CGPoint?
        /// 分隔条拖动的绝对基准：起始鼠标坐标（窗口绝对）与起始信息区高度/宽度。
        /// 上下布局用 y 拖高度；右侧布局用 x 拖宽度。按下时按 axis 记录。
        private var dividerStartPos: CGFloat = 0
        private var dividerStartH: CGFloat = 0
        private var dividerIsWidthAxis = false
        /// 双击的第二下按下已处理，紧随其后的 mouseUp 直接吞掉，避免孤儿事件。
        private var swallowNextUp = false

        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); install() }
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil { remove() }
            super.viewWillMove(toWindow: newWindow)
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        private func install() {
            guard mouseMonitor == nil, window != nil else { return }
            keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
                guard let self, e.keyCode == 49, self.window != nil else { return e }
                self.spaceHeld = true
                return nil // 吞掉空格，避免触发按钮/菜单
            }
            keyUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak self] e in
                guard let self, e.keyCode == 49 else { return e }
                self.spaceHeld = false
                return nil
            }
            mouseMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
            ) { [weak self] e in
                guard let self, let win = self.window, e.window === win else { return e }
                let p = self.convert(e.locationInWindow, from: nil)
                guard self.bounds.width > 0 else { return e }

                // 分隔条命中：上下布局在预览区正下方（水平条），右侧布局在预览区正右方
                // （垂直条）。用 view 本地坐标 p，只在 leftMouseDown 那一刻判定，此时布局未变。
                // 按下时读取当前方向（拖动过程中不会变），基准用窗口绝对坐标。
                let vertical = self.coordinator?.dividerIsVertical?() ?? false
                let inDivider: Bool
                if vertical {
                    inDivider = p.y >= 0 && p.y <= self.bounds.height
                        && p.x >= self.bounds.width && p.x < self.bounds.width + 10
                } else {
                    inDivider = p.x >= 0 && p.x <= self.bounds.width && p.y >= -10 && p.y < 0
                }
                if inDivider, e.type == .leftMouseDown {
                    self.action = .divider
                    // 关键：拖动基准必须用窗口绝对坐标 e.locationInWindow，
                    // 不能用 p。p 是"桥接 view 的本地坐标"，而这个 view 铺满预览区，
                    // 其边缘会随信息区尺寸变化而移动 —— 用 p 会构成反馈闭环：
                    // 拖动 → 改尺寸 → view 边缘移动 → 同一鼠标位置 p 改变 →
                    // 再改尺寸 → 来回震荡（信息区与照片一起跳）。
                    // 窗口坐标在布局变化时不移动，是真正的绝对基准。
                    self.dividerIsWidthAxis = vertical
                    self.dividerStartPos = vertical ? e.locationInWindow.x : e.locationInWindow.y
                    self.dividerStartH = self.coordinator?.dividerBegin?() ?? 0
                    return nil
                }
                if self.action == .divider {
                    switch e.type {
                    case .leftMouseDragged:
                        // 上下布局：鼠标上移 → 信息区变高（窗口 y 向上，与旧语义一致）。
                        // 右侧布局：鼠标左移 → 信息区变宽（窗口 x 向右，左移 x 减小 → 宽度增大）。
                        let delta = self.dividerIsWidthAxis
                            ? -(e.locationInWindow.x - self.dividerStartPos)
                            : (e.locationInWindow.y - self.dividerStartPos)
                        self.coordinator?.dividerDrag?(self.dividerStartH + delta)
                    case .leftMouseUp:
                        self.action = nil
                        self.coordinator?.dividerEnd?()
                    default: break
                    }
                    return nil
                }

                // 正在拖动分隔条时完全放行，避免被误判为"平移画面"。
                if self.coordinator?.isSuppressed?() == true { return e }
                // 用桥接视图自身 bounds 判断，范围严格等于预览区（不吞分隔条/信息区事件）；
                // 坐标转左上原点后与 GeometryReader 的 fitW/fitH 同一基准。
                guard self.bounds.contains(p) else { return e }
                let topLeft = CGPoint(x: p.x, y: self.bounds.height - p.y)
                switch e.type {
                case .leftMouseDown:
                    // 双击优先：macOS 会给出 clickCount==2，直接以点击位置为中心放大
                    //（用户 2026-11-23 要求，不再跳到相机对焦点）；单击仍走 tap 复位。
                    if e.clickCount >= 2 {
                        self.action = nil
                        self.start = nil
                        self.last = nil
                        self.swallowNextUp = true
                        self.coordinator?.onGesture?(.doubleTap(topLeft))
                        return nil
                    }
                    let flags = e.modifierFlags.intersection([.command, .control, .option, .shift])
                    let a: DragAction
                    if self.spaceHeld {
                        a = .pan
                    } else if !flags.isEmpty && flags.contains(self.coordinator?.zoomFlag ?? .command) {
                        a = .zoom
                    } else if !flags.isEmpty && flags.contains(self.coordinator?.subjectFlag ?? .control) {
                        a = .subject
                    } else {
                        a = .pan
                    }
                    self.action = a
                    self.start = topLeft
                    self.last = topLeft
                    self.coordinator?.onGesture?(.began(a, topLeft))
                case .leftMouseDragged:
                    guard self.action != nil else { return e }
                    self.last = topLeft
                    self.coordinator?.onGesture?(.moved(topLeft))
                case .leftMouseUp:
                    if self.swallowNextUp {
                        self.swallowNextUp = false
                        return nil
                    }
                    guard self.action != nil else { return e }
                    let end = self.last ?? topLeft
                    let s = self.start ?? topLeft
                    if hypot(end.x - s.x, end.y - s.y) < 4 {
                        self.coordinator?.onGesture?(.tap)
                    } else {
                        self.coordinator?.onGesture?(.ended(end))
                    }
                    self.action = nil
                    self.start = nil
                    self.last = nil
                default: break
                }
                return nil // 吞掉左键，全部交给统一桥接
            }
            NotificationCenter.default.addObserver(
                self, selector: #selector(resign),
                name: NSApplication.didResignActiveNotification, object: nil
            )
        }

        @objc private func resign() {
            spaceHeld = false
            if action == .divider {
                action = nil
                coordinator?.dividerEnd?()
            } else if action != nil, let s = start {
                coordinator?.onGesture?(.ended(s))
                action = nil; start = nil; last = nil
            }
        }

        private func remove() {
            [keyDownMonitor, keyUpMonitor, mouseMonitor].compactMap { $0 }.forEach(NSEvent.removeMonitor)
            keyDownMonitor = nil; keyUpMonitor = nil; mouseMonitor = nil
            NotificationCenter.default.removeObserver(self)
            spaceHeld = false; action = nil; start = nil; last = nil; swallowNextUp = false
        }
        deinit { remove() }
    }
}

// MARK: - 右上：预览与缩放

/// 预览区里几种彩色框的图例，放在工具栏下方一行。只显示当前开启的框，
/// 与工具栏的「AI主体蓝框 / 自选主体黄框 / 对焦点」勾选保持一致（2026-11-23）。
private struct FrameLegend: View {
    @EnvironmentObject var store: Store
    var body: some View {
        HStack(spacing: 14) {
            if store.showAISubjectBox { legend(Color.cyan, "蓝框＝AI 主体") }
            if store.showAFPoints { legend(Color.red, "红框＝相机对焦点") }
            if store.showManualSubjectBox { legend(Color.yellow, "黄框＝自选主体（信息区可取消）") }
        }
        .font(.caption2)
        .foregroundColor(.secondary)
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
    }
    @ViewBuilder
    private func legend(_ c: Color, _ text: String) -> some View {
        HStack(spacing: 4) {
            Rectangle().stroke(c, lineWidth: 1.5).frame(width: 11, height: 9)
            Text(text)
        }
    }
}

/// 工具栏开关文字 + 小号灰色快捷键提示。实际按键由 ContentView 的本地监听统一处理
/// （快捷键可在设置面板自定义），这里只把当前绑定的组合显示出来。
private struct ShortcutToggleLabel: View {
    let title: String
    let key: String
    var body: some View {
        HStack(spacing: 3) {
            Text(title)
            Text(key).font(.caption2).foregroundColor(.secondary)
        }
    }
}

/// 构图辅助线：九宫格（三分线）+ 对角线，可分别开关、同时开启则叠加。
/// 用 Path 按 fitW/fitH 画，放在与主图同一 transform 里，缩放平移都不会错位。
private struct CompositionGuides: View {
    let fitW: CGFloat
    let fitH: CGFloat
    let thirds: Bool
    let diagonals: Bool
    let scale: CGFloat

    var body: some View {
        GeometryReader { _ in
            Path { path in
                if thirds {
                    for i in 1..<3 {
                        let x = fitW * CGFloat(i) / 3
                        let y = fitH * CGFloat(i) / 3
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x, y: fitH))
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: fitW, y: y))
                    }
                }
                if diagonals {
                    path.move(to: .zero)
                    path.addLine(to: CGPoint(x: fitW, y: fitH))
                    path.move(to: CGPoint(x: fitW, y: 0))
                    path.addLine(to: CGPoint(x: 0, y: fitH))
                }
            }
            .stroke(Color.white.opacity(0.28), lineWidth: 1 / scale)
            .shadow(color: .black.opacity(0.18), radius: 0.6, x: 0, y: 0)
            .allowsHitTesting(false)
        }
        .frame(width: fitW, height: fitH)
    }
}

/// 相机对焦点叠加层。抽成独立 View 以减小 DetailView.body 的类型检查复杂度。
private struct AFPointsOverlay: View {
    let points: [FocusPoint]
    let fitW: CGFloat
    let fitH: CGFloat
    let scale: CGFloat

    var body: some View {
        ForEach(Array(points.enumerated()), id: \.offset) { _, p in
            Rectangle()
                .stroke(Color.red, lineWidth: 2 / scale)
                .background(Color.red.opacity(0.10))
                .frame(width: max(CGFloat(p.w) * fitW, 10 / scale),
                       height: max(CGFloat(p.h) * fitH, 10 / scale))
                .position(x: CGFloat(p.cx) * fitW, y: CGFloat(p.cy) * fitH)
        }
    }
}

/// 拖框（放大 / 圈选主体）的即时几何。独立 ObservableObject：
/// 鼠标移动每帧只写这里，只有读它的那个 Rectangle overlay 会重绘，
/// 不再让整个 Store 广播触发上千行目录 + 全部信息面板的 body 重算。
final class DragBoxState: ObservableObject {
    @Published var start: CGPoint?
    @Published var current: CGPoint?
    @Published var isZoom = false

    func begin(_ p: CGPoint, zoom: Bool) {
        isZoom = zoom
        start = p
        current = p
    }

    func clear() {
        start = nil
        current = nil
        isZoom = false
    }
}

/// 拖框即时预览。独立 View 只观察 DragBoxState，保证每帧移动只重绘这个 Rectangle，
/// 不牵连 DetailView / 目录 / 信息区的 body 重算（圈选主体卡顿的根因）。
private struct DragBoxOverlay: View {
    @ObservedObject var box: DragBoxState

    var body: some View {
        if let s = box.start, let c = box.current {
            Rectangle().stroke(box.isZoom ? Color.white : Color.yellow, lineWidth: 2)
                .background((box.isZoom ? Color.white : Color.yellow).opacity(0.12))
                .frame(width: abs(c.x - s.x), height: abs(c.y - s.y))
                .position(x: (s.x + c.x) / 2, y: (s.y + c.y) / 2)
        }
    }
}

struct DetailView: View {
    @EnvironmentObject var store: Store
    @StateObject private var dragBox = DragBoxState()
    let r: PhotoResult
    /// 右侧竖排布局时预览区较窄：工具栏换成两行、提示文字收进悬停说明，
    /// 否则一整行（开关 + 缩放 + 一长串提示）超出预览区宽度，会画到信息区上。
    var compact = false

    /// 图像当前在容器坐标系里的显示矩形。
    /// 视图先以自身中心 scaleEffect，再叠加 offset，所以显示矩形的左上角要
    /// 同时考虑 zoomCenter 与 panOffset；第一次放大后必须按这个矩形换算坐标。
    private func displayedImageRect(fitW: CGFloat, fitH: CGFloat,
                                    ox: CGFloat, oy: CGFloat) -> CGRect {
        let sc = store.zoom
        let dx = (0.5 - store.zoomCenter.x) * fitW * sc + store.panOffset.width
        let dy = (store.zoomCenter.y - 0.5) * fitH * sc + store.panOffset.height
        return CGRect(
            x: ox + fitW / 2 - fitW * sc / 2 + dx,
            y: oy + fitH / 2 - fitH * sc / 2 + dy,
            width: fitW * sc,
            height: fitH * sc
        )
    }

    /// 以光标所在位置为锚点缩放：缩放前后，光标下的同一个图像点保持在屏幕原位。
    /// 保持 zoomCenter 不变，只按当前显示矩形反算 panOffset，因此可连续滚动累积。
    private func zoomAround(_ p: CGPoint, factor: CGFloat,
                            fitW: CGFloat, fitH: CGFloat,
                            ox: CGFloat, oy: CGFloat) {
        let sc0 = store.zoom
        let sc1 = min(8, max(1, sc0 * factor))
        guard abs(sc1 - sc0) > 1e-6, fitW > 0, fitH > 0 else { return }
        let d = displayedImageRect(fitW: fitW, fitH: fitH, ox: ox, oy: oy)
        guard d.width > 0, d.height > 0 else { return }
        // 光标在图像中的归一化位置（缩放前后不变）
        let u = (p.x - d.minX) / d.width
        let v = (p.y - d.minY) / d.height
        let zx = store.zoomCenter.x, zy = store.zoomCenter.y
        // 令缩放后 d2.x + u*d2.w == p.x，反算所需 offset
        let dx2 = p.x - u * fitW * sc1 - ox - fitW / 2 + fitW * sc1 / 2
        let dy2 = p.y - v * fitH * sc1 - oy - fitH / 2 + fitH * sc1 / 2
        store.panOffset = CGSize(
            width: dx2 - (0.5 - zx) * fitW * sc1,
            height: dy2 - (zy - 0.5) * fitH * sc1
        )
        store.zoom = sc1
        store.panStart = nil
    }

    /// 把屏幕坐标的拖框换算成图像归一化坐标（Vision 的 y 轴朝上）。
    /// 基于当前显示矩形换算，因此放大后再次拖框、圈选仍然对得上。
    private func imageRect(_ s: CGPoint, _ e: CGPoint,
                           fitW: CGFloat, fitH: CGFloat,
                           ox: CGFloat, oy: CGFloat) -> CGRect {
        let d = displayedImageRect(fitW: fitW, fitH: fitH, ox: ox, oy: oy)
        let x0 = min(s.x, e.x), y0 = min(s.y, e.y)
        let w = abs(e.x - s.x), h = abs(e.y - s.y)
        return CGRect(
            x: min(max((x0 - d.minX) / d.width, 0), 1),
            y: 1 - min(max((y0 + h - d.minY) / d.height, 0), 1),
            width: min(w / d.width, 1),
            height: min(h / d.height, 1)
        )
    }

    /// ACR 式放大：把选区中心移到视窗中心，选区较长边尽量铺满视窗。
    /// 倍数在当前 zoom 上累乘，所以可以在已放大的画面上继续框选放大；
    /// 中心与选区都按当前显示矩形反算，避免第二次起画面跑偏。
    private func zoomToSelection(_ s: CGPoint, _ e: CGPoint,
                                 fitW: CGFloat, fitH: CGFloat,
                                 ox: CGFloat, oy: CGFloat) {
        let w = abs(e.x - s.x), h = abs(e.y - s.y)
        guard w > 8, h > 8, fitW > 0, fitH > 0 else { return }
        let d = displayedImageRect(fitW: fitW, fitH: fitH, ox: ox, oy: oy)
        guard d.width > 0, d.height > 0 else { return }
        let nx = min(max(((s.x + e.x) / 2 - d.minX) / d.width, 0), 1)
        let nyTop = min(max(((s.y + e.y) / 2 - d.minY) / d.height, 0), 1)
        let rw = min(w / d.width, 1), rh = min(h / d.height, 1)
        let factor = min(1 / max(rw, 0.001), 1 / max(rh, 0.001))
        store.zoom = min(8, max(1.2, store.zoom * factor))
        store.zoomCenter = CGPoint(x: nx, y: 1 - nyTop)
        store.panOffset = .zero
        store.panStart = nil
        // 放大是「看」的操作：不写判定参数、也不再画黄框（黄框只标注用户圈选的主体）。
    }

    /// 双击预览：以鼠标点击位置为中心放大（用户 2026-11-23 要求，取代旧的
    /// 「跳到相机对焦点」）。点击落在图像外的边距上时钳制到最近边缘。
    /// 放大倍数与旧双击一致：把约 1/2.6 的画面铺满视窗（保留一些上下文）。
    private func zoomAtPoint(_ p: CGPoint, fitW: CGFloat, fitH: CGFloat,
                             ox: CGFloat, oy: CGFloat) {
        let d = displayedImageRect(fitW: fitW, fitH: fitH, ox: ox, oy: oy)
        guard d.width > 0, d.height > 0 else { return }
        // 点击点在图像里的归一化位置（左上原点，y 向下）
        let u = min(max((p.x - d.minX) / d.width, 0), 1)
        let v = min(max((p.y - d.minY) / d.height, 0), 1)
        // zoomCenter 的 y 是 Vision 坐标（y 向上），故用 1 - v
        store.zoomCenter = CGPoint(x: u, y: 1 - v)
        store.zoom = min(8, max(1.2, store.zoom * 2.6))
        store.panOffset = .zero
        store.panStart = nil
        // 双击放大是「看」的操作：不写判定参数、不画黄框（黄框只标注圈选主体）。
    }

    var body: some View {
        let m = r.metrics
        VStack(spacing: 0) {
            if compact {
                // 右侧窄栏：开关一行、缩放一行，保证最窄时也不超出预览区宽度。
                HStack(spacing: 12) {
                    Toggle(isOn: $store.showHeatmap) {
                        ShortcutToggleLabel(title: "锐度热力图", key: store.shortcuts.heatmap.display)
                    }
                    .help("""
                    把画面分成小格计算每格的锐度后着色：绿＝锐利、黄＝偏软、红＝发虚、灰＝纹理太少无法判断。主体区域绿说明对焦在主体上；整片偏红说明整体没对上焦。只是相对参考，不影响判定。
                    （快捷键 \(store.shortcuts.heatmap.display)，可在快捷键面板改）
                    """)
                    Toggle(isOn: $store.showAFPoints) {
                        ShortcutToggleLabel(title: "对焦点", key: store.shortcuts.afPoints.display)
                    }
                    Toggle(isOn: $store.showThirds) {
                        ShortcutToggleLabel(title: "九宫格", key: store.shortcuts.thirds.display)
                    }
                    Toggle(isOn: $store.showDiagonals) {
                        ShortcutToggleLabel(title: "对角线", key: store.shortcuts.diagonals.display)
                    }
                    Toggle(isOn: $store.showAISubjectBox) {
                        ShortcutToggleLabel(title: "AI主体蓝框", key: store.shortcuts.aiBox.display)
                    }
                    Toggle(isOn: $store.showManualSubjectBox) {
                        ShortcutToggleLabel(title: "自选主体黄框", key: store.shortcuts.manualBox.display)
                    }
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.vertical, 4)
                HStack(spacing: 12) {
                    Button("－") { store.zoomOut() }.frame(width: 26)
                    Text(String(format: "%.1f×", store.zoom)).font(.caption).monospacedDigit()
                    Button("＋") { store.zoomIn() }.frame(width: 26)
                    Button("复位") { store.resetZoom() }.font(.caption)
                    Toggle(isOn: $store.lockZoom) { Text("锁定缩放").font(.caption) }
                        .help("开启后切换照片保留当前放大倍数和位置；关闭时切图自动复位")
                    Button("一键隐藏/恢复") { store.toggleAllOverlays() }
                        .font(.caption)
                        .help("一键隐藏当前勾选的辅助项，再按一次恢复原来的勾选。快捷键 \(store.shortcuts.overlayToggle.display)（中文输入法下 ⌘、 也可以），可在快捷键面板改")
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.bottom, 4)
                .help("\(store.shortcuts.zoom.symbol)+左键拖框放大 · \(store.shortcuts.subject.symbol)+左键圈选主体 · 按住左键拖动平移 · 双击放大点击处 · 滚轮缩放 · 单击还原 · 快捷键：↑/↓ 切换照片 / ⇧↑↓ 连续多选 / \(store.shortcuts.heatmap.display) 热力图 / \(store.shortcuts.afPoints.display) 对焦点 / \(store.shortcuts.thirds.display) 九宫格 / \(store.shortcuts.diagonals.display) 对角线 / \(store.shortcuts.aiBox.display) AI蓝框 / \(store.shortcuts.manualBox.display) 黄框 / \(store.shortcuts.overlayToggle.display) 一键隐藏或恢复辅助项 / ⌘1-5 评星 / ⌘0 取消评级 / ⌥⌫ 拒绝 / ⌘⌫ 删除（⌘Z 撤销）")
            } else {
                HStack(spacing: 12) {
                    Toggle(isOn: $store.showHeatmap) {
                        ShortcutToggleLabel(title: "锐度热力图", key: store.shortcuts.heatmap.display)
                    }
                    .help("""
                    把画面分成小格计算每格的锐度后着色：绿＝锐利、黄＝偏软、红＝发虚、灰＝纹理太少无法判断。主体区域绿说明对焦在主体上；整片偏红说明整体没对上焦。只是相对参考，不影响判定。
                    （快捷键 \(store.shortcuts.heatmap.display)，可在快捷键面板改）
                    """)
                    Toggle(isOn: $store.showAFPoints) {
                        ShortcutToggleLabel(title: "对焦点", key: store.shortcuts.afPoints.display)
                    }
                    Toggle(isOn: $store.showThirds) {
                        ShortcutToggleLabel(title: "九宫格", key: store.shortcuts.thirds.display)
                    }
                    Toggle(isOn: $store.showDiagonals) {
                        ShortcutToggleLabel(title: "对角线", key: store.shortcuts.diagonals.display)
                    }
                    Toggle(isOn: $store.showAISubjectBox) {
                        ShortcutToggleLabel(title: "AI主体蓝框", key: store.shortcuts.aiBox.display)
                    }
                    .help("显示/隐藏 AI 自动识别的主体框（青蓝色）。只管画面显示，不影响判定与评分。快捷键 \(store.shortcuts.aiBox.display)，可在快捷键面板改。")
                    Toggle(isOn: $store.showManualSubjectBox) {
                        ShortcutToggleLabel(title: "自选主体黄框", key: store.shortcuts.manualBox.display)
                    }
                    .help("显示/隐藏你手动圈选的主体框（黄色）。只管画面显示；取消圈选请用信息区的「取消自选主体」。快捷键 \(store.shortcuts.manualBox.display)，可在快捷键面板改。")
                    Button("－") { store.zoomOut() }.frame(width: 26)
                    Text(String(format: "%.1f×", store.zoom)).font(.caption).monospacedDigit()
                    Button("＋") { store.zoomIn() }.frame(width: 26)
                    Button("复位") { store.resetZoom() }.font(.caption)
                    Toggle(isOn: $store.lockZoom) { Text("锁定缩放").font(.caption) }
                        .help("开启后切换照片保留当前放大倍数和位置；关闭时切图自动复位")
                    Button("一键隐藏/恢复") { store.toggleAllOverlays() }
                        .font(.caption)
                        .help("一键隐藏当前勾选的辅助项，再按一次恢复原来的勾选。快捷键 \(store.shortcuts.overlayToggle.display)（中文输入法下 ⌘、 也可以），可在快捷键面板改")
                    Spacer()
                    Text("\(store.shortcuts.zoom.symbol)+左键拖框放大 · \(store.shortcuts.subject.symbol)+左键圈选主体 · 按住左键拖动平移 · 双击放大点击处 · 滚轮缩放 · 单击还原 · ↑/↓ 切图 / ⇧↑↓ 连续多选 · \(store.shortcuts.heatmap.display)/\(store.shortcuts.afPoints.display)/\(store.shortcuts.thirds.display)/\(store.shortcuts.diagonals.display)/\(store.shortcuts.aiBox.display)/\(store.shortcuts.manualBox.display) 切换热力图/对焦点/九宫格/对角线/AI蓝框/黄框 · \(store.shortcuts.overlayToggle.display) 一键隐藏或恢复 · ⌘1-5 评星 · ⌘0 取消评级 · ⌥⌫ 拒绝 · ⌘⌫ 删除（⌘Z 撤销）")
                        .font(.caption).foregroundColor(.secondary).lineLimit(1)
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
            }

            FrameLegend()

            HStack {
                Button("设为参考图") { store.pinReference(r.id) }
                    .help("固定列表当前选中的照片作比较")
                    .disabled(store.fullPreviewURL != r.id || store.fullPreview == nil)
                if let ref = store.reference {
                    Button(store.showingReference ? "看候选图" : "看参考图") { store.showingReference.toggle() }
                    Text(store.showingReference ? "参考：\(ref.url.lastPathComponent) · 评级对象：\(r.id.lastPathComponent)" : "候选：\(r.id.lastPathComponent)")
                        .lineLimit(1)
                    Button("结束对比") { store.showingReference = false; store.reference = nil }
                }
                Spacer()
            }.font(.caption).padding(.horizontal, 12)
            if store.showingReference, let ref = store.reference {
                GeometryReader { geo in
                    let factor = min(geo.size.width / CGFloat(ref.image.width), geo.size.height / CGFloat(ref.image.height))
                    let w = CGFloat(ref.image.width) * factor, h = CGFloat(ref.image.height) * factor
                    Image(decorative: ref.image, scale: 1)
                        .resizable().frame(width: w, height: h)
                        .scaleEffect(store.zoom)
                        .position(x: geo.size.width / 2 + (0.5 - store.zoomCenter.x) * w * store.zoom + store.panOffset.width,
                                  y: geo.size.height / 2 + (store.zoomCenter.y - 0.5) * h * store.zoom + store.panOffset.height)
                }.clipped()
            } else {
            GeometryReader { geo in
                let aspect = CGFloat(max(m.width, 1)) / CGFloat(max(m.height, 1))
                let naturalW = min(geo.size.width, geo.size.height * aspect)
                let naturalH = naturalW / aspect
                let naturalOy = (geo.size.height - naturalH) / 2
                // ACR 式：照片每一帧都按当前预览区实时 fit，不冻结尺寸。
                // 拖分隔条时预览区高度平滑变化，照片跟着平滑缩放、始终待在画布内，
                // 既不溢出到信息区，也不会在松手瞬间突然跳变尺寸。
                let fitW = naturalW
                let fitH = naturalH
                let ox = (geo.size.width - fitW) / 2
                let oy = naturalOy
                let scale = store.zoom

                ZStack {
                    ZStack {
                        Image(nsImage: store.baseImage(for: r))
                            .resizable().frame(width: fitW, height: fitH)
                        // 照片相关的叠加层整组门控：主预览还没换成"本张"时一律不画。
                        // 切图那一帧 SwiftUI 已用新 r 算了 body，但 onChange 尚未替换
                        // fullPreview；不门控就会把新框套在旧图上（用户说的"虚晃一下"）。
                        // 对焦点读原始 CR3 较慢，未就绪时也不画空框；读回来后与图一起出现。
                        if store.overlaysReady(for: r.id) {
                            if store.showHeatmap {
                                Image(nsImage: store.heatmapImage(for: r))
                                    .resizable().frame(width: fitW, height: fitH)
                            }
                            if store.showAISubjectBox {
                                ForEach(Array(m.bboxes.enumerated()), id: \.offset) { _, b in
                                    Rectangle().stroke(Color.cyan, lineWidth: 1.5 / scale)
                                        .frame(width: b.width * fitW, height: b.height * fitH)
                                        .position(x: (b.minX + b.width / 2) * fitW,
                                                  y: (1 - b.minY - b.height / 2) * fitH)
                                }
                            }
                            // 相机记录的实际对焦点（红色），来自 RAW MakerNote
                            if store.showAFPoints, let af = store.afCache[r.id] {
                                AFPointsOverlay(points: af.points, fitW: fitW, fitH: fitH, scale: scale)
                            }
                            // 黄框＝人工圈选主体：按照片持久保留；青框 AI 主体独立绘制，不受影响。
                            // 隐藏开关只影响画面显示，圈选记录/判定/评分都还在（2026-11-23）。
                            if store.showManualSubjectBox, let sel = store.selectionRect {
                                Rectangle().stroke(Color.yellow, lineWidth: 1.5 / scale)
                                    .frame(width: sel.width * fitW, height: sel.height * fitH)
                                    .position(x: (sel.minX + sel.width / 2) * fitW,
                                              y: (1 - sel.minY - sel.height / 2) * fitH)
                            }
                        }
                        CompositionGuides(fitW: fitW, fitH: fitH,
                                          thirds: store.showThirds,
                                          diagonals: store.showDiagonals,
                                          scale: scale)
                    }
                    .frame(width: fitW, height: fitH)
                    .scaleEffect(scale, anchor: .center)
                    .offset(x: (0.5 - store.zoomCenter.x) * fitW * scale + store.panOffset.width,
                            y: (store.zoomCenter.y - 0.5) * fitH * scale + store.panOffset.height)

                    // 双层显示链的提示层（显示的始终是本张的图，无"暂显上一张"状态）：
                    // - 原图还没就位（中间层也在途）→ 居中加载提示；
                    // - 中间层已显示、原尺寸仍在解码 → 底部小字提示，不遮挡看图；
                    // - 原尺寸解码失败 → 中间层可用时退化为底部小字，否则居中明确提示。
                    if store.isPreviewFailed(for: r.id) {
                        if store.fullPreview != nil {
                            VStack {
                                Spacer()
                                HStack(spacing: 6) {
                                    Image(systemName: "exclamationmark.triangle")
                                        .font(.caption2)
                                    Text("原尺寸解码失败，当前显示中间分辨率预览；切换照片后重试")
                                        .font(.caption2)
                                }
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.black.opacity(0.65)))
                                .foregroundColor(.white)
                                .padding(.bottom, 10)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .allowsHitTesting(false)
                        } else {
                            VStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle")
                                    .font(.title2).foregroundColor(.orange)
                                Text("原图无法解码").font(.caption).foregroundColor(.secondary)
                                Text("可切换照片后重试").font(.caption2).foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    } else if store.fullPreview == nil {
                        // 中间层与原尺寸都在途（首次进入/缓存缺失，通常零点几秒）。
                        VStack(spacing: 8) {
                            ProgressView().scaleEffect(0.8)
                            Text("正在加载预览…").font(.caption).foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if store.isPreviewLoading(for: r.id) {
                        // 中间层已显示：底部小字提示原尺寸解码中，不遮挡看图。
                        VStack {
                            Spacer()
                            Text("中间分辨率预览显示中，正在解码原尺寸…")
                                .font(.caption2)
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.black.opacity(0.65)))
                                .foregroundColor(.white)
                                .padding(.bottom, 10)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .allowsHitTesting(false)
                    }

                    // 只让这个独立小视图读 dragBox：拖动每帧仅它重绘，
                    // DetailView 的 body（含整张信息区）不跟着鼠标重算。
                    DragBoxOverlay(box: dragBox)
                    ScrollWheelBridge { deltaY, p in
                        // deltaY < 0 = 向下滚 → 放大；deltaY > 0 = 向上滚 → 缩小。
                        // 以光标所在图像点为锚点缩放。
                        if deltaY < 0 {
                            zoomAround(p, factor: 1.18, fitW: fitW, fitH: fitH, ox: ox, oy: oy)
                        } else if deltaY > 0 {
                            zoomAround(p, factor: 1 / 1.18, fitW: fitW, fitH: fitH, ox: ox, oy: oy)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
                    // 右键拖框放大（保留为额外便利方式）
                    RightDragBridge(
                        onStart: { p in
                            dragBox.begin(p, zoom: true)
                            store.dragAction = .zoom
                            store.didDrag = true
                        },
                        onMove: { p in dragBox.current = p },
                        onEnd: { p in
                            if let s = dragBox.start {
                                zoomToSelection(s, p,
                                                fitW: fitW, fitH: fitH, ox: ox, oy: oy)
                            }
                            dragBox.clear()
                            store.dragAction = nil
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                store.didDrag = false
                            }
                        }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
                    // 统一的左键手势：⌘/⌃框选、按住拖动平移、单击复位。
                    LeftMouseBridge(
                        zoomFlag: store.shortcuts.zoom.flag,
                        subjectFlag: store.shortcuts.subject.flag,
                        isSuppressed: { store.isDividerDragging },
                        dividerBegin: {
                            store.isDividerDragging = true
                            return store.dividerValue
                        },
                        dividerIsVertical: { store.infoOnRight },
                        dividerDrag: { next in
                            if store.infoOnRight {
                                store.infoWidth = min(max(next, store.dividerMin),
                                                      store.dividerMax)
                            } else {
                                store.infoHeight = min(max(next, store.dividerMin),
                                                       store.dividerMax)
                            }
                        },
                        dividerEnd: {
                            store.isDividerDragging = false
                        }
                    ) { g in
                        switch g {
                        case .began(let action, let p):
                            store.dragAction = action
                            store.didDrag = true
                            if action == .pan {
                                store.panStart = p
                                store.panBegin = store.panOffset
                                dragBox.clear()
                            } else {
                                dragBox.begin(p, zoom: action == .zoom)
                                store.panStart = nil
                            }
                        case .moved(let p):
                            if store.dragAction == .pan {
                                guard let s = store.panStart else { break }
                                store.panOffset = CGSize(
                                    width: store.panBegin.width + p.x - s.x,
                                    height: store.panBegin.height + p.y - s.y
                                )
                            } else {
                                dragBox.current = p
                            }
                        case .ended(let p):
                            if let action = store.dragAction {
                                if action == .pan {
                                    // 平移已在 moved 完成，无需额外处理。
                                } else if let s = dragBox.start {
                                    let rect = imageRect(s, p, fitW: fitW, fitH: fitH, ox: ox, oy: oy)
                                    if abs(p.x - s.x) > 8, abs(p.y - s.y) > 8 {
                                        if action == .zoom {
                                            zoomToSelection(s, p,
                                                            fitW: fitW, fitH: fitH, ox: ox, oy: oy)
                                        } else {
                                            // 圈选主体：重判这一张 + 让评分参数跟着圈选区走
                                            //（主体清晰度按圈选算、「人工圈选」指标格出格、黄框显示）。
                                            // recheck 内部同时写入 overrideRect（判定）与
                                            // selectionRects（显示/评分），切照片后按 id 恢复。
                                            store.recheck(id: r.id, rect: rect)
                                        }
                                    }
                                }
                            }
                            dragBox.clear()
                            store.panStart = nil
                            store.dragAction = nil
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                store.didDrag = false
                            }
                        case .tap:
                            store.resetZoom()
                        case .doubleTap(let p):
                            zoomAtPoint(p, fitW: fitW, fitH: fitH, ox: ox, oy: oy)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
                }
                .clipped()
                .overlay(alignment: .bottomTrailing) {
                    if store.showAFPoints && store.afLoading.contains(r.id) {
                        HStack(spacing: 6) {
                            ProgressView().scaleEffect(0.7).frame(width: 14, height: 14)
                            Text("读取相机对焦点信息中…")
                        }
                        .font(.caption)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 6)
                            .fill(Color.black.opacity(0.65)))
                        .foregroundColor(.white)
                        .padding(12)
                        .allowsHitTesting(false)
                    }
                }
                // 所有左键手势由 ZStack 内的 LeftMouseBridge 在 AppKit 层统一处理，
                // 这里只保留 contentShape 让透明桥接视图能覆盖整个预览区。
                .contentShape(Rectangle())
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.gray.opacity(0.08))
            }
        }
        .onAppear {
            store.ensureFullPreview(for: r.id)
            store.ensureAF(for: r.id)
        }
        .onChange(of: r.id) { url in
            store.ensureFullPreview(for: url)
            store.ensureAF(for: url)
        }
    }
}

// MARK: - 综合评分区（替换原合焦结论块，主轴已改为主体清晰度）

/// 综合评分面板：建议星级 + 题材（自动/手动）+ 各维度得分条 + 采用建议写入 Bridge 星级。
/// 抽成独立 View 以减小 InfoView.body 的类型检查复杂度。
private struct ScorePanel: View {
    @EnvironmentObject var store: Store
    let r: PhotoResult
    let score: PhotoScore
    /// 右侧竖排窄栏用紧凑布局；默认 false 保持原样。
    var compact = false

    /// 题材选择：auto 表示恢复自动识别，其余为人工覆盖。
    private var genreBinding: Binding<String> {
        Binding(
            get: { score.genreIsGuess ? "auto" : score.genre.rawValue },
            set: { value in
                if value == "auto" { store.setGenre(nil, for: r.id) }
                else { store.setGenre(PhotoGenre(rawValue: value), for: r.id) }
            }
        )
    }

    private var starColor: Color {
        switch score.stars {
        case 5, 4: return .green
        case 3: return .orange
        default: return .red
        }
    }

    private func bar(_ part: ScorePart) -> some View {
        let col: Color = part.score >= 70 ? .green : (part.score >= 40 ? .orange : .red)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(part.name).font(.caption2).foregroundColor(.secondary)
                Spacer()
                Text(part.weight > 0 ? String(format: "%.0f 分 · 占 %.0f%%", part.score, part.weight * 100)
                                     : String(format: "%.0f 分", part.score))
                    .font(.caption2).monospacedDigit().foregroundColor(.secondary)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.gray.opacity(0.18)).frame(height: 5)
                    Capsule().fill(col).frame(width: g.size.width * CGFloat(part.score / 100), height: 5)
                }
            }
            .frame(height: 5)
            .help(part.detail)
        }
    }

    /// 星星 + 综合分
    private var starsBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                ForEach(1...5, id: \.self) { n in
                    Image(systemName: n <= score.stars ? "star.fill" : "star")
                        .foregroundColor(n <= score.stars ? starColor : .gray)
                }
                Text("\(score.stars) 星").font(.headline).foregroundColor(starColor)
            }
            Text("综合 \(Int(score.total.rounded())) 分").font(.caption)
                .foregroundColor(.secondary).monospacedDigit()
        }
    }

    /// 「采用建议」按钮 + 当前星级（紧挨星星行右侧，看完星一眼写入）
    private var adoptBlock: some View {
        HStack(spacing: 8) {
            Button {
                store.setRating(r.id, rating: score.stars)
            } label: {
                Label("采用建议：打 \(score.stars) 星", systemImage: "checkmark.circle")
            }
            .buttonStyle(.borderedProminent).controlSize(.small)
            .help("把建议星级写入 Adobe Bridge 星级评分（xmp:Rating）")
            if store.displayedRating(r.id) != nil {
                Text("当前 \(store.displayedRating(r.id)! == -1 ? "拒绝" : "\(store.displayedRating(r.id)!) 星")")
                    .font(.caption2).foregroundColor(.secondary)
            }
        }
    }


/// 题材选择 + 识别依据
private var genreBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            // 用独立 Text 做「题材」标签：系统 Picker 的 label 在 menu 样式下会
            // 缩进、和上方面板文字对不齐（用户实测）；拆开后整体 HStack 左对齐。
            HStack(spacing: 6) {
                Text("题材").font(.caption2).foregroundColor(.secondary)
                Picker("", selection: genreBinding) {
                    Text("自动识别（\(score.genre.display)）").tag("auto")
                    ForEach(PhotoGenre.allCases) { g in Text(g.display).tag(g.rawValue) }
                }
                .pickerStyle(.menu).frame(width: compact ? 200 : 168, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(score.genreIsGuess ? "自动识别依据：\(genreDisplayText(score.genreReason))"
                                    : "题材已手动指定")
                .font(.caption2).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .help(score.genreIsGuess
                      ? "软件按「\(genreDisplayText(score.genreReason))」判为该题材；不准可在上面手动改"
                      : "你已手动指定题材，评分权重按该题材计算")
            if !store.memory.isEmpty {
                HStack(spacing: 6) {
                    Text("纠正记忆 \(store.memory.count) 条")
                        .font(.caption2).foregroundColor(.secondary)
                    Button("清空") { store.clearGenreMemory() }
                        .font(.caption2).buttonStyle(.borderless)
                        .help("清空所有题材纠正记录，识别回到纯自动规则（清空前可把\n\(GenreMemory.fileURL.path) 备份）")
                }
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if compact {
                    // 右侧窄栏：星星、按钮、题材依次分行，避免挤在一起。
                    VStack(alignment: .leading, spacing: 8) {
                        starsBlock
                        adoptBlock
                        genreBlock
                    }
                } else {
                    HStack(alignment: .center, spacing: 12) {
                        starsBlock
                        adoptBlock
                        Spacer()
                        genreBlock
                    }
                }
            }

            Text(score.headline).font(.callout)

            VStack(alignment: .leading, spacing: 6) {
                // 白平衡/曝光只在人像题材显示（用户要求）：其他题材权重本就为 0，
                // 留着只会占地方、让人误以为参与了评分。
                ForEach(score.parts.filter { score.genre == .portrait || $0.id != "color" }) { p in bar(p) }
            }

            if r.verdict.isSuspect {
                HStack(spacing: 10) {
                    Button(store.excluded.contains(r.id) ? "已排除写入" : "排除写入") {
                        store.toggleExclude(r.id)
                    }
                    .buttonStyle(.borderless).font(.caption)
                    Spacer()
                }
            }

            Text("评分口径：\(score.genre.rule)").font(.caption2).foregroundColor(.secondary)
            ForEach(score.tips, id: \.self) { t in
                Text("· \(t)").font(.caption2).foregroundColor(.secondary)
            }
        }
    }
}

// MARK: - 右下：指标信息

struct InfoView: View {
    @EnvironmentObject var store: Store
    let r: PhotoResult
    /// 右侧竖排窄栏时用紧凑尺寸；默认下方布局保持原样。
    var compact = false
    /// 详细判别依据默认折叠（2026-11-25 用户要求），需要时手动展开。
    @State private var showReasonDetail = false

    private func cell(_ title: String, _ value: String, limit: Int = 1,
                      help: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundColor(.secondary)
            Text(value).font(compact ? .caption : .callout).monospacedDigit()
                .lineLimit(limit).fixedSize(horizontal: false, vertical: limit > 1)
                // 值被 lineLimit 省略时，悬停仍看到完整内容（用户要求）。
                .help(help ?? value)
        }
        .frame(minWidth: compact ? 96 : 120, alignment: .leading)
    }

    /// 通俗命名的指标格：鼠标悬停即时显示大白话解释，标题用指标名（用户要求，
    /// 如悬停「7%」时提示框标题显示「主体清晰度」而不是数值）。
    private func metricCell(_ title: String, _ value: String, _ tip: String) -> some View {
        cell(title, value, help: nil).instantHelp(tip, title: title)
    }

    private func sectionTitle(_ s: String) -> some View {
        Text(s).font(.caption).fontWeight(.medium).foregroundColor(.secondary)
    }

    private func subjectLabel(_ s: String) -> String {
        switch s {
        case "前景主体": return "识别到的画面主体"
        case "人脸检测": return "识别到的人脸"
        case "显著性区域": return "按画面重点区域估计"
        default: return "以画面中心为准"
        }
    }

    /// Bridge 风格评分：5 颗星；已评当前星级时再点该星清零；单独「拒绝」按钮。
    private func ratingBar(_ r: PhotoResult) -> some View {
        let current = store.displayedRating(r.id) ?? 0
        let rejected = current == -1
        return HStack(spacing: 10) {
            Text("评分").font(.caption).foregroundColor(.secondary)
            HStack(spacing: 2) {
                ForEach(1...5, id: \.self) { n in
                    Button {
                        let next = (current == n) ? 0 : n
                        store.setRating(r.id, rating: next)
                    } label: {
                        Image(systemName: (!rejected && current >= n) ? "star.fill" : "star")
                            .foregroundColor((!rejected && current >= n) ? .orange : .secondary)
                    }
                    .buttonStyle(.plain).help("\(n) 星（快捷键 ⌘\(n)）")
                }
                Button {
                    store.setRating(r.id, rating: rejected ? 0 : -1)
                } label: {
                    // 未拒绝＝不显眼的灰色；标记拒绝后才变红底白字（2026-11-23 用户要求）。
                    Text("拒绝").font(.caption)
                        .foregroundColor(rejected ? .white : .secondary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(rejected ? Color.red : Color.clear)
                        .cornerRadius(4)
                }
                .buttonStyle(.plain).help("标记/取消拒绝（Bridge Reject），快捷键 ⌥⌫")
            }
            if let rt = store.displayedRating(r.id) {
                Text(rt == -1 ? "已拒绝" : "\(rt) 星").font(.caption2).foregroundColor(.secondary)
            }
            Spacer()
        }
    }

    var body: some View {
        let m = r.metrics
        let wb = store.wbCache[r.id]
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                // 1) 评分
                ratingBar(r)

                Divider()

                // 2) 拍摄参数
                VStack(alignment: .leading, spacing: 4) {
                    sectionTitle("拍摄参数")
                    if let exif = store.exifCache[r.id] {
                        if !exif.coreLine.isEmpty {
                            Text(exif.coreLine).font(.callout).monospacedDigit()
                        }
                        if compact {
                            // 窄栏规整排版：相机与镜头同一行（镜头长、最多两行不截断）；
                            // 曝光补偿已并入上面核心参数行；拍摄时间整行。
                            HStack(alignment: .top, spacing: 14) {
                                cell("相机", exif.camera ?? "—")
                                cell("镜头", exif.lens ?? "—", limit: 2)
                            }
                            cell("拍摄时间", exif.dateTime ?? "—")
                        } else {
                            HStack(spacing: 16) {
                                cell("相机", exif.camera ?? "—")
                                cell("镜头", exif.lens ?? "—")
                                cell("拍摄时间", exif.dateTime ?? "—")
                            }
                        }
                        if !exif.detailLine.isEmpty {
                            Text(exif.detailLine).font(.caption2).foregroundColor(.secondary)
                        }
                    } else {
                        Text("正在读取拍摄参数…").font(.caption).foregroundColor(.secondary)
                    }
                }

                Divider()

                // 3) 综合评分：建议星级 + 题材 + 各维度
                ScorePanel(r: r, score: store.score(for: r), compact: compact)

                Divider()

                // 3b) 清晰度判定结论 + 判断依据：同一个区域、中间不分割（用户 2026-11-19 要求）
                HStack(spacing: 6) {
                    Image(systemName: r.verdict.isSuspect ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundColor(verdictColor(r.verdict))
                    Text("清晰判定：\(r.verdict.rawValue)").font(.caption)
                        .foregroundColor(verdictColor(r.verdict))
                    Text("· \(r.reason)").font(.caption2).foregroundColor(.secondary)
                        .lineLimit(1).help(r.reason)
                }

                // 4) 判断依据：详细数值默认折叠（2026-11-25 用户要求），
                //    折叠标题给一句提示，展开后仍是说人话 + 悬停看解释。
                VStack(alignment: .leading, spacing: 6) {
                    DisclosureGroup(isExpanded: $showReasonDetail) {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 10)],
                              alignment: .leading, spacing: 8) {
                        metricCell("主体清晰度", String(format: "%.0f%%", m.displaySubjectRatio * 100),
                                   "主体有多清楚，按整张照片最锐利那一块算 100%。越接近 100% 越好。")
                        metricCell("画面中心清晰度", String(format: "%.0f%%", m.displayCenterRatio * 100),
                                   "画面正中央有多清楚，同样按最锐利那一块算 100%。")
                        metricCell("合格线", String(format: "%.0f", store.heatFloor),
                                   "判断整张照片是否整体失焦用的尺子，看的是画面绝大部分区域，不是最锐的那一小块。拍鸟这类主体很小的片子它偏低属正常，以主体清晰度为准。")
                        metricCell("最清楚处", String(format: "%.0f", m.peakBlock),
                                   "整张照片里最锐利那一块的读数，上面几项百分比都拿它当 100% 基准。")
                        metricCell("发虚区域", String(format: "%.0f%%", m.softRatio * 100),
                                   "画面里模糊、没细节的地方占多少。")
                        metricCell("拖影", String(format: "%.2f", m.anisotropy),
                                   "数值越高越像手抖或物体移动留下的拖影，正常约 1 左右。")
                        metricCell("主体虚化", String(format: "%.2f", m.subjectReblur),
                                   "把主体再人为模糊一次，细节掉得越多说明原来越虚。")
                        if let sr = store.selectionDisplayRatio {
                            metricCell("人工圈选", String(format: "%.0f%%", sr * 100),
                                       "人工圈出区域有多清楚，按整张照片最锐利那一块算 100%。")
                        }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text("判断依据").font(.caption).fontWeight(.medium).foregroundColor(.secondary)
                            Text("— 展开看详细判别依据").font(.caption2).foregroundColor(.secondary)
                        }
                    }
                    Text("主体位置：\(subjectLabel(m.subjectSource))")
                        .font(.caption2).foregroundColor(.secondary)
                    if store.selectionRects[r.id] != nil || r.overrideRect != nil {
                        HStack(spacing: 8) {
                            Text("当前按自选主体判定与评分")
                                .font(.caption2).foregroundColor(.secondary)
                            Spacer(minLength: 4)
                            Button(store.showManualSubjectBox ? "隐藏黄框" : "显示黄框") {
                                store.showManualSubjectBox.toggle()
                            }
                            .font(.caption2)
                            .help("只隐藏/显示画面里的黄框，不影响这张照片按自选主体判定与评分")
                            Button("取消自选主体") { store.clearManualSubject(for: r.id) }
                                .font(.caption2)
                                .help("清除这张照片的黄框和圈选，恢复按 AI 自动识别主体判定与评分；其他照片不受影响")
                        }
                    }
                    if let af = store.afCache[r.id] {
                        let rel = Analyzer.afSubjectRelation(m, af: af)
                        // 悬停热区放整行而不是 ⓘ 小图标：图标只有 12pt，很难停准（用户实测不灵敏）
                        HStack(spacing: 5) {
                            Text("对焦点与主体：\(rel.0)")
                                .font(.caption2).foregroundColor(.secondary)
                            Image(systemName: "info.circle")
                                .font(.caption2).foregroundColor(.secondary)
                        }
                        .instantHelp(rel.1)
                    }
                    let miss = FocusMiss.diagnose(m, af: store.afCache[r.id], verdict: r.verdict,
                                                  lens: store.exifCache[r.id]?.lens,
                                                  shutter: store.exifCache[r.id]?.shutterSafety)
                    // 对焦提示区（用户 2026-11-18 规划）：对焦方式 → 主体发虚 → 疑似跑焦等提示。
                    // 「快门偏慢」与「主体发虚」两条黄提示合并成一条：有发虚原因时只显示发虚
                    // （原因里已含快门信息）；主体清楚但快门确实偏慢才单独提示。
                    HStack(spacing: 5) {
                        Text("对焦方式：\(miss.focusMethod)")
                            .font(.caption2).foregroundColor(.secondary)
                            .lineLimit(1)
                        Image(systemName: "info.circle")
                            .font(.caption2).foregroundColor(.secondary)
                    }
                    .instantHelp(miss.focusMethod)
                    if let blur = miss.subjectBlurCause {
                        HStack(spacing: 5) {
                            Text("主体发虚：\(blur.short)").font(.caption2).foregroundColor(.orange)
                            Image(systemName: "info.circle")
                                .font(.caption2).foregroundColor(.secondary)
                        }
                        .instantHelp(blur.detail)
                    } else if let exif = store.exifCache[r.id],
                              let shutter = exif.shutterSafety, shutter.isSlow {
                        HStack(spacing: 5) {
                            Image(systemName: "clock.badge.exclamationmark")
                                .font(.caption2).foregroundColor(.orange)
                            Text("快门偏慢，可能手抖发虚").font(.caption2).foregroundColor(.orange)
                            Image(systemName: "info.circle")
                                .font(.caption2).foregroundColor(.secondary)
                        }
                        .instantHelp(shutter.text)
                    }
                    // 对焦失误提示：只在实际有话说时显示（自动对焦无失误就不出这行）
                    if !miss.short.isEmpty {
                        HStack(spacing: 5) {
                            Text(miss.short)
                                .font(.caption2)
                                .foregroundColor(miss.suspected ? .orange : .secondary)
                            Image(systemName: "info.circle")
                                .font(.caption2).foregroundColor(.secondary)
                        }
                        .instantHelp(miss.detail)
                    }
                }

                Divider()

                // 5) 白平衡 / 曝光参考：仅人像题材显示（用户要求）
                if store.genre(for: r).0 == .portrait {
                VStack(alignment: .leading, spacing: 4) {
                    sectionTitle("白平衡 / 曝光参考")
                    if let wb {
                        if compact {
                            // 窄栏必须换行：HStack 四格 minWidth 96 最少要 432pt，
                            // 人像时多出「人脸偏色」格就会超出窄栏宽度，内容被居中后
                            // 左右各溢出一段，左边直接画到预览区上（用户实测的重叠）。
                            // 改用与「判断依据」一致的自适应网格，放不下自动换行。
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 10)],
                                      alignment: .leading, spacing: 8) {
                                let rr = wb.meanR / max(wb.meanG, 1)
                                let bb = wb.meanB / max(wb.meanG, 1)
                                metricCell("整体偏色 红:蓝", String(format: "%.2f : %.2f  %@",
                                     rr, bb, colorBiasText(r: rr, b: bb)),
                                     "以绿色为 1，红比蓝高偏暖（偏黄），蓝比红高偏冷（偏蓝），接近 1:1 为中性。")
                                if let fr = wb.faceRG, let fb = wb.faceBG {
                                    metricCell("人脸偏色 红:蓝", String(format: "%.2f : %.2f", fr, fb),
                                               "只看人脸区域的红蓝比例，参考肤色是否偏色。")
                                }
                                metricCell("过曝面积", String(format: "%.2f%%", wb.highlightClip * 100),
                                           "亮到没有细节的面积占比，太高说明高光溢出。")
                                metricCell("死黑面积", String(format: "%.2f%%", wb.shadowClip * 100),
                                           "暗到没有细节的面积占比。")
                            }
                        } else {
                            HStack(spacing: 16) {
                                let rr = wb.meanR / max(wb.meanG, 1)
                                let bb = wb.meanB / max(wb.meanG, 1)
                                metricCell("整体偏色 红:蓝", String(format: "%.2f : %.2f  %@",
                                     rr, bb, colorBiasText(r: rr, b: bb)),
                                     "以绿色为 1，红比蓝高偏暖（偏黄），蓝比红高偏冷（偏蓝），接近 1:1 为中性。")
                                if let fr = wb.faceRG, let fb = wb.faceBG {
                                    metricCell("人脸偏色 红:蓝", String(format: "%.2f : %.2f", fr, fb),
                                               "只看人脸区域的红蓝比例，参考肤色是否偏色。")
                                }
                                metricCell("过曝面积", String(format: "%.2f%%", wb.highlightClip * 100),
                                           "亮到没有细节的面积占比，太高说明高光溢出。")
                                metricCell("死黑面积", String(format: "%.2f%%", wb.shadowClip * 100),
                                           "暗到没有细节的面积占比。")
                            }
                        }
                        Text(wb.summary).font(.caption).foregroundColor(.secondary)
                    } else {
                        Text("正在读取白平衡统计…").font(.caption).foregroundColor(.secondary)
                    }
                }
                }

                // 6) 鸟种识别：拍鸟题材显示；另外手动圈主体/改题材后已识别的非鸟
                //    题材照片也显示结果，否则用户手动触发的识别看不到。
                if store.genre(for: r).0 == .bird
                    || store.birdCache[r.id] != nil || store.birdLoading.contains(r.id)
                    || store.birdMessage[r.id] != nil || store.birdUnreliable.contains(r.id) {
                    Divider()
                    BirdSpeciesPanel(r: r, compact: compact)
                }

                Text("灰块 = 该处纹理太少、无法判断。热力图只是相对参考，不是相机的 K 值或测光表。")
                    .font(.caption2).foregroundColor(.secondary)
                Text(r.id.path).font(.caption2).foregroundColor(.secondary)
                    .lineLimit(1).help(r.id.path)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            // 鸟种不在信息区触发：分析阶段已整批识别完，这里只读缓存结果。
            store.ensureWB(for: r.id)
            store.ensureAF(for: r.id)
            store.ensureExif(for: r.id)
            store.ensureFocus(for: r.id, subjectBoxes: r.metrics.bboxes)
            store.ensureHuman(for: r.id)
            store.ensureAI(for: r.id)
            store.ensureRating(for: r.id)
        }
        .onChange(of: r.id) { u in
            store.ensureWB(for: u)
            store.ensureAF(for: u)
            store.ensureExif(for: u)
            if let nr = store.result(for: u) {
                store.ensureFocus(for: u, subjectBoxes: nr.metrics.bboxes)
            } else {
                store.ensureFocus(for: u)
            }
            store.ensureHuman(for: u)
            store.ensureAI(for: u)
            store.ensureRating(for: u)
        }
    }
}

// MARK: - 鸟种识别面板

private struct BirdSpeciesPanel: View {
    @EnvironmentObject var store: Store
    let r: PhotoResult
    var compact: Bool = false

    private var url: URL { r.id }
    private var guess: BirdSpeciesGuess? { store.birdCache[url] }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("鸟种识别").font(.caption).fontWeight(.medium).foregroundColor(.secondary)
                if store.birdLoading.contains(url) { ProgressView().scaleEffect(0.6) }
                Spacer()
            }
            if let g = guess {
                HStack(spacing: 6) {
                    Text(g.chinese).font(.callout).fontWeight(.medium)
                    Text(String(format: "%.0f%%", g.confidence * 100))
                        .font(.caption2).foregroundColor(.secondary)
                    if let src = store.birdSource[url] {
                        Text(src).font(.caption2).foregroundColor(.secondary)
                    }
                    Button {
                        store.clearBirdLabel(for: url)
                    } label: {
                        Image(systemName: "xmark.circle").font(.caption2)
                    }
                    .buttonStyle(.plain).help("清除这张照片的鸟种标签")
                }
                if !g.latin.isEmpty {
                    Text(g.latin).font(.caption2).italic().foregroundColor(.secondary)
                }
                if let t3 = store.birdTop3[url], !t3.isEmpty {
                    Text("候选：\(t3)").font(.caption2).foregroundColor(.secondary).lineLimit(2)
                }
                if let why = store.birdReason[url], !why.isEmpty {
                    Text(why).font(.caption2).foregroundColor(.secondary).lineLimit(2)
                }
            } else if let msg = store.birdMessage[url], !msg.isEmpty {
                Text(msg).font(.caption2).foregroundColor(
                    store.birdLoading.contains(url) ? .secondary : .orange)
            } else if store.birdLoading.contains(url) {
                Text("识别中…").font(.caption2).foregroundColor(.secondary)
            } else if store.birdDismissed.contains(url) {
                Text("已清除鸟种标签，本次打开不再自动识别").font(.caption2).foregroundColor(.secondary)
            } else {
                Text("尚未识别").font(.caption2).foregroundColor(.secondary)
            }

            HStack(spacing: 6) {
                TextField("人工确认鸟种", text: Binding(
                    get: { store.birdConfirm[url] ?? "" },
                    set: { store.birdConfirm[url] = $0 }))
                    .textFieldStyle(.roundedBorder)
                Button("确认") { store.confirmBird(for: url) }
                    .disabled((store.birdConfirm[url] ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text("BioCLIP 2 本地识别，完全离线、不上传照片；结果只作参考，以你放大原图的人工确认为准。确认结果写入 xmp:Label 和根目录的 kingfisher-birds.log。")
                .font(.caption2).foregroundColor(.secondary)
        }
        // 鸟种识别只发生在分析阶段，以及手动圈主体后的单张刷新。
        // 筛选阶段本面板只读 birdCache，不在这里（onAppear/onChange）现算，
        // 避免切到一张还没识别的照片时转圈。
    }
}

// MARK: - 导入后题材选择面板

private struct FolderGenrePromptView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("这个文件夹主要拍什么？").font(.headline)
            Text("选定后再读取历史数据或开始分析；整批按该题材评分，之后仍可在信息区逐张修改。选「自动识别题材」则保持逐张判断。")
                .font(.caption).foregroundColor(.secondary)
            ForEach(FolderGenreChoice.allCases) { c in
                Button {
                    store.applyFolderGenre(c)
                } label: {
                    HStack(spacing: 8) {
                        Text(c.title).font(.callout)
                        Spacer()
                        Text(c.detail).font(.caption2).foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 5).padding(.horizontal, 8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.10)))
                }
                .buttonStyle(.plain)
            }
            Divider()
            Toggle("同时识别鸟种", isOn: $store.birdRecognitionEnabled)
                .font(.caption)
                .help("默认关闭：只在历史日志已有结果时显示鸟名。开启后分析阶段会用本地 BioCLIP 2 逐张识别（几百张会慢一些），识别结果写入元数据和鸟种日志。之后仍可手动圈主体对单张重认。")
            Text("鸟种识别仅对拍鸟题材生效；识别结果只作参考，以放大原图人工确认为准。")
                .font(.caption2).foregroundColor(.secondary)
            HStack {
                Spacer()
                Button("暂不设置") { store.closeGenrePrompt() }
                    .buttonStyle(.borderless).font(.caption)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

// MARK: - 快捷键设置面板

/// 点一下按钮再按实际按键，录制「修饰键 + 字母/符号」的组合；Esc 取消。
private struct ShortcutRecorder: View {
    @Binding var combo: KeyCombo
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            if recording { stop() } else { start() }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: recording ? "keyboard.fill" : "keyboard")
                Text(recording ? "请按按键…" : (combo.key.isEmpty ? "未设置" : combo.display))
                    .monospacedDigit()
            }
            .frame(minWidth: 96)
        }
        .buttonStyle(.bordered)
        .help("点这里后按下你要的按键（可同时按 ⌘/⌃/⌥/⇧）；按 Esc 取消录制")
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == 53 || e.keyCode == 36 || e.keyCode == 76 {   // Esc/回车：取消，避免误触「完成」
                DispatchQueue.main.async { self.stop() }
                return nil
            }
            guard let ch = e.characters?.first, !ch.isWhitespace else { return e }
            let raw = String(ch)
            guard raw.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 }) else { return e }
            let mods = ModifierKey.allCases.filter { e.modifierFlags.contains($0.flag) }
            let captured = KeyCombo(raw, mods)
            DispatchQueue.main.async {
                self.combo = captured
                self.stop()
            }
            return nil
        }
    }
    private func stop() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        recording = false
    }
}

struct ShortcutsView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss

    private func comboBinding(for item: OverlayItem) -> Binding<KeyCombo> {
        Binding(get: { store.shortcuts.combo(for: item) },
                set: { store.shortcuts.setCombo($0, for: item) })
    }

    /// 查重：同一个组合被分给两个动作时后按的那个不会触发，提示用户改掉。
    private var conflicts: [String] {
        var seen: [KeyCombo: String] = [:]
        var found: [String] = []
        for entry in store.shortcuts.allCombos {
            if let previous = seen[entry.combo] {
                found.append("「\(previous)」和「\(entry.name)」都是 \(entry.combo.display)")
            } else {
                seen[entry.combo] = entry.name
            }
        }
        return found
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("快捷键设置").font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("上半部分是鼠标手势的修饰键；下面是画面辅助项的按键。点右侧按钮后直接按你要的键（可带 ⌘/⌃/⌥/⇧），按 Esc 取消。修改后立即生效并保存在本机。中文输入法下 ⌘、 与 ⌘/ 等效。")
                        .font(.caption).foregroundColor(.secondary)

                    HStack(spacing: 12) {
                        Text("框选放大").frame(width: 100, alignment: .leading)
                        Picker("", selection: $store.shortcuts.zoom) {
                            ForEach(ModifierKey.allCases) { k in Text(k.label).tag(k) }
                        }
                        .pickerStyle(.menu).frame(width: 140)
                        Text("按住此键 + 左键拖框，放大选中的区域")
                            .font(.caption2).foregroundColor(.secondary)
                    }
                    HStack(spacing: 12) {
                        Text("圈选主体").frame(width: 100, alignment: .leading)
                        Picker("", selection: $store.shortcuts.subject) {
                            ForEach(ModifierKey.allCases) { k in Text(k.label).tag(k) }
                        }
                        .pickerStyle(.menu).frame(width: 140)
                        Text("按住此键 + 左键拖框，按圈选范围重判这一张")
                            .font(.caption2).foregroundColor(.secondary)
                    }

                    Divider()
                    Text("画面辅助项（显示 / 隐藏）").font(.subheadline.weight(.medium))
                    ForEach(OverlayItem.allCases) { item in
                        HStack(spacing: 12) {
                            Text(item.label).frame(width: 100, alignment: .leading)
                            ShortcutRecorder(combo: comboBinding(for: item))
                            Text(item == .aiBox ? "AI 自动识别的主体框（青蓝色）"
                                 : item == .manualBox ? "你手动圈选的主体框（黄色）"
                                 : "只管画面显示，不影响判定与评分")
                                .font(.caption2).foregroundColor(.secondary)
                        }
                    }
                    HStack(spacing: 12) {
                        Text("一键隐藏/恢复").frame(width: 100, alignment: .leading)
                        ShortcutRecorder(combo: $store.shortcuts.overlayToggle)
                        Text("隐藏当前勾选的辅助项，再按一次恢复原来的勾选")
                            .font(.caption2).foregroundColor(.secondary)
                    }

                    if store.shortcuts.zoom == store.shortcuts.subject {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                            Text("两个手势用了同一个修饰键，圈选主体将无法触发。请选择不同的键。")
                                .font(.caption).foregroundColor(.orange)
                        }
                    }
                    ForEach(conflicts, id: \.self) { text in
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                            Text("\(text)，请改掉其中一个。")
                                .font(.caption).foregroundColor(.orange)
                        }
                    }
                    if store.shortcuts.subject == .control {
                        Text("提示：若系统开启了「Control + 点击 = 右键」，⌃+左键会被系统拦截。此时请把圈选主体改成 ⌥ Option 或 ⇧ Shift，或在系统设置里关闭该辅助点按。")
                            .font(.caption2).foregroundColor(.secondary)
                    }
                    Text("请避开系统/本软件已占用的组合：⌘1-5 评星、⌘0 取消星级/拒绝、⌘⌫ 删除、⌘Z 撤销、↑/↓ 切图。")
                        .font(.caption2).foregroundColor(.secondary)
                }
            }
            .frame(maxHeight: 480)

            HStack {
                Spacer()
                Button("恢复默认") {
                    store.shortcuts = ShortcutSettings()
                    store.shortcuts.save()
                }
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 620)
        .onChange(of: store.shortcuts) { _ in store.shortcuts.save() }
    }
}

// MARK: - 主界面：左目录 / 右上预览 / 右下信息

struct ContentView: View {
    @EnvironmentObject var store: Store
    @State private var shortcutMonitor: Any?

    /// 预览窗格：选中照片时是 DetailView，否则是空态提示。两种布局共用。
    @ViewBuilder
    private var previewPane: some View {
        if let id = store.selected,
           let r = store.result(for: id) {
            DetailView(r: r, compact: store.infoOnRight)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 44)).foregroundColor(.secondary)
                Text("拖入照片文件夹即可开始筛选")
                    .foregroundColor(.secondary)
                Text("RAW 原片不会被修改，只生成同名 .xmp 侧车")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
    }

    /// 信息窗格：compact=true 时元素紧凑排列（用于右侧竖排窄栏）。
    @ViewBuilder
    private func infoPane(compact: Bool) -> some View {
        if let id = store.selected,
           let r = store.result(for: id) {
            InfoView(r: r, compact: compact)
        } else {
            Text("选中照片后显示清晰度、白平衡等信息")
                .foregroundColor(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var screeningPane: some View {
    HSplitView {
        VStack(spacing: 0) {
            VStack(spacing: 4) {
                HStack {
                    Toggle("只看需留意", isOn: $store.onlySuspect)
                    Spacer()
                    Text("\(store.shown.count) / \(store.results.count) 张").font(.caption).foregroundColor(.secondary)
                }
                HStack {
                    Picker("人工评级", selection: $store.ratingFilter) {
                        Text("全部评级").tag(Int?.none)
                        Text("未评级").tag(Int?.some(0))
                        Text("已拒绝").tag(Int?.some(-1))
                        ForEach(1...5, id: \.self) { Text("\($0) 星").tag(Optional($0)) }
                    }.labelsHidden()
                    Toggle("评后前进", isOn: $store.advanceAfterRating)
                }
                // 预览图大小档位：−/+ 直接改缩略图 frame，行高自动联动；
                // 无动画，不影响 ⇧ 多选与滚动逻辑，档位持久化到 UserDefaults。
                HStack(spacing: 6) {
                    Text("预览图").font(.caption2).foregroundColor(.secondary)
                    Spacer()
                    Button {
                        store.stepThumbnailScale(-1)
                    } label: {
                        Image(systemName: "minus").font(.caption2)
                    }
                    .buttonStyle(.plain).frame(width: 20, height: 18)
                    .disabled(store.thumbnailScale == .small)
                    .help("缩小列表预览图与行高")
                    Text("\(store.thumbnailScale.percent)%")
                        .font(.caption2).foregroundColor(.secondary)
                        .monospacedDigit()
                    Button {
                        store.stepThumbnailScale(1)
                    } label: {
                        Image(systemName: "plus").font(.caption2)
                    }
                    .buttonStyle(.plain).frame(width: 20, height: 18)
                    .disabled(store.thumbnailScale == .huge)
                    .help("放大列表预览图与行高")
                }
            }.padding(8)
            // 目录跟随当前预览滚动：方向键切图/圈选跳下一张时，左侧自动滚到那张。
            ScrollViewReader { proxy in
                List(selection: $store.selections) {
                    ForEach(store.shown) { r in
                        ResultRow(r: r).tag(r.id).id(r.id)
                            .contextMenu {
                                Button("在访达中显示") {
                                    NSWorkspace.shared.activateFileViewerSelecting([r.id])
                                }
                                Button("打开所在文件夹") {
                                    NSWorkspace.shared.open(r.id.deletingLastPathComponent())
                                }
                                Button("删除（移到废纸篓）") {
                                    store.deleteURLs = [r.id]
                                    store.confirmDelete = true
                                }
                            }
                    }
                }
                // 只写非 @Published 的可视高度，供 Shift 边缘滚动换算半屏行数；
                // PreferenceKey 不触发布局反馈循环。
                .background(GeometryReader { listGeo in
                    Color.clear.preference(key: ListViewportHeightKey.self,
                                           value: listGeo.size.height)
                })
                .onPreferenceChange(ListViewportHeightKey.self) { h in
                    store.listViewportHeight = h
                }
                .onChange(of: store.selected) { id in
                    guard let id, store.shownContains(id) else { return }
                    // Shift 区间多选：只有选中到可视边缘才滚动（露出下方/上方
                    // 几张隐藏照片），未到边缘列表完全不动；防抖在 store 内部。
                    if store.pendingShiftEdgeScroll {
                        store.pendingShiftEdgeScroll = false
                        if let edge = store.shiftEdgeScrollTarget(for: id) {
                            // 无动画（1458 行列表动画重排是既有卡顿源，约定保持）。
                            proxy.scrollTo(edge.target, anchor: edge.anchor)
                        }
                        return
                    }
                    // 非 Shift 切图：保持现状——不做 withAnimation；anchor=nil
                    // 只在行不可见时最小滚动，可见则列表不动（2026-11-24 修复）。
                    proxy.scrollTo(id)
                }
            }
        }
        .frame(minWidth: 90, idealWidth: 100, maxWidth: 240)
        .frame(maxHeight: .infinity)

        // 右侧区域两种布局：
        // - 默认（infoOnRight=true）：预览占左、信息区竖排在最右，宽度可拖并记住；
        // - infoOnRight=false：预览在上、信息区在下、可拖分隔条 —— 原布局。
        Group {
            if store.infoOnRight {
                // 宽度完全由 store.infoWidth 驱动（与下方布局的 infoHeight 同模式）：
                // 拖动分隔条改变宽度，批内记住；预览区吃剩余宽度。
                GeometryReader { region in
                    let totalW = region.size.width
                    let dividerW: CGFloat = 8
                    let minLeft: CGFloat = 420
                    let minRight: CGFloat = 260
                    let maxRight = max(minRight, totalW - dividerW - minLeft)
                    let rightW = min(max(store.infoWidth, minRight), maxRight)
                    let leftW = max(minLeft, totalW - dividerW - rightW)
                    // 每帧把分隔条几何交给左键桥接（非 @Published，不触发重算）。
                    let _ = store.setDividerContext(axis: .width, value: rightW,
                                                    min: minRight, max: maxRight)
                    HStack(spacing: 0) {
                        previewPane
                            .frame(width: leftW)
                            .frame(maxHeight: .infinity)

                        // 垂直分隔条仅作视觉；拖动由 DetailView 内的左键桥接统一处理。
                        Rectangle()
                            .fill(Color.gray.opacity(0.28))
                            .frame(width: dividerW)
                            .frame(maxHeight: .infinity)
                            .onHover { hovering in
                                if hovering { NSCursor.resizeLeftRight.push() }
                                else { NSCursor.resizeLeftRight.pop() }
                            }

                        infoPane(compact: true)
                            .frame(width: rightW)
                            .frame(maxHeight: .infinity)
                            // 保险：任何将来超宽的内容都不许画到分隔条/预览区上。
                            .clipped()
                    }
                }
            } else {
                // 预览区弹性 + 信息区固定高度 + 可拖动分隔条。
                // 高度完全由 store.infoHeight 驱动：导入新素材时重置为默认值（显示到清晰度判定），
                // 同序列内切照片/重算不动它 → 用户调好的比例一直保持。
                GeometryReader { region in
                    let totalH = region.size.height
                    let dividerH: CGFloat = 8
                    let minTop: CGFloat = 200
                    let minBottom: CGFloat = 170
                    let maxBottom = max(minBottom, totalH - dividerH - minTop)
                    let bottomH = min(max(store.infoHeight, minBottom), maxBottom)
                    let topH = max(minTop, totalH - dividerH - bottomH)
                    // 每帧把分隔条几何交给左键桥接（非 @Published，不触发重算）。
                    // 分隔条拖动已改由 AppKit 绝对坐标处理，不再用 SwiftUI DragGesture。
                    let _ = store.setDividerContext(axis: .height, value: bottomH,
                                                    min: minBottom, max: maxBottom)
                    VStack(spacing: 0) {
                        previewPane
                            .frame(height: topH)
                            .frame(maxWidth: .infinity)

                        // 分隔条仅作视觉；拖动由 DetailView 内的左键桥接统一处理。
                        Rectangle()
                            .fill(Color.gray.opacity(0.28))
                            .frame(height: dividerH)
                            .frame(maxWidth: .infinity)
                            .onHover { hovering in
                                if hovering { NSCursor.resizeUpDown.push() }
                                else { NSCursor.resizeUpDown.pop() }
                            }

                        infoPane(compact: false)
                            .frame(height: bottomH)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .frame(minWidth: 480, idealWidth: 820, maxWidth: .infinity)
        .frame(maxHeight: .infinity)
    }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Kingfisher-PhotoSelector").font(.title3).fontWeight(.medium)
                    Text("RAW · 锐度热力图 · 主体清晰度辅助 · 白平衡参考 · Bridge 元数据")
                        .font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                Button(store.infoOnRight ? "信息区：右侧" : "信息区：下方") {
                    store.infoOnRight.toggle()
                }
                .font(.caption)
                .help("切换信息区位置：默认在预览下方；点一下竖排到画面最右侧")
                Button("快捷键") { store.showShortcuts = true }.font(.caption)
                Button("选择文件夹") { pickFolder() }.disabled(store.processing)
                Button("重新分析") {
                    if let f = store.currentFolder { store.scan(folder: f, forceReload: true) }
                }
                .disabled(store.currentFolder == nil || store.processing)
                .help("忽略历史判定，把这个文件夹的全部照片重新分析一遍（会话缓存会被覆盖）")
                .onAppear {
                    // UILOAD 调试入口：启动后自动载入指定目录（仅开发期，trigger 文件触发）。
                    if let dir = KingfisherPhotoSelectorApp.pendingLoad {
                        KingfisherPhotoSelectorApp.pendingLoad = nil
                        store.onlySuspect = false   // 调试复现用：显示全部，不被过滤清空
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            store.scan(folder: URL(fileURLWithPath: dir))
                        }
                    }
                }
                Button("导出 CSV 报告") { store.exportCSV() }
                    .disabled(store.results.isEmpty || store.processing || store.historyReading)
                Button("鸟种记录") { store.exportBirdLog() }
                    .font(.caption)
                    .help("导出照片根目录的 kingfisher-birds.log 为 CSV，含根目录绝对路径与来源")
                if store.devMode {
                    Button("导出调试 CSV") { store.exportDebugCSV() }
                        .disabled(store.results.isEmpty || store.processing || store.historyReading)
                        .help("开发模式：导出全部中间参数（清晰度判定依据、各维度分数、对焦点语义标签、题材判定链），用于对照真值调阈值。设置环境变量 KINGFISHER_DEV=1 才显示。")
                }
            }.padding(12)

            Divider()

            if store.processing || store.historyReading {
                VStack(spacing: 12) {
                    Text(store.historyReading ? "正在读取历史日志" : store.sessionPhase)
                        .font(.headline)
                    if store.historyReading {
                        ProgressView()
                    } else {
                        ProgressView(value: Double(store.done), total: Double(max(store.total, 1)))
                            .frame(width: 260)
                        Text("\(store.done) / \(store.total) 张")
                            .monospacedDigit().foregroundColor(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                screeningPane

            }

            Divider()

            HStack(spacing: 14) {
                Text("灵敏度").font(.caption)
                Picker("", selection: $store.sensitivity) {
                    Text("严格").tag(1.8)
                    Text("标准").tag(1.0)
                    Text("宽松").tag(0.6)
                }
                .pickerStyle(.segmented).frame(width: 200)
                .onChange(of: store.sensitivity) { _ in store.recompute() }

                Divider().frame(height: 18)
                Button("设清晰基准") { pickAnchor() }.font(.caption)
                Text(store.anchorName).font(.caption2).foregroundColor(.secondary)
                if store.anchorHi != nil {
                    Button("恢复批次") { store.clearAnchor() }.font(.caption2)
                }

                Toggle("写入判定标签", isOn: $store.addColorLabel)
                    .help("""
                    开启后，「写入 Bridge 元数据」把判定词直接写入每张照片的 xmp:Label 字段：
                    主体清晰 / 焦点正常 / 整片偏软 / 景深不足 / 主体偏软 / 主体拖影。
                    在 Bridge「偏好设置 → 标签」里把 5 个标签名改成对应判定词后，Bridge 会按词显示颜色并可按名筛选；
                    未改设置或对不上的词显示白标。照片已有的标签不会被覆盖。本软件不再写任何关键词。
                    """)
                Toggle("导入时自动写说明", isOn: $store.autoWriteDescription)
                    .help("""
                    导入/读取文件夹时一次性把每张的评星依据、清晰度判定写入其元数据「说明」字段
                    （只动说明，其他元数据一律不碰）。改为导入时批量写，选片切照片时不再落盘，减少卡顿。
                    用「清除本软件标记」前建议先关掉这个开关，否则下次导入会把说明重新写回去。
                    """)
                Spacer()
                Button("写入 Bridge 元数据 (\(store.writableTargets.count))") { store.confirmWrite = true }
                    .disabled(store.writableTargets.isEmpty || store.processing)
                Button("清除本软件标记 (\(store.writableTargets.count))") { store.confirmCleanup = true }
                    .disabled(store.writableTargets.isEmpty || store.processing)
                Button("删除所选 (\(store.deleteTargets.count))") {
                    store.deleteURLs = store.deleteTargets
                    store.confirmDelete = !store.deleteURLs.isEmpty
                }
                .disabled(store.deleteTargets.isEmpty || store.processing)
                .foregroundColor(.red)
                .keyboardShortcut(.delete, modifiers: .command)
            }.padding(10).disabled(store.processing || store.historyReading)

            HStack {
                Text(store.status).font(.caption).foregroundColor(.secondary).lineLimit(2)
                Spacer()
                // ⌘Z：撤销最近一次删除（隐藏按钮只承载快捷键，从废纸篓原样搬回）
                Button { store.undoDelete() } label: { EmptyView() }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(store.processing || store.historyReading)
                if !store.backupDirs.isEmpty {
                    Button("打开写入前备份") {
                        // 备份就在照片所在目录：优先打开当前选中照片的文件夹。
                        let target: String?
                        if let sel = store.selected,
                           store.backupDirs.contains(sel.deletingLastPathComponent().path) {
                            target = sel.deletingLastPathComponent().path
                        } else {
                            target = store.backupDirs.first
                        }
                        if let t = target { NSWorkspace.shared.open(URL(fileURLWithPath: t)) }
                    }.font(.caption)
                }
            }.padding(.horizontal, 12).padding(.bottom, 8)
        }
        .frame(minWidth: 1020, minHeight: 680)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(store.dropTarget ? Color.accentColor : Color.clear, lineWidth: 3)
                .padding(3)
        )
        .onDrop(of: [.fileURL], isTargeted: $store.dropTarget) { providers in
            guard !store.processing else { return false }
            handleDrop(providers)
            return true
        }
        .alert("写入 Bridge 元数据", isPresented: $store.confirmWrite) {
            Button("取消", role: .cancel) { }
            Button("确认写入") { store.writeMetadata() }
        } message: {
            Text("""
            将对 \(store.writableTargets.count) 张照片把判定原因写入 IPTC Core 的说明与 Instructions 字段，并把判定词（主体清晰/焦点正常/整片偏软/景深不足/主体偏软/主体拖影）直接写入 xmp:Label 标签字段。本软件不再写任何关键词。

            已有的关键词、说明、标签、星级都会被保留（照片已有标签时不覆盖）。RAW 只生成同名 .xmp 侧车，不改动原片。写入前的元数据会备份到照片所在目录（已有备份时不覆盖）。
            """)
        }
        .alert("清除本软件写入的标记", isPresented: $store.confirmCleanup) {
            Button("取消", role: .cancel) { }
            Button("确认清除") { store.cleanupMetadata() }
        } message: {
            Text("""
            将对 \(store.writableTargets.count) 张照片清除本软件写入的内容：说明与 Instructions 里的「[Kingfisher-PhotoSelector]」「[合焦质检]」段、本软件写的判定词标签（含旧版英文颜色标签）。写入前的元数据同样先备份到照片所在目录。

            你自己的说明、关键词、星级、拒绝标记、手动打的标签全部不会动。注意：清除后如果「切换时自动写说明」还开着，切照片时会重新写入说明。
            """)
        }
        .alert("删除照片", isPresented: $store.confirmDelete) {
            Button("取消", role: .cancel) { store.deleteURLs = [] }
            Button("移到废纸篓", role: .destructive) {
                let targets = store.deleteURLs
                store.deleteURLs = []
                guard !targets.isEmpty else { return }
                // 用户 2026-11-23 要求：回车直接确认。删除走后台，避免界面冻结。
                store.status = "正在移到废纸篓…"
                store.deletePhotos(targets) { msg in store.status = msg }
            }
            // 回车 = 默认按钮「移到废纸篓」（用户 2026-11-23 要求），Esc = 取消。
            .keyboardShortcut(.defaultAction)
        } message: {
            if store.deleteURLs.count == 1, let u = store.deleteURLs.first {
                let jpg = store.siblingJPG(for: u)
                Text("""
                将把 \(u.lastPathComponent) 移到废纸篓\(jpg == nil ? "" : "，以及同名的 \(jpg!.lastPathComponent)")。

                文件会进入废纸篓，确认后可用 ⌘Z 撤销（自动从废纸篓搬回并恢复到列表）。确认继续？
                """)
            } else {
                Text("""
                将把 \(store.deleteURLs.count) 张照片（连同各自同名 JPG）一起移到废纸篓。

                文件会进入废纸篓，确认后可用 ⌘Z 撤销最近一次。确认继续？
                """)
            }
        }
        // 退出软件前把最近一次已编码的判定快照落盘（绝不在 willTerminate 里现编码
        // 845 张 v2 JSON——那是"退出时卡死"的直接原因）。
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.willTerminateNotification)) { _ in
            store.saveSessionOnExit()
        }
        .sheet(isPresented: $store.showShortcuts) {
            ShortcutsView().environmentObject(store)
        }
        .sheet(isPresented: $store.showGenrePrompt) {
            FolderGenrePromptView().environmentObject(store)
        }
        // ↑/↓ 切换照片 + 辅助项快捷键：统一用本地事件监听，保证焦点在预览或列表都生效。
        // 输入框里打字、弹窗/面板打开时不拦截，避免抢走系统正常的方向键行为。
        .onAppear {
            // 软件一启动就后台预热鸟种模型（低优先级）：用户导入文件夹、翻照片的
            // 这几秒正好把模型读进内存，点开第一张鸟片就不用再等 5～6 秒。
            if store.birdRecognitionEnabled { store.prewarmBirdModel() }
            guard shortcutMonitor == nil else { return }
            shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
                guard NSApp.modalWindow == nil, e.window === NSApp.mainWindow else { return e }
                guard !store.processing, !store.historyReading else { return e }
                if let fr = NSApp.keyWindow?.firstResponder, fr is NSText { return e }
                let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
                // 125=↓ 126=↑。单独 Shift 时扩展多选区间，预览跟着走；
                // 其他修饰键（⌘/⌥/⌃）不拦，留给评星等快捷键或系统。
                if (mods.isEmpty || mods == .shift), e.keyCode == 125 || e.keyCode == 126 {
                    store.moveSelection(by: e.keyCode == 125 ? 1 : -1, shift: mods == .shift)
                    return nil
                }
                for item in OverlayItem.allCases {
                    if store.shortcuts.combo(for: item).matches(e) {
                        store.toggleOverlay(item)
                        return nil
                    }
                }
                if store.shortcuts.overlayToggle.matches(e) {
                    store.toggleAllOverlays()
                    return nil
                }
                // 评星快捷键统一在这里处理：按钮内嵌 .keyboardShortcut 在滚动信息区里
                // 不稳定（用户反馈按完星级不刷新），且会顺带渲染出一个灰色空按钮。
                if let id = store.selected {
                    if mods == .command {
                        // 键码经系统实测：1=18 2=19 3=20 4=21 5=23 0=29
                        // （原先写成 22:5、27:0，22 其实是 4、27 其实是 -，导致 ⌘5 无效、⌘0 要按 ⌘- 才触发）。
                        let starKeys: [UInt16: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5]
                        if let n = starKeys[e.keyCode] {
                            let current = store.displayedRating(id) ?? 0
                            store.setRating(id, rating: current == n ? 0 : n)
                            return nil
                        }
                        if e.keyCode == 29 {   // ⌘0 取消星级/拒绝
                            store.setRating(id, rating: 0)
                            return nil
                        }
                    }
                    if mods == .option, e.keyCode == 51 || e.keyCode == 117 {   // ⌥⌫ / ⌥Del 拒绝
                        let rejected = (store.displayedRating(id) ?? 0) == -1
                        store.setRating(id, rating: rejected ? 0 : -1)
                        return nil
                    }
                }
                return e
            }
        }
        .onDisappear {
            if let m = shortcutMonitor {
                NSEvent.removeMonitor(m)
                shortcutMonitor = nil
            }
        }
    }

    private func pickFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.allowsMultipleSelection = false
        p.message = "选择要筛选的照片文件夹（含子文件夹）"
        if p.runModal() == .OK, let u = p.url { store.scan(folder: u) }
    }

    private func pickAnchor() {
        let p = NSOpenPanel()
        p.canChooseDirectories = false
        p.canChooseFiles = true
        p.allowsMultipleSelection = false
        p.allowedContentTypes = [.image]
        p.message = "选一张你确认清晰的照片，作为热力图和判定的固定基准"
        if p.runModal() == .OK, let u = p.url { store.setAnchor(u) }
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        var urls: [URL] = []
        let group = DispatchGroup()
        for p in providers {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { u, _ in
                if let u { urls.append(u) }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            guard let first = urls.first else { return }
            var isDir: ObjCBool = false
            if urls.count == 1,
               FileManager.default.fileExists(atPath: first.path, isDirectory: &isDir),
               isDir.boolValue {
                store.scan(folder: first)
            } else {
                store.scan(files: urls)
            }
        }
    }
}

@main
struct KingfisherPhotoSelectorApp: App {
    @StateObject private var store = Store()

    init() {
        // 隐藏的复核模式：--genreprobe <目录>，或 /tmp/genreprobe_trigger.txt
        // （内容为目录路径）。在 App 进程里跑（继承 App 对素材文件夹的读取权限），
        // 打印主体框 / 对焦点语义 / 最终题材到 /tmp/genreprobe_out.txt，仅开发期使用。
        // trigger 文件以 "UILOAD " 开头则不跑探针，改为启动后自动载入该目录到界面。
        var probeDir: String? = nil
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--genreprobe"), i + 1 < args.count {
            probeDir = args[i + 1]
        } else if let t = try? String(contentsOfFile: "/tmp/genreprobe_trigger.txt",
                                      encoding: .utf8) {
            let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("UILOAD ") {
                Self.pendingLoad = String(trimmed.dropFirst("UILOAD ".count))
                try? FileManager.default.removeItem(atPath: "/tmp/genreprobe_trigger.txt")
            } else if trimmed.hasPrefix("SCOREPROBE ") {
                Self.runScoreProbe(dir: String(trimmed.dropFirst("SCOREPROBE ".count)))
                try? FileManager.default.removeItem(atPath: "/tmp/genreprobe_trigger.txt")
                exit(0)
            } else {
                probeDir = trimmed
                try? FileManager.default.removeItem(atPath: "/tmp/genreprobe_trigger.txt")
            }
        }
        if let dir = probeDir, !dir.isEmpty {
            Self.runGenreProbe(dir: dir)
            exit(0)
        }

        // 软件更名数据迁移：FocusScreener → PhotoSelector → Kingfisher-PhotoSelector。
        // 一次性把旧数据目录整体搬过来（题材纠正记忆、元数据备份），
        // 老用户的纠正记忆不丢。新目录已存在则不动（可能已有新数据）。
        Self.migrateLegacySupportDir()
    }

    /// 旧 App Support 目录迁移（按从新到旧的顺序找）：
    /// ~/Library/Application Support/{PhotoSelector|FocusScreener}
    /// → ~/Library/Application Support/Kingfisher-PhotoSelector
    private static func migrateLegacySupportDir() {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let newDir = support.appendingPathComponent("Kingfisher-PhotoSelector", isDirectory: true)
        guard !fm.fileExists(atPath: newDir.path) else { return }
        for name in ["PhotoSelector", "FocusScreener"] {
            let oldDir = support.appendingPathComponent(name, isDirectory: true)
            guard fm.fileExists(atPath: oldDir.path) else { continue }
            try? fm.createDirectory(at: support, withIntermediateDirectories: true)
            do {
                try fm.moveItem(at: oldDir, to: newDir)
            } catch {
                // 搬不动就留着旧目录，不阻塞启动；纠正记忆读不到时按空处理。
            }
            return
        }
    }

    /// UILOAD 调试入口：启动后自动载入该目录（仅 /tmp/genreprobe_trigger.txt 触发）。
    static var pendingLoad: String? = nil

    /// 50 张真值回归（Tests/score_probe_real.swift 的 App 进程版——终端没有
    /// 「下载」文件夹权限，真值样本在下载目录里只能由 App 进程读）。
    /// 真值 CSV 固定 /tmp/scoreprobe/truth.csv（文件名,人工真值 两列）。
    /// trigger 写 "SCOREPROBE <照片目录>"，输出 /tmp/scoreprobe_out.txt。
    static func runScoreProbe(dir: String) {
        var out = "文件名,人工真值,题材,建议星级,总分,主体清晰度,整体锐度,对焦,白平衡,判定\n"
        var starGood = 0, goodCount = 0, starBad = 0, badCount = 0
        func flush() {
            var all = out
            all += "\n好片 \(goodCount) 张：\(starGood) 张评 3 星以上；废片 \(badCount) 张：\(starBad) 张评 2 星以下\n"
            try? all.write(toFile: "/tmp/scoreprobe_out.txt", atomically: true, encoding: .utf8)
        }
        defer { flush() }
        // 先落一个头——即便中途出问题也能看出探针启动过。
        flush()
        guard let truthText = try? String(contentsOfFile: "/tmp/scoreprobe/truth.csv",
                                          encoding: .utf8) else {
            out += "真值 CSV 读取失败：/tmp/scoreprobe/truth.csv\n"
            return
        }
        var truth: [String: String] = [:]
        for row in truthText.split(separator: "\n").dropFirst() {
            let cols = String(row).split(separator: ",", omittingEmptySubsequences: false)
            if cols.count >= 2 {
                truth[String(cols[0]).trimmingCharacters(in: .whitespaces)] =
                    String(cols[1]).trimmingCharacters(in: .whitespaces)
            }
        }
        let fm = FileManager.default
        let files = ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).filter {
            MetadataWriter.rawExts.contains(($0 as NSString).pathExtension.lowercased())
        }.sorted()
        if files.isEmpty {
            out += "目录无 RAW 文件或不可读：\(dir)\n"
            return
        }
        for f in files {
            let url = URL(fileURLWithPath: (dir as NSString).appendingPathComponent(f))
            guard let m = Analyzer.analyze(url) else { continue }
            let hiMin = Analyzer.independentThreshold()
            let (v, _) = Analyzer.classify(m, hiMin: hiMin)
            let r = PhotoResult(id: url, metrics: m, verdict: v, reason: "")
            let wb = WhiteBalance.analyze(url)
            let af = AFReader.read(url)
            let exif = ExifInfo.read(url)
            let focus = FocusSemanticsEngine.detect(url: url, subjectBoxes: m.bboxes)
            let human = HumanPresenceEngine.detect(url: url)
            let (genre, genreWhy) = ScoreEngine.guessGenre(m: m, af: af, wb: wb,
                                                           exif: exif, focus: focus,
                                                           human: human)
            let s = ScoreEngine.score(r, af: af, wb: wb, exif: exif, genre: genre,
                                      genreIsGuess: true, genreReason: genreWhy,
                                      focus: focus)
            func part(_ id: String) -> String {
                s.parts.first { $0.id == id }.map { String(Int($0.score)) } ?? "-"
            }
            let name = (f as NSString).deletingPathExtension
            let t = truth[f] ?? truth[name] ?? "?"
            out += "\(f),\(t),\(genre.rawValue),\(s.stars),\(Int(s.total.rounded()))," +
                   "\(part("clarity")),\(part("overall")),\(part("focus"))," +
                   "\(part("color")),\(v.rawValue),\(genreWhy)\n"
            if t.contains("废") { badCount += 1; if s.stars <= 2 { starBad += 1 } }
            else if t.contains("好") { goodCount += 1; if s.stars >= 3 { starGood += 1 } }
            flush()
        }
        print(out)
    }

    /// 回归探针：递归扫描目录，按路径真值核对题材与星级。
    /// 真值取自路径成分：题材=拍鸟/风光/人像；好坏=好片/废片（好片应 ≥3 星，废片应 ≤2 星）。
    /// 输出 /tmp/genreprobe_out.txt。仅开发期使用。
    static func runGenreProbe(dir: String) {
        var out = ""
        defer {
            try? out.write(toFile: "/tmp/genreprobe_out.txt", atomically: true,
                           encoding: .utf8)
        }
        let fm = FileManager.default
        let root = URL(fileURLWithPath: dir)
        // 递归收集 RAW。不要用 fm.enumerator：TCC 场景下它会被静默拦成空，
        // contentsOfDirectory 则能正常触发/命中「文件与文件夹」授权。
        var files: [URL] = []
        var queue: [URL] = [root]
        while let dirURL = queue.popLast() {
            let items = ((try? fm.contentsOfDirectory(atPath: dirURL.path)) ?? [])
                .sorted()
            for item in items {
                let child = dirURL.appendingPathComponent(item)
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: child.path, isDirectory: &isDir) {
                    if isDir.boolValue {
                        queue.append(child)
                    } else if MetadataWriter.rawExts.contains(
                        (item as NSString).pathExtension.lowercased()) {
                        files.append(child)
                    }
                }
            }
        }
        files.sort { $0.lastPathComponent < $1.lastPathComponent }
        out += "文件数 \(files.count)\n"

        // 第一遍：全量分析，算批次基准。
        var metricsByURL: [URL: PhotoMetrics] = [:]
        var metrics: [PhotoMetrics] = []
        for u in files {
            if let m = Analyzer.analyze(u) {
                metricsByURL[u] = m
                metrics.append(m)
            } else {
                out += "\(u.lastPathComponent): Analyzer 失败\n"
            }
        }
        let hiMin = Analyzer.referenceThreshold(metrics, sensitivity: 1.0, anchor: nil)
        out += String(format: "批次基准 %.1f\n", hiMin)

        var goodOK = 0, goodTotal = 0, badOK = 0, badTotal = 0, genreMiss = 0
        // 诊断 CSV：每张的相对路径、真值、预测、分项得分、关键中间量。
        let csvHeader = "relpath,truth,genre,reason,ai,human,verdict,stars,total," +
            "clarity,overall,focus,color,globalHi,peakBlock,subjectScore,ratio,centerRatio," +
            "softRatio,spread,reblur,subjectReblur,subjectSource,bboxCount,bboxMax,focal"
        var csvRows: [String] = [csvHeader]
        let caseDir = URL(fileURLWithPath: "/tmp/genreprobe_cases")
        try? FileManager.default.createDirectory(at: caseDir, withIntermediateDirectories: true)
        let rawDir = caseDir.appendingPathComponent("raw")
        try? FileManager.default.createDirectory(at: rawDir, withIntermediateDirectories: true)
        for u in files {
            guard let m = metricsByURL[u] else { continue }
            let af = AFReader.read(u)
            let exif = ExifInfo.read(u)
            let wb = WhiteBalance.analyze(u)
            let focus = FocusSemanticsEngine.detect(url: u, subjectBoxes: m.bboxes)
            let human = HumanPresenceEngine.detect(url: u)
            let ai = AISubjectEngine.detect(url: u)
            let (genre, why) = ScoreEngine.guessGenre(m: m, af: af, wb: wb,
                                                      exif: exif, focus: focus,
                                                      human: human, ai: ai)
            let comps = u.pathComponents
            let truth = comps.contains("拍鸟") ? "拍鸟"
                      : comps.contains("人像") ? "人像"
                      : comps.contains("风光") ? "风光" : nil
            let isGood = comps.contains("好片")
            let isBad = comps.contains("废片")
            let (verdict, _) = Analyzer.classify(m, hiMin: hiMin, subjectOverride: nil)
            let fake = PhotoResult(id: u, metrics: m, verdict: verdict,
                                   reason: "", overrideRect: nil)
            let s = ScoreEngine.score(fake, af: af, wb: wb, exif: exif,
                                      genre: genre, genreIsGuess: true, genreReason: why,
                                      focus: focus)
            var flag = ""
            if let truth = truth, truth != genre.rawValue {
                flag += " ⚠题材应为\(truth)"
                genreMiss += 1
            }
            if isGood {
                goodTotal += 1
                if s.stars >= 3 { goodOK += 1 } else { flag += " ⚠好片仅\(s.stars)星" }
            }
            if isBad {
                badTotal += 1
                if s.stars <= 2 { badOK += 1 } else { flag += " ⚠废片\(s.stars)星" }
            }
            out += "== \(u.lastPathComponent) [\(comps.count >= 2 ? comps[comps.count - 2] : "")]"
            out += " 题材=\(genre.rawValue)（\(why)）"
            out += " AI=\(ai.map { "\($0.kind)" } ?? "nil")"
            out += " \(s.stars)星/\(Int(s.total.rounded()))分\(flag.isEmpty ? "" : flag)\n"

            // 指标全零（解码异常）→ 把原文件复制出来供离线排查。
            if m.globalHi <= 0 {
                try? FileManager.default.copyItem(at: u, to: rawDir.appendingPathComponent(u.lastPathComponent))
            }

            // CSV 行
            let rel = u.path.dropFirst(root.path.count + 1)
            func esc(_ v: String) -> String { v.contains(",") ? "\"\(v)\"" : v }
            func partScore(_ id: String) -> String {
                if let p = s.parts.first(where: { $0.id == id }) {
                    return String(format: "%.0f", p.score)
                }
                return ""
            }
            func num(_ v: Double) -> String { String(format: "%.2f", v) }
            let truthStr = (truth ?? "-") + "|" + (isGood ? "好片" : isBad ? "废片" : "-")
            let humanStr: String
            if let h = human, h.hasPerson {
                humanStr = "人\(h.count)个/主\(h.isMainSubject ? 1 : 0)/高\(Int(h.bodyHeightRatio * 100))%"
            } else {
                humanStr = "无人"
            }
            let bboxMax = m.bboxes.map { $0.width * $0.height }.max() ?? 0
            let focal = exif?.focalLength ?? ""
            csvRows.append([
                esc(String(rel)), esc(truthStr), esc(genre.rawValue), esc(why),
                ai.map { "\($0.kind)|\($0.reason)" } ?? "nil", esc(humanStr),
                verdict.rawValue, "\(s.stars)", String(format: "%.0f", s.total),
                partScore("clarity"), partScore("overall"), partScore("focus"),
                partScore("color"), num(m.globalHi), num(m.peakBlock), num(m.subjectScore),
                num(m.ratio), num(m.centerRatio), num(m.softRatio), num(m.spread),
                num(m.reblurRatio), num(m.subjectReblur), esc(m.subjectSource),
                "\(m.bboxes.count)", num(bboxMax), focal
            ].joined(separator: ","))

            // 报警案例：把预览图复制到 /tmp/genreprobe_cases，便于人工看图。
            if !flag.isEmpty, let img = m.preview {
                var tag = "OTHER"
                if flag.contains("题材应为") { tag = "GENRE" }
                if flag.contains("好片仅") { tag = "GOOD" + s.stars.description + "star" }
                else if flag.contains("废片") { tag = "BAD" + s.stars.description + "star" }
                let base = u.deletingPathExtension().lastPathComponent
                let name = "\(tag)_\(base).jpg"
                let rep = NSBitmapImageRep(cgImage: img)
                if let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) {
                    try? data.write(to: caseDir.appendingPathComponent(name))
                }
            }
        }
        try? csvRows.joined(separator: "\n").write(
            toFile: "/tmp/genreprobe_cases/diag.csv", atomically: true, encoding: .utf8)
        out += "\n汇总：好片达标 \(goodOK)/\(goodTotal)，废片压住 \(badOK)/\(badTotal)，题材不符 \(genreMiss)\n"
        out += "诊断明细与案例图：/tmp/genreprobe_cases/diag.csv\n"
        print(out)
    }

    var body: some Scene {
        WindowGroup("Kingfisher-PhotoSelector") {
            ContentView().environmentObject(store)
        }
        .defaultSize(width: 1060, height: 700)
    }
}

/// 把题材判定依据里的旧短词换成规范用词（内部 rawValue / CSV 保持原样）。
/// 用正则只替换没跟"摄影"的裸词，避免把"风光摄影"再变成"风光摄影摄影"。
func genreDisplayText(_ s: String) -> String {
    guard let re = try? NSRegularExpression(pattern: "(拍鸟|风光|人像)(?!摄影)") else { return s }
    var out = s
    let matches = re.matches(in: s, range: NSRange(s.startIndex..., in: s))
    for m in matches.reversed() {
        guard let range = Range(m.range, in: s) else { continue }
        let word = String(s[range])
        let full: String
        switch word {
        case "拍鸟": full = "鸟类摄影"
        case "风光": full = "风光摄影"
        default:   full = "人像摄影"
        }
        out.replaceSubrange(range, with: full)
    }
    return out
}

/// 把「红:蓝」比例（以绿=1）翻成人话结论，直接告诉用户偏黄还是偏蓝。
/// 红多于蓝 → 暖（偏黄/偏红），蓝多于红 → 冷（偏蓝），接近相等 → 中性。
/// 阈值 0.06 来自经验：肉眼可察觉的色偏大致从 6% 差异起。
func colorBiasText(r: Double, b: Double) -> String {
    let d = r - b
    if d > 0.20 { return "明显偏黄（暖）" }
    if d > 0.06 { return "偏黄（暖）" }
    if d < -0.20 { return "明显偏蓝（冷）" }
    if d < -0.06 { return "偏蓝（冷）" }
    return "接近中性"
}

/// 即时悬停提示：鼠标停留满 1 秒后弹出（用户要求，滑过不乱弹），离开立刻消失。
/// 用系统 popover 而不是自绘 overlay——之前自绘气泡有两个问题：宽度被锚定格子
/// （约 130pt）限住变成竖条；网格里后面的格子会盖在气泡上，看起来像透明底、
/// 和底下文字叠在一起。popover 是独立窗口：不透明、跟随系统深浅色、
/// 始终完整显示在屏幕内、宽度可到 460 横向排版。
/// title：可选的第一行标题（指标格显示指标名，如「主体清晰度」，而不是数值）。
struct InstantHelp: ViewModifier {
    let text: String
    var title: String? = nil
    @State private var showing = false
    @State private var showTask: Task<Void, Never>?
    func body(content: Content) -> some View {
        content
            .onHover { hover in
                showTask?.cancel()
                showTask = nil
                if hover {
                    showTask = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        guard !Task.isCancelled else { return }
                        showing = true
                    }
                } else {
                    showing = false
                }
            }
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    if let title {
                        Text(title).font(.caption).fontWeight(.semibold)
                    }
                    Text(text)
                        .font(.caption)
                        .foregroundColor(.primary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(maxWidth: 460, alignment: .leading)
                .background(Color(nsColor: .windowBackgroundColor))
            }
    }
}

extension View {
    /// 即时悬停提示（替代判断依据区的 .help）。
    func instantHelp(_ text: String, title: String? = nil) -> some View {
        modifier(InstantHelp(text: text, title: title))
    }
}
