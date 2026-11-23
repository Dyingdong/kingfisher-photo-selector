import Foundation
import CoreML
import Accelerate

// MARK: - 鸟种识别（BioCLIP 2 / open_clip ViT-L/14，纯本地，生命周期与 App 绑定）
//
// 用户 2026-11-23 决定：本地鸟种识别用 BioCLIP 2，纯离线；
// 拍鸟题材照片一点开就显示识别结果，风光 / 人像不识别。
//
// 工程约定：
// - 模型与 App 同生命周期，懒加载；切换文件夹 / 重置会话时 dropModel()。
// - 图像塔转成 Core ML，文本塔预计算成特征文件随包分发，运行时只做点积，不联网。
// - 预处理必须对齐 open_clip 的 Resize(224) + CenterCrop(224) + CLIP 归一化；
//   不能用 CGContext.draw（P3→DeviceRGB 色彩管理会改像素），只读 CGImage 原始字节 + vImage。
// - 鸟种只进信息区 / xmp:Label / 日志 / CSV，绝不参与六档判定和评星。

struct BirdSpeciesGuess: Codable, Hashable {
    let chinese: String
    let latin: String
    let confidence: Double

    var display: String { "\(chinese)（\(latin)）" }
}

enum BirdSpeciesEngine {

    private static var model: MLModel?
    private static var species: [(cn: String, latin: String)] = []
    private static var textFeatures: [Float] = []
    // 模型约 580MB，首次加载实测 5～6 秒。预热与按需加载可能同时发生，
    // 用锁串行化：后到的调用等第一次加载完直接复用，绝不重复读两遍模型。
    private static let loadLock = NSLock()
    private static let featureDim = 768
    private static let inputName = "image"        // MLMultiArray [1,3,224,224]
    private static let outputName = "embedding"   // MLMultiArray [1,768]（未归一化）

    /// 采纳本地结果的常规门槛：达到它即可直接显示、写标签、写日志。
    static let localAcceptThreshold = 0.50

    /// 窄口径放宽下限：仅当整图与主体框 Top1 一致（reason 含「互相印证」）时才允许采用。
    /// 旧口径 0.25 太松，曾把黑胸鸫 26.8% / 普通翠鸟 26.2% 的暗光误认写进标签；
    /// 0.45 既能恢复大山雀 49.3% 的正确结果，又继续挡住那两张 26%/27% 的误认。
    /// 低于 0.45 一律不显示、不写标签、不写日志，两路一致也不例外。
    static let localAgreementThreshold = 0.45

    /// 历史日志里标记「整图与主体框 Top1 一致」的 reason 子串，用于复用上面的窄口径。
    static let agreementReasonToken = "互相印证"

    static var available: Bool {
        Bundle.main.url(forResource: "BioCLIPImage", withExtension: "mlmodelc") != nil
            && Bundle.main.url(forResource: "bioclip_text_features", withExtension: "bin") != nil
            && Bundle.main.url(forResource: "bioclip_labels", withExtension: "txt") != nil
    }

    static var isLoaded: Bool {
        loadLock.lock()
        defer { loadLock.unlock() }
        return model != nil
    }

    @discardableResult
    static func loadIfNeeded() -> Bool {
        loadLock.lock()
        defer { loadLock.unlock() }
        guard model == nil else { return true }
        guard available,
              let url = Bundle.main.url(forResource: "BioCLIPImage", withExtension: "mlmodelc"),
              let m = try? MLModel(contentsOf: url, configuration: MLModelConfiguration()),
              let labelURL = Bundle.main.url(forResource: "bioclip_labels", withExtension: "txt"),
              let labelText = try? String(contentsOf: labelURL, encoding: .utf8),
              let featURL = Bundle.main.url(forResource: "bioclip_text_features", withExtension: "bin"),
              let featData = try? Data(contentsOf: featURL) else { return false }
        let list: [(cn: String, latin: String)] = labelText.split(separator: "\n").compactMap { line in
            let p = line.split(separator: "|", maxSplits: 1)
            guard p.count == 2 else { return nil }
            return (cn: String(p[1]), latin: String(p[0]))
        }
        guard !list.isEmpty else { return false }
        let count = featData.count / MemoryLayout<Float>.size
        guard count == list.count * featureDim else { return false }
        var features = [Float](repeating: 0, count: count)
        featData.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                _ = features.withUnsafeMutableBytes { dst in
                    memcpy(dst.baseAddress, base, min(count * MemoryLayout<Float>.size, featData.count))
                }
            }
        }
        model = m
        species = list
        textFeatures = features
        return true
    }

    /// 立刻归还模型与特征内存（切文件夹 / 重置会话时调用）。
    static func dropModel() {
        loadLock.lock()
        defer { loadLock.unlock() }
        model = nil
        species = []
        textFeatures = []
    }

    /// 识别一张图，返回相似度降序 Top-3。nil = 模型没加载或推理失败。
    /// - parameter crop: 归一化主体框，原点在**左下**（与 Report.swift 的"主体框"列一致）。
    static func guess(image: CGImage, crop: CGRect? = nil) -> [BirdSpeciesGuess]? {
        guard let model, !species.isEmpty, textFeatures.count == species.count * featureDim else { return nil }
        guard let input = makeInput(image: image, crop: crop) else { return nil }
        guard let provider = try? MLDictionaryFeatureProvider(dictionary: [inputName: MLFeatureValue(multiArray: input)]),
              let out = try? model.prediction(from: provider),
              let embedding = out.featureValue(for: outputName)?.multiArrayValue else { return nil }

        var imageVec = [Float](repeating: 0, count: featureDim)
        for i in 0..<min(embedding.count, featureDim) { imageVec[i] = embedding[i].floatValue }
        var norm: Float = 0
        vDSP_dotpr(imageVec, 1, imageVec, 1, &norm, vDSP_Length(featureDim))
        guard norm > 0 else { return nil }
        norm = sqrt(norm)
        for i in 0..<featureDim { imageVec[i] /= norm }

        // 文本特征已归一化：点积即余弦相似度；open_clip 用 logit_scale=100 做 softmax。
        var scores = [Float](repeating: 0, count: species.count)
        for i in 0..<species.count {
            let base = i * featureDim
            var dot: Float = 0
            for k in 0..<featureDim { dot += imageVec[k] * textFeatures[base + k] }
            scores[i] = dot
        }
        let maxScore = scores.max() ?? 0
        var exps = [Float](repeating: 0, count: scores.count)
        var sum: Float = 0
        for i in 0..<scores.count {
            let e = expf((scores[i] - maxScore) * 100)
            exps[i] = e
            sum += e
        }
        guard sum > 0 else { return nil }

        var ranked: [(Double, Int)] = []
        ranked.reserveCapacity(scores.count)
        for i in 0..<scores.count {
            let p = Double(exps[i] / sum)
            if p.isFinite && p > 0 { ranked.append((p, i)) }
        }
        ranked.sort { $0.0 > $1.0 }
        return ranked.prefix(3).map { p, i in
            BirdSpeciesGuess(chinese: species[i].cn, latin: species[i].latin, confidence: p)
        }
    }

    /// 按验证脚本口径把主体框四周扩边，并保证最小边长 0.18（左下原点归一化）。
    static func paddedCrop(_ box: CGRect, pad: CGFloat = 0.12, minSide: CGFloat = 0.18) -> CGRect {
        let cx = box.origin.x + box.width / 2
        let cy = box.origin.y + box.height / 2
        let w = max(box.width * (1 + 2 * pad), minSide)
        let h = max(box.height * (1 + 2 * pad), minSide)
        return CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
    }

    // MARK: - 预处理（open_clip ViT-L/14 口径）

    static func makeInput(image: CGImage, crop: CGRect?) -> MLMultiArray? {
        let src: CGImage
        if let crop {
            // 左下原点 → CoreGraphics 左上原点
            let x = crop.origin.x * CGFloat(image.width)
            let y = (1 - crop.origin.y - crop.height) * CGFloat(image.height)
            let r = CGRect(x: x, y: y,
                           width: crop.width * CGFloat(image.width),
                           height: crop.height * CGFloat(image.height))
            src = image.cropping(to: r) ?? image
        } else {
            src = image
        }

        guard src.bitsPerComponent == 8, src.bitsPerPixel == 32,
              let provider = src.dataProvider, let data = provider.data else { return nil }
        let w = src.width, h = src.height
        guard w >= 8, h >= 8 else { return nil }

        // open_clip Resize(224)：短边=224，长边等比；随后 CenterCrop(224)。
        let scale = 224.0 / Double(min(w, h))
        let dw = max(224, Int(round(Double(w) * scale)))
        let dh = max(224, Int(round(Double(h) * scale)))

        let alpha = CGImageAlphaInfo(rawValue: src.bitmapInfo.rawValue & CGBitmapInfo.alphaInfoMask.rawValue)
        let offsets: [Int]
        switch alpha {
        case .premultipliedFirst, .first: offsets = [1, 2, 3]  // ARGB
        default: offsets = [0, 1, 2]                            // RGBA（JPG 预览常见）
        }

        guard let array = try? MLMultiArray(shape: [1, 3, 224, 224], dataType: .float32) else { return nil }
        let out = array.dataPointer.assumingMemoryBound(to: Float.self)
        let mean: [Float] = [0.48145466, 0.4578275, 0.40821073]
        let std: [Float] = [0.26862954, 0.26130258, 0.27577711]
        let left = (dw - 224) / 2
        let top = (dh - 224) / 2
        let rowBytes = dw * 4

        (data as Data).withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var srcBuf = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: base),
                                       height: UInt(h), width: UInt(w),
                                       rowBytes: src.bytesPerRow)
            let scaled = UnsafeMutableRawPointer.allocate(byteCount: dh * rowBytes, alignment: 16)
            defer { scaled.deallocate() }
            var dstBuf = vImage_Buffer(data: scaled, height: UInt(dh), width: UInt(dw), rowBytes: rowBytes)
            guard vImageScale_ARGB8888(&srcBuf, &dstBuf, nil,
                                       vImage_Flags(kvImageHighQualityResampling)) == kvImageNoError else { return }
            for c in 0..<3 {
                let off = offsets[c]
                for y in 0..<224 {
                    var p = out + c * 224 * 224 + y * 224
                    var b = scaled + (top + y) * rowBytes + left * 4 + off
                    for _ in 0..<224 {
                        p.pointee = (Float(b.load(as: UInt8.self)) / 255 - mean[c]) / std[c]
                        p += 1
                        b += 4
                    }
                }
            }
        }
        return array
    }
}
