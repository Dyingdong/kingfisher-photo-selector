import Foundation

@main
struct ScoreProbe {
    static func main() {
        for p in Array(CommandLine.arguments.dropFirst()) {
            guard let m = Analyzer.analyze(URL(fileURLWithPath: p)) else { print("\(p): FAIL"); continue }
            let qs = [0.50, 0.75, 0.90, 0.95, 0.98, 0.99, 0.995, 1.0]
            let vals = qs.map { Analyzer.percentile(m.scores, $0) }.map { String(format: "%.1f", $0) }
            print("\(URL(fileURLWithPath: p).lastPathComponent) blocks=\(m.scores.count)")
            print("  " + qs.map { "P\(Int($0*1000)/10)" }.joined(separator: " "))
            print("  " + vals.joined(separator: " "))
        }
    }
}
