import Foundation
import ImageIO

func walk(_ d: [String: Any], _ prefix: String, _ depth: Int) {
    if depth > 3 { return }
    for (k, v) in d.sorted(by: { $0.key < $1.key }) {
        let key = "\(prefix).\(k)"
        if let sub = v as? [String: Any] {
            print("\(key)  [dict \(sub.count) keys]")
            walk(sub, key, depth + 1)
        } else if let arr = v as? [Any] {
            print("\(key)  [array \(arr.count)] \(arr.prefix(6))")
        } else if let s = v as? String {
            let shown = s.count > 90 ? String(s.prefix(90)) + "..." : s
            print("\(key) = \(shown)")
        } else {
            print("\(key) = \(v)")
        }
    }
}

for path in Array(CommandLine.arguments.dropFirst()) {
    print("===== \((path as NSString).lastPathComponent) =====")
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] else {
        print("读取失败"); continue
    }
    for (k, v) in props.sorted(by: { $0.key < $1.key }) {
        if let sub = v as? [String: Any] {
            let interesting = k.lowercased().contains("maker") || k.lowercased().contains("exif")
            print("[\(k)]  \(sub.count) keys\(interesting ? "" : " (skip)")")
            if interesting { walk(sub, k, 0) }
        } else if let s = v as? String {
            print("\(k) = \(s.prefix(80))")
        } else {
            print("\(k) = \(v)")
        }
    }
}
