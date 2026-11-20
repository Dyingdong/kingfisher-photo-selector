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
    case divider   // 拖动分隔条（在预览区外、下方的 8pt 区域）
}

/// 用户可自定义的快捷键，持久化到 UserDefaults。
struct ShortcutSettings: Codable, Equatable {
    var zoom: ModifierKey = .command       // 框选放大，默认 ⌘
    var subject: ModifierKey = .control    // 圈选主体，默认 ⌃(Control)

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
    @Published var selected: URL? {
        didSet {
            // 切换照片时做两件事：
            // 1) 把上一张的评星依据、合焦信息（含鸟类识别）写进该照片元数据的「说明」
            //    ——用户 2026-11-19 要求，且只动说明字段，其他元数据一律不碰；
            // 2) 缩放/平移复位；人工圈选记录按照片持久保留，切走再切回来仍在。
            guard oldValue != selected else { return }
            if let old = oldValue { writeDescription(for: old) }
            resetZoom()
        }
    }
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
    @Published var afAttempted: Set<URL> = []
    @Published var exifCache: [URL: ExifInfo] = [:]
    /// 对焦点处语义（人脸/鸟/其他），用于题材识别；随 AF 加载后异步算一次。
    @Published var focusCache: [URL: FocusSemantics] = [:]
    /// 画面中是否有人（不依赖露脸，人体姿态检测），用于无脸人像的题材兜底。
    @Published var humanCache: [URL: HumanPresence] = [:]
    /// AI 主体识别缓存：分割+分类较慢，异步算一次；nil 占位表示「进行中」。
    @Published var aiCache: [URL: AISubject?] = [:]
    /// Bridge 星级：-1 = 拒绝，0~5 = 星级，nil = 未评分。
    @Published var ratingCache: [URL: Int] = [:]
    @Published var showAFPoints = true
    /// 构图辅助线：九宫格与对角线。默认开启（2026-11-19 用户要求），
    /// 线条画得很淡（见 CompositionGuides），不影响看图。
    @Published var showThirds = true
    @Published var showDiagonals = true
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
        focusCache = [:]
        humanCache = [:]
        aiCache = [:]
        ratingCache = [:]
        genreOverride = [:]
        heatCache = [:]
        baseCache = [:]
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
        // 同时持久记录显示用圈选框：切照片/复位缩放后仍按这张照片恢复。
        selectionRects[id] = rect
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

    /// 对焦点语义：算一次缓存住。结果只影响题材识别，不算出来也能用原有规则。
    /// 传入主体检测框：对焦点没认出鸟时，拿主体框再复核一次能不能认出鸟。
    func ensureFocus(for url: URL, subjectBoxes: [CGRect] = []) {
        guard focusCache[url] == nil else { return }
        DispatchQueue.global(qos: .utility).async {
            let s = FocusSemanticsEngine.detect(url: url, subjectBoxes: subjectBoxes)
            DispatchQueue.main.async { self.focusCache[url] = s }
        }
    }

    /// 人体存在检测（背影/侧身也算人）：算一次缓存住。只影响题材识别的兜底判断。
    func ensureHuman(for url: URL) {
        guard humanCache[url] == nil else { return }
        DispatchQueue.global(qos: .utility).async {
            let h = HumanPresenceEngine.detect(url: url)
            DispatchQueue.main.async { self.humanCache[url] = h }
        }
    }

    /// AI 主体识别（前景实例分割 + 逐主体分类）：算一次缓存住。
    /// 与对焦点语义互补——对焦点认不出时看画面主体本身是什么。
    /// macOS 14 以下没有分割 API，结果是 nil，识别链退回原有规则。
    func ensureAI(for url: URL) {
        guard aiCache[url] == nil else { return }
        aiCache[url] = AISubject(kind: .none, reason: "AI 主体识别进行中…", labels: [])
        DispatchQueue.global(qos: .utility).async {
            let s = AISubjectEngine.detect(url: url)
            DispatchQueue.main.async {
                self.aiCache[url] = s ?? AISubject(kind: .none, reason: "本机系统不支持前景分割（需 macOS 14+）", labels: [])
            }
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
            .appendingPathComponent("Kingfisher-PhotoSelector/backups/\(stamp)")
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
                                 manualSubjectRatio: selectionDisplayRatio,
                                 focus: focusCache[r.id])
    }

    func setGenre(_ g: PhotoGenre?, for url: URL) {
        if let g = g {
            genreOverride[url] = g
            recordGenreCorrection(for: url, userGenre: g)
        } else {
            genreOverride.removeValue(forKey: url)
        }
    }

    /// 记住一次题材纠正：机器判错的瞬间是最宝贵的监督信号。
    /// 记录对焦点标签签名 + 焦距/镜头/主体来源，特征相似的照片以后按此优先。
    private func recordGenreCorrection(for url: URL, userGenre: PhotoGenre) {
        guard let r = results.first(where: { $0.id == url }) else { return }
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
        // 复位只针对放大/平移：人工圈选记录（黄框 + 评分参数）按照片保留。
    }

    func zoomIn() { zoom = min(8, zoom * 1.5) }
    func zoomOut() { zoom = max(1, zoom / 1.5) }

    func writeMetadata() {
        let targets = writableSuspects
        guard !targets.isEmpty else { return }
        let stamp = Int(Date().timeIntervalSince1970)
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kingfisher-PhotoSelector/backups/\(stamp)")
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
        var trashPairs: [(trash: URL, original: URL)] = []
        for t in targets {
            do {
                var resulting: NSURL?
                try FileManager.default.trashItem(at: t, resultingItemURL: &resulting)
                moved.append(t.lastPathComponent)
                removedURLs.insert(t)
                // 记录「废纸篓里的位置 ← 原位置」，⌘Z 撤销时原样搬回去
                if let r = resulting {
                    trashPairs.append((trash: r as URL, original: t))
                }
            } catch {
                failed = "\(t.lastPathComponent)：\(error.localizedDescription)"
            }
        }
        if !trashPairs.isEmpty { lastDeleted = trashPairs }
        // 从内存列表与缓存移除（只移除确实删掉的）
        results.removeAll { removedURLs.contains($0.id) }
        metrics.removeAll { removedURLs.contains($0.url) }
        for key in removedURLs {
            wbCache[key] = nil; afCache[key] = nil; exifCache[key] = nil; ratingCache[key] = nil
            focusCache[key] = nil; humanCache[key] = nil
            genreOverride[key] = nil
            afLoading.remove(key); afAttempted.remove(key)
            heatCache[key] = nil; baseCache[key] = nil
        }
        excluded = excluded.subtracting(removedURLs)
        if let s = selected, removedURLs.contains(s) {
            selected = shown.first?.id
        }
        return (moved, failed)
    }

    /// 最近一次删除的记录（废纸篓位置 ↔ 原位置），⌘Z 撤销用。
    var lastDeleted: [(trash: URL, original: URL)] = []
    /// 撤销最近一次删除：从废纸篓原样搬回原位置，并重新分析恢复到列表里。
    func undoDelete() {
        let pairs = lastDeleted
        guard !pairs.isEmpty else {
            status = "没有可撤销的删除"
            return
        }
        lastDeleted = []
        DispatchQueue.global(qos: .userInitiated).async {
            var restored: [URL] = []
            var failed: String?
            for p in pairs {
                let dir = p.original.deletingLastPathComponent()
                if !FileManager.default.fileExists(atPath: dir.path) {
                    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                }
                do {
                    try FileManager.default.removeItem(at: p.original)   // 原位置若已有同名文件先让位
                    try FileManager.default.moveItem(at: p.trash, to: p.original)
                    restored.append(p.original)
                } catch {
                    failed = "\(p.original.lastPathComponent)：\(error.localizedDescription)"
                }
            }
            DispatchQueue.main.async {
                if restored.isEmpty {
                    self.status = "撤销删除失败\(failed.map { "：\($0)" } ?? "")"
                    return
                }
                // 重新分析并插回列表（按文件名排序位置不重要，放最前即可）
                var newResults: [PhotoResult] = []
                for u in restored where MetadataWriter.isRAW(u) {
                    if let m = Analyzer.analyze(u, preferFaces: self.preferFaces) {
                        let (v, why) = Analyzer.classify(m, hiMin: self.hiMin)
                        newResults.append(PhotoResult(id: m.url, metrics: m, verdict: v, reason: why))
                    }
                }
                self.metrics.append(contentsOf: newResults.map { $0.metrics })
                self.results.append(contentsOf: newResults)
                self.status = "已撤销删除：\(restored.map { $0.lastPathComponent }.joined(separator: "、"))" +
                    (failed.map { "；失败：\($0)" } ?? "")
                if let first = newResults.first { self.selected = first.id }
            }
        }
    }

    // MARK: - 「说明」元数据写入（切照片时自动执行）

    /// 组一张照片的「说明」内容：鸟类类别（首位）→ 评星依据 → 合焦信息。
    /// 什么数据都没有（还没分析完）返回 nil，不写。
    private func describeNote(for url: URL) -> String? {
        guard let r = results.first(where: { $0.id == url }) else { return nil }
        let s = score(for: r)
        var seg: [String] = []
        if let bird = birdCategory(for: url) { seg.append("鸟类：\(bird)") }
        var scoreDesc = "建议 \(s.stars) 星（总分 \(Int(s.total))）"
        if let w = s.weakest, w.weight > 0 { scoreDesc += "，短板：\(w.name) \(Int(w.score)) 分" }
        seg.append("评星依据：\(scoreDesc)")
        seg.append("合焦：\(r.verdict.rawValue)——\(r.reason)")
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

    /// 把「说明」写进照片元数据（异步、只动 dc:description 一个字段）。
    /// 文件已不存在（刚被删除）时跳过，避免往废纸篓里的文件写侧车。
    func writeDescription(for url: URL) {
        guard FileManager.default.fileExists(atPath: url.path),
              let note = describeNote(for: url) else { return }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kingfisher-PhotoSelector/backups/descriptions")
        DispatchQueue.global(qos: .utility).async {
            do {
                _ = try MetadataWriter.setDescription(to: url, note: note, backupDir: dir)
                DispatchQueue.main.async {
                    self.status = "已写入说明：\(url.lastPathComponent)"
                }
            } catch {
                DispatchQueue.main.async {
                    self.status = "写入说明失败 \(url.lastPathComponent)：\(error.localizedDescription)"
                }
            }
        }
    }

    func exportCSV() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "摄影筛选报告.csv"
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
        let csv = Report.csv(results, hiMin: hiMin, sensitivity: sensitivity,
                             anchor: anchorHi, genres: genres, focusMiss: focusMiss)
        do {
            try csv.write(to: u, atomically: true, encoding: .utf8)
            status = "报告已导出：\(u.path)（可填「人工真值」列后用 verify.py 复核）"
        } catch { status = "导出失败：\(error.localizedDescription)" }
    }

    // MARK: 开发模式调试导出

    /// 开发模式：设置环境变量 KINGFISHER_DEV=1 启动才显示「导出调试 CSV」。
    /// 发布版没有这个按钮，也不写任何调试文件。
    let devMode = ProcessInfo.processInfo.environment["KINGFISHER_DEV"] == "1"

    /// 调试 CSV：每张照片的全部中间参数（合焦判定依据、各维度分数与依据、
    /// 对焦点语义标签、人体检测、题材判定链），用于对照真值调阈值。
    func exportDebugCSV() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "调试记录.csv"
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

/// 预览区里几种彩色框的图例，放在工具栏下方一行。
private struct FrameLegend: View {
    var body: some View {
        HStack(spacing: 14) {
            legend(Color.cyan, "青框＝AI 主体")
            legend(Color.red, "红框＝相机对焦点")
            legend(Color.yellow, "黄框＝人工圈选的主体")
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

/// 工具栏开关文字 + 小号灰色快捷键字母。快捷键本身仍由 .keyboardShortcut 绑定，
/// 这里只把字母显示出来，避免用户看不见 H/F/G/D。
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

struct DetailView: View {
    @EnvironmentObject var store: Store
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
        // 双击放大是「看」的操作：不写判定参数、不画黄框（黄框只标注圈选主体）。
    }

    var body: some View {
        let m = r.metrics
        VStack(spacing: 0) {
            if compact {
                // 右侧窄栏：开关一行、缩放一行，保证最窄时也不超出预览区宽度。
                HStack(spacing: 12) {
                    Toggle(isOn: $store.showHeatmap) { ShortcutToggleLabel(title: "锐度热力图", key: "H") }
                        .keyboardShortcut("h", modifiers: [])
                        .help("""
                        把画面分成小格计算每格的锐度后着色：绿＝锐利、黄＝偏软、红＝发虚、灰＝纹理太少无法判断。主体区域绿说明对焦在主体上；整片偏红说明整体没对上焦。只是相对参考，不影响判定。
                        （快捷键 H）
                        """)
                    Toggle(isOn: $store.showAFPoints) { ShortcutToggleLabel(title: "对焦点", key: "F") }
                        .keyboardShortcut("f", modifiers: [])
                    Toggle(isOn: $store.showThirds) { ShortcutToggleLabel(title: "九宫格", key: "G") }
                        .keyboardShortcut("g", modifiers: [])
                    Toggle(isOn: $store.showDiagonals) { ShortcutToggleLabel(title: "对角线", key: "D") }
                        .keyboardShortcut("d", modifiers: [])
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.vertical, 4)
                HStack(spacing: 12) {
                    Button("－") { store.zoomOut() }.frame(width: 26)
                    Text(String(format: "%.1f×", store.zoom)).font(.caption).monospacedDigit()
                    Button("＋") { store.zoomIn() }.frame(width: 26)
                    Button("复位") { store.resetZoom() }.font(.caption)
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.bottom, 4)
                .help("\(store.shortcuts.zoom.symbol)+左键拖框放大 · \(store.shortcuts.subject.symbol)+左键圈选主体 · 按住左键拖动平移 · 双击放大对焦点 · 滚轮缩放 · 单击还原 · 快捷键：H 热力图 / F 对焦点 / G 九宫格 / D 对角线 / ⌘1-5 评星 / ⌘0 清除星级 / ⌘⌫ 删除（⌘Z 撤销）")
            } else {
                HStack(spacing: 12) {
                    Toggle(isOn: $store.showHeatmap) { ShortcutToggleLabel(title: "锐度热力图", key: "H") }
                        .keyboardShortcut("h", modifiers: [])
                        .help("""
                        把画面分成小格计算每格的锐度后着色：绿＝锐利、黄＝偏软、红＝发虚、灰＝纹理太少无法判断。主体区域绿说明对焦在主体上；整片偏红说明整体没对上焦。只是相对参考，不影响判定。
                        （快捷键 H）
                        """)
                    Toggle(isOn: $store.showAFPoints) { ShortcutToggleLabel(title: "对焦点", key: "F") }
                        .keyboardShortcut("f", modifiers: [])
                    Toggle(isOn: $store.showThirds) { ShortcutToggleLabel(title: "九宫格", key: "G") }
                        .keyboardShortcut("g", modifiers: [])
                    Toggle(isOn: $store.showDiagonals) { ShortcutToggleLabel(title: "对角线", key: "D") }
                        .keyboardShortcut("d", modifiers: [])
                    Button("－") { store.zoomOut() }.frame(width: 26)
                    Text(String(format: "%.1f×", store.zoom)).font(.caption).monospacedDigit()
                    Button("＋") { store.zoomIn() }.frame(width: 26)
                    Button("复位") { store.resetZoom() }.font(.caption)
                    Spacer()
                    Text("\(store.shortcuts.zoom.symbol)+左键拖框放大 · \(store.shortcuts.subject.symbol)+左键圈选主体 · 按住左键拖动平移 · 双击放大对焦点 · 滚轮缩放 · 单击还原 · H/F/G/D 切换热力图/对焦点/九宫格/对角线 · ⌘1-5 评星 · ⌘0 清除 · ⌘⌫ 删除（⌘Z 撤销）")
                        .font(.caption).foregroundColor(.secondary).lineLimit(1)
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
            }

            FrameLegend()

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
                            AFPointsOverlay(points: af.points, fitW: fitW, fitH: fitH, scale: scale)
                        }
                        CompositionGuides(fitW: fitW, fitH: fitH,
                                          thirds: store.showThirds,
                                          diagonals: store.showDiagonals,
                                          scale: scale)
                        // 黄框＝人工圈选主体：按照片持久保留；青框 AI 主体在上方独立绘制，不受影响
                        if let sel = store.selectionRect {
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
                        // 拖框预览：圈选主体画黄框（松手后保留）；框选放大画白框（纯看图）
                        Rectangle().stroke(store.dragIsZoom ? Color.white : Color.yellow, lineWidth: 2)
                            .background((store.dragIsZoom ? Color.white : Color.yellow).opacity(0.12))
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
                                zoomToSelection(s, p,
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

// MARK: - 综合评分区（替换原合焦块）

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
            if store.ratingCache[r.id] != nil {
                Text("当前 \(store.ratingCache[r.id]! == -1 ? "拒绝" : "\(store.ratingCache[r.id]!) 星")")
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
                    Text("自动识别（\(score.genre.rawValue)）").tag("auto")
                    ForEach(PhotoGenre.allCases) { g in Text(g.rawValue).tag(g.rawValue) }
                }
                .pickerStyle(.menu).frame(width: compact ? 200 : 168, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(score.genreIsGuess ? "自动识别依据：\(score.genreReason)"
                                    : "题材已手动指定")
                .font(.caption2).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .help(score.genreIsGuess
                      ? "软件按「\(score.genreReason)」判为该题材；不准可在上面手动改"
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
                    .keyboardShortcut(KeyEquivalent(n.description.first ?? "1"), modifiers: .command)
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
                // ⌘0：清除星级（隐藏按钮只承载快捷键）
                Button { store.setRating(r.id, rating: 0) } label: { EmptyView() }
                    .keyboardShortcut("0", modifiers: .command)
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

                // 3) 综合评分：建议星级 + 题材 + 各维度，替换原合焦结论块
                ScorePanel(r: r, score: store.score(for: r), compact: compact)

                Divider()

                // 3b) 合焦结论 + 判断依据：同一个区域、中间不分割（用户 2026-11-19 要求）
                HStack(spacing: 6) {
                    Image(systemName: r.verdict.isSuspect ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundColor(verdictColor(r.verdict))
                    Text("合焦判定：\(r.verdict.rawValue)").font(.caption)
                        .foregroundColor(verdictColor(r.verdict))
                    Text("· \(r.reason)").font(.caption2).foregroundColor(.secondary)
                        .lineLimit(1).help(r.reason)
                }

                // 4) 判断依据：全部常显，名字说人话，悬停看解释
                VStack(alignment: .leading, spacing: 6) {
                    sectionTitle("判断依据（鼠标停上看解释）")
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
                    Text("主体位置：\(subjectLabel(m.subjectSource))")
                        .font(.caption2).foregroundColor(.secondary)
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
            if let nr = store.results.first(where: { $0.id == u }) {
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

    /// 预览窗格：选中照片时是 DetailView，否则是空态提示。两种布局共用。
    @ViewBuilder
    private var previewPane: some View {
        if let id = store.selected,
           let r = store.results.first(where: { $0.id == id }) {
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
           let r = store.results.first(where: { $0.id == id }) {
            InfoView(r: r, compact: compact)
        } else {
            Text("选中照片后显示清晰度、白平衡等信息")
                .foregroundColor(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Kingfisher-PhotoSelector").font(.title3).fontWeight(.medium)
                    Text("RAW · 锐度热力图 · 合焦辅助 · 白平衡参考 · Bridge 元数据")
                        .font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                Button(store.infoOnRight ? "信息区：右侧" : "信息区：下方") {
                    store.infoOnRight.toggle()
                }
                .font(.caption)
                .help("切换信息区位置：默认在预览下方；点一下竖排到画面最右侧")
                Button("快捷键") { store.showShortcuts = true }.font(.caption)
                Button("选择文件夹") { pickFolder() }
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
                    .disabled(store.results.isEmpty)
                if store.devMode {
                    Button("导出调试 CSV") { store.exportDebugCSV() }
                        .disabled(store.results.isEmpty)
                        .help("开发模式：导出全部中间参数（合焦依据、各维度分数、对焦点语义标签、题材判定链），用于对照真值调阈值。设置环境变量 KINGFISHER_DEV=1 才显示。")
                }
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
                    .help("""
                    开启后，「写入 Bridge 元数据」会给每张未合焦照片加上红色颜色标签（xmp:Label=Red），
                    在 Bridge 里一眼就能把废片筛出来；关闭则只写关键词和说明，不动颜色标签。
                    """)
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
                .keyboardShortcut(.delete, modifiers: .command)
            }.padding(10)

            HStack {
                Text(store.status).font(.caption).foregroundColor(.secondary).lineLimit(2)
                Spacer()
                // ⌘Z：撤销最近一次删除（隐藏按钮只承载快捷键，从废纸篓原样搬回）
                Button { store.undoDelete() } label: { EmptyView() }
                    .keyboardShortcut("z", modifiers: .command)
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

            已有的关键词、说明、颜色标签、星级都会被保留。RAW 只生成同名 .xmp 侧车，不改动原片。写入前的元数据会备份到「应用程序支持/Kingfisher-PhotoSelector/backups」。
            """)
        }
        .alert("删除照片", isPresented: $store.confirmDelete) {
            Button("取消", role: .cancel) { store.deleteURL = nil }
            Button("移到废纸篓", role: .destructive) {
                if let u = store.deleteURL {
                    let out = store.deletePhoto(u)
                    let names = out.moved.joined(separator: "、")
                    store.status = "已移到废纸篓：\(names)（⌘Z 可撤销）" +
                        (out.failed.map { "；失败：\($0)" } ?? "")
                }
                store.deleteURL = nil
            }
        } message: {
            if let u = store.deleteURL {
                let jpg = store.siblingJPG(for: u)
                Text("""
                将把 \(u.lastPathComponent) 移到废纸篓\(jpg == nil ? "" : "，以及同名的 \(jpg!.lastPathComponent)")。

                文件会进入废纸篓，确认后可用 ⌘Z 撤销（自动从废纸篓搬回并恢复到列表）。确认继续？
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
