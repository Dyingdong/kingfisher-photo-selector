import Foundation

/// 从 RAW 的 MakerNote 里读取相机记录的合焦点。
/// 数据来自项目内自带的 exiftool（Tools/exiftool），不依赖用户系统安装。
/// 目前支持 Canon（AFInfo：AFPointsInFocus / AFAreaXPositions 等）；
/// 其他品牌或 DNG 代理没有这些字段时返回 nil，界面会明确标注"无数据"。
struct FocusPoint {
    /// 归一化坐标，原点在画面左上，x 右为正、y 下为正，取值 0~1。
    let cx: Double
    let cy: Double
    /// 对焦框大小（归一化）。Spot/单点模式框很小；Whole Area 模式框很大。
    let w: Double
    let h: Double
}

struct AFInfo {
    let mode: Int                 // exiftool 的 AFAreaMode 数值
    let modeName: String
    let validPoints: Int
    let totalPoints: Int
    let points: [FocusPoint]
    let imageWidth: Int
    let imageHeight: Int

    var summary: String {
        guard !points.isEmpty else { return "无合焦点数据" }
        let p = points[0]
        let xPct = Int(p.cx * 100), yPct = Int(p.cy * 100)
        let whereText = "横向\(xPct)%／纵向\(yPct)%"
        return "\(modeName) · \(points.count) 个合焦点 · 中心 \(whereText)"
    }
}

enum AFReader {
    /// exiftool 可执行文件的路径：优先 App 包内 Resources，其次开发环境的项目目录。
    private static func exiftoolURL() -> URL? {
        let fm = FileManager.default
        if let bundled = Bundle.main.url(forResource: "exiftool", withExtension: nil),
           fm.fileExists(atPath: bundled.path) {
            return bundled
        }
        // 环境变量（开发/测试用）
        if let root = ProcessInfo.processInfo.environment["FS_EXIFTOOL_ROOT"] {
            let candidate = URL(fileURLWithPath: root).appendingPathComponent("Tools/exiftool/exiftool")
            if fm.fileExists(atPath: candidate.path) { return candidate }
        }
        // 开发环境：从可执行文件位置、当前目录分别回溯到项目 Tools/exiftool
        let exec = URL(fileURLWithPath: CommandLine.arguments[0])
        var starts = [exec.deletingLastPathComponent()]
        if let cwd = fm.currentDirectoryPath as String? { starts.append(URL(fileURLWithPath: cwd)) }
        for start in starts {
            var dir = start
            for _ in 0..<6 {
                let candidate = dir.appendingPathComponent("Tools/exiftool/exiftool")
                if fm.fileExists(atPath: candidate.path) { return candidate }
                dir = dir.deletingLastPathComponent()
            }
        }
        return nil
    }

    static func read(_ url: URL) -> AFInfo? {
        guard let exe = exiftoolURL() else { return nil }
        guard let perl = executablePath("perl") else { return nil }
        // Perl 对非 ASCII 的脚本路径会解析失败（App 路径含中文），
        // 因此把 exiftool 脚本复制到一个纯 ASCII 的临时路径再执行。
        guard let stage = stageExiftool(exe) else { return nil }

        let tags = ["AFImageWidth", "AFImageHeight", "NumAFPoints", "ValidAFPoints",
                    "AFAreaWidths", "AFAreaHeights", "AFAreaXPositions",
                    "AFAreaYPositions", "AFPointsInFocus", "AFAreaMode"]
        var args = [stage.script, "-a", "-G1", "-n", "-j"]
        args += tags.map { "-" + $0 }
        args.append(url.path)

        let task = Process()
        task.executableURL = URL(fileURLWithPath: perl)
        task.arguments = args
        let out = Pipe(), err = Pipe()
        task.standardOutput = out
        task.standardError = err
        do { try task.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0,
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let d = arr.first else { return nil }

        // 只要 Canon 组（Track4 是同一份数据的重复）
        func val(_ key: String) -> Any? { d["Canon:" + key] ?? d[key] }
        func number(_ key: String) -> Int? {
            guard let v = val(key) else { return nil }
            if let n = v as? Int { return n }
            if let s = v as? String { return Int(s.trimmingCharacters(in: .whitespaces)) }
            return nil
        }
        func numbers(_ key: String) -> [Int] {
            guard let v = val(key) else { return [] }
            if let a = v as? [Int] { return a }
            if let s = v as? String {
                return s.split(whereSeparator: { $0 == " " || $0 == "\n" })
                       .compactMap { Int($0) }
            }
            return []
        }

        let focus = numbers("AFPointsInFocus")
        let xs = numbers("AFAreaXPositions")
        let ys = numbers("AFAreaYPositions")
        let ws = numbers("AFAreaWidths")
        let hs = numbers("AFAreaHeights")
        let iw = number("AFImageWidth") ?? 1
        let ih = number("AFImageHeight") ?? 1
        let mode = number("AFAreaMode") ?? -1

        // AF 坐标原点在画面中心：x 右为正，y 上为正；转成左上原点的 0~1 坐标
        var pts: [FocusPoint] = []
        for (i, hit) in focus.enumerated() where hit != 0 {
            guard i < xs.count, i < ys.count else { continue }
            let afX = Double(xs[i]), afY = Double(ys[i])
            let cx = (Double(iw) / 2 + afX) / Double(iw)
            let cy = (Double(ih) / 2 - afY) / Double(ih)
            let bw = i < ws.count ? Double(ws[i]) / Double(iw) : 0
            let bh = i < hs.count ? Double(hs[i]) / Double(ih) : 0
            pts.append(FocusPoint(cx: cx, cy: cy, w: bw, h: bh))
        }

        return AFInfo(mode: mode, modeName: Self.modeName(mode),
                      validPoints: number("ValidAFPoints") ?? 0,
                      totalPoints: number("NumAFPoints") ?? 0,
                      points: pts, imageWidth: iw, imageHeight: ih)
    }

    /// 把 exiftool 脚本和 lib 准备到纯 ASCII 的临时目录，规避 Perl 对中文路径的解析问题。
    /// exiftool 用脚本所在目录/lib 找模块，所以这里在同级建一个 lib 符号链接。
    private static func stageExiftool(_ original: URL) -> (script: String, dir: URL)? {
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fs_af_exiftool", isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let script = dir.appendingPathComponent("exiftool")
            let libLink = dir.appendingPathComponent("lib")
            // 脚本内容每次覆盖，确保版本更新生效
            if !fm.fileExists(atPath: script.path) ||
               (try? Data(contentsOf: original)) != (try? Data(contentsOf: script)) {
                try? fm.removeItem(at: script)
                try fm.copyItem(at: original, to: script)
            }
            if !fm.fileExists(atPath: libLink.path) {
                let base = original.deletingLastPathComponent()
                let candidates = ["lib", "exiftool_lib"].map { base.appendingPathComponent($0) }
                let srcLib = candidates.first { fm.fileExists(atPath: $0.path) }
                           ?? base.appendingPathComponent("lib")
                try fm.createSymbolicLink(at: libLink, withDestinationURL: srcLib)
            }
            return (script.path, dir)
        } catch {
            return nil
        }
    }

    private static func executablePath(_ name: String) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        task.arguments = [name]
        let pipe = Pipe()
        task.standardOutput = pipe
        do { try task.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        let s = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return s.isEmpty ? nil : s
    }

    static func modeName(_ m: Int) -> String {
        switch m {
        case 0: return "手动对焦"
        case 1: return "对焦点扩展（周围）"
        case 2: return "单点对焦"
        case 4: return "自动"
        case 5: return "人脸检测"
        case 6: return "人脸＋追踪"
        case 7: return "区域对焦"
        case 8: return "对焦点扩展（4点）"
        case 9: return "定点对焦"
        case 10: return "对焦点扩展（8点）"
        case 13: return "单点对焦"
        case 14: return "大区域对焦"
        case 16: return "大区域对焦（纵向）"
        case 17: return "大区域对焦（横向）"
        case 19: return "灵活区域 1"
        case 20: return "灵活区域 2"
        case 21: return "灵活区域 3"
        case 22: return "全区域对焦"
        default: return "对焦模式 \(m)"
        }
    }
}
