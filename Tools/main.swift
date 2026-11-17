import Foundation
import ImageIO

// 命令行入口：与 App 共用 Analyzer / Subject / Report，保证两条路径的判定完全一致。
// 用法：focuscli <照片或文件夹...> [-o 报告.csv] [-s 灵敏度] [-a 清晰参考片] [--faces]
// 默认用独立固定阈值判定，不依赖同批照片的构成。

func usage() -> String {
    """
    用法: focuscli <照片或文件夹...> [-o 报告.csv] [-s 灵敏度] [-a 清晰参考片] [--faces]

    每张照片独立判定，默认基准为固定阈值 400（用真值标定，不随同批照片变化）。
      -o       输出 CSV 路径；省略则打印到标准输出
      -s       灵敏度，默认 1.00（越大越容易判为未合焦）
      -a       可选：指定一张已知清晰的照片作固定基准（旧功能，默认不需要）
      --faces  优先按人脸定位主体
    """
}

let argv = Array(CommandLine.arguments.dropFirst())
var paths: [String] = []
var outPath: String?
var anchorPath: String?
var sensitivity = 1.0
var preferFaces = false

var i = 0
while i < argv.count {
    let a = argv[i]
    if a == "-h" || a == "--help" { print(usage()); exit(0) }
    if a == "-o", i + 1 < argv.count { outPath = argv[i + 1]; i += 2; continue }
    if a == "-a", i + 1 < argv.count { anchorPath = argv[i + 1]; i += 2; continue }
    if a == "-s", i + 1 < argv.count {
        sensitivity = Double(argv[i + 1]) ?? 1.0
        i += 2; continue
    }
    if a == "--faces" { preferFaces = true; i += 1; continue }
    paths.append(a)
    i += 1
}

guard !paths.isEmpty else { print(usage()); exit(2) }

func err(_ s: String) {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
}

let fm = FileManager.default
let allowed = MetadataWriter.jpgExts.union(MetadataWriter.rawExts)
var files: [URL] = []
for p in paths {
    let u = URL(fileURLWithPath: p)
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: p, isDirectory: &isDir) else {
        err("路径不存在：\(p)")
        continue
    }
    if isDir.boolValue {
        if let e = fm.enumerator(at: u, includingPropertiesForKeys: [.isDirectoryKey],
                                 options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
            for case let f as URL in e where allowed.contains(f.pathExtension.lowercased()) {
                files.append(f)
            }
        }
    } else if allowed.contains(u.pathExtension.lowercased()) {
        files.append(u)
    }
}
files.sort { $0.path < $1.path }

guard !files.isEmpty else { err("没有找到可处理的 JPG / RAW 照片"); exit(1) }

var metrics: [PhotoMetrics] = []
for u in files {
    if let m = Analyzer.analyze(u, preferFaces: preferFaces) { metrics.append(m) }
}

var anchor: Double?
if let ap = anchorPath {
    guard let am = Analyzer.analyze(URL(fileURLWithPath: ap)) else {
        err("锚点照片无法解析：\(ap)")
        exit(1)
    }
    anchor = am.globalHi
    err("固定锚点 \(URL(fileURLWithPath: ap).lastPathComponent)："
        + "最锐区 P90 \(String(format: "%.1f", am.globalHi))")
}

let hiMin = Analyzer.referenceThreshold(metrics, sensitivity: sensitivity, anchor: anchor)
let results = Analyzer.decide(metrics, sensitivity: sensitivity, anchor: anchor)
let csv = Report.csv(results, hiMin: hiMin, sensitivity: sensitivity, anchor: anchor)

if let o = outPath {
    do {
        try csv.write(to: URL(fileURLWithPath: o), atomically: true, encoding: .utf8)
        err("分析 \(results.count) 张，独立判定基准 \(String(format: "%.1f", hiMin))，报告：\(o)")
    } catch {
        err("写入报告失败：\(error.localizedDescription)")
        exit(1)
    }
} else {
    print(csv)
}
