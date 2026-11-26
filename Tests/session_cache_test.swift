import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// 会话缓存往返一致性测试：
// 1) 合成指标 → SessionCache.save → load → 逐字段核对；
// 2) 真实小图 → metrics(from:url:) 重建 → preview 非空、数值一致；
// 3) 文件名对账逻辑的载体（byName 匹配）由 App.apply 负责组装，这里只测缓存层。
@main
struct SessionCacheTest {
    static func main() {
        var failed = 0
        func check(_ cond: Bool, _ name: String) {
            print("\(cond ? "PASS" : "FAIL") \(name)")
            if !cond { failed += 1 }
        }

        let root = URL(fileURLWithPath: "/tmp/sessioncache_test")
        try? FileManager.default.removeItem(at: root)
        let folder = root.appendingPathComponent("folder")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        // 造一张真实小图，供 metrics(from:) 重建 preview 用
        let imgURL = folder.appendingPathComponent("IMG_0001.JPG")
        let w = 96, h = 72
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                            bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.setFillColor(gray: 0.6, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let cg = ctx.makeImage()!
        let dest = CGImageDestinationCreateWithURL(imgURL as CFURL,
                                                   UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, cg, nil)
        CGImageDestinationFinalize(dest)

        // 合成指标
        let cols = 3, rows = 2
        let m = PhotoMetrics(
            url: imgURL, globalHi: 512.5, peakBlock: 800.25, subjectScore: 300.0,
            ratio: 0.585, centerRatio: 0.42, anisotropy: 1.31,
            softRatio: 0.18, spread: 0.77,
            reblurRatio: 0.55, subjectReblur: 0.33,
            scores: Array(stride(from: 0.0, to: Double(cols * rows), by: 1)),
            blurScores: Array(repeating: 12.5, count: cols * rows),
            cols: cols, rows: rows,
            weights: Array(repeating: 0.5, count: cols * rows),
            subjectSource: "前景主体",
            bboxes: [CGRect(x: 0.2, y: 0.3, width: 0.1, height: 0.15)],
            preview: cg, width: w, height: h)
        var r = PhotoResult(id: imgURL, metrics: m, verdict: .subjectBlur,
                            reason: "主体是虚的，测试原因")
        r.overrideRect = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)

        SessionCache.save(folder: folder, sensitivity: 1.25, anchorHi: 900.0, hiMin: 500.0,
                          excluded: [imgURL], results: [r], metrics: [m],
                          selectionRects: [imgURL: CGRect(x: 0.05, y: 0.06, width: 0.5, height: 0.6)],
                          genreOverride: [imgURL: .bird])

        let snap = SessionCache.load(folder: folder)
        check(snap != nil, "缓存能读回")
        guard let snap else { exit(failed == 0 ? 0 : 1) }
        check(snap.photos.count == 1, "照片数 = 1")
        check(snap.sensitivity == 1.25 && snap.hiMin == 500.0 && snap.anchorHi == 900.0,
              "灵敏度/基准字段往返")
        check(snap.excludedFiles == ["IMG_0001.JPG"], "排除写入列表往返")
        let c = snap.photos[0]
        check(c.file == "IMG_0001.JPG", "文件名往返")
        check(c.verdict == Verdict.subjectBlur.rawValue, "判定词往返")
        check(c.reason == r.reason, "原因往返")
        check(c.overrideRect == r.overrideRect, "圈选重判框往返")
        check(c.selectionRect == CGRect(x: 0.05, y: 0.06, width: 0.5, height: 0.6), "显示圈选框往返")
        check(c.genreOverride == PhotoGenre.bird.rawValue, "题材覆盖往返")
        check(c.globalHi == m.globalHi && c.peakBlock == m.peakBlock && c.subjectScore == m.subjectScore,
              "核心数值往返")
        check(c.scores == m.scores && c.blurScores == m.blurScores && c.weights == m.weights,
              "分块数组往返（含元素个数 \(m.scores.count)）")
        check(c.cols == cols && c.rows == rows && c.subjectSource == "前景主体", "网格/主体来源往返")
        check(c.bboxes == m.bboxes, "主体框往返")

        if let rebuilt = SessionCache.metrics(from: c, url: imgURL) {
            check(rebuilt.preview != nil, "重建时 preview 已重新解码")
            check(rebuilt.globalHi == m.globalHi && rebuilt.scores == m.scores,
                  "重建指标与原指标一致")
            check(rebuilt.url == imgURL, "重建 URL 正确")
        } else {
            check(false, "重建 metrics 失败")
        }

        var invalid = c
        invalid.blurScores.removeLast()
        check(SessionCache.metrics(from: invalid, url: imgURL, decodePreview: false) == nil,
              "缺分块的缓存被拒绝")
        invalid = c
        invalid.cols = Int.max
        check(SessionCache.metrics(from: invalid, url: imgURL, decodePreview: false) == nil,
              "网格尺寸溢出的缓存被拒绝")

        // —— v1 兼容：老 log（version=1、无信息字段）必须可读，新字段解码为 nil ——
        // 行为退回现状（按需现算），补算后回写 v2。写入时把信息字段显式置 nil，
        // 模拟老版本保存的 JSON 键缺失（Codable 解码缺失键 = nil）。
        var v1 = snap
        v1.version = 1
        v1.photos[0].wb = nil
        v1.photos[0].af = nil
        v1.photos[0].exif = nil
        v1.photos[0].focus = nil
        v1.photos[0].human = nil
        v1.photos[0].ai = nil
        v1.photos[0].rating = nil
        if let d1 = try? JSONEncoder().encode(v1) {
            try! d1.write(to: SessionCache.cacheFile(for: folder))
            if let old1 = SessionCache.load(folder: folder) {
                check(old1.version == 1, "v1 旧缓存可读（version 往返）")
                check(old1.photos[0].rating == nil && old1.photos[0].wb == nil
                      && old1.photos[0].af == nil && old1.photos[0].exif == nil
                      && old1.photos[0].focus == nil && old1.photos[0].human == nil
                      && old1.photos[0].ai == nil, "v1 缺失信息字段解码为 nil")
            } else {
                check(false, "v1 旧缓存可读")
            }
        } else {
            check(false, "v1 快照可编码")
        }

        // —— v2 信息字段往返：WB/AF/EXIF/Focus/Human/AI/Rating 全字段 ——
        let info = [imgURL: PhotoInfoSnapshot(
            wb: WhiteBalanceStats(meanR: 131.4, meanG: 128.2, meanB: 120.9,
                                  wholeCast: "偏暖（R 高于 B）", faceCast: "接近中性",
                                  faceRG: 1.01, faceBG: 0.97, highlightClip: 0.031,
                                  shadowClip: 0.052),
            af: AFInfo(mode: 2, modeName: "单点对焦", validPoints: 1, totalPoints: 525,
                       points: [FocusPoint(cx: 0.51, cy: 0.48, w: 0.02, h: 0.02)],
                       imageWidth: 6000, imageHeight: 4000),
            exif: ExifInfo(camera: "Canon EOS R7", lens: "RF 100-500", iso: "3200",
                           shutter: "1/2000s", aperture: "f/9", focalLength: "500mm",
                           exposureBias: "+0.3EV", dateTime: "2026-11-20 10:12",
                           flash: "未闪光", whiteBalance: "自动", metering: "评价/矩阵",
                           exposureMode: "手动"),
            focus: FocusSemantics(kind: .bird, reason: "对焦点处识别到：鹭 (63%)",
                                  labels: ["heron 63%"]),
            human: HumanPresence(hasPerson: false, isMainSubject: false, count: 0,
                                 bodyHeightRatio: 0, reason: "未检测到人"),
            ai: AISubject(kind: .bird, reason: "前景主体是鸟", labels: ["bird 88%"]),
            rating: 4)]
        SessionCache.save(folder: folder, sensitivity: 1.25, anchorHi: 900.0, hiMin: 500.0,
                          excluded: [imgURL], results: [r], metrics: [m],
                          selectionRects: [imgURL: CGRect(x: 0.05, y: 0.06, width: 0.5, height: 0.6)],
                          genreOverride: [imgURL: .bird], info: info)
        if let snap2 = SessionCache.load(folder: folder) {
            check(snap2.version == SessionCache.version, "v2 保存后 version 为当前值")
            let c2 = snap2.photos[0]
            check(c2.rating == 4, "星级往返")
            check(c2.wb?.meanR == 131.4 && c2.wb?.wholeCast == "偏暖（R 高于 B）"
                  && c2.wb?.faceRG == 1.01, "白平衡统计往返")
            check(c2.af?.modeName == "单点对焦" && c2.af?.points.count == 1
                  && c2.af?.points.first?.cx == 0.51, "对焦点信息往返")
            check(c2.exif?.iso == "3200" && c2.exif?.shutter == "1/2000s"
                  && c2.exif?.camera == "Canon EOS R7", "EXIF 往返")
            check(c2.focus?.kind == .bird && c2.focus?.reason.contains("鹭") == true,
                  "对焦点语义往返（枚举+文本）")
            check(c2.human?.hasPerson == false, "人体检测往返")
            check(c2.ai?.kind == .bird && c2.ai?.labels == ["bird 88%"], "AI 主体往返")
        } else {
            check(false, "v2 信息字段快照可读回")
        }

        // 父目录恢复、子日志重定位、旧日志重名拒配。
        let a = folder.appendingPathComponent("A/IMG.CR3")
        let b = folder.appendingPathComponent("B/IMG.CR3")
        var dual = snap
        var first = c, second = c
        first.file = "A/IMG.CR3"; first.rating = 2
        second.file = "B/IMG.CR3"; second.rating = 5
        dual.photos = [first, second]
        dual.excludedFiles = [second.file]
        let restored = SessionCache.matched(dual, source: folder, folder: folder, files: [a, b])
        check(restored?.photos.first { $0.file == first.file }?.rating == 2 &&
              restored?.photos.first { $0.file == second.file }?.rating == 5, "子目录同名照片独立恢复")
        let child = b.deletingLastPathComponent()
        let subset = SessionCache.matched(dual, source: folder, folder: child, files: [b])
        check(subset?.photos.first?.file == "IMG.CR3" && subset?.excludedFiles == ["IMG.CR3"],
              "读取父日志时重定位路径与排除项")
        dual.version = 2
        first.file = "IMG.CR3"; second.file = first.file
        dual.photos = [first, second]
        check(SessionCache.matched(dual, source: folder, folder: folder, files: [a, b]) == nil,
              "老日志重复记录拒配")
        dual.photos = [first]
        check(SessionCache.matched(dual, source: folder, folder: folder, files: [a, b]) == nil,
              "老日志遇到磁盘同名照片拒配")
        let rebased = SessionCache.matched(dual, source: child, folder: folder, files: [a, b])
        check(rebased?.photos.first?.file == "B/IMG.CR3", "老子日志唯一匹配迁入父目录")

        // version 不符的旧缓存要拒载
        var old = snap
        old.version = 999
        let data = try! JSONEncoder().encode(old)
        try! data.write(to: SessionCache.cacheFile(for: folder))
        check(SessionCache.load(folder: folder) == nil, "版本不符的旧缓存拒载")

        SessionCache.remove(folder: folder)
        check(SessionCache.load(folder: folder) == nil, "remove 后缓存清空")

        try? FileManager.default.removeItem(at: root)
        print(failed == 0 ? "ALL PASS" : "\(failed) FAILED")
        exit(failed == 0 ? 0 : 1)
    }
}
