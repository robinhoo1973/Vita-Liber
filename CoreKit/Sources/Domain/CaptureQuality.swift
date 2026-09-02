import Foundation

/// §5.34 / M-QUALITY：拍摄质量评估与重复检测（纯 Domain，零框架，Linux 可跑）。
///
/// 设计原则：
/// - 确定性：同输入同输出（便于金样回归）。
/// - 零自动删除：重复仅提示，不静默去重（BR-002 延伸）。
/// - 可解释：给出可被 UI 呈现的依据（相似度分值、质量分项）。
///
/// 评审修正（iOS 编译门禁暴露，5WHY）：本文件曾把「图像解码」直接内嵌
/// `#if os(iOS)||os(macOS)` 段并裸用 CoreGraphics/ImageIO 符号——Domain 的
/// import 白名单（L0 [5]：⊆ {Foundation}）使文件无法 import 平台框架，Linux
/// 因 #if 永远编译不到 Apple 段，直到 macOS 编译门禁（build-testflight）首次
/// 真实编译才暴露。解码是平台能力（架构规则 3：系统服务协议注入、实现落
/// Infrastructure）：现由 `GrayscaleDecoding` 端口注入（同 `PinLockPersisting`
/// 先例：端口定义在 Domain，实现在 Infrastructure），本文件只留纯计算。

/// 灰度位图（解码产物，纯数据）。
public struct GrayscaleImage: Sendable, Equatable {
    public let width: Int
    public let height: Int
    /// 逐行灰度 0..255
    public let buffer: [UInt8]
    public init(width: Int, height: Int, buffer: [UInt8]) {
        self.width = width; self.height = height; self.buffer = buffer
    }
}

/// 图像解码端口（系统服务，实现在 Infrastructure `GrayscaleImageDecoder`）。
public protocol GrayscaleDecoding: Sendable {
    /// 解码为灰度位图并按 maxDimension 降采样（保持宽高比、短边对齐）。
    /// 解码失败必须抛错，绝不返回空/占位产物（FR6.6 可见错误）。
    func decode(_ data: Data, maxDimension: Int) throws -> GrayscaleImage
}

public enum ImageDecodeError: Error, Sendable, Equatable {
    case corruptData
}

/// 单张图片的质量评估结果。
public struct CaptureQuality: Sendable, Equatable {
    /// 综合质量分（0..1，越高越清晰）。
    public var score: Double
    /// 维度分（用于 UI 解释）。
    public var sharpness: Double      // 清晰度（拉普拉斯方差归一化）
    public var brightness: Double     // 亮度适中度（0..1，0.5 最佳）
    public var occlusion: Double      // 遮挡比例（0..1，越小越好）
    /// 可解释标签（供 UI 直观展示）。
    public var tags: [String]

    public init(score: Double, sharpness: Double, brightness: Double, occlusion: Double, tags: [String]) {
        self.score = score; self.sharpness = sharpness; self.brightness = brightness
        self.occlusion = occlusion; self.tags = tags
    }

    /// 质量是否达标（阈值可由上层配置，默认 0.5）。
    public func meetsThreshold(_ threshold: Double = 0.5) -> Bool { score >= threshold }
}

/// 重复检测结果。
public struct DuplicateDetectionResult: Sendable, Equatable {
    /// 是否为重复（精确哈希命中或感知哈希高相似）。
    public var isDuplicate: Bool
    /// 精确哈希命中（SHA-256 完全一致）。
    public var exactHashMatch: Bool
    /// 感知哈希相似度（0..1，1 为完全相同）。
    public var perceptualSimilarity: Double
    /// 命中的现有记录 ID（若 exactHashMatch）。
    public var matchedRecordID: String?

    public init(isDuplicate: Bool, exactHashMatch: Bool, perceptualSimilarity: Double, matchedRecordID: String? = nil) {
        self.isDuplicate = isDuplicate; self.exactHashMatch = exactHashMatch
        self.perceptualSimilarity = perceptualSimilarity; self.matchedRecordID = matchedRecordID
    }
}

/// 拍摄质量评估器（纯函数，确定性；输入为解码后的灰度位图）。
///
/// 算法（启发式，领域特有）：
/// 1. 输入 256x256（或更小）灰度位图。
/// 2. sharpness = 拉普拉斯方差归一化（经验阈值）。
/// 3. brightness = 1 - |mean - 0.5| * 2（0.5 最佳）。
/// 4. occlusion = 暗区/亮区饱和像素比例（近似遮挡/过曝/欠曝）。
/// 5. score = 0.5*sharpness + 0.3*(1-brightnessDeviation) + 0.2*(1-occlusion)。
/// 6. tags 给出可解释依据（如 "模糊"、"过暗"、"疑似遮挡"）。
///
/// 解码由注入的 `GrayscaleDecoding` 完成（评审修正：解码曾内嵌本文件，
/// 见文件头注）。解码失败抛错，由调用方处理（FR6.6）。
public enum CaptureQualityAssessor {
    /// 评估一张灰度位图的质量。
    public static func assess(_ image: GrayscaleImage) -> CaptureQuality {
        let w = image.width
        let h = image.height
        let buf = image.buffer
        guard w >= 3, h >= 3, buf.count >= w * h else {
            // 过小图像无法做拉普拉斯邻域差分：返回最保守的「疑似不合格」，
            // 不崩溃、不产生 NaN（评审修正：原实现对 1xN/2x2 输入会越界/除零）。
            return CaptureQuality(score: 0, sharpness: 0, brightness: 0, occlusion: 1, tags: ["不可评估"])
        }

        // 1) Sharpness: 拉普拉斯二阶差分方差
        var lapSum: Double = 0
        var lapSqSum: Double = 0
        var count = 0
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let c = Double(buf[y * w + x])
                let lap = (Double(buf[(y - 1) * w + x]) + Double(buf[(y + 1) * w + x])
                         + Double(buf[y * w + x - 1]) + Double(buf[y * w + x + 1]) - 4 * c)
                lapSum += lap
                lapSqSum += lap * lap
                count += 1
            }
        }
        let meanLap = lapSum / Double(count)
        let varLap = lapSqSum / Double(count) - meanLap * meanLap
        let sharpness = min(1.0, varLap / 5000.0) // 经验归一化

        // 2) Brightness: 偏离 0.5 的程度
        let mean = buf.map { Double($0) }.reduce(0, +) / Double(buf.count) / 255.0
        let brightnessDeviation = abs(mean - 0.5) * 2.0 // 0..1
        let brightness = 1.0 - brightnessDeviation

        // 3) Occlusion: 饱和像素比例（<10 或 >245 视为饱和）
        let satCount = buf.filter { $0 < 10 || $0 > 245 }.count
        let occlusion = Double(satCount) / Double(buf.count)
        let occlusionScore = 1.0 - min(1.0, occlusion * 4.0) // 过曝/欠曝惩罚

        // 4) 综合分
        let score = 0.5 * sharpness + 0.3 * brightness + 0.2 * occlusionScore

        // 5) 可解释标签
        var tags: [String] = []
        if sharpness < 0.35 { tags.append("模糊") }
        if brightness < 0.6 { tags.append(mean < 0.3 ? "过暗" : "过亮") }
        if occlusion > 0.15 { tags.append("疑似遮挡/过曝") }
        if tags.isEmpty { tags.append("质量良好") }

        return CaptureQuality(score: score, sharpness: sharpness, brightness: brightness,
                              occlusion: occlusion, tags: tags)
    }
}

/// 重复检测服务（纯逻辑，确定性）。
///
/// 两级策略：
/// 1. 精确哈希（SHA-256）：完全一致 → `exactHashMatch=true`。
/// 2. 感知哈希：32x32 灰度 → 低频 8x8 均值二值化 → 64 位指纹。
///    汉明距离 ≤ 5 视为高相似（可配置阈值，默认 5/64 ≈ 7.8%）。
///
/// 零自动删除：仅返回 `isDuplicate` 与相似度，上层决定提示用户（BR-002）。
///
/// 解码经注入的 `GrayscaleDecoding`（评审修正：原实现内嵌 Apple-only 解码段，
/// 见文件头注——iOS 编译门禁暴露 Domain 内裸用 CoreGraphics 无法 import）。
public struct DuplicateDetectionService {
    private var exactHashes: Set<String> = []        // SHA-256 hex
    private var perceptualHashes: [String: UInt64] = [:] // recordID -> pHash

    /// 感知哈希阈值（汉明距离上限，默认 5/64）。
    public var perceptualThreshold: Int = 5

    public init() {}

    /// 注册一张已存在的图片（用于后续比对）。
    public mutating func register(recordID: String, imageData: Data,
                                  decoder: any GrayscaleDecoding) throws {
        let exact = SHA256.hash(data: imageData).hexString
        exactHashes.insert(exact)
        let image = try decoder.decode(imageData, maxDimension: 32)
        perceptualHashes[recordID] = Self.perceptualHash(from: image)
    }

    /// 检测新图片是否重复。
    public func detect(_ imageData: Data,
                       decoder: any GrayscaleDecoding) throws -> DuplicateDetectionResult {
        let exact = SHA256.hash(data: imageData).hexString
        if exactHashes.contains(exact) {
            return DuplicateDetectionResult(isDuplicate: true, exactHashMatch: true, perceptualSimilarity: 1.0)
        }
        let image = try decoder.decode(imageData, maxDimension: 32)
        let pHash = Self.perceptualHash(from: image)
        var bestDist = 64
        var bestID: String?
        for (id, ph) in perceptualHashes {
            let dist = (pHash ^ ph).nonzeroBitCount
            if dist < bestDist { bestDist = dist; bestID = id }
        }
        if bestDist <= perceptualThreshold {
            let sim = 1.0 - Double(bestDist) / 64.0
            return DuplicateDetectionResult(isDuplicate: true, exactHashMatch: false,
                                            perceptualSimilarity: sim, matchedRecordID: bestID)
        }
        return DuplicateDetectionResult(isDuplicate: false, exactHashMatch: false,
                                        perceptualSimilarity: 0.0)
    }

    /// 感知哈希（pHash，64 位）——纯函数：32x32 灰度 → 低频 8x8 均值二值化。
    ///
    /// 评审修正：原实现对「全局均值」误取 `buf.prefix(64)`（图像前两行）——
    /// 白边文档会让均值≈255、所有宏像素都低于均值 → pHash 恒 0，任意两张
    /// 白边文档互相误判重复。现按整幅 1024 像素求均值。
    public static func perceptualHash(from image: GrayscaleImage) -> UInt64 {
        guard image.width >= 8, image.height >= 8, image.buffer.count >= image.width * image.height else {
            return 0
        }
        let buf = image.buffer
        let w = image.width
        // 32x32 输入（decoder 已按 maxDimension 降采样）；防御任意尺寸：
        // 把 8x8 网格映射到实际尺寸。
        let cellW = Double(w) / 8.0
        let cellH = Double(image.height) / 8.0
        let globalMean = buf.reduce(0) { $0 + Int($1) } / buf.count
        var bits: UInt64 = 0
        var idx = 0
        for cy in 0..<8 {
            for cx in 0..<8 {
                var sum = 0
                var n = 0
                let x0 = Int(Double(cx) * cellW), x1 = min(Int(Double(cx + 1) * cellW), w)
                let y0 = Int(Double(cy) * cellH), y1 = min(Int(Double(cy + 1) * cellH), image.height)
                for y in y0..<y1 {
                    for x in x0..<x1 {
                        sum += Int(buf[y * w + x]); n += 1
                    }
                }
                if n > 0, sum / n > globalMean { bits |= (1 << idx) }
                idx += 1
            }
        }
        return bits
    }
}
