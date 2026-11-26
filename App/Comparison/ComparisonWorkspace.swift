import SwiftUI
import ImageIO
import UniformTypeIdentifiers

struct PhotoWorkspaces: View {
    @EnvironmentObject private var store: Store
    @StateObject private var comparison = ComparisonSession()
    @State private var isComparing = KingfisherPhotoSelectorApp.pendingLoad == nil

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Label { Text("Kingfisher-PhotoSelector") } icon: { KingfisherMark().stroke(lineWidth: 1.4).frame(width: 21, height: 19).accessibilityHidden(true) }
                    .font(.headline)
                Spacer()
                tab("照片筛选", active: !isComparing) {
                    comparison.leaveGroup { isComparing = false }
                }
                tab("对比筛选", active: isComparing) { isComparing = true }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(.bar)
            Divider()
            if isComparing {
                ComparisonWorkspace(session: comparison)
            } else {
                ContentView()
            }
        }
        // 照片筛选切到后台工作区时也要保存最近一次已编码的快照。
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            store.saveSessionOnExit()
        }
    }

    private func tab(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .fontWeight(active ? .semibold : .regular)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(active ? Color.accentColor.opacity(0.20) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? [.isSelected] : [])
    }
}

private enum ComparisonDecision: String {
    case reject = "已放弃"
}

private final class ComparisonViewport: ObservableObject {
    struct Position {
        var zoom: CGFloat = 1
        var center = CGPoint(x: 0.5, y: 0.5)
    }
    @Published var positions = [Position(), Position()]
    var fittedCoverage = [CGSize(width: 1, height: 1), CGSize(width: 1, height: 1)]

    func zoom(_ steps: Int, side: Int) {
        let current = positions[side]
        let scale = steps == 0 ? 1 : min(8, max(1, current.zoom * (steps > 0 ? 1.25 : 0.8)))
        positions[side] = scale == 1 ? Position() : Position(zoom: scale, center: current.center)
    }

    func pan(side: Int, x: Int, y: Int) {
        var updated = positions
        for index in side == 2 ? [0, 1] : [side] where updated[index].zoom > 1 {
            let scale = updated[index].zoom
            let marginX = min(0.5, 0.5 / (max(0.001, fittedCoverage[index].width) * scale))
            let marginY = min(0.5, 0.5 / (max(0.001, fittedCoverage[index].height) * scale))
            let center = updated[index].center
            updated[index].center = CGPoint(
                x: min(1 - marginX, max(marginX, center.x - CGFloat(x) * 0.12 / scale)),
                y: min(1 - marginY, max(marginY, center.y - CGFloat(y) * 0.12 / scale))
            )
        }
        positions = updated
    }
}

@MainActor
private final class ComparisonSession: ObservableObject {
    @Published var directory: URL?
    @Published var groups: [ComparisonGroup] = []
    @Published var group: ComparisonGroup?
    @Published var base: Int?
    @Published var candidate: Int?
    let viewport = ComparisonViewport()
    @Published var showsDirectory = true
    @Published var scanning = false
    @Published var error: String?
    @Published var deleting = false
    @Published var operationError: String?
    @Published var showFocus = true
    @Published var decisions: [URL: ComparisonDecision] = [:] {
        didSet {
            updatePendingSession()
        }
    }
    @Published private(set) var pendingJPEGs: [URL: URL] = [:] { didSet { updatePendingSession() } }

    private func updatePendingSession() {
        if !pendingJPEGs.isEmpty || decisions.values.contains(.reject) {
            ComparisonQuitDelegate.pending[ObjectIdentifier(self)] = self
        } else {
            ComparisonQuitDelegate.pending[ObjectIdentifier(self)] = nil
        }
    }
    private struct UndoEntry {
        let id = UUID()
        var perform: () -> Void
    }
    @Published private var history: [UndoEntry] = []
    @Published private(set) var selection: Set<URL> = []
    private var selectionAnchor: URL?
    var hasExplicitSelection: Bool { selectionAnchor != nil }
    private var scanTask: Task<Void, Never>?
    private var groupPreviewTask: Task<Void, Never>?
    @Published private(set) var openingGroupID: String?

    private static let shortcutKey = "Kingfisher-PhotoSelector.comparisonShortcuts.v1"
    @Published private var shortcuts: [ComparisonKeyAction: ComparisonKey] = [:]

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.shortcutKey),
           let saved = try? JSONDecoder().decode([ComparisonKeyAction: ComparisonKey].self, from: data) {
            shortcuts = saved
        }
        ComparisonQuitDelegate.sessions.add(self)
    }

    func key(_ action: ComparisonKeyAction) -> ComparisonKey {
        shortcuts[action] ?? ComparisonKeyAction.defaults.first { $0.0 == action }!.2
    }

    func assign(_ action: ComparisonKeyAction, key proposed: ComparisonKey) -> String? {
        if proposed.reserved { return "方向键组合已保留用于导航。" }
        if let conflict = ComparisonKeyAction.defaults.first(where: { $0.0 != action && key($0.0) == proposed }) {
            return "该组合已用于「\(conflict.1)」。"
        }
        shortcuts[action] = proposed
        if let data = try? JSONEncoder().encode(shortcuts) {
            UserDefaults.standard.set(data, forKey: Self.shortcutKey)
        }
        return nil
    }

    func resetShortcuts() {
        shortcuts = [:]
        UserDefaults.standard.removeObject(forKey: Self.shortcutKey)
    }

    func handleKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(ComparisonKey.modifierMask)
        if modifiers.isEmpty || modifiers == .shift {
            switch event.keyCode {
            case 123: move(-1, extend: modifiers == .shift); return true
            case 124: move(1, extend: modifiers == .shift); return true
            case 125 where modifiers.isEmpty, 126 where modifiers.isEmpty:
                if !event.isARepeat { moveGroup(event.keyCode == 125 ? 1 : -1) }
                return true
            default: break
            }
        }
        guard let action = ComparisonKeyAction.defaults.first(where: { key($0.0).matches(event) })?.0 else { return false }
        switch action {
        case .group(let delta): if !event.isARepeat { moveGroup(delta) }
        case .undo: if !event.isARepeat { undo() }
        default:
            guard group != nil else { return false }
            switch action {
            case .candidate(let delta): move(delta)
            case .zoom(let steps, let baseline):
                if (baseline ? baseURL : candidateURL) != nil { viewport.zoom(steps, side: baseline ? 0 : 1) }
            case .pan(let side, let x, let y): viewport.pan(side: side, x: x, y: y)
            default:
                guard !event.isARepeat else { return true }
                switch action {
                case .rating(let stars, let baseline): rateSelection(stars, baseline: baseline)
                case .reject(let baseline): toggleReject(baseline: baseline)
                case .trash(let baseline): delete(baseline ? [baseURL].compactMap { $0 } : operationURLs, automatic: false)
                case .selectAll: selectAll()
                case .clearSelection:
                    clearSelection()
                    viewport.positions = [.init(), .init()]
                case .pin: pin()
                default: break
                }
            }
        }
        return true
    }

    @Published private(set) var ratings: [URL: Int] = [:]
    @Published private(set) var ratingWrites = 0
    private let ratingQueue = DispatchQueue(label: "Kingfisher.Comparison.Rating", qos: .userInitiated)
    private var ratingRevision: [URL: Int] = [:]
    private var pendingRatings: [URL: Int] = [:]

    var candidateURL: URL? { candidate.flatMap { group?.photos[$0] } }
    var baseURL: URL? { base.flatMap { group?.photos[$0] } }

    var operationURLs: [URL] {
        if hasExplicitSelection {
            return group?.photos.filter { selection.contains($0) } ?? []
        }
        return [candidateURL].compactMap { $0 }
    }

    func rateSelection(_ stars: Int, baseline: Bool, clicked: URL? = nil) {
        let urls = baseline ? [baseURL].compactMap { $0 }
            : hasExplicitSelection ? operationURLs : [clicked ?? candidateURL].compactMap { $0 }
        writeRatings(urls.map { ($0, stars) })
    }

    func loadRating(_ url: URL) async {
        guard pendingRatings[url] == nil else { return }
        let revision = ratingRevision[url]
        let value = await Task.detached(priority: .utility) { Self.readRating(url) }.value
        guard !Task.isCancelled, ratingRevision[url] == revision else { return }
        ratings[url] = value
    }

    nonisolated private static func readRating(_ url: URL) -> Int {
        if let value = MetadataWriter.snapshot(url).rating { return value }
        guard url.pathExtension.lowercased() == "dng",
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil),
              let rating = CGImageMetadataCopyStringValueWithPath(metadata, nil, "xmp:Rating" as CFString),
              let value = Int(rating as String), (-1...5).contains(value) else { return 0 }
        return value
    }

    private func writeRatings(_ changes: [(URL, Int)], recordUndo: Bool = true) {
        guard !deleting, !changes.isEmpty else { return }
        for (url, _) in changes {
            ratingRevision[url, default: 0] += 1
            pendingRatings[url, default: 0] += 1
        }
        ratingWrites += changes.count
        let entry = UndoEntry(perform: {})
        if recordUndo { history.append(entry) }
        ratingQueue.async {
            var applied: [(URL, Int, Int)] = []
            var errors: [String] = []
            for (url, stars) in changes {
                guard FileManager.default.fileExists(atPath: url.path) else {
                    errors.append("\(url.lastPathComponent)：照片已不存在")
                    continue
                }
                let previous = Self.readRating(url)
                guard previous != stars else {
                    applied.append((url, previous, stars))
                    continue
                }
                do {
                    _ = try MetadataWriter.setRating(to: url, rating: stars, backupDir: url.deletingLastPathComponent())
                    applied.append((url, previous, stars))
                } catch {
                    errors.append("\(url.lastPathComponent)：\(error.localizedDescription)")
                }
            }
            let results = applied
            let failures = errors
            DispatchQueue.main.async {
                self.ratingWrites -= changes.count
                for (url, _) in changes {
                    self.pendingRatings[url, default: 1] -= 1
                    if self.pendingRatings[url] == 0 { self.pendingRatings[url] = nil }
                }
                for (url, _, stars) in results { self.ratings[url] = stars }
                if !failures.isEmpty { self.operationError = failures.joined(separator: "\n") }
                let previousRatings = results.filter { $0.1 != $0.2 }.map { ($0.0, $0.1) }
                if let index = self.history.firstIndex(where: { $0.id == entry.id }) {
                    guard !previousRatings.isEmpty else { self.history.remove(at: index); return }
                    self.history[index].perform = { [weak self] in
                        self?.writeRatings(previousRatings, recordUndo: false)
                    }
                }
            }
        }
    }

    func open(_ url: URL) {
        scanTask?.cancel()
        cancelGroupPreview()
        if directory != url { history.removeAll() }
        directory = url
        showsDirectory = true
        groups = []
        group = nil
        clearSelection()
        error = nil
        scanning = true
        let worker = Task.detached(priority: .utility) { try BurstIndex.scan(url) }
        scanTask = Task { [weak self] in
            let result = await withTaskCancellationHandler {
                await worker.result
            } onCancel: {
                worker.cancel()
            }
            guard let self, !Task.isCancelled else { return }
            self.scanning = false
            switch result {
            case .success(let groups): self.groups = groups
            case .failure(let error): self.error = error.localizedDescription
            }
        }
    }

    private func initialPair(in group: ComparisonGroup) -> (base: Int?, candidate: Int?) {
        let base = group.name == "未分组" ? nil : group.photos.firstIndex { decisions[$0] != .reject }
        return (base, group.photos.indices.first { $0 != base })
    }

    private func select(_ group: ComparisonGroup) {
        let pair = initialPair(in: group)
        clearSelection()
        base = pair.base
        candidate = pair.candidate
        viewport.positions = [.init(), .init()]
        self.group = group
    }

    private func cancelGroupPreview() {
        groupPreviewTask?.cancel()
        groupPreviewTask = nil
        openingGroupID = nil
    }

    func openGroup(_ target: ComparisonGroup) {
        guard !deleting, ratingWrites == 0, openingGroupID != target.id else { return }
        cancelGroupPreview()
        guard group?.id != target.id else { return }
        let pair = initialPair(in: target)
        let previews = [pair.base, pair.candidate].compactMap { $0 }.map { target.photos[$0] }
        if previews.allSatisfy({ ComparisonDecoder.fitted.cached($0) != nil }) {
            leaveGroup(keepingPreview: true) { self.select(target) }
            return
        }

        // Keep the current pair visible until the target pair is ready to draw.
        openingGroupID = target.id
        groupPreviewTask = Task(priority: .userInitiated) { [weak self] in
            for url in previews {
                guard !Task.isCancelled else { return }
                _ = await ComparisonDecoder.fitted.decode(url)
            }
            guard let self, !Task.isCancelled else { return }
            self.openingGroupID = nil
            self.groupPreviewTask = nil
            self.leaveGroup(keepingPreview: true) {
                if let current = self.groups.first(where: { $0.id == target.id }) {
                    self.select(current)
                }
            }
        }
    }

    func clearSelection() {
        selection.removeAll()
        selectionAnchor = nil
    }

    func selectAll() {
        guard let group else { return }
        selection = Set(group.photos)
        selectionAnchor = candidateURL ?? baseURL
    }

    func selectPhoto(_ index: Int, modifiers: NSEvent.ModifierFlags) {
        guard let group, group.photos.indices.contains(index) else { return }
        let url = group.photos[index]
        if modifiers.contains(.shift) {
            let anchor = selectionAnchor ?? candidateURL ?? url
            let start = group.photos.firstIndex(of: anchor) ?? index
            selectionAnchor = anchor
            selection = Set(group.photos[min(start, index)...max(start, index)])
        } else if modifiers.contains(.command) {
            if !hasExplicitSelection, let candidateURL {
                selection.insert(candidateURL)
            }
            if !selection.insert(url).inserted { selection.remove(url) }
            selectionAnchor = url
            return
        } else {
            selection = [url]
            selectionAnchor = url
        }
        if index != base { candidate = index }
    }

    func moveGroup(_ delta: Int) {
        guard !groups.isEmpty else { return }
        let index = groups.firstIndex { $0.id == (openingGroupID ?? group?.id) }.map { $0 + delta }
            ?? (delta > 0 ? 0 : groups.count - 1)
        guard groups.indices.contains(index) else { return }
        let target = groups[index]
        openGroup(target)
    }

    func leaveGroup(keepingPreview: Bool = false, _ finish: @escaping () -> Void) {
        guard !deleting, ratingWrites == 0 else { return }
        cancelGroupPreview()
        let rejects = (group?.photos.filter { decisions[$0] == .reject } ?? []) + Array(pendingJPEGs.keys)
        let finishLeaving = {
            if !keepingPreview { self.group = nil }
            finish()
        }
        if rejects.isEmpty {
            finishLeaving()
        } else {
            delete(rejects, automatic: true) { success in
                if success { finishLeaving() }
            }
        }
    }

    func confirmDeletion(_ urls: [URL], automatic: Bool) -> Bool {
        if automatic && ComparisonQuitDelegate.skipAutomaticPrompt { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        if automatic {
            alert.messageText = "清理已放弃的照片？"
        } else if urls.count > 1 {
            alert.messageText = "删除选中的 \(urls.count) 张照片？"
        } else {
            alert.messageText = urls.first == baseURL ? "删除基准照片？" : "删除候选照片？"
        }
        if urls.contains(where: MetadataWriter.isJPEG) {
            alert.informativeText = "将本次待清理的 RAW 及其同名 JPEG、此前失败的 JPEG 移到废纸篓。待重试 JPEG：\(urls.filter(MetadataWriter.isJPEG).count) 张。"
        } else {
            let target = !automatic && urls.count == 1 ? (urls.first?.lastPathComponent ?? "") : "\(urls.count) 张 RAW"
            alert.informativeText = "将 \(target) 和同目录同名的 JPG（如有）移到废纸篓。"
        }
        alert.addButton(withTitle: "移到废纸篓").keyEquivalent = "\r"
        alert.addButton(withTitle: "取消").keyEquivalent = "\u{1b}"
        alert.showsSuppressionButton = automatic
        alert.suppressionButton?.title = "在退出软件前不再提醒"
        alert.suppressionButton?.state = .off
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        if automatic && alert.suppressionButton?.state == .on { ComparisonQuitDelegate.skipAutomaticPrompt = true }
        return true
    }

    func delete(_ urls: [URL], automatic: Bool, confirmed: Bool = false,
                completion: @escaping (Bool) -> Void = { _ in }) {
        guard !deleting, ratingWrites == 0 else { completion(false); return }
        guard !urls.isEmpty else { completion(true); return }
        guard confirmed || confirmDeletion(urls, automatic: automatic) else { completion(false); return }
        deleting = true
        let previousDirectory = directory
        let previousGroup = group
        let previousBase = baseURL
        let previousCandidate = candidateURL
        Task {
            let requested = Set(urls)
            let retries = pendingJPEGs.filter { requested.contains($0.key) }
            let raws = urls.filter(MetadataWriter.isRAW)
            let result = await Task.detached(priority: .userInitiated) { ComparisonTrash.move(raws, retries: retries) }.value
            for jpeg in retries.keys { pendingJPEGs.removeValue(forKey: jpeg) }
            pendingJPEGs.merge(result.failedJPEGs) { _, latest in latest }
            applyDeletion(result.removed)
            if !result.moves.isEmpty {
                history.append(UndoEntry { [weak self] in
                    self?.restore(result.moves, directory: previousDirectory,
                                  group: previousGroup, base: previousBase, candidate: previousCandidate)
                })
            }
            deleting = false
            if !result.errors.isEmpty { operationError = result.errors.joined(separator: "\n") }
            completion(result.errors.isEmpty)
        }
    }

    private func applyDeletion(_ removed: Set<URL>) {
        guard !removed.isEmpty else { return }
        let oldGroup = group
        let baseURL = base.flatMap { oldGroup?.photos[$0] }
        decisions = decisions.filter { !removed.contains($0.key) }
        clearSelection()
        groups = groups.compactMap {
            let photos = $0.photos.filter { !removed.contains($0) }
            return photos.isEmpty ? nil : ComparisonGroup(name: $0.name, photos: photos)
        }
        if let updated = groups.first(where: { $0.id == oldGroup?.id }) {
            base = baseURL.flatMap { updated.photos.firstIndex(of: $0) }
            let start = candidate ?? 0
            let oldPhotos = oldGroup?.photos ?? []
            let ordered = Array(oldPhotos.dropFirst(start)) + Array(oldPhotos.prefix(start).reversed())
            candidate = ordered.lazy.compactMap { updated.photos.firstIndex(of: $0) }
                .first { $0 != base }
            group = updated
        } else {
            group = nil
        }
    }

    private func restore(_ moves: [ComparisonTrash.Move], directory oldDirectory: URL?,
                         group oldGroup: ComparisonGroup?,
                         base oldBase: URL?, candidate oldCandidate: URL?) {
        deleting = true
        Task {
            let result = await Task.detached(priority: .userInitiated) { ComparisonTrash.restore(moves) }.value
            defer { deleting = false }
            if !result.errors.isEmpty { operationError = result.errors.joined(separator: "\n") }
            pendingJPEGs = pendingJPEGs.filter { !result.removed.contains($0.value) }
            guard let directory, directory == oldDirectory,
                  result.removed.contains(where: MetadataWriter.isRAW) else { return }
            let currentBase = baseURL
            let currentCandidate = candidateURL
            let preferred = [currentBase, currentCandidate, group?.photos.first, oldBase, oldCandidate].compactMap { $0 }
            do {
                let scanned = try await Task.detached(priority: .userInitiated) { try BurstIndex.scan(directory) }.value
                groups = scanned
                clearSelection()
                if let updated = preferred.lazy.compactMap({ url in scanned.first { $0.photos.contains(url) } }).first {
                    let oldMembers = Set(oldGroup?.photos ?? [])
                    let sameGroup = group == nil || group?.photos.contains(where: oldMembers.contains) == true
                    select(updated)
                    let preferredBase = sameGroup ? oldBase : currentBase
                    let preferredCandidate = sameGroup ? oldCandidate : currentCandidate
                    base = preferredBase.flatMap { updated.photos.firstIndex(of: $0) } ?? base
                    candidate = preferredCandidate.flatMap { updated.photos.firstIndex(of: $0) }
                    if candidate == nil || candidate == base {
                        candidate = updated.photos.indices.first { $0 != base }
                    }
                } else { group = nil }
            } catch { operationError = "照片已尝试恢复，刷新目录失败：\(error.localizedDescription)" }
        }
    }

    func move(_ delta: Int, extend: Bool = false) {
        if !extend { clearSelection() }
        guard let group, !group.photos.isEmpty else { return }
        let count = group.photos.count
        let start = candidate ?? (delta > 0 ? count - 1 : 0)
        for step in 1...count {
            let next = (start + delta * step + count) % count
            if next != base {
                if extend {
                    selectPhoto(next, modifiers: .shift)
                } else {
                    candidate = next
                }
                return
            }
        }
        candidate = nil
    }

    private var pinIndex: Int? {
        let targets = operationURLs
        guard targets.count == 1, let url = targets.first,
              let index = group?.photos.firstIndex(of: url), index != base else { return nil }
        return index
    }

    var canPin: Bool { pinIndex != nil }

    func pin() {
        guard let index = pinIndex, let group else { return }
        let priorBase = baseURL
        let priorCandidate = candidateURL
        let oldURL = baseURL
        let newURL = group.photos[index]
        let previousMarks = [oldURL, newURL].compactMap { $0 }.map { ($0, decisions[$0]) }
        var updated = decisions
        if let oldURL { updated[oldURL] = .reject }
        updated[newURL] = nil
        decisions = updated
        history.append(UndoEntry { [weak self] in
            guard let self else { return }
            var restored = self.decisions
            for (url, mark) in previousMarks { restored[url] = mark }
            self.decisions = restored
            self.restorePair(base: priorBase, candidate: priorCandidate)
        })
        base = index
        candidate = index
        move(1)
    }

    func toggleReject(baseline: Bool = false) {
        let urls = baseline ? [baseURL].compactMap { $0 } : operationURLs
        guard !urls.isEmpty else { return }
        let marking = urls.contains { decisions[$0] != .reject }
        let prior = urls.map { ($0, decisions[$0]) }
        let previousBase = baseURL
        let previousCandidate = candidateURL
        var updated = decisions
        for url in urls { updated[url] = marking ? .reject : nil }
        decisions = updated
        if marking, let group, let base, urls.contains(group.photos[base]) {
            let indices = Array(group.photos.indices.dropFirst(base + 1)) + Array(group.photos.indices.prefix(base))
            self.base = indices.first { decisions[group.photos[$0]] != .reject }
            if candidate == self.base || candidate == nil {
                candidate = group.photos.indices.first { $0 != self.base && decisions[group.photos[$0]] != .reject }
                    ?? group.photos.indices.first { $0 != self.base }
            }
            if self.base == nil { operationError = "本组没有未标记放弃的照片可设为基准。" }
        }
        history.append(UndoEntry { [weak self] in
            guard let self else { return }
            var restored = self.decisions
            for (url, previous) in prior { restored[url] = previous }
            self.decisions = restored
            self.restorePair(base: previousBase, candidate: previousCandidate)
        })
    }

    private func restorePair(base previousBase: URL?, candidate previousCandidate: URL?) {
        guard let photos = group?.photos else { return }
        let b = previousBase.flatMap { photos.firstIndex(of: $0) }
        let c = previousCandidate.flatMap { photos.firstIndex(of: $0) }
        guard b != nil || c != nil else { return }
        if previousBase == nil || b != nil { base = b }
        if previousCandidate == nil || c != nil { candidate = c }
        if candidate == base { candidate = photos.indices.first { $0 != base } }
    }

    func undo() {
        guard canUndo else { return }
        history.popLast()?.perform()
    }

    var canUndo: Bool { !history.isEmpty && !scanning && !deleting && ratingWrites == 0 }
}

@MainActor
private struct ComparisonWorkspace: View {
    @ObservedObject var session: ComparisonSession
    @State private var monitor: Any?
    @State private var showsShortcuts = false
    @State private var isDropTarget = false
    @State private var dropRequest: UUID?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button {
                    session.showsDirectory.toggle()
                } label: {
                    Label(session.showsDirectory ? "隐藏目录" : "显示目录", systemImage: "sidebar.left")
                }
                .disabled(session.groups.isEmpty)
                Text(session.group?.name ?? session.directory?.lastPathComponent ?? "对比筛选")
                    .font(.headline)
                Spacer()
                if session.group != nil {
                    Toggle("对焦点", isOn: $session.showFocus)
                    Button("退出分组") { session.leaveGroup {} }
                }
                Button("快捷键") { showsShortcuts.toggle() }
                    .help("查看对比筛选的快捷键和鼠标手势")
                    .popover(isPresented: $showsShortcuts) { shortcutHelp }
                Button("添加目录", action: pickDirectory)
            }
            .padding(12)
            Divider()
            if session.scanning {
                ProgressView("正在识别连拍…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = session.error {
                Text("读取目录失败：\(error)").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if session.groups.isEmpty {
                directoryPlaceholder
            } else {
                HStack(spacing: 0) {
                    if session.showsDirectory {
                        directorySidebar
                        Divider()
                    }
                    if let group = session.group {
                        comparison(group)
                    } else {
                        Text("从连拍目录选择一组照片")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .background(Color.clear.contentShape(Rectangle()))
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .padding(5)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTarget, perform: receiveDirectory)
        .disabled(session.deleting)
        .alert("操作未完成", isPresented: Binding(
            get: { session.operationError != nil }, set: { if !$0 { session.operationError = nil } }
        )) {
            if !session.pendingJPEGs.isEmpty {
                Button("重试失败的 JPEG") { session.delete(Array(session.pendingJPEGs.keys), automatic: false, confirmed: true) }
            }
            Button("好") { session.operationError = nil }
        } message: {
            Text(session.operationError ?? "")
        }
        .onAppear {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard !session.deleting, NSApp.modalWindow == nil,
                      let window = event.window, window === NSApp.mainWindow,
                      window.attachedSheet == nil, !showsShortcuts, !(window.firstResponder is NSText) else { return event }
                return session.handleKey(event) ? nil : event
            }
        }
        .onDisappear {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            dropRequest = nil
        }
    }

    private var directoryPlaceholder: some View {
        Button(action: pickDirectory) {
            VStack(spacing: 8) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 32))
                    .accessibilityHidden(true)
                Text(session.directory == nil ? "添加要筛选的 RAW 照片目录" : "目录中没有可筛选的 RAW 照片")
                    .font(.headline)
                Text("点击选择目录，或拖入文件夹")
                    .font(.callout)
            }
            .foregroundStyle(isDropTarget ? Color.accentColor : Color.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var shortcutHelp: some View {
        ComparisonKeyEditor(binding: session.key, assign: { session.assign($0, key: $1) },
                            reset: session.resetShortcuts)
    }

    private var directorySidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("连拍目录").font(.headline)
                .padding(12)
            ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(session.groups) { group in
                        let selected = session.group?.id == group.id
                        Button {
                            session.openGroup(group)
                        } label: {
                            HStack(spacing: 8) {
                                if let first = group.photos.first {
                                    ComparisonThumbnail(url: first).frame(width: 56, height: 42)
                                }
                                Text(group.name).lineLimit(1)
                                Spacer(minLength: 0)
                                if session.openingGroupID == group.id {
                                    ProgressView().controlSize(.mini)
                                }
                            }
                            .padding(6)
                            .background(selected ? Color.accentColor.opacity(0.20) : .clear,
                                        in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selected ? [.isSelected] : [])
                        .id(group.id)
                    }
                }
                .padding(.horizontal, 6)
            }
            .onChange(of: session.group?.id) { if let id = $0 { proxy.scrollTo(id) } }
            }
        }
        .frame(width: 184)
        .background(.bar)
    }

    private func filmstrip(_ group: ComparisonGroup) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 6) {
                    ForEach(group.photos.indices, id: \.self) { index in
                        let url = group.photos[index]
                        let isBase = index == session.base
                        let selected = session.selection.contains(url) || (!session.hasExplicitSelection && index == session.candidate)
                        let decision = session.decisions[url]
                        Button {
                            session.selectPhoto(index, modifiers: NSApp.currentEvent?.modifierFlags ?? [])
                        } label: {
                            VStack(spacing: 3) {
                                ComparisonThumbnail(url: url).frame(width: 72, height: 46)
                                    .overlay(alignment: .topLeading) {
                                        if decision == .reject { ComparisonRejectBadge(compact: true).padding(3) }
                                    }
                                HStack(spacing: 3) {
                                    Text(isBase ? "基准" : "\(index + 1)").monospacedDigit()
                                }
                                .font(.caption2)
                            }
                            .padding(4)
                            .background(selected ? Color.accentColor.opacity(0.24) : .clear,
                                        in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel([url.lastPathComponent, isBase ? "基准" : nil, decision?.rawValue]
                            .compactMap { $0 }.joined(separator: "，"))
                        .accessibilityAddTraits(selected ? [.isSelected] : [])
                        .id(index)
                    }
                }
            }
            .frame(height: 78)
            .onAppear { if let candidate = session.candidate { proxy.scrollTo(candidate) } }
            .onChange(of: session.candidate) { if let candidate = $0 { proxy.scrollTo(candidate) } }
        }
        .id(group.id)
    }

    private func comparison(_ group: ComparisonGroup) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                pane("基准", side: 0, url: session.base.map { group.photos[$0] })
                pane("候选", side: 1, url: session.candidateURL)
            }
            filmstrip(group)
            HStack {
                Button("←") { session.move(-1) }.accessibilityLabel("上一张候选")
                Button("→") { session.move(1) }.accessibilityLabel("下一张候选")
                Text(session.hasExplicitSelection ? "已选 \(session.selection.count) 张" : session.candidate.map { "\($0 + 1) / \(group.photos.count)" } ?? "无候选")
                    .monospacedDigit().foregroundStyle(.secondary)
                Spacer()
                Button("撤销") { session.undo() }.disabled(!session.canUndo).help(session.key(.undo).display)
                Button("设为基准  \(session.key(.pin).display)") { session.pin() }
                    .disabled(!session.canPin)
                    .help("将目标设为基准，原基准标为放弃")
                let targets = session.operationURLs
                let marked = !targets.isEmpty && targets.allSatisfy { session.decisions[$0] == .reject }
                Button("\(marked ? "取消放弃" : "放弃")  \(session.key(.reject(false)).display)") { session.toggleReject() }
                    .disabled(targets.isEmpty)
                    .help("切换选区或当前候选的放弃标记")
            }
            HStack(spacing: 14) {
                Text("↑↓ / \(session.key(.group(-1)).display) \(session.key(.group(1)).display) 切组")
                Text("←→ / \(session.key(.candidate(-1)).display) \(session.key(.candidate(1)).display) 切候选")
                Text("\(session.key(.clearSelection).display) 双图复位")
                Text("\(session.key(.reject(true)).display) 放弃基准")
                Text("\(panKeys(side: 2)) 同步移动")
                Spacer(minLength: 0)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .task(id: session.candidateURL, priority: .utility) {
            let candidates = group.photos.indices.filter { $0 != session.base }
            guard candidates.count > 1, let current = session.candidate,
                  let position = candidates.firstIndex(of: current) else { return }
            do { try await Task.sleep(nanoseconds: 150_000_000) } catch { return }
            var prefetched = Set<Int>()
            for delta in [1, -1] {
                let nearby = candidates[(position + delta + candidates.count) % candidates.count]
                guard !Task.isCancelled else { return }
                if prefetched.insert(nearby).inserted {
                    _ = await ComparisonDecoder.fitted.decode(group.photos[nearby])
                }
            }
        }
    }

    private func pane(_ title: String, side: Int, url: URL?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.headline)
                if let url {
                    Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                }
            }
            if let url {
                HStack(spacing: 5) {
                    let rating = session.ratings[url]
                    ForEach(1...5, id: \.self) { stars in
                        Button { session.rateSelection(stars, baseline: false, clicked: url) } label: {
                            Image(systemName: stars <= (rating ?? 0) ? "star.fill" : "star")
                        }
                        .buttonStyle(.plain)
                        .help(session.key(.rating(stars, side == 0)).display)
                        .accessibilityLabel("设为 \(stars) 星")
                    }
                    if rating == -1 { Text("已拒绝").font(.caption) }
                    Spacer(minLength: 8)
                    previewKeyHints(side: side)
                }
                .foregroundStyle(Color.accentColor)
                .task(id: url) { await session.loadRating(url) }
                ComparisonPreview(url: url, side: side, showFocus: session.showFocus, viewport: session.viewport)
                    .overlay(alignment: .topLeading) {
                        if session.decisions[url] == .reject { ComparisonRejectBadge(compact: false).padding(10) }
                    }
            } else {
                Text(side == 0 ? "按 \(session.key(.pin).display) 将候选设为基准" : "本组没有候选照片").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.quaternary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func previewKeyHints(side: Int) -> some View {
        let baseline = side == 0
        let zoom = session.key(.zoom(1, baseline)).display
        let zoomOut = session.key(.zoom(-1, baseline)).display
        let reset = session.key(.zoom(0, baseline)).display
        return Text("缩放 \(zoom) / \(zoomOut) / \(reset)    移动 \(panKeys(side: side))")
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.trailing)
            .help("放大 / 缩小 / 复位。移动按键依次为下 / 上 / 右 / 左。")
    }

    private func panKeys(side: Int) -> String {
        [(0, 1), (0, -1), (1, 0), (-1, 0)]
            .map { session.key(.pan(side, $0.0, $0.1)).display }
            .joined(separator: " ")
    }

    private func pickDirectory() {
        dropRequest = nil
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { importDirectory(url) }
    }

    private func receiveDirectory(_ providers: [NSItemProvider]) -> Bool {
        guard !session.deleting else { return false }
        dropRequest = nil
        guard providers.count == 1, let provider = providers.first,
              provider.canLoadObject(ofClass: URL.self) else {
            session.operationError = "请一次拖入一个照片文件夹。"
            return false
        }
        let request = UUID()
        dropRequest = request
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            DispatchQueue.main.async {
                guard dropRequest == request else { return }
                dropRequest = nil
                guard let url, url.isFileURL,
                      (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                    session.operationError = "请拖入包含 RAW 照片的文件夹。"
                    return
                }
                importDirectory(url)
            }
        }
        return true
    }

    private func importDirectory(_ url: URL) {
        session.leaveGroup { session.open(url) }
    }
}

private struct ComparisonRejectBadge: View {
    let compact: Bool

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "trash").font(.system(size: compact ? 11 : 22))
            if !compact { Text("待移到废纸篓").font(.caption) }
        }
        .padding(compact ? 4 : 8)
        .foregroundStyle(.white)
        .background(.black.opacity(0.73), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityLabel("已标记放弃")
        .allowsHitTesting(false)
    }
}

private struct ComparisonThumbnail: View {
    let url: URL
    @State private var loaded: (URL, CGImage)?

    var body: some View {
        ZStack {
            Color(nsColor: NSColor(white: 0.12, alpha: 1))
            if let loaded, loaded.0 == url {
                Image(decorative: loaded.1, scale: 1).resizable().scaledToFit()
            } else {
                Image(systemName: "photo").foregroundStyle(.secondary)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .accessibilityHidden(true)
        .task(id: url) {
            let image = await ComparisonDecoder.thumbnail.decode(url)
            guard !Task.isCancelled else { return }
            loaded = image.map { (url, $0) }
        }
    }
}

private actor ComparisonDecoder {
    static let thumbnail = ComparisonDecoder(limit: 24 * 1024 * 1024, maxSide: 176)
    static let fitted = ComparisonDecoder(limit: 96 * 1024 * 1024, maxSide: 1600)
    static let original = ComparisonDecoder(limit: 256 * 1024 * 1024, maxSide: nil)

    private final class Entry {
        let stamp: String
        let image: CGImage

        init(stamp: String, image: CGImage) {
            self.stamp = stamp
            self.image = image
        }
    }

    // NSCache protects concurrent reads and writes. Entries are immutable.
    private final class Memory: @unchecked Sendable {
        let entries = NSCache<NSURL, Entry>()
    }

    private nonisolated let memory = Memory()
    private let maxSide: Int?

    init(limit: Int, maxSide: Int?) {
        memory.entries.totalCostLimit = limit
        self.maxSide = maxSide
    }

    nonisolated func cached(_ url: URL) -> CGImage? {
        memory.entries.object(forKey: url as NSURL)?.image
    }

    func decode(_ url: URL) -> CGImage? {
        guard !Task.isCancelled else { return nil }
        let key = url as NSURL
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let modified = values?.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
        let stamp = "\(modified)\u{0}\(values?.fileSize ?? 0)"
        if let entry = memory.entries.object(forKey: key) {
            if entry.stamp == stamp { return entry.image }
            memory.entries.removeObject(forKey: key)
        }
        let image: CGImage?
        if let maxSide {
            if let cached = MidPreviewCache.thumbnail(for: url, maxSide: maxSide) {
                image = cached
            } else if let source = CGImageSourceCreateWithURL(url as CFURL, nil) {
                func thumbnail(forceDecode: Bool) -> CGImage? {
                    CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: forceDecode,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceShouldCacheImmediately: true,
                        kCGImageSourceThumbnailMaxPixelSize: maxSide
                    ] as CFDictionary)
                }
                image = (maxSide <= 176 ? thumbnail(forceDecode: false) : nil) ?? thumbnail(forceDecode: true)
            } else {
                image = nil
            }
        } else {
            image = Analyzer.loadFullPreview(url, decodeImmediately: true)
        }
        if let image, !Task.isCancelled {
            memory.entries.setObject(Entry(stamp: stamp, image: image), forKey: key, cost: image.bytesPerRow * image.height)
        }
        return image
    }
}

private struct ComparisonInspection {
    let points: [FocusPoint]
}

private actor ComparisonInspector {
    static let shared = ComparisonInspector()
    private var cache: [URL: ComparisonInspection] = [:]

    func inspect(_ url: URL) -> ComparisonInspection? {
        guard !Task.isCancelled else { return nil }
        if let cached = cache[url] { return cached }
        let source = CGImageSourceCreateWithURL(url as CFURL, nil)
        let properties = source.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) } as? [String: Any]
        let orientation = properties?[kCGImagePropertyOrientation as String] as? Int ?? 1
        let points = (AFReader.read(url)?.points ?? []).map { displayPoint($0, orientation: orientation) }
        let result = ComparisonInspection(points: points)
        if cache.count >= 256 { cache.removeAll(keepingCapacity: true) }
        if !Task.isCancelled { cache[url] = result }
        return result
    }

    private func displayPoint(_ point: FocusPoint, orientation: Int) -> FocusPoint {
        let x = point.cx, y = point.cy
        let center: (Double, Double)
        switch orientation {
        case 2: center = (1 - x, y)
        case 3: center = (1 - x, 1 - y)
        case 4: center = (x, 1 - y)
        case 5: center = (y, x)
        case 6: center = (1 - y, x)
        case 7: center = (1 - y, 1 - x)
        case 8: center = (y, 1 - x)
        default: return point
        }
        let swapped = (5...8).contains(orientation)
        return FocusPoint(cx: center.0, cy: center.1,
                          w: swapped ? point.h : point.w, h: swapped ? point.w : point.h)
    }
}

private struct ComparisonPreview: View {
    let url: URL
    let side: Int
    let showFocus: Bool
    @ObservedObject var viewport: ComparisonViewport
    @State private var fitted: (URL, CGImage?)?
    @State private var original: (URL, CGImage)?
    @State private var loadingIndicatorURL: URL?
    @State private var inspection: (URL, ComparisonInspection)?
    @GestureState private var isDragging = false
    @State private var previousTranslation: CGSize?
    @State private var dragMode: NSEvent.ModifierFlags?
    @State private var box: CGRect?

    private var position: ComparisonViewport.Position { viewport.positions[side] }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geometry in
                let fit = fitted?.0 == url ? fitted?.1 : ComparisonDecoder.fitted.cached(url)
                let lowResolution = fitted?.0 == url && fitted?.1 == nil ? nil : ComparisonDecoder.thumbnail.cached(url)
                let full = position.zoom > 1
                    ? (original?.0 == url ? original?.1 : ComparisonDecoder.original.cached(url)) : nil
                let image = full ?? fit ?? lowResolution
                ZStack {
                    Color(nsColor: NSColor(white: 0.09, alpha: 1))
                    if let image {
                        preview(image, in: geometry.size)
                    } else if fitted?.0 == url {
                        Text("无法解码").foregroundStyle(.white.opacity(0.8))
                    } else if loadingIndicatorURL == url {
                        ProgressView().tint(.white)
                    }
                }
                .clipped()
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .onChange(of: isDragging) { dragging in
            if !dragging { resetDrag() }
        }
        .onChange(of: url) { _ in resetDrag(); loadingIndicatorURL = nil }
        .task(id: url) {
            do { try await Task.sleep(nanoseconds: 180_000_000) } catch { return }
            loadingIndicatorURL = url
        }
        .task(id: url, priority: .userInitiated) {
            let image = await ComparisonDecoder.fitted.decode(url)
            guard !Task.isCancelled else { return }
            fitted = (url, image)
        }
        .task(id: position.zoom > 1 ? url : nil) {
            guard position.zoom > 1, original?.0 != url else { return }
            let image = await ComparisonDecoder.original.decode(url)
            guard !Task.isCancelled, let image else { return }
            original = (url, image)
        }
        .task(id: url, priority: .utility) {
            do { try await Task.sleep(nanoseconds: 220_000_000) } catch { return }
            let result = await ComparisonInspector.shared.inspect(url)
            guard !Task.isCancelled, let result else { return }
            inspection = (url, result)
        }
    }

    private func preview(_ image: CGImage, in bounds: CGSize) -> some View {
        let rect = imageRect(image, in: bounds, position: position)
        return ZStack {
            Image(decorative: image, scale: 1).resizable()
                .allowsHitTesting(false)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
            if showFocus, let inspection, inspection.0 == url {
                ForEach(Array(inspection.1.points.enumerated()), id: \.offset) { _, point in
                    Rectangle().stroke(.red, lineWidth: 1.5)
                        .frame(width: max(8, point.w * rect.width), height: max(8, point.h * rect.height))
                        .position(x: rect.minX + point.cx * rect.width, y: rect.minY + point.cy * rect.height)
                }
            }
            if let box {
                Rectangle().stroke(.white, style: StrokeStyle(lineWidth: 1, dash: [4]))
                    .frame(width: box.width, height: box.height)
                    .position(x: box.midX, y: box.midY)
            }
            ScrollWheelBridge { delta, point in
                guard rect.contains(point), delta != 0 else { return }
                let factor: CGFloat = delta > 0 ? 1.18 : 1 / 1.18
                let zoom = min(8, max(1, position.zoom * factor))
                let fraction = unit(point, in: rect)
                let fit = imageRect(image, in: bounds, position: .init())
                let center = CGPoint(x: fraction.x + (bounds.width / 2 - point.x) / (fit.width * zoom),
                                     y: fraction.y + (bounds.height / 2 - point.y) / (fit.height * zoom))
                viewport.positions[side] = zoom == 1 ? .init() : .init(zoom: zoom, center: center)
            }
            Color.clear.frame(width: bounds.width, height: bounds.height)
                .contentShape(Rectangle())
                .onTapGesture(count: position.zoom > 1 ? 1 : 2, coordinateSpace: .local) { point in
                    if position.zoom > 1 {
                        viewport.positions = [.init(), .init()]
                    } else if rect.contains(point), rect.width > 0, rect.height > 0 {
                        let target = ComparisonViewport.Position(zoom: 3, center: unit(point, in: rect))
                        viewport.positions = [target, target]
                    }
                }
                .simultaneousGesture(panGesture(for: image, in: bounds))
        }
        .frame(width: bounds.width, height: bounds.height)
        .contentShape(Rectangle())
        .clipped()
        .task(id: CGRect(x: bounds.width, y: bounds.height, width: CGFloat(image.width), height: CGFloat(image.height))) {
            guard bounds.width > 0, bounds.height > 0 else { return }
            let fitted = imageRect(image, in: bounds, position: .init())
            viewport.fittedCoverage[side] = CGSize(width: fitted.width / bounds.width,
                                                    height: fitted.height / bounds.height)
        }
    }

    private func resetDrag() {
        previousTranslation = nil
        dragMode = nil
        box = nil
    }

    private func unit(_ point: CGPoint, in rect: CGRect) -> CGPoint {
        CGPoint(x: (point.x - rect.minX) / rect.width, y: (point.y - rect.minY) / rect.height)
    }

    private func panGesture(for image: CGImage, in bounds: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .updating($isDragging) { _, active, _ in active = true }
            .onChanged { drag in
                let rect = imageRect(image, in: bounds, position: position)
                guard rect.width > 0, rect.height > 0 else { return }
                if dragMode == nil {
                    guard rect.contains(drag.startLocation) else { return }
                    dragMode = NSApp.currentEvent?.modifierFlags.intersection([.command, .option]) ?? []
                }
                if dragMode?.contains(.command) == true {
                    let a = drag.startLocation, b = drag.location
                    box = CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                                 width: abs(a.x - b.x), height: abs(a.y - b.y))
                        .intersection(rect).intersection(CGRect(origin: .zero, size: bounds))
                    return
                }
                guard position.zoom > 1 else { return }
                let previous = previousTranslation ?? .zero
                previousTranslation = drag.translation
                let current = unit(CGPoint(x: bounds.width / 2, y: bounds.height / 2), in: rect)
                let dx = rect.width > bounds.width ? (drag.translation.width - previous.width) / rect.width : 0
                let dy = rect.height > bounds.height ? (drag.translation.height - previous.height) / rect.height : 0
                let marginX = min(0.5, bounds.width / (2 * rect.width))
                let marginY = min(0.5, bounds.height / (2 * rect.height))
                let center = CGPoint(x: min(1 - marginX, max(marginX, current.x - dx)),
                                     y: min(1 - marginY, max(marginY, current.y - dy)))
                var positions = viewport.positions
                positions[side].center = center
                if dragMode?.contains(.option) == true {
                    if positions[1 - side].zoom == 1 {
                        positions[1 - side] = positions[side]
                    } else {
                        let other = positions[1 - side].center
                        positions[1 - side].center = CGPoint(
                            x: min(1, max(0, other.x + center.x - current.x)),
                            y: min(1, max(0, other.y + center.y - current.y))
                        )
                    }
                }
                viewport.positions = positions
            }
            .onEnded { _ in
                defer { resetDrag() }
                guard let box, !box.isNull, box.width >= 8, box.height >= 8 else { return }
                let rect = imageRect(image, in: bounds, position: position)
                let scale = min(bounds.width / box.width, bounds.height / box.height)
                let zoom = min(8, max(1, position.zoom * scale))
                viewport.positions[side] = .init(zoom: zoom,
                    center: unit(CGPoint(x: box.midX, y: box.midY), in: rect))
            }
    }

    private func imageRect(_ image: CGImage, in viewport: CGSize, position: ComparisonViewport.Position) -> CGRect {
        let width = CGFloat(image.width), height = CGFloat(image.height)
        let scale = min(viewport.width / width, viewport.height / height) * position.zoom
        let size = CGSize(width: width * scale, height: height * scale)
        func origin(_ space: CGFloat, _ extent: CGFloat, _ fraction: CGFloat) -> CGFloat {
            guard extent > space else { return (space - extent) / 2 }
            return min(0, max(space - extent, space / 2 - fraction * extent))
        }
        return CGRect(x: origin(viewport.width, size.width, position.center.x),
                      y: origin(viewport.height, size.height, position.center.y),
                      width: size.width, height: size.height)
    }
}

private enum ComparisonTrash {
    struct Move {
        let original: URL
        let trash: URL
    }
    struct Result {
        var moves: [Move] = []
        var removed: Set<URL> = []
        var errors: [String] = []
        var failedJPEGs: [URL: URL] = [:]
    }

    static func move(_ urls: [URL], retries: [URL: URL]) -> Result {
        var result = Result()
        let fm = FileManager.default
        func trash(_ url: URL) throws {
            var target: NSURL?
            try fm.trashItem(at: url, resultingItemURL: &target)
            if let target { result.moves.append(Move(original: url, trash: target as URL)) }
        }
        var companions = retries
        for (folder, raws) in Dictionary(grouping: urls, by: { $0.deletingLastPathComponent() }) {
            do {
                let siblings = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey])
                let byStem = Dictionary(grouping: siblings.filter(MetadataWriter.isJPEG)) {
                    $0.deletingPathExtension().lastPathComponent
                }
                for raw in raws {
                    do {
                        let matches = try (byStem[raw.deletingPathExtension().lastPathComponent] ?? []).filter {
                            try $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
                        }
                        try trash(raw)
                        result.removed.insert(raw)
                        for jpeg in matches { companions[jpeg] = raw }
                    } catch { result.errors.append("\(raw.lastPathComponent)：\(error.localizedDescription)") }
                }
            } catch { result.errors.append("\(folder.path)：\(error.localizedDescription)") }
        }
        for (jpeg, raw) in companions {
            do {
                guard try jpeg.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                    throw CocoaError(.fileReadUnsupportedScheme)
                }
                try trash(jpeg)
            } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
                continue
            } catch {
                result.failedJPEGs[jpeg] = raw
                result.errors.append("\(jpeg.lastPathComponent)：\(error.localizedDescription)")
            }
        }
        return result
    }

    static func restore(_ moves: [Move]) -> Result {
        var result = Result()
        for move in moves {
            do {
                try FileManager.default.moveItem(at: move.trash, to: move.original)
                result.removed.insert(move.original)
            } catch {
                result.errors.append("\(move.original.lastPathComponent)：\(error.localizedDescription)")
            }
        }
        return result
    }

}

@MainActor
final class ComparisonQuitDelegate: NSObject, NSApplicationDelegate {
    fileprivate static let sessions = NSHashTable<ComparisonSession>.weakObjects()
    fileprivate static var pending: [ObjectIdentifier: ComparisonSession] = [:]
    fileprivate static var skipAutomaticPrompt = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let live = Self.sessions.allObjects
        let liveIDs = Set(live.map(ObjectIdentifier.init))
        let sessions = live + Self.pending.filter { !liveIDs.contains($0.key) }.map(\.value)
        guard !sessions.contains(where: { $0.deleting || $0.ratingWrites > 0 }) else { return .terminateCancel }
        let jobs = sessions.compactMap { session -> (ComparisonSession, [URL])? in
            let urls = session.decisions.compactMap { $0.value == .reject ? $0.key : nil } + Array(session.pendingJPEGs.keys)
            return urls.isEmpty ? nil : (session, urls)
        }
        guard !jobs.isEmpty else { return .terminateNow }
        for (session, urls) in jobs {
            guard session.confirmDeletion(urls, automatic: true) else { return .terminateCancel }
        }
        Task {
            for (session, urls) in jobs {
                let success = await withCheckedContinuation { continuation in
                    session.delete(urls, automatic: true, confirmed: true) { continuation.resume(returning: $0) }
                }
                if !success {
                    if let error = session.operationError {
                        let alert = NSAlert()
                        alert.messageText = "部分照片未能移到废纸篓"
                        alert.informativeText = error
                        alert.runModal()
                        session.operationError = nil
                    }
                    sender.reply(toApplicationShouldTerminate: false)
                    return
                }
            }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

private struct KingfisherMark: Shape {
    func path(in rect: CGRect) -> Path {
        // 取应用图标里向右下俯冲的剪影，省略水面、网格和对焦框。
        let points: [(CGFloat, CGFloat)] = [
            (0.16, 0.27), (0.32, 0.31), (0.23, 0.08), (0.36, 0.19),
            (0.35, 0.02), (0.49, 0.27), (0.58, 0.31), (0.67, 0.12),
            (0.88, 0.06), (0.77, 0.39), (0.68, 0.48), (0.71, 0.55),
            (0.76, 0.71), (0.73, 0.77), (0.79, 0.97), (0.65, 0.75),
            (0.55, 0.66), (0.40, 0.57), (0.07, 0.37), (0.32, 0.39),
            (0.16, 0.27)
        ]
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
        }
        var path = Path()
        path.addLines(points.map { point($0.0, $0.1) })
        path.move(to: point(0.34, 0.39))
        path.addQuadCurve(to: point(0.54, 0.57), control: point(0.49, 0.38))
        let eye = point(0.65, 0.65)
        path.addEllipse(in: CGRect(x: eye.x, y: eye.y, width: 1.5, height: 1.5))
        return path
    }
}
