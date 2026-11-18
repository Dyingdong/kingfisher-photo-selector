import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Foundation
import CoreGraphics

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
}

/// 用户可自定义的快捷键，持久化到 UserDefaults。
struct ShortcutSettings: Codable, Equatable {
    var zoom: ModifierKey = .command       // 框选放大，默认 ⌘
    var subject: ModifierKey = .control    // 圈选主体，默认 ⌃(Control)

    private static let storeKey = "FocusScreener.shortcuts.v1"

    static func load() -> ShortcutSettings {
        guard let data = UserDefaults.standard.data(forKey: storeKey),
              let s = try? JSONDecoder().decode(ShortcutSettings.self, from: data) else {
            return ShortcutSettings()
        }
        return s
    }
    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.storeKey)
        }
    }
    /// 判断当前按下的修饰键对应哪个框选动作；无匹配返回 nil（交给平移/复位）。
    func action(for flags: NSEvent.ModifierFlags) -> DragAction? {
        let f = flags.intersection([.command, .control, .option, .shift])
        if f.contains(zoom.flag) { return .zoom }
        if f.contains(subject.flag) { return .subject }
        return nil
    }
}

// MARK: - 状态

final class Store: ObservableObject {
    @Published var results: [PhotoResult] = []
    /// 信息区高度（像素）。默认 = 刚好显示到合焦结论；用户拖分隔条调整。
    /// 同一序列内切照片/重算都不改它，导入新素材时重置为默认值。
    @Published var infoHeight: CGFloat = Store.defaultInfoHeight
    /// 默认信息区高度：让「评分 / 拍摄参数 / 合焦结论」可见，白平衡需滚动。
    static let defaultInfoHeight: CGFloat = 300
    @Published var processing = false
    @Published var done = 0
    @Published var total = 0
    @Published var status = "把照片文件夹拖进窗口，或点「选择文件夹」开始"
    @Published var selected: URL?
    @Published var onlySuspect = true
    @Published var sensitivity: Double = 1.0
    @Published var preferFaces = false
    @Published var addColorLabel = true
    @Published var confirmWrite = false
    @Published var confirmDelete = false
    @Published var deleteURL: URL?
    @Published var backupPath = ""
    @Published var dropTarget = false
    @Published var showHeatmap = true
    @Published var dragStart: CGPoint?
    @Published var dragCurrent: CGPoint?
    @Published var dragIsZoom = false
    /// 当前左键拖动意图（⌘=放大 / ⌃=圈选主体 / 无修饰键=平移）；nil 表示未在拖动。
    @Published var dragAction: DragAction?
    @Published var didDrag = false
    @Published var excluded: Set<URL> = []
    @Published var anchorHi: Double?
    @Published var zoom: CGFloat = 1
    @Published var zoomCenter = CGPoint(x: 0.5, y: 0.5)
    @Published var selectionRatio: Double?
    @Published var selectionRect: CGRect?
    @Published var wbCache: [URL: WhiteBalanceStats] = [:]
    @Published var afCache: [URL: AFInfo] = [:]
    /// 对焦点读取状态：loading 驱动"读取中"提示；attempted 避免 nil 结果反复跑 exiftool。
    @Published var afLoading: Set<URL> = []
    @Published var afAttempted: Set<URL> = []
    @Published var exifCache: [URL: ExifInfo] = [:]
    /// Bridge 星级：-1 = 拒绝，0~5 = 星级，nil = 未评分。
    @Published var ratingCache: [URL: Int] = [:]
    @Published var showAFPoints = true
    /// 分隔条拖动基准：按下时记录当前信息区高度，作为绝对基准。
    @Published var dividerStartHeight: CGFloat = 0
    /// 正在拖动分隔条：左键桥接据此放行事件，避免把分隔条拖动误判为平移。
    @Published var isDividerDragging = false
    /// 拖分隔条期间锁定照片的显示高度与相对预览区顶部的偏移，
    /// 使照片不随预览区高度伸缩（这是"拖分区时画面跳动"的来源）。
    @Published var frozenFit: (height: CGFloat, top: CGFloat)?
    /// 预览区每帧记录的自然 fit（非 @Published，避免赋值触发 UI 重算）。
    /// 分隔条按下时冻结它，即可得到"拖动前一刻"的照片尺寸。
    var lastNaturalFit: (height: CGFloat, top: CGFloat)?
    func recordNaturalFit(height: CGFloat, top: CGFloat) {
        guard frozenFit == nil else { return }
        lastNaturalFit = (height, top)
    }
    func freezeCurrentFit() { frozenFit = lastNaturalFit }
    func endFitFreeze() { frozenFit = nil }
    /// 可自定义的快捷键（框选放大 / 圈选主体的修饰键）。
    @Published var shortcuts = ShortcutSettings.load()
    /// 快捷键设置面板是否显示。
    @Published var showShortcuts = false
    /// 当前选中照片的原尺寸预览；分析用小图只用于缩略图与打分。
    @Published var fullPreview: CGImage?
    @Published var fullPreviewURL: URL?
    @Published var panOffset = CGSize.zero
    @Published var panStart: CGPoint?
    @Published var panBegin = CGSize.zero

    /// 渲染缓存：拖动分隔条/缩放窗口会反复触发 body 重算，热力图按块绘制很重。
    /// 缓存后 body 重算只取现成 NSImage 做 GPU 缩放，避免画面跳动。
    /// 非 @Published：生成结果不需要触发 UI 刷新；选中图/基准变化时按 key 自动失效。
    private var heatCache: [URL: (floor: Double, img: NSImage)] = [:]
    private var baseCache: [URL: (full: Bool, img: NSImage)] = [:]

    func heatmapImage(for r: PhotoResult) -> NSImage {
        let floor = heatFloor
        if let c = heatCache[r.id], c.floor == floor { return c.img }
        let img = makeHeatmap(r.metrics, floor: floor)
        heatCache[r.id] = (floor, img)
        return img
    }

    func baseImage(for r: PhotoResult) -> NSImage {
        let useFull = fullPreviewURL == r.id && fullPreview != nil
        if let c = baseCache[r.id], c.full == useFull { return c.img }
        let cg = useFull ? (fullPreview ?? r.metrics.preview) : r.metrics.preview
        let img: NSImage
        if let cg {
            img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        } else {
            img = NSImage()
        }
        baseCache[r.id] = (useFull, img)
        return img
    }

    private var metrics: [PhotoMetrics] = []
    private var hiMin: Double = 0
    private var cancelled = false

    var suspects: [PhotoResult] { results.filter { $0.verdict.isSuspect } }
    var writableSuspects: [PhotoResult] { suspects.filter { !excluded.contains($0.id) } }
    var shown: [PhotoResult] { onlySuspect ? suspects : results }

    /// 热力图的固定标尺：有锚点用锚点，否则用本批 P75。
    /// 与判定共用同一个基准，避免「全糊的图按自己 P99 归一化后满屏绿」。
    var heatFloor: Double {
        Analyzer.independentThreshold(sensitivity: 1.0, anchor: anchorHi)
    }
    var anchorName: String {
        anchorHi == nil ? "独立阈值 \(Int(Analyzer.independentFloor))" : "固定锚点"
    }

    func displayName(_ u: URL) -> String {
        let stem = u.deletingPathExtension().lastPathComponent
        let same = results.filter { $0.id.deletingPathExtension().lastPathComponent == stem }.count
        return same > 1 ? u.lastPathComponent : stem
    }

    func toggleExclude(_ u: URL) {
        if excluded.contains(u) { excluded.remove(u) } else { excluded.insert(u) }
    }

    func scan(folder: URL) {
        let fm = FileManager.default
        var files: [URL] = []
        let allowed = MetadataWriter.rawExts
        if let e = fm.enumerator(at: folder, includingPropertiesForKeys: [.isDirectoryKey],
                                 options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
            for case let u as URL in e where allowed.contains(u.pathExtension.lowercased()) {
                files.append(u)
            }
        }
        process(files.sorted { $0.lastPathComponent < $1.lastPathComponent })
    }

    func scan(files: [URL]) {
        let allowed = MetadataWriter.rawExts
        process(files.filter { allowed.contains($0.pathExtension.lowercased()) }
                     .sorted { $0.lastPathComponent < $1.lastPathComponent })
    }

    private func process(_ files: [URL]) {
        guard !files.isEmpty else {
            status = "没有找到可处理的 RAW 照片"
            return
        }
        cancelled = false
        processing = true
        done = 0
        total = files.count
        results = []
        wbCache = [:]
        afCache = [:]
        afLoading = []
        afAttempted = []
        exifCache = [:]
        ratingCache = [:]
        heatCache = [:]
        baseCache = [:]
        selectionRatio = nil
        status = "正在分析…"
        let faces = preferFaces
        let anchor = anchorHi
        DispatchQueue.global(qos: .userInitiated).async {
            var found: [PhotoMetrics] = []
            for (i, u) in files.enumerated() {
                if self.cancelled { break }
                if let m = Analyzer.analyze(u, preferFaces: faces) { found.append(m) }
                DispatchQueue.main.async { self.done = i + 1 }
            }
            let min = Analyzer.referenceThreshold(found, sensitivity: self.sensitivity, anchor: anchor)
            let list = found.map { m -> PhotoResult in
                let (v, why) = Analyzer.classify(m, hiMin: min)
                return PhotoResult(id: m.url, metrics: m, verdict: v, reason: why)
            }
            DispatchQueue.main.async {
                self.metrics = found
                self.hiMin = min
                // 新素材序列：信息区高度重置为默认（显示到合焦）；同一序列内切照片不动它。
                self.infoHeight = Store.defaultInfoHeight
                self.results = list
                self.processing = false
                self.status = "已分析 \(found.count) 张，未合焦 \(self.suspects.count) 张"
                if let f = self.shown.first { self.selected = f.id }
            }
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
        status = "已按新灵敏度重算，未合焦 \(suspects.count) 张"
    }

    func recheck(id: URL, rect: CGRect) {
        guard let idx = results.firstIndex(where: { $0.id == id }),
              let m = metrics.first(where: { $0.url == id }) else { return }
        let cr = Analyzer.rectRatio(m, rect: rect)
        let (v, why) = Analyzer.classify(m, hiMin: hiMin, subjectOverride: cr)
        objectWillChange.send()
        results[idx].verdict = v
        results[idx].reason = why + "（人工圈选）"
        results[idx].overrideRect = rect
        status = "已按圈选区域重判 \(id.deletingPathExtension().lastPathComponent)：\(v.rawValue)"
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

    func ensureWB(for url: URL) {
        guard wbCache[url] == nil else { return }
        DispatchQueue.global(qos: .utility).async {
            let s = WhiteBalance.analyze(url)
            DispatchQueue.main.async { self.wbCache[url] = s }
        }
    }

    func ensureAF(for url: URL) {
        // attempted 同时覆盖"读到数据"与"确认无数据"，避免无数据的图反复跑 exiftool。
        guard !afAttempted.contains(url) else { return }
        afAttempted.insert(url)
        afLoading.insert(url)
        DispatchQueue.global(qos: .utility).async {
            let info = AFReader.read(url)
            DispatchQueue.main.async {
                self.afLoading.remove(url)
                if let info { self.afCache[url] = info }
            }
        }
    }

    func ensureExif(for url: URL) {
        guard exifCache[url] == nil else { return }
        DispatchQueue.global(qos: .utility).async {
            let info = ExifInfo.read(url)
            DispatchQueue.main.async { self.exifCache[url] = info }
        }
    }

    func ensureRating(for url: URL) {
        guard ratingCache[url] == nil else { return }
        DispatchQueue.global(qos: .utility).async {
            let rating = MetadataWriter.snapshot(url).rating
            DispatchQueue.main.async { self.ratingCache[url] = rating }
        }
    }

    /// 设置星级：0~5 星，-1 为 Bridge 的「拒绝」。即时写入元数据，失败则回滚 UI。
    func setRating(_ url: URL, rating: Int) {
        let previous = ratingCache[url]
        let stamp = Int(Date().timeIntervalSince1970)
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FocusScreener/backups/\(stamp)")
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                _ = try MetadataWriter.setRating(to: url, rating: rating, backupDir: dir)
                DispatchQueue.main.async {
                    self.ratingCache[url] = rating
                    self.backupPath = dir.path
                    let label = rating == -1 ? "拒绝" : "\(rating) 星"
                    self.status = "已设 \(url.deletingPathExtension().lastPathComponent) 为\(label)，并写入元数据"
                }
            } catch {
                DispatchQueue.main.async {
                    self.ratingCache[url] = previous
                    self.status = "评分写入失败：\(error.localizedDescription)"
                }
            }
        }
    }

    func ensureFullPreview(for url: URL) {
        if fullPreviewURL == url {
            if fullPreview != nil { return }
        }
        fullPreviewURL = url
        fullPreview = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let img = Analyzer.loadFullPreview(url)
            DispatchQueue.main.async {
                guard self.fullPreviewURL == url else { return }
                self.fullPreview = img
            }
        }
    }

    func resetZoom() {
        zoom = 1
        zoomCenter = CGPoint(x: 0.5, y: 0.5)
        panOffset = .zero
        panStart = nil
        dragAction = nil
        selectionRatio = nil
        selectionRect = nil
    }

    func zoomIn() { zoom = min(8, zoom * 1.5) }
    func zoomOut() { zoom = max(1, zoom / 1.5) }

    func writeMetadata() {
        let targets = writableSuspects
        guard !targets.isEmpty else { return }
        let stamp = Int(Date().timeIntervalSince1970)
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FocusScreener/backups/\(stamp)")
        var ok = 0
        var failed: [String] = []
        for r in targets {
            do {
                _ = try MetadataWriter.apply(to: r.id, reason: r.reason,
                                             addLabel: addColorLabel, backupDir: dir)
                ok += 1
            } catch {
                failed.append("\(r.id.lastPathComponent)：\(error.localizedDescription)")
            }
        }
        backupPath = dir.path
        status = "已写入 \(ok) 张照片的 Bridge 元数据" +
                 (failed.isEmpty ? "" : "，\(failed.count) 张失败：\(failed.joined(separator: "；"))")
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

    /// 删除选中的照片；RAW 会连同同名 JPG 一起移到废纸篓。返回实际处理的文件名。
    func deletePhoto(_ url: URL) -> (moved: [String], failed: String?) {
        var targets = [url]
        if let jpg = siblingJPG(for: url) { targets.append(jpg) }
        var moved: [String] = []
        var failed: String?
        var removedURLs: Set<URL> = []
        for t in targets {
            do {
                var resulting: NSURL?
                try FileManager.default.trashItem(at: t, resultingItemURL: &resulting)
                moved.append(t.lastPathComponent)
                removedURLs.insert(t)
            } catch {
                failed = "\(t.lastPathComponent)：\(error.localizedDescription)"
            }
        }
        // 从内存列表与缓存移除（只移除确实删掉的）
        results.removeAll { removedURLs.contains($0.id) }
        metrics.removeAll { removedURLs.contains($0.url) }
        for key in removedURLs {
            wbCache[key] = nil; afCache[key] = nil; exifCache[key] = nil; ratingCache[key] = nil
            afLoading.remove(key); afAttempted.remove(key)
            heatCache[key] = nil; baseCache[key] = nil
        }
        excluded = excluded.subtracting(removedURLs)
        if let s = selected, removedURLs.contains(s) {
            selected = shown.first?.id
        }
        return (moved, failed)
    }

    func exportCSV() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "摄影筛选报告.csv"
        panel.allowedContentTypes = [UTType.commaSeparatedText]
        guard panel.runModal() == .OK, let u = panel.url else { return }
        let csv = Report.csv(results, hiMin: hiMin, sensitivity: sensitivity, anchor: anchorHi)
        do {
            try csv.write(to: u, atomically: true, encoding: .utf8)
            status = "报告已导出：\(u.path)（可填「人工真值」列后用 verify.py 复核）"
        } catch { status = "导出失败：\(error.localizedDescription)" }
    }
}

// MARK: - 热力图

func verdictColor(_ v: Verdict) -> Color {
    switch v {
    case .pass: return .secondary
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

struct ResultRow: View {
    @EnvironmentObject var store: Store
    let r: PhotoResult
    var body: some View {
        HStack(spacing: 8) {
            if let cg = r.metrics.preview {
                Image(nsImage: NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)))
                    .resizable().aspectRatio(contentMode: .fill)
                    .frame(width: 46, height: 34).clipped().cornerRadius(3)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(store.displayName(r.id)).lineLimit(1).font(.body)
                HStack(spacing: 6) {
                    Text(r.verdict.rawValue).font(.caption2).foregroundColor(verdictColor(r.verdict))
                    if store.excluded.contains(r.id) {
                        Text("排除写入").font(.caption2).foregroundColor(.orange)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .help(r.id.path)
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
    case doubleTap                   // 双击 → 放大到对焦点所在区域
}

struct LeftMouseBridge: NSViewRepresentable {
    var zoomFlag: NSEvent.ModifierFlags
    var subjectFlag: NSEvent.ModifierFlags
    /// 返回 true 时完全放行左键事件（正在拖动分隔条），避免误判为平移。
    var isSuppressed: () -> Bool = { false }
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
    }

    final class Coordinator {
        var zoomFlag: NSEvent.ModifierFlags = .command
        var subjectFlag: NSEvent.ModifierFlags = .control
        var isSuppressed: (() -> Bool)?
        var onGesture: ((LeftMouseGesture) -> Void)?
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
                // 正在拖动分隔条时完全放行，避免被误判为"平移画面"。
                if self.coordinator?.isSuppressed?() == true { return e }
                // 用桥接视图自身 bounds 判断，范围严格等于预览区（不吞分隔条/信息区事件）；
                // 坐标转左上原点后与 GeometryReader 的 fitW/fitH 同一基准。
                let p = self.convert(e.locationInWindow, from: nil)
                guard self.bounds.width > 0, self.bounds.contains(p) else { return e }
                let topLeft = CGPoint(x: p.x, y: self.bounds.height - p.y)
                switch e.type {
                case .leftMouseDown:
                    // 双击优先：macOS 会给出 clickCount==2，直接触发对焦点放大，
                    // 不再进入拖动流程；单击仍走 tap 复位。
                    if e.clickCount >= 2 {
                        self.action = nil
                        self.start = nil
                        self.last = nil
                        self.swallowNextUp = true
                        self.coordinator?.onGesture?(.doubleTap)
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
            if action != nil, let s = start {
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

struct DetailView: View {
    @EnvironmentObject var store: Store
    let r: PhotoResult

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
    private func zoomToSelection(_ s: CGPoint, _ e: CGPoint, metrics m: PhotoMetrics,
                                 fitW: CGFloat, fitH: CGFloat,
                                 ox: CGFloat, oy: CGFloat) {
        let w = abs(e.x - s.x), h = abs(e.y - s.y)
        guard w > 8, h > 8, fitW > 0, fitH > 0 else { return }
        let d = displayedImageRect(fitW: fitW, fitH: fitH, ox: ox, oy: oy)
        guard d.width > 0, d.height > 0 else { return }
        // 先用「放大前」的显示矩形算好选区，再改 zoom/zoomCenter，
        // 否则选区会被按放大后的变换解释，位置整体偏移。
        let rect = imageRect(s, e, fitW: fitW, fitH: fitH, ox: ox, oy: oy)
        let nx = min(max(((s.x + e.x) / 2 - d.minX) / d.width, 0), 1)
        let nyTop = min(max(((s.y + e.y) / 2 - d.minY) / d.height, 0), 1)
        let rw = min(w / d.width, 1), rh = min(h / d.height, 1)
        let factor = min(1 / max(rw, 0.001), 1 / max(rh, 0.001))
        store.zoom = min(8, max(1.2, store.zoom * factor))
        store.zoomCenter = CGPoint(x: nx, y: 1 - nyTop)
        store.panOffset = .zero
        store.panStart = nil
        store.selectionRect = rect
        store.selectionRatio = Analyzer.rectRatio(m, rect: rect)
    }

    /// 双击预览：把相机对焦点（合焦点）所在区域放大铺满视窗。
    /// 没有对焦点数据时退回主体框；两者都没有则给出状态提示。
    private func zoomToFocusArea(metrics m: PhotoMetrics) {
        // 先取相机对焦点：FocusPoint 是左上原点、y 向下的归一化坐标。
        var box: CGRect? = nil
        if let af = store.afCache[r.id], !af.points.isEmpty {
            let minX = af.points.map { $0.cx }.min() ?? 0.5
            let maxX = af.points.map { $0.cx }.max() ?? 0.5
            let minY = af.points.map { $0.cy }.min() ?? 0.5
            let maxY = af.points.map { $0.cy }.max() ?? 0.5
            // 把对焦框自身大小也纳入包围盒，避免只框住中心点。
            let x0 = minX - (af.points.first?.w ?? 0) / 2
            let x1 = maxX + (af.points.first?.w ?? 0) / 2
            let y0 = minY - (af.points.first?.h ?? 0) / 2
            let y1 = maxY + (af.points.first?.h ?? 0) / 2
            box = CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
        } else if let b = m.bboxes.first {
            // 主体框是 Vision 坐标（y 向上），转成左上原点。
            box = CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height)
        }
        guard let b = box, b.width > 0.001, b.height > 0.001 else {
            store.status = "这张照片没有相机对焦点数据，无法按对焦点放大"
            return
        }
        // 让该区域较长边占视窗约 38%（比之前的 60% 小约 37%），四周留更多上下文。
        let fill: CGFloat = 0.38
        let factor = min(fill / max(b.width, 0.001), fill / max(b.height, 0.001))
        store.zoom = min(8, max(1.2, factor))
        store.zoomCenter = CGPoint(x: b.midX, y: 1 - b.midY)
        store.panOffset = .zero
        store.panStart = nil
        // 黄色选区框用 Vision 坐标（y 向上）显示。
        let vision = CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height)
        store.selectionRect = vision
        store.selectionRatio = Analyzer.rectRatio(m, rect: vision)
    }

    var body: some View {
        let m = r.metrics
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Toggle("锐度热力图", isOn: $store.showHeatmap)
                Toggle("对焦点", isOn: $store.showAFPoints)
                Button("－") { store.zoomOut() }.frame(width: 26)
                Text(String(format: "%.1f×", store.zoom)).font(.caption).monospacedDigit()
                Button("＋") { store.zoomIn() }.frame(width: 26)
                Button("复位") { store.resetZoom() }.font(.caption)
                Spacer()
                Text("\(store.shortcuts.zoom.symbol)+左键拖框放大 · \(store.shortcuts.subject.symbol)+左键圈选主体 · 按住左键拖动平移 · 双击放大对焦点 · 滚轮缩放 · 单击还原")
                    .font(.caption).foregroundColor(.secondary).lineLimit(1)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)

            GeometryReader { geo in
                let aspect = CGFloat(max(m.width, 1)) / CGFloat(max(m.height, 1))
                let naturalW = min(geo.size.width, geo.size.height * aspect)
                let naturalH = naturalW / aspect
                let naturalOy = (geo.size.height - naturalH) / 2
                // 拖分隔条期间用锁定值，照片不随预览区高度伸缩（消除画面跳动）；
                // 未锁定时正常 fit，同时记录自然 fit 供分隔条按下时冻结。
                let fitW: CGFloat = {
                    if let f = store.frozenFit { return f.height * aspect }
                    store.recordNaturalFit(height: naturalH, top: naturalOy)
                    return naturalW
                }()
                let fitH = fitW / aspect
                let ox = (geo.size.width - fitW) / 2
                let oy = store.frozenFit?.top ?? naturalOy
                let scale = store.zoom

                ZStack {
                    ZStack {
                        Image(nsImage: store.baseImage(for: r))
                            .resizable().frame(width: fitW, height: fitH)
                        if store.showHeatmap {
                            Image(nsImage: store.heatmapImage(for: r))
                                .resizable().frame(width: fitW, height: fitH)
                        }
                        ForEach(Array(m.bboxes.enumerated()), id: \.offset) { _, b in
                            Rectangle().stroke(Color.cyan, lineWidth: 1.5 / scale)
                                .frame(width: b.width * fitW, height: b.height * fitH)
                                .position(x: (b.minX + b.width / 2) * fitW,
                                          y: (1 - b.minY - b.height / 2) * fitH)
                        }
                        // 相机记录的实际对焦点（红色），来自 RAW MakerNote
                        if store.showAFPoints, let af = store.afCache[r.id] {
                            ForEach(Array(af.points.enumerated()), id: \.offset) { _, p in
                                Rectangle()
                                    .stroke(Color.red, lineWidth: 2 / scale)
                                    .background(Color.red.opacity(0.10))
                                    .frame(width: max(p.w * fitW, 10 / scale),
                                           height: max(p.h * fitH, 10 / scale))
                                    .position(x: p.cx * fitW, y: p.cy * fitH)
                            }
                        }
                        if let sel = store.selectionRect, store.zoom > 1 {
                            Rectangle().stroke(Color.yellow, lineWidth: 1.5 / scale)
                                .frame(width: sel.width * fitW, height: sel.height * fitH)
                                .position(x: (sel.minX + sel.width / 2) * fitW,
                                          y: (1 - sel.minY - sel.height / 2) * fitH)
                        }
                    }
                    .frame(width: fitW, height: fitH)
                    .scaleEffect(scale, anchor: .center)
                    .offset(x: (0.5 - store.zoomCenter.x) * fitW * scale + store.panOffset.width,
                            y: (store.zoomCenter.y - 0.5) * fitH * scale + store.panOffset.height
                                // 图片层默认在预览区里居中；但手势换算用的是 (ox, oy)。
                                // 拖分隔条时预览区高度变化，若靠居中，图片中心会跟着预览区中心
                                // 上下移动（就是"画面跳动"）。冻结期间 oy 固定，这里补偿掉
                                // 居中的位置漂移，使渲染位置与 displayedImageRect / oy 完全一致。
                                // 未冻结时 oy 就等于居中值，补偿为 0，不改变正常行为。
                                + (oy - (geo.size.height - fitH) / 2))

                    if let s = store.dragStart, let c = store.dragCurrent {
                        Rectangle().stroke(store.dragIsZoom ? Color.yellow : Color.cyan, lineWidth: 2)
                            .background((store.dragIsZoom ? Color.yellow : Color.cyan).opacity(0.12))
                            .frame(width: abs(c.x - s.x), height: abs(c.y - s.y))
                            .position(x: (s.x + c.x) / 2, y: (s.y + c.y) / 2)
                    }
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
                            store.dragIsZoom = true
                            store.dragAction = .zoom
                            store.didDrag = true
                            store.dragStart = p
                            store.dragCurrent = p
                        },
                        onMove: { p in store.dragCurrent = p },
                        onEnd: { p in
                            if let s = store.dragStart {
                                zoomToSelection(s, p, metrics: m,
                                                fitW: fitW, fitH: fitH, ox: ox, oy: oy)
                            }
                            store.dragStart = nil
                            store.dragCurrent = nil
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
                        isSuppressed: { store.isDividerDragging }
                    ) { g in
                        switch g {
                        case .began(let action, let p):
                            store.dragAction = action
                            store.didDrag = true
                            if action == .pan {
                                store.panStart = p
                                store.panBegin = store.panOffset
                                store.dragStart = nil
                                store.dragCurrent = nil
                            } else {
                                store.dragIsZoom = (action == .zoom)
                                store.dragStart = p
                                store.dragCurrent = p
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
                                store.dragCurrent = p
                            }
                        case .ended(let p):
                            if let action = store.dragAction {
                                if action == .pan {
                                    // 平移已在 moved 完成，无需额外处理。
                                } else if let s = store.dragStart {
                                    let rect = imageRect(s, p, fitW: fitW, fitH: fitH, ox: ox, oy: oy)
                                    if abs(p.x - s.x) > 8, abs(p.y - s.y) > 8 {
                                        if action == .zoom {
                                            zoomToSelection(s, p, metrics: m,
                                                            fitW: fitW, fitH: fitH, ox: ox, oy: oy)
                                        } else {
                                            store.recheck(id: r.id, rect: rect)
                                        }
                                    }
                                }
                            }
                            store.dragStart = nil
                            store.dragCurrent = nil
                            store.panStart = nil
                            store.dragAction = nil
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                store.didDrag = false
                            }
                        case .tap:
                            store.resetZoom()
                        case .doubleTap:
                            zoomToFocusArea(metrics: m)
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

// MARK: - 右下：指标信息

struct InfoView: View {
    @EnvironmentObject var store: Store
    let r: PhotoResult

    private func cell(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundColor(.secondary)
            Text(value).font(.callout).monospacedDigit().lineLimit(1)
        }
        .frame(minWidth: 120, alignment: .leading)
    }

    /// 通俗命名的指标格：鼠标悬停显示大白话解释。
    private func metricCell(_ title: String, _ value: String, _ tip: String) -> some View {
        cell(title, value).help(tip)
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
        let current = store.ratingCache[r.id] ?? 0
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
                    .buttonStyle(.plain).help("\(n) 星")
                }
                Button {
                    store.setRating(r.id, rating: rejected ? 0 : -1)
                } label: {
                    Text("拒绝").font(.caption)
                        .foregroundColor(rejected ? .white : .red)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(rejected ? Color.red : Color.clear)
                        .cornerRadius(4)
                }
                .buttonStyle(.plain).help("标记/取消拒绝（Bridge Reject）")
            }
            if let rt = store.ratingCache[r.id] {
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
                        HStack(spacing: 16) {
                            cell("相机", exif.camera ?? "—")
                            cell("镜头", exif.lens ?? "—")
                            cell("曝光补偿", exif.exposureBias ?? "—")
                            cell("拍摄时间", exif.dateTime ?? "—")
                        }
                        if !exif.detailLine.isEmpty {
                            Text(exif.detailLine).font(.caption2).foregroundColor(.secondary)
                        }
                    } else {
                        Text("正在读取拍摄参数…").font(.caption).foregroundColor(.secondary)
                    }
                }

                Divider()

                // 3) 合焦：醒目的结论 + 大白话原因
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: r.verdict.isSuspect ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                            .font(.title3)
                            .foregroundColor(verdictColor(r.verdict))
                        Text(r.verdict.rawValue)
                            .font(.headline)
                            .foregroundColor(verdictColor(r.verdict))
                        if r.verdict.isSuspect {
                            Button(store.excluded.contains(r.id) ? "已排除写入" : "排除写入") {
                                store.toggleExclude(r.id)
                            }
                            .buttonStyle(.borderless).font(.caption)
                        }
                        Spacer()
                    }
                    Text(r.reason).font(.callout)
                }

                Divider()

                // 4) 判断依据：全部常显，名字说人话，悬停看解释
                VStack(alignment: .leading, spacing: 6) {
                    sectionTitle("判断依据（鼠标停上看解释）")
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 10)],
                              alignment: .leading, spacing: 8) {
                        metricCell("主体清晰度", String(format: "%.0f%%", m.ratio * 100),
                                   "主体有多清楚，按最清楚的地方算 100%。越接近 100% 越好。")
                        metricCell("画面中心清晰度", String(format: "%.0f%%", m.centerRatio * 100),
                                   "画面正中央有多清楚，同样按最清楚的地方算 100%。")
                        metricCell("合格线", String(format: "%.0f", store.heatFloor),
                                   "判断清不清楚的门槛。比它高算清晰，比它低算模糊。")
                        metricCell("最清楚处", String(format: "%.0f", m.globalHi),
                                   "整张照片里最锐利那一块的读数，上面几项都拿它当 100% 基准。")
                        metricCell("发虚区域", String(format: "%.0f%%", m.softRatio * 100),
                                   "画面里模糊、没细节的地方占多少。")
                        metricCell("拖影", String(format: "%.2f", m.anisotropy),
                                   "数值越高越像手抖或物体移动留下的拖影，正常约 1 左右。")
                        metricCell("主体虚化", String(format: "%.2f", m.subjectReblur),
                                   "把主体再人为模糊一次，细节掉得越多说明原来越虚。")
                        if let sr = store.selectionRatio {
                            metricCell("你圈的地方", String(format: "%.0f%%", sr * 100),
                                       "手动圈出区域有多清楚，按最清楚的地方算 100%。")
                        }
                    }
                    Text("主体位置：\(subjectLabel(m.subjectSource))")
                        .font(.caption2).foregroundColor(.secondary)
                }

                Divider()

                // 5) 白平衡 / 曝光参考
                VStack(alignment: .leading, spacing: 4) {
                    sectionTitle("白平衡 / 曝光参考")
                    if let wb {
                        HStack(spacing: 16) {
                            metricCell("整体偏色 红:蓝", String(format: "%.2f : %.2f",
                                     wb.meanR / max(wb.meanG, 1), wb.meanB / max(wb.meanG, 1)),
                                     "以绿色为 1，红比蓝高偏暖，蓝比红高偏冷，接近 1:1 为中性。")
                            if let fr = wb.faceRG, let fb = wb.faceBG {
                                metricCell("人脸偏色 红:蓝", String(format: "%.2f : %.2f", fr, fb),
                                           "只看人脸区域的红蓝比例，参考肤色是否偏色。")
                            }
                            metricCell("过曝面积", String(format: "%.2f%%", wb.highlightClip * 100),
                                       "亮到没有细节的面积占比，太高说明高光溢出。")
                            metricCell("死黑面积", String(format: "%.2f%%", wb.shadowClip * 100),
                                       "暗到没有细节的面积占比。")
                        }
                        Text(wb.summary).font(.caption).foregroundColor(.secondary)
                    } else {
                        Text("正在读取白平衡统计…").font(.caption).foregroundColor(.secondary)
                    }
                }

                Text("灰块 = 该处纹理太少、无法判断。热力图只是相对参考，不是相机的 K 值或测光表。")
                    .font(.caption2).foregroundColor(.secondary)
                Text(r.id.path).font(.caption2).foregroundColor(.secondary).lineLimit(1)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            store.ensureWB(for: r.id)
            store.ensureAF(for: r.id)
            store.ensureExif(for: r.id)
            store.ensureRating(for: r.id)
        }
        .onChange(of: r.id) { u in
            store.ensureWB(for: u)
            store.ensureAF(for: u)
            store.ensureExif(for: u)
            store.ensureRating(for: u)
        }
    }
}

// MARK: - 快捷键设置面板

struct ShortcutsView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("快捷键设置").font(.headline)
            Text("选择各操作使用的修饰键。修改后立即生效并保存在本机；按住左键拖动始终用于平移，单击始终用于复位。")
                .font(.caption).foregroundColor(.secondary)

            HStack(spacing: 12) {
                Text("框选放大").frame(width: 80, alignment: .leading)
                Picker("", selection: $store.shortcuts.zoom) {
                    ForEach(ModifierKey.allCases) { k in Text(k.label).tag(k) }
                }
                .pickerStyle(.menu).frame(width: 150)
                Text("按住此键 + 左键拖框，放大选中的区域")
                    .font(.caption2).foregroundColor(.secondary)
            }

            HStack(spacing: 12) {
                Text("圈选主体").frame(width: 80, alignment: .leading)
                Picker("", selection: $store.shortcuts.subject) {
                    ForEach(ModifierKey.allCases) { k in Text(k.label).tag(k) }
                }
                .pickerStyle(.menu).frame(width: 150)
                Text("按住此键 + 左键拖框，按圈选范围重判这一张")
                    .font(.caption2).foregroundColor(.secondary)
            }

            if store.shortcuts.zoom == store.shortcuts.subject {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                    Text("两个操作用了同一个修饰键，圈选主体将无法触发。请选择不同的键。")
                        .font(.caption).foregroundColor(.orange)
                }
            }
            if store.shortcuts.subject == .control {
                Text("提示：若系统开启了「Control + 点击 = 右键」，⌃+左键会被系统拦截。此时请把圈选主体改成 ⌥ Option 或 ⇧ Shift，或在系统设置里关闭该辅助点按。")
                    .font(.caption2).foregroundColor(.secondary)
            }

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
        .frame(width: 520)
        .onChange(of: store.shortcuts) { _ in store.shortcuts.save() }
    }
}

// MARK: - 主界面：左目录 / 右上预览 / 右下信息

struct ContentView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("摄影照片筛选工具").font(.title3).fontWeight(.medium)
                    Text("RAW · 锐度热力图 · 合焦辅助 · 白平衡参考 · Bridge 元数据")
                        .font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                Button("快捷键") { store.showShortcuts = true }.font(.caption)
                Button("选择文件夹") { pickFolder() }
                Button("导出 CSV 报告") { store.exportCSV() }
                    .disabled(store.results.isEmpty)
            }.padding(12)

            Divider()

            HSplitView {
                VStack(spacing: 0) {
                    HStack {
                        Toggle("只看未合焦", isOn: $store.onlySuspect)
                        Spacer()
                        Text("\(store.shown.count) 张").font(.caption).foregroundColor(.secondary)
                    }.padding(8)
                    List(selection: $store.selected) {
                        ForEach(store.shown) { r in
                            ResultRow(r: r).tag(r.id)
                        }
                    }
                }
                .frame(minWidth: 90, idealWidth: 100, maxWidth: 240)
                .frame(maxHeight: .infinity)

                // 预览区弹性 + 信息区固定高度 + 可拖动分隔条。
                // 高度完全由 store.infoHeight 驱动：导入新素材时重置为默认值（显示到合焦），
                // 同序列内切照片/重算不动它 → 用户调好的比例一直保持。
                GeometryReader { region in
                    let totalH = region.size.height
                    let dividerH: CGFloat = 8
                    let minTop: CGFloat = 200
                    let minBottom: CGFloat = 170
                    let maxBottom = max(minBottom, totalH - dividerH - minTop)
                    let bottomH = min(max(store.infoHeight, minBottom), maxBottom)
                    let topH = max(minTop, totalH - dividerH - bottomH)
                    VStack(spacing: 0) {
                        Group {
                            if let id = store.selected,
                               let r = store.results.first(where: { $0.id == id }) {
                                DetailView(r: r)
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
                        .frame(height: topH)
                        .frame(maxWidth: .infinity)

                        Rectangle()
                            .fill(Color.gray.opacity(0.28))
                            .frame(height: dividerH)
                            .frame(maxWidth: .infinity)
                            .contentShape(Rectangle())
                            .onHover { hovering in
                                if hovering { NSCursor.resizeUpDown.push() }
                                else { NSCursor.resizeUpDown.pop() }
                            }
                            .gesture(DragGesture(minimumDistance: 0)
                                .onChanged { g in
                                    if !store.isDividerDragging {
                                        // 用实际显示高度（已被窗口 clamp 过）作基准，
                                        // 避免默认高度超出可用空间时第一次拖动突然跳变。
                                        store.dividerStartHeight = bottomH
                                        store.isDividerDragging = true
                                        // 冻结照片当前尺寸，拖分区时照片不跟着伸缩。
                                        store.freezeCurrentFit()
                                    }
                                    // 向上拖（translation<0）→ 信息区变高
                                    store.infoHeight = min(max(store.dividerStartHeight - g.translation.height, minBottom), maxBottom)
                                }
                                .onEnded { _ in
                                    store.isDividerDragging = false
                                    store.endFitFreeze()
                                })

                        Group {
                            if let id = store.selected,
                               let r = store.results.first(where: { $0.id == id }) {
                                InfoView(r: r)
                            } else {
                                Text("选中照片后显示清晰度、白平衡等信息")
                                    .foregroundColor(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                        }
                        .frame(height: bottomH)
                        .frame(maxWidth: .infinity)
                    }
                }
                .frame(minWidth: 480, idealWidth: 820, maxWidth: .infinity)
                .frame(maxHeight: .infinity)
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

                Toggle("附红色标签", isOn: $store.addColorLabel)
                Spacer()
                if store.processing {
                    ProgressView(value: Double(store.done), total: Double(max(store.total, 1)))
                        .frame(width: 140)
                }
                Button("写入 Bridge 元数据 (\(store.writableSuspects.count))") { store.confirmWrite = true }
                    .disabled(store.suspects.isEmpty || store.processing)
                Button("删除当前照片") {
                    if let u = store.selected { store.deleteURL = u; store.confirmDelete = true }
                }
                .disabled(store.selected == nil || store.processing)
                .foregroundColor(.red)
            }.padding(10)

            HStack {
                Text(store.status).font(.caption).foregroundColor(.secondary).lineLimit(2)
                Spacer()
                if !store.backupPath.isEmpty {
                    Button("打开写入前备份") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: store.backupPath))
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
            handleDrop(providers)
            return true
        }
        .alert("写入 Bridge 元数据", isPresented: $store.confirmWrite) {
            Button("取消", role: .cancel) { }
            Button("确认写入") { store.writeMetadata() }
        } message: {
            Text("""
            将对 \(store.writableSuspects.count) 张未合焦照片追加关键词「未合焦」，并把判定原因写入 IPTC Core 的说明与 Instructions 字段。

            已有的关键词、说明、颜色标签、星级都会被保留。RAW 只生成同名 .xmp 侧车，不改动原片。写入前的元数据会备份到「应用程序支持/FocusScreener/backups」。
            """)
        }
        .alert("删除照片", isPresented: $store.confirmDelete) {
            Button("取消", role: .cancel) { store.deleteURL = nil }
            Button("移到废纸篓", role: .destructive) {
                if let u = store.deleteURL {
                    let out = store.deletePhoto(u)
                    let names = out.moved.joined(separator: "、")
                    store.status = "已移到废纸篓：\(names)" +
                        (out.failed.map { "；失败：\($0)" } ?? "")
                }
                store.deleteURL = nil
            }
        } message: {
            if let u = store.deleteURL {
                let jpg = store.siblingJPG(for: u)
                Text("""
                将把 \(u.lastPathComponent) 移到废纸篓\(jpg == nil ? "" : "，以及同名的 \(jpg!.lastPathComponent)")。

                文件会进入废纸篓，仍可从废纸篓恢复。确认继续？
                """)
            }
        }
        .sheet(isPresented: $store.showShortcuts) {
            ShortcutsView().environmentObject(store)
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
struct FocusScreenerApp: App {
    @StateObject private var store = Store()
    var body: some Scene {
        WindowGroup("摄影照片筛选工具") {
            ContentView().environmentObject(store)
        }
        .defaultSize(width: 1060, height: 700)
    }
}
