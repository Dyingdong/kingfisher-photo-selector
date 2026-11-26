import Foundation
import ImageIO

struct ComparisonGroup: Identifiable {
    let name: String
    let photos: [URL]
    var id: String { name }
}

enum BurstIndex {
    private struct Frame {
        let url: URL
        let time: Date?
        let fraction: Double?
        let modified: Date
        let camera: String
        let focalLength: Double?
        let sequence: Int?
    }

    static func scan(_ directory: URL) throws -> [ComparisonGroup] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey]
        var readError: Error?
        let files = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]
        ) { _, error in
            readError = error
            return false
        }
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(secondsFromGMT: 0)
        parser.dateFormat = "yyyy:MM:dd HH:mm:ss"
        var frames: [Frame] = []
        if let files {
            for case let url as URL in files {
                try Task.checkCancellation()
                guard MetadataWriter.isRAW(url) else { continue }
                let values = try url.resourceValues(forKeys: keys)
                guard values.isRegularFile == true else { continue }
                frames.append(frame(url, modified: values.contentModificationDate, parser: parser))
            }
        }
        if let readError { throw readError }
        guard files != nil else { throw CocoaError(.fileReadUnknown) }
        return groups(frames)
    }

    private static func frame(_ url: URL, modified: Date?, parser: DateFormatter) -> Frame {
        let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        let properties = source.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) } as? [String: Any] ?? [:]
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        let auxiliary = properties[kCGImagePropertyExifAuxDictionary as String] as? [String: Any] ?? [:]
        let canon = properties[kCGImagePropertyMakerCanonDictionary as String] as? [String: Any] ?? [:]
        let make = tiff[kCGImagePropertyTIFFMake as String] as? String ?? ""
        let model = tiff[kCGImagePropertyTIFFModel as String] as? String ?? ""
        let serial = (exif[kCGImagePropertyExifBodySerialNumber as String]
                      ?? auxiliary[kCGImagePropertyExifAuxSerialNumber as String]
                      ?? canon[kCGImagePropertyMakerCanonCameraSerialNumber as String])
            .map { String(describing: $0) } ?? ""
        let fraction = (exif[kCGImagePropertyExifSubsecTimeOriginal as String] ?? exif["SubSecTimeOriginal"]).flatMap {
            let digits = String(describing: $0).trimmingCharacters(in: .whitespacesAndNewlines)
            return digits.isEmpty ? nil : Double("0." + digits)
        }
        let time = (exif[kCGImagePropertyExifDateTimeOriginal as String] as? String).flatMap { parser.date(from: $0) }
        return Frame(url: url, time: time, fraction: fraction, modified: modified ?? .distantPast,
                     camera: model.isEmpty ? "" : [make, model, serial].joined(separator: "|"),
                     focalLength: exif[kCGImagePropertyExifFocalLength as String] as? Double,
                     sequence: (canon["SequenceNumber"] as? Int).flatMap { $0 > 0 ? $0 : nil })
    }

    private static func order(_ frame: Frame) -> Date {
        frame.time?.addingTimeInterval(frame.fraction ?? 0) ?? frame.modified
    }

    private static func follows(_ previous: Frame, _ next: Frame) -> Bool {
        guard let earlier = previous.time, let later = next.time else { return false }
        if let first = previous.focalLength, let second = next.focalLength, abs(first - second) > 1 {
            return false
        }
        if let first = previous.sequence, let second = next.sequence {
            return second > first && second - first == 1 && later.timeIntervalSince(earlier) <= 1
        }
        if previous.fraction != nil, next.fraction != nil {
            return order(next).timeIntervalSince(order(previous)) <= 0.45
        }
        // 只有整秒时间时，按同秒聚合，避免把跨秒散拍串成一组。
        return earlier == later
    }

    private static func groups(_ frames: [Frame]) -> [ComparisonGroup] {
        let sorted = frames.sorted {
            let first = order($0), second = order($1)
            return first == second ? $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending : first < second
        }
        let cameras = Dictionary(grouping: sorted.indices) { index in
            let frame = sorted[index]
            return frame.url.deletingLastPathComponent().path + "\u{0}" + frame.camera
        }
        var bursts: [[Int]] = []
        var singles: [Int] = []
        for indices in cameras.values {
            var sequence: [Int] = []
            for index in indices {
                if let last = sequence.last,
                   sorted[index].camera.isEmpty || !follows(sorted[last], sorted[index]) {
                    if sequence.count > 1 { bursts.append(sequence) } else { singles.append(last) }
                    sequence.removeAll(keepingCapacity: true)
                }
                sequence.append(index)
            }
            if sequence.count > 1 { bursts.append(sequence) } else { singles.append(contentsOf: sequence) }
        }
        var groups = bursts.sorted { $0[0] < $1[0] }.enumerated().map { index, burst in
            ComparisonGroup(name: String(format: "连拍 %02d", index + 1), photos: burst.map { sorted[$0].url })
        }
        if !singles.isEmpty {
            groups.append(ComparisonGroup(name: "未分组", photos: singles.sorted().map { sorted[$0].url }))
        }
        return groups
    }
}
