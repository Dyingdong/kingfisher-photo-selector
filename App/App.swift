import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Foundation
import CoreGraphics

// MARK: - 状态

final class Store: ObservableObject {
    @Published var results: [PhotoResult] = []
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
    @Published var backupPath = ""
    @Published var dropTarget = false
    @Published var showHeatmap = true
    @Published var dragStart: CGPoint?
    @Published var dragCurrent: CGPoint?
    @Published var dragIsZoom = false
    @Published var didDrag = false
    @Published var excluded: Set<URL> = []
    @Published var anchorHi: Double?
    @Published var zoom: CGFloat = 1
    @Published var zoomCenter = CGPoint(x: 0.5, y: 0.5)
    @Published var selectionRatio: Double?
    @Published var selectionRect: CGRect?
    @Published var wbCache: [URL: WhiteBalanceStats] = [:]
    @Published var afCache: [URL: AFInfo] = [:]
    @Published var exifCache: [URL: ExifInfo] = [:]
    @Published var showAFPoints = true
    /// 当前选中照片的原尺寸预览；分析用小图只用于缩略图与打分。
    @Published var fullPreview: CGImage?
    @Published var fullPreviewURL: URL?
    /// 空格键平移：panMode 时左键拖动只移动画面，不圈选。
    @Published var panMode = false
    @Published var panOffset = CGSize.zero
    @Published var panStart: CGPoint?
    @Published var panBegin = CGSize.zero

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
        let allowed = MetadataWriter.jpgExts.union(MetadataWriter.rawExts)
        if let e = fm.enumerator(at: folder, includingPropertiesForKeys: [.isDirectoryKey],
                                 options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
            for case let u as URL in e where allowed.contains(u.pathExtension.lowercased()) {
                files.append(u)
            }
        }
        process(files.sorted { $0.lastPathComponent < $1.lastPathComponent })
    }

    func scan(files: [URL]) {
        let allowed = MetadataWriter.jpgExts.union(MetadataWriter.rawExts)
        process(files.filter { allowed.contains($0.pathExtension.lowercased()) }
                     .sorted { $0.lastPathComponent < $1.lastPathComponent })
    }

    private func process(_ files: [URL]) {
        guard !files.isEmpty else {
            status = "没有找到可处理的 JPG / RAW 照片"
            return
        }
        cancelled = false
        processing = true
        done = 0
        total = files.count
        results = []
        wbCache = [:]
        afCache = [:]
        exifCache = [:]
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
                self.results = list
                self.processing = false
                self.status = "已分析 \(found.count) 张，疑似失焦 \(self.suspects.count) 张"
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
        status = "已按新灵敏度重算，疑似失焦 \(suspects.count) 张"
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
        guard afCache[url] == nil else { return }
        DispatchQueue.global(qos: .utility).async {
            let info = AFReader.read(url)
            DispatchQueue.main.async { self.afCache[url] = info }
        }
    }

    func ensureExif(for url: URL) {
        guard exifCache[url] == nil else { return }
        DispatchQueue.global(qos: .utility).async {
            let info = ExifInfo.read(url)
            DispatchQueue.main.async { self.exifCache[url] = info }
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
    let bs = CGFloat(Analyzer.block)
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
            let rect = NSRect(x: CGFloat(c) * bs,
                              y: size.height - CGFloat(r + 1) * bs,
                              width: bs, height: bs)
            NSBezierPath(rect: rect).fill()
        }
    }
    img.unlockFocus()
    return img
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
                let host = self.superview ?? win.contentView
                guard let host else { return event }
                let p = host.convert(event.locationInWindow, from: nil)
                guard host.bounds.contains(p) else { return event }
                let topLeft = CGPoint(x: p.x, y: host.bounds.height - p.y)
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

// MARK: - 空格键平移桥接
// 空格不是 modifier flag，SwiftUI 手势拿不到。这里在 AppKit 层监听空格键；
// 按住空格时直接接管左键按下/拖动/抬起并吞掉事件，因此不会和圈选/放大手势打架。

struct PanBridge: NSViewRepresentable {
    var onPan: (Bool) -> Void
    var onStart: (CGPoint) -> Void
    var onMove: (CGPoint) -> Void
    var onEnd: (CGPoint) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView {
        let v = PanNSView()
        v.coordinator = context.coordinator
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        guard let v = nsView as? PanNSView else { return }
        let c = v.coordinator
        c?.onPan = onPan; c?.onStart = onStart; c?.onMove = onMove; c?.onEnd = onEnd
    }

    final class Coordinator {
        var onPan: ((Bool) -> Void)?
        var onStart: ((CGPoint) -> Void)?
        var onMove: ((CGPoint) -> Void)?
        var onEnd: ((CGPoint) -> Void)?
    }

    final class PanNSView: NSView {
        weak var coordinator: Coordinator?
        private var keyDownMonitor: Any?
        private var keyUpMonitor: Any?
        private var mouseMonitor: Any?
        private var panning = false

        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); install() }
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil { remove() }
            super.viewWillMove(toWindow: newWindow)
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        private func install() {
            guard keyDownMonitor == nil, window != nil else { return }
            keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
                guard let self, e.keyCode == 49, self.window != nil else { return e }
                if !self.panning {
                    self.panning = true
                    self.coordinator?.onPan?(true)
                }
                return nil // 吞掉空格，避免触发按钮/菜单
            }
            keyUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak self] e in
                guard let self, e.keyCode == 49 else { return e }
                self.finishPan()
                return nil
            }
            mouseMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
            ) { [weak self] e in
                guard let self, self.panning, let win = self.window, e.window === win else { return e }
                let host = self.superview ?? win.contentView
                guard let host else { return e }
                let p = host.convert(e.locationInWindow, from: nil)
                guard host.bounds.contains(p) else { return e }
                let topLeft = CGPoint(x: p.x, y: host.bounds.height - p.y)
                switch e.type {
                case .leftMouseDown: self.coordinator?.onStart?(topLeft)
                case .leftMouseDragged: self.coordinator?.onMove?(topLeft)
                case .leftMouseUp: self.coordinator?.onEnd?(topLeft)
                default: break
                }
                return nil // 平移期间吞掉左键，交给平移逻辑
            }
            NotificationCenter.default.addObserver(
                self, selector: #selector(resign),
                name: NSApplication.didResignActiveNotification, object: nil
            )
        }

        @objc private func resign() { finishPan() }

        private func finishPan() {
            guard panning else { return }
            panning = false
            coordinator?.onPan?(false)
        }

        private func remove() {
            [keyDownMonitor, keyUpMonitor, mouseMonitor].compactMap { $0 }.forEach(NSEvent.removeMonitor)
            keyDownMonitor = nil; keyUpMonitor = nil; mouseMonitor = nil
            NotificationCenter.default.removeObserver(self)
            panning = false
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

    var body: some View {
        let m = r.metrics
        let shownImage = store.fullPreviewURL == r.id ? (store.fullPreview ?? m.preview) : m.preview
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Toggle("锐度热力图", isOn: $store.showHeatmap)
                Toggle("对焦点", isOn: $store.showAFPoints)
                Button("－") { store.zoomOut() }.frame(width: 26)
                Text(String(format: "%.1f×", store.zoom)).font(.caption).monospacedDigit()
                Button("＋") { store.zoomIn() }.frame(width: 26)
                Button("复位") { store.resetZoom() }.font(.caption)
                Spacer()
                Text("在图上拖框可圈选主体并重判 · ⌘/右键拖框放大 · 空格+拖动平移 · 单击还原")
                    .font(.caption).foregroundColor(.secondary).lineLimit(1)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)

            GeometryReader { geo in
                let aspect = CGFloat(max(m.width, 1)) / CGFloat(max(m.height, 1))
                let fitW = min(geo.size.width, geo.size.height * aspect)
                let fitH = fitW / aspect
                let ox = (geo.size.width - fitW) / 2
                let oy = (geo.size.height - fitH) / 2
                let scale = store.zoom

                ZStack {
                    ZStack {
                        if let cg = shownImage {
                            Image(nsImage: NSImage(cgImage: cg,
                                                   size: NSSize(width: cg.width, height: cg.height)))
                                .resizable().frame(width: fitW, height: fitH)
                        }
                        if store.showHeatmap {
                            Image(nsImage: makeHeatmap(m, floor: store.heatFloor))
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
                            y: (store.zoomCenter.y - 0.5) * fitH * scale + store.panOffset.height)

                    if let s = store.dragStart, let c = store.dragCurrent {
                        Rectangle().stroke(store.dragIsZoom ? Color.yellow : Color.cyan, lineWidth: 2)
                            .background((store.dragIsZoom ? Color.yellow : Color.cyan).opacity(0.12))
                            .frame(width: abs(c.x - s.x), height: abs(c.y - s.y))
                            .position(x: (s.x + c.x) / 2, y: (s.y + c.y) / 2)
                    }
                    RightDragBridge(
                        onStart: { p in
                            store.dragIsZoom = true
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
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                store.didDrag = false
                            }
                        }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
                    PanBridge(
                        onPan: { pressed in
                            store.panMode = pressed
                            if !pressed { store.panStart = nil }
                        },
                        onStart: { p in
                            store.panStart = p
                            store.panBegin = store.panOffset
                            store.didDrag = true
                        },
                        onMove: { p in
                            guard let s = store.panStart else { return }
                            store.panOffset = CGSize(
                                width: store.panBegin.width + p.x - s.x,
                                height: store.panBegin.height + p.y - s.y
                            )
                        },
                        onEnd: { _ in
                            store.panStart = nil
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                store.didDrag = false
                            }
                        }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
                }
                .clipped()
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 4)
                    .onChanged { v in
                        if store.panMode {
                            // 空格 + 左键：只平移画面，不圈选、不放大。
                            if store.panStart == nil {
                                store.panStart = v.location
                                store.panBegin = store.panOffset
                            }
                            if let start = store.panStart {
                                store.panOffset = CGSize(
                                    width: store.panBegin.width + v.location.x - start.x,
                                    height: store.panBegin.height + v.location.y - start.y
                                )
                            }
                            store.didDrag = true
                            store.dragStart = nil
                            store.dragCurrent = nil
                            return
                        }
                        if store.dragStart == nil {
                            store.dragIsZoom = NSEvent.modifierFlags.contains(.command)
                        }
                        store.dragStart = v.startLocation
                        store.dragCurrent = v.location
                    }
                    .onEnded { v in
                        if store.panMode {
                            store.panStart = nil
                            return
                        }
                        let s = v.startLocation, e = v.location
                        let dx = e.x - s.x, dy = e.y - s.y
                        // 左键单击（没有拖出有效距离）= 恢复 1×、清除平移与选区。
                        // 必须在 DragGesture 的 onEnded 里处理：SwiftUI 即便没有拖动
                        // 也会调用 onEnded，先置 didDrag 会让并列的 TapGesture 被吞掉。
                        if hypot(dx, dy) < 4 {
                            store.resetZoom()
                            store.dragStart = nil
                            store.dragCurrent = nil
                            return
                        }
                        store.didDrag = true
                        let rect = imageRect(s, e, fitW: fitW, fitH: fitH, ox: ox, oy: oy)
                        if abs(dx) > 8, abs(dy) > 8 {
                            if store.dragIsZoom {
                                zoomToSelection(s, e, metrics: m,
                                                fitW: fitW, fitH: fitH, ox: ox, oy: oy)
                            } else {
                                store.recheck(id: r.id, rect: rect)
                            }
                        }
                        store.dragStart = nil
                        store.dragCurrent = nil
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            store.didDrag = false
                        }
                    })
                // 兜底：某些 macOS 版本上纯点击不会触发 DragGesture.onEnded。
                .simultaneousGesture(TapGesture(count: 1).onEnded {
                    if !store.didDrag { store.resetZoom() }
                })
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

    var body: some View {
        let m = r.metrics
        let wb = store.wbCache[r.id]
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(r.verdict.rawValue)
                        .foregroundColor(verdictColor(r.verdict)).fontWeight(.medium)
                    if r.verdict.isSuspect {
                        Button(store.excluded.contains(r.id) ? "已排除写入" : "排除写入") {
                            store.toggleExclude(r.id)
                        }
                        .buttonStyle(.borderless).font(.caption)
                    }
                    Spacer()
                    Text("主体定位：\(m.subjectSource)").font(.caption).foregroundColor(.secondary)
                }
                Text(r.reason).font(.callout)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 10)],
                          alignment: .leading, spacing: 8) {
                    cell("最锐区 P99", String(format: "%.0f", m.globalHi))
                    cell("失焦基准", String(format: "%.0f（%@）", store.heatFloor, store.anchorName))
                    cell("主体锐度比", String(format: "%.3f", m.ratio))
                    cell("中心锐度比", String(format: "%.3f", m.centerRatio))
                    cell("偏软块占比", String(format: "%.0f%%", m.softRatio * 100))
                    cell("重模糊比", String(format: "%.2f", m.reblurRatio))
                    cell("主体重模糊", String(format: "%.2f", m.subjectReblur))
                    cell("方向性", String(format: "%.2f", m.anisotropy))
                    if let sr = store.selectionRatio {
                        cell("⌘ 选区锐度比", String(format: "%.3f", sr))
                    }
                }

                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text("拍摄参数").font(.caption).foregroundColor(.secondary)
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
                VStack(alignment: .leading, spacing: 4) {
                    Text("白平衡 / 曝光参考").font(.caption).foregroundColor(.secondary)
                    if let wb {
                        HStack(spacing: 16) {
                            cell("全图 R/G:B/G", String(format: "%.2f : %.2f",
                                 wb.meanR / max(wb.meanG, 1), wb.meanB / max(wb.meanG, 1)))
                            if let fr = wb.faceRG, let fb = wb.faceBG {
                                cell("人脸 R/G:B/G", String(format: "%.2f : %.2f", fr, fb))
                            }
                            cell("高光裁剪", String(format: "%.2f%%", wb.highlightClip * 100))
                            cell("死黑占比", String(format: "%.2f%%", wb.shadowClip * 100))
                        }
                        Text(wb.summary).font(.caption).foregroundColor(.secondary)
                    } else {
                        Text("正在读取白平衡统计…").font(.caption).foregroundColor(.secondary)
                    }
                Text("灰块 = 该处纹理太少，无法判断锐度。热力图是相对参考，不是相机 K 值或测光表。")
                    .font(.caption2).foregroundColor(.secondary)
            }
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Text("相机对焦点").font(.caption).foregroundColor(.secondary)
                if let af = store.afCache[r.id] {
                    Text(af.summary).font(.callout)
                    if let p = af.points.first {
                        Text("对焦框 \(Int(p.w * 100))%×\(Int(p.h * 100))% · 画面 \(Int(p.cx * 100))%, \(Int(p.cy * 100))%")
                            .font(.caption2).foregroundColor(.secondary)
                    }
                    Text("读取自 RAW 原始文件；DNG 代理或转档后可能保留旧数据，仅供参考。")
                        .font(.caption2).foregroundColor(.secondary)
                } else {
                    Text("无对焦点数据（非 RAW、或相机未记录）").font(.caption).foregroundColor(.secondary)
                }
            }
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
        }
        .onChange(of: r.id) { u in
            store.ensureWB(for: u)
            store.ensureAF(for: u)
            store.ensureExif(for: u)
        }
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
                    Text("JPG / RAW · 锐度热力图 · 失焦辅助 · 白平衡参考 · Bridge 元数据")
                        .font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                Button("选择文件夹") { pickFolder() }
                Button("导出 CSV 报告") { store.exportCSV() }
                    .disabled(store.results.isEmpty)
            }.padding(12)

            Divider()

            HSplitView {
                VStack(spacing: 0) {
                    HStack {
                        Toggle("只看疑似", isOn: $store.onlySuspect)
                        Spacer()
                        Text("\(store.shown.count) 张").font(.caption).foregroundColor(.secondary)
                    }.padding(8)
                    List(selection: $store.selected) {
                        ForEach(store.shown) { r in
                            ResultRow(r: r).tag(r.id)
                        }
                    }
                }
                .frame(minWidth: 150, idealWidth: 180, maxWidth: 400)
                .frame(maxHeight: .infinity)

                VSplitView {
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
                    .frame(minHeight: 180, idealHeight: 430, maxHeight: .infinity)
                    .frame(maxWidth: .infinity)

                    Group {
                        if let id = store.selected,
                           let r = store.results.first(where: { $0.id == id }) {
                            InfoView(r: r)
                        } else {
                            Text("选中照片后显示清晰度、白平衡等信息")
                                .foregroundColor(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .frame(minHeight: 120, idealHeight: 150, maxHeight: .infinity)
                    .frame(maxWidth: .infinity)
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
            将对 \(store.writableSuspects.count) 张疑似失焦照片追加关键词「失焦」，并把判定原因写入 IPTC Core 的说明与 Instructions 字段。

            已有的关键词、说明、颜色标签、星级都会被保留。RAW 只生成同名 .xmp 侧车；JPG 只插入 XMP 段，图像数据不变。写入前的元数据会备份到「应用程序支持/FocusScreener/backups」。
            """)
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
