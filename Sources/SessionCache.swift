import Foundation
import CoreGraphics

// MARK: - 会话缓存
//
// 把某个文件夹的判定结果落盘；下次打开同一文件夹时直接加载历史数据，
// 不再全量重分析（用户 2026-11-22 要求）。缓存跟着照片走：
// 存在**照片文件夹的根目录**下，单一日志文件 `kingfisher-session.log`
//（可见文件，内容是 JSON），随文件夹移动/拷贝一起带走
//（用户 2026-11-23 要求，明确不要隐藏文件）。
// 兜底：照片目录只读（如部分 SD 卡/光盘挂载）时退回老位置
// ~/Library/Application Support/Kingfisher-PhotoSelector/SessionCache/。
//
// 设计要点：
// - PhotoMetrics 的 preview（CGImage）不落盘——加载时重新解码缩略图，
//   这一步很快；真正耗时的是前景分割/显著性等 Vision 分析，那部分结果全存。
// - 按文件名对账：缓存里有、文件夹里没有的（已被删除）直接丢弃；
//   文件夹里有、缓存里没有的（新增照片）照常重新分析。
// - version 字段：判定算法大改时 +1，旧缓存自动失效。

struct CachedPhoto: Codable {
    var file: String              // v3 为根目录相对路径，v1/v2 为文件名
    var verdict: String           // Verdict.rawValue
    var reason: String
    var overrideRect: CGRect?     // 人工圈选重判框
    var selectionRect: CGRect?    // 显示用圈选框（黄框）
    var genreOverride: String?    // 人工指定题材（PhotoGenre.rawValue，nil=未改）
    // —— PhotoMetrics 数值字段 ——
    var globalHi: Double
    var peakBlock: Double
    var subjectScore: Double
    var ratio: Double
    var centerRatio: Double
    var anisotropy: Double
    var softRatio: Double
    var spread: Double
    var reblurRatio: Double
    var subjectReblur: Double
    var scores: [Double]
    var blurScores: [Double]
    var cols: Int
    var rows: Int
    var weights: [Double]
    var subjectSource: String
    var bboxes: [CGRect]
    var width: Int
    var height: Int
    // —— 信息区全量字段（v2 新增，全部可选） ——
    // 设计：分析阶段把 WB/AF/EXIF/Focus/Human/AI/Rating 全算完落盘，
    // 筛选阶段信息区零现算（用户 2026-11-25 拍板「把能放到分析阶段的东西全放
    // 到分析阶段」）。老 v1 log 没有这些键，解码为 nil，行为退回按需现算，
    // 后台补算后回写 v2。rating 非 nil 视为「这张的信息已算过」（导入阶段每张
    // 都会算出星级快照，星级恒有值）；wb/af 等为 nil 表示「算过但无数据」，
    // App 端用 attempted 标记防止重复现算。
    var wb: WhiteBalanceStats?
    var af: AFInfo?
    var exif: ExifInfo?
    var focus: FocusSemantics?
    var human: HumanPresence?
    var ai: AISubject?
    var rating: Int?
}

/// 一张照片的信息区字段快照（saveSession 时从内存缓存收集，写入 CachedPhoto）。
struct PhotoInfoSnapshot {
    var wb: WhiteBalanceStats?
    var af: AFInfo?
    var exif: ExifInfo?
    var focus: FocusSemantics?
    var human: HumanPresence?
    var ai: AISubject?
    var rating: Int?
}

struct SessionSnapshot: Codable {
    var version: Int
    var folderPath: String
    var savedAt: Date
    var sensitivity: Double
    var anchorHi: Double?
    var hiMin: Double
    var excludedFiles: [String]   // 「排除写入」的照片文件名
    var photos: [CachedPhoto]
    /// 导入时整批选择的题材（FolderGenreChoice.rawValue，auto 也记）。
    /// 可选字段：老 log 没有它，解码为 nil，下次仍会问一次题材，兼容旧数据。
    var folderGenreChoice: String?
}

enum SessionCache {
    /// v2：信息区字段（WB/AF/EXIF/Focus/Human/AI/Rating）随判定一起落盘。
    /// v1 的老 log 仍可读（缺字段解码为 nil，按需现算后回写升到 v2）。
    static let version = 3
    /// 缓存日志文件名（可见文件；.log 扩展名不会被 RAW 扫描当成素材）。
    static let fileName = "kingfisher-session.log"
    /// 上一版曾用过的隐藏文件名，自动转正后删除，兼容中途升级。
    private static let hiddenFileName = ".kingfisher-session.log"

    /// 老位置（软件数据目录），只作只读兜底/迁移来源。
    static var legacyDir: URL {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Kingfisher-PhotoSelector/SessionCache", isDirectory: true)
    }

    /// 老位置的按路径命名文件（历史遗留，只读）。
    static func legacyFile(for folder: URL) -> URL {
        var name = folder.path
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        name = name.components(separatedBy: invalid).joined(separator: "_")
        var h: UInt64 = 1469598103934665603
        for b in folder.path.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return legacyDir.appendingPathComponent("\(name)-\(String(h, radix: 36)).json")
    }

    /// 缓存日志文件：直接放在照片文件夹的根目录下。
    static func cacheFile(for folder: URL) -> URL {
        folder.appendingPathComponent(fileName)
    }

    static func relativePath(_ url: URL, in folder: URL) -> String {
        url.standardizedFileURL.pathComponents.dropFirst(folder.standardizedFileURL.pathComponents.count)
            .joined(separator: "/")
    }

    /// 将来源日志投影到本次导入范围。旧日志只接受磁盘和快照中都唯一的文件名。
    static func matched(_ snapshot: SessionSnapshot, source: URL, folder: URL, files: [URL]) -> SessionSnapshot? {
        let prefix = source.standardizedFileURL.pathComponents
        let scoped = files.filter { $0.standardizedFileURL.pathComponents.starts(with: prefix) }
        guard !scoped.isEmpty else { return nil }
        let legacy = snapshot.version < 3
        func key(_ url: URL) -> String { legacy ? url.lastPathComponent : relativePath(url, in: source) }
        let urls = Dictionary(grouping: scoped, by: key)
        var ambiguous = Set<String>()
        // 借用父目录的老日志时，本次导入只含部分文件，必须检查兄弟目录的同名文件。
        if legacy, folder.standardizedFileURL.pathComponents.starts(with: prefix),
           folder.standardizedFileURL.pathComponents.count > prefix.count {
            guard let enumerator = FileManager.default.enumerator(at: source, includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return nil }
            var seen = Set<String>()
            for case let url as URL in enumerator where urls[url.lastPathComponent] != nil {
                if !seen.insert(url.lastPathComponent).inserted { ambiguous.insert(url.lastPathComponent) }
            }
        }
        let records = Dictionary(grouping: snapshot.photos, by: { $0.file })
        var result = snapshot
        result.version = version
        result.folderPath = folder.path
        result.photos = []
        result.excludedFiles = []
        let excluded = Set(snapshot.excludedFiles)
        for (name, group) in records {
            guard !ambiguous.contains(name), group.count == 1, let matches = urls[name], matches.count == 1,
                  var photo = group.first, let url = matches.first else { continue }
            photo.file = relativePath(url, in: folder)
            result.photos.append(photo)
            if excluded.contains(name) { result.excludedFiles.append(photo.file) }
        }
        return result.photos.isEmpty ? nil : result
    }

    static func save(folder: URL, sensitivity: Double, anchorHi: Double?, hiMin: Double,
                     excluded: Set<URL>, results: [PhotoResult], metrics: [PhotoMetrics],
                     selectionRects: [URL: CGRect], genreOverride: [URL: PhotoGenre],
                     folderGenreChoice: String? = nil,
                     info: [URL: PhotoInfoSnapshot] = [:]) {
        let byURL = Dictionary(uniqueKeysWithValues: metrics.map { ($0.url, $0) })
        let photos: [CachedPhoto] = results.compactMap { r in
            guard let m = byURL[r.id] else { return nil }
            let i = info[r.id]
            return CachedPhoto(
                file: relativePath(r.id, in: folder),
                verdict: r.verdict.rawValue,
                reason: r.reason,
                overrideRect: r.overrideRect,
                selectionRect: selectionRects[r.id],
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
        guard !photos.isEmpty else { return }
        let snap = SessionSnapshot(version: version, folderPath: folder.path, savedAt: Date(),
                                   sensitivity: sensitivity, anchorHi: anchorHi, hiMin: hiMin,
                                   excludedFiles: excluded.map { relativePath($0, in: folder) }.sorted(),
                                   photos: photos, folderGenreChoice: folderGenreChoice)
        do {
            let data = try JSONEncoder().encode(snap)
            // 首选照片文件夹根目录；写不进去（只读卷等）退回软件数据目录兜底。
            do {
                try data.write(to: cacheFile(for: folder), options: .atomic)
            } catch {
                try fmSafeCreateLegacyDir()
                try data.write(to: legacyFile(for: folder), options: .atomic)
            }
        } catch {
            // 缓存写失败不影响主流程，静默即可（下次打开全量重分析兜底）。
        }
    }

    private static func fmSafeCreateLegacyDir() throws {
        try FileManager.default.createDirectory(at: legacyDir, withIntermediateDirectories: true)
    }

    /// 写已经编码好的快照数据。App 退出时走这条路：845 张照片 + v2 信息字段的
    /// JSON 编码如果放在 willTerminate 的主线程现做，会让「退出」看起来卡死。
    @discardableResult
    static func writeEncoded(_ data: Data, for folder: URL) -> Bool {
        do {
            try data.write(to: cacheFile(for: folder), options: .atomic)
            return true
        } catch {
            do {
                try fmSafeCreateLegacyDir()
                try data.write(to: legacyFile(for: folder), options: .atomic)
                return true
            } catch { return false }
        }
    }

    static func load(folder: URL) -> SessionSnapshot? {
        // v1 与 v2 都可读：v1 缺信息字段（解码为 nil，App 端退回按需现算），
        // 高于当前 version 的未来格式拒载（防前向兼容破坏）。
        func decode(_ f: URL) -> SessionSnapshot? {
            guard let data = try? Data(contentsOf: f),
                  let snap = try? JSONDecoder().decode(SessionSnapshot.self, from: data),
                  snap.version >= 1, snap.version <= version, !snap.photos.isEmpty else { return nil }
            return snap
        }
        func migrate(_ snap: SessionSnapshot, remove source: URL) -> SessionSnapshot {
            // 迁到可见日志文件；成功才删源文件，失败下次再试（源还在）。
            if let data = try? JSONEncoder().encode(snap) {
                do {
                    try data.write(to: cacheFile(for: folder), options: .atomic)
                    try? FileManager.default.removeItem(at: source)
                } catch { /* 只读目录等：保留源文件，下次再试 */ }
            }
            return snap
        }
        // 1) 可见日志文件（正式位置）
        if let snap = decode(cacheFile(for: folder)) { return snap }
        // 2) 上一版的隐藏文件：自动转正
        let hidden = folder.appendingPathComponent(hiddenFileName)
        if let snap = decode(hidden) { return migrate(snap, remove: hidden) }
        // 3) 更早的软件数据目录缓存：迁移到照片文件夹
        let legacy = legacyFile(for: folder)
        guard let snap = decode(legacy) else { return nil }
        return migrate(snap, remove: legacy)
    }

    /// 缓存条目 → PhotoMetrics，但**不解码 RAW 缩略图**（preview=nil）。
    /// 判定/评分/热力图/主预览都不依赖 preview：
    /// - 主预览由 DetailView 的 ensureFullPreview 单独异步解码原图；
    /// - 热力图只用 scores/blurScores/weights 等数值；
    /// - 左侧列表缩略图由 Store.ensureThumbnail 按需解码小图并缓存。
    /// 历史加载因此可以在几十毫秒内瞬间恢复上百张照片，不再逐张解 RAW
    ///（实测单张 CR3 解码 260~500ms，45 张就是 12~22 秒的进度条爬行）。
    static func metrics(from c: CachedPhoto, url: URL, decodePreview: Bool = true) -> PhotoMetrics? {
        let (count, overflow) = c.cols.multipliedReportingOverflow(by: c.rows)
        guard !overflow, c.cols > 0, c.rows > 0, c.width > 0, c.height > 0,
              c.cols == c.width / Analyzer.block, c.rows == c.height / Analyzer.block,
              c.scores.count == count, c.blurScores.count == count, c.weights.count == count
        else { return nil }
        var thumb: CGImage?
        if decodePreview { thumb = Analyzer.decode(url)?.image }
        return PhotoMetrics(
            url: url, globalHi: c.globalHi, peakBlock: c.peakBlock, subjectScore: c.subjectScore,
            ratio: c.ratio, centerRatio: c.centerRatio, anisotropy: c.anisotropy,
            softRatio: c.softRatio, spread: c.spread,
            reblurRatio: c.reblurRatio, subjectReblur: c.subjectReblur,
            scores: c.scores, blurScores: c.blurScores, cols: c.cols, rows: c.rows,
            weights: c.weights, subjectSource: c.subjectSource, bboxes: c.bboxes,
            preview: thumb, width: c.width, height: c.height)
    }

    /// 删除某个文件夹的缓存（照片全被删光等场景下避免残留）。三处一起清。
    static func remove(folder: URL) {
        let fm = FileManager.default
        try? fm.removeItem(at: cacheFile(for: folder))
        try? fm.removeItem(at: folder.appendingPathComponent(hiddenFileName))
        try? fm.removeItem(at: legacyFile(for: folder))
    }
}
