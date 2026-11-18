import Foundation
import ImageIO

/// 照片的基础拍摄参数（EXIF）。相机/镜头来自 TIFF 与 EXIF 字典，
/// ISO 兼容 CR3 的 ISOSpeed 与 DNG 的 ISOSpeedRatings 两种写法。
struct ExifInfo {
    let camera: String?
    let lens: String?
    let iso: String?
    let shutter: String?
    let aperture: String?
    let focalLength: String?
    let exposureBias: String?
    let dateTime: String?
    let flash: String?
    let whiteBalance: String?
    let metering: String?
    let exposureMode: String?

    /// 一行核心参数：ISO 3200 · 1/2000s · f/9 · 672mm · +0.3EV
    /// 佳能半画幅微单的焦距额外带等效值（×1.6），全画幅保持原样。
    /// 曝光补偿并到这一行末尾，不再单独占一格（用户要求与 ISO/光圈同排）。
    var coreLine: String {
        let focal = focalLength.map { f in
            if let eq = equivalentFocal { return "\(f)（\(eq)）" }
            return f
        }
        let parts = [iso.map { "ISO \($0)" }, shutter, aperture, focal, exposureBias]
        return parts.compactMap { $0 }.joined(separator: "  ·  ")
    }

    /// 等效焦距文本（如「等效 320mm」）。只对佳能 APS-C 半画幅微单显示，
    /// 全画幅、其他品牌、无焦距数据时返回 nil —— 界面据此完全不显示这一项。
    /// 目前只支持佳能微单，按机型字符串识别，不猜测其他品牌。
    var equivalentFocal: String? {
        guard let model = camera, Self.isCanonAPSCMirrorless(model),
              let f = Self.focalNumber(focalLength), f > 0 else { return nil }
        return "等效 \(Int((f * 1.6).rounded()))mm"
    }

    /// 佳能 APS-C 半画幅微单机型（含 EOS R 系列与 EOS M 系列）。系数统一 1.6。
    /// 用「去掉空格后的型号串 contains 关键词」判断，能覆盖 Mark II / V 等后缀。
    private static let canonAPSCTokens = ["R7", "R50", "R10", "R100",
                                          "M50", "M6", "M10", "M100", "M200", "M5", "M3"]
    private static func isCanonAPSCMirrorless(_ model: String) -> Bool {
        let m = model.uppercased().filter { !$0.isWhitespace }
        // 必须是佳能机型，避免别家型号里恰好含 R5/M5 之类被误判。
        guard m.contains("CANON") else { return false }
        return canonAPSCTokens.contains { m.contains($0) }
    }

    private static func focalNumber(_ s: String?) -> Double? {
        guard let s = s else { return nil }
        var cur = ""
        var best = 0.0
        func flush() { if let v = Double(cur), v > 0 { best = max(best, v) }; cur = "" }
        for ch in s {
            if ch.isNumber || ch == "." { cur.append(ch) } else { flush() }
        }
        flush()
        return best > 0 ? best : nil
    }

    /// 次要信息：测光 · 曝光模式 · 白平衡 · 闪光灯
    var detailLine: String {
        var parts: [String] = []
        if let m = metering { parts.append("测光 \(m)") }
        if let e = exposureMode { parts.append("曝光 \(e)") }
        if let w = whiteBalance { parts.append("白平衡 \(w)") }
        if let f = flash { parts.append("闪光灯 \(f)") }
        return parts.joined(separator: " · ")
    }

    static func read(_ url: URL) -> ExifInfo? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any]
        else { return nil }
        let exif = props["{Exif}"] as? [String: Any] ?? [:]
        let tiff = props["{TIFF}"] as? [String: Any] ?? [:]

        let info = ExifInfo(
            camera: tiff["Model"] as? String,
            lens: exif["LensModel"] as? String,
            iso: readISO(exif),
            shutter: readShutter(exif),
            aperture: readAperture(exif),
            focalLength: readFocalLength(exif),
            exposureBias: readBias(exif),
            dateTime: readDate(exif),
            flash: readFlash(exif),
            whiteBalance: readWB(exif),
            metering: readMetering(exif),
            exposureMode: readExposureMode(exif)
        )
        guard info.camera != nil || info.iso != nil || info.shutter != nil || info.aperture != nil
        else { return nil }
        return info
    }

    // MARK: - 字段格式化

    private static func num(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        return nil
    }

    private static func readISO(_ exif: [String: Any]) -> String? {
        if let n = num(exif["ISOSpeed"]), n > 0 { return "\(Int(n))" }
        if let arr = exif["ISOSpeedRatings"] as? [NSNumber], let first = arr.first, first.intValue > 0 {
            return "\(first.intValue)"
        }
        if let arr = exif["ISOSpeedRatings"] as? [Int], let first = arr.first, first > 0 {
            return "\(first)"
        }
        return nil
    }

    private static func readShutter(_ exif: [String: Any]) -> String? {
        guard let t = num(exif["ExposureTime"]), t > 0 else { return nil }
        if t >= 1 {
            if abs(t - t.rounded()) < 0.01 { return "\(Int(t.rounded()))s" }
            return String(format: "%.1fs", t)
        }
        let d = 1 / t
        let rounded = d.rounded()
        if abs(d - rounded) < max(1, d * 0.01) { return "1/\(Int(rounded))s" }
        return String(format: "1/%.0fs", d)
    }

    private static func readAperture(_ exif: [String: Any]) -> String? {
        guard let f = num(exif["FNumber"]), f > 0 else { return nil }
        if abs(f - f.rounded()) < 0.01 { return "f/\(Int(f.rounded()))" }
        return String(format: "f/%.1f", f)
    }

    private static func readFocalLength(_ exif: [String: Any]) -> String? {
        guard let f = num(exif["FocalLength"]), f > 0 else { return nil }
        if abs(f - f.rounded()) < 0.01 { return "\(Int(f.rounded()))mm" }
        return String(format: "%.1fmm", f)
    }

    private static func readBias(_ exif: [String: Any]) -> String? {
        guard let v = num(exif["ExposureBiasValue"]) else { return nil }
        if abs(v) < 0.01 { return "±0EV" }
        return String(format: v > 0 ? "+%.1fEV" : "%.1fEV", v)
    }

    private static func readDate(_ exif: [String: Any]) -> String? {
        guard let s = exif["DateTimeOriginal"] as? String else { return nil }
        let parts = s.split(separator: " ")
        guard parts.count >= 2 else { return s }
        let d = parts[0].replacingOccurrences(of: ":", with: "-")
        let t = String(parts[1]).split(separator: ":").prefix(2).joined(separator: ":")
        return "\(d) \(t)"
    }

    private static func readFlash(_ exif: [String: Any]) -> String? {
        guard let v = num(exif["Flash"]) else { return nil }
        if v == 0 { return "未闪光" }
        if v == 16 { return "强制不闪光" }
        if v == 24 || v == 25 { return "自动闪光" }
        return "已闪光"
    }

    private static func readWB(_ exif: [String: Any]) -> String? {
        guard let v = num(exif["WhiteBalance"]) else { return nil }
        switch Int(v) {
        case 0: return "自动"
        case 1: return "手动"
        case 2: return "日光"
        case 3: return "阴天"
        case 4: return "白炽灯"
        case 5: return "荧光灯"
        case 6: return "闪光灯"
        default: return nil
        }
    }

    private static func readMetering(_ exif: [String: Any]) -> String? {
        guard let v = num(exif["MeteringMode"]) else { return nil }
        switch Int(v) {
        case 1: return "平均"
        case 2: return "中央重点"
        case 3: return "点测光"
        case 4, 5: return "评价/矩阵"
        case 6: return "局部"
        default: return nil
        }
    }

    private static func readExposureMode(_ exif: [String: Any]) -> String? {
        guard let v = num(exif["ExposureMode"]) else { return nil }
        switch Int(v) {
        case 0: return "自动"
        case 1: return "手动"
        case 2: return "包围曝光"
        default: return nil
        }
    }
}
