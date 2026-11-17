import Foundation

@main
struct AnalyzeTest {
    static func main() {
        let dir = URL(fileURLWithPath: "/tmp/fs_test/cases")
        let names = ["clear", "blur", "portrait", "misfocus", "motion"]
        var metrics: [PhotoMetrics] = []
        for n in names {
            let u = dir.appendingPathComponent(n + ".jpg")
            if let m = Analyzer.analyze(u) {
                metrics.append(m)
            } else {
                print("\(n): 解码失败")
            }
        }
        let results = Analyzer.decide(metrics)
        print("照片数: \(results.count)")
        print(String(format: "%-14@ %9@ %9@ %9@ %8@ %8@ %8@ %-12@ %-16@",
                     "场景" as NSString, "最锐P90" as NSString, "中心/最锐" as NSString,
                     "主体/最锐" as NSString, "软块%" as NSString, "分布差" as NSString,
                     "方向性" as NSString, "主体来源" as NSString, "判定" as NSString))
        print(String(repeating: "-", count: 108))
        for r in results {
            let m = r.metrics
            print(String(format: "%-14@ %9.0f %9.2f %9.2f %8.0f %8.2f %8.2f %-12@ %-16@",
                         r.id.lastPathComponent as NSString,
                         m.globalHi, m.centerRatio, m.ratio, m.softRatio * 100, m.spread,
                         m.anisotropy, m.subjectSource as NSString,
                         r.verdict.rawValue as NSString))
            print("    原因: \(r.reason)")
        }
        print("ANALYZE_TEST_DONE")
    }
}
