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
