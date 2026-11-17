import Foundation
import ImageIO

func s(_ d: [CFString: Any], _ k: CFString) -> String {
    if let v = d[k] as? String { return v }
    if let v = d[k] as? NSNumber { return v.stringValue }
    return ""
}

let args = Array(CommandLine.arguments.dropFirst())
print("文件名\tMake\tModel\tLens\t焦距mm\t光圈F\t快门s\tISO\t拍摄时间\t宽\t高\tUTI")

for p in args {
    let u = URL(fileURLWithPath: p)
    let name = u.lastPathComponent
    guard let src = CGImageSourceCreateWithURL(u as CFURL, nil) else {
        print("\(name)\tERR\t\t\t\t\t\t\t\t\t\t")
        continue
    }
    let props = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]) ?? [:]
    let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
    let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
    let uti = (CGImageSourceGetType(src) as String?) ?? ""
    var iso = ""
    if let arr = exif[kCGImagePropertyExifISOSpeedRatings] as? [Any], let v = arr.first {
        iso = "\(v)"
    }
    let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0
    let h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
    let cols = [name, s(tiff, kCGImagePropertyTIFFMake), s(tiff, kCGImagePropertyTIFFModel),
                s(exif, kCGImagePropertyExifLensModel), s(exif, kCGImagePropertyExifFocalLength),
                s(exif, kCGImagePropertyExifFNumber), s(exif, kCGImagePropertyExifExposureTime),
                iso, s(exif, kCGImagePropertyExifDateTimeOriginal), "\(w)", "\(h)", uti]
    print(cols.joined(separator: "\t"))
}
