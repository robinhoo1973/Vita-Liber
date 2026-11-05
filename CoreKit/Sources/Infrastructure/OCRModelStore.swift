import Foundation
import Domain

#if canImport(CryptoKit)
import CryptoKit
#endif

/// 随包 PP-OCRv6 识别模型加载/校验（2026-11-03 调参批）。
///
/// 只加载 `Resources/OCRModels` 的 rec 模型与字典；目录/名称/sha256/字节数
/// 全部来自 catalog.json，任何一项不符即返回 nil，调用方回退 Vision。
/// 不做网络下载、不写临时文件。模型缺失是正常降级，不是 OCR 失败。
public actor OCRModelStore {
    public struct Catalog: Codable, Sendable {
        public struct Asset: Codable, Sendable {
            public var file: String
            public var bytes: Int
            public var sha256: String
            public var dictFile: String
            public var dictBytes: Int
            public var dictSha256: String
            public var dictCount: Int
            public var classes: Int
            public var blankIndex: Int
            public var height: Int
            public var maxWidth: Int
            public var inputName: String
            public var outputName: String
        }
        public var formatVersion: Int
        public var family: String
        public var version: String
        public var license: String
        public var assets: [String: Asset]
        /// det（Paddle-primary）为顶层键，与 `assets.rec` 分离；缺省 = 不支持检测。
        public var det: DetectorAsset?
        /// 第三识别源（CnOCR）：复用 Paddle det 的行框，独立 rec 投票；缺省 = 未随包。
        public var third: ThirdAsset?
    }

    /// CnOCR 行识别资产。字典按 `label_cn.txt` 顺序，blank 恒在末尾
    ///（`blankIndex == dictCount`，classes = dictCount + 1）。
    public struct ThirdAsset: Codable, Sendable {
        public var file: String
        public var bytes: Int
        public var sha256: String
        public var version: String
        public var dictFile: String
        public var dictBytes: Int
        public var dictSha256: String
        public var dictCount: Int
        public var classes: Int
        public var blankIndex: Int
        public var height: Int
        public var maxWidth: Int
        public var inputName: String
        public var lengthInputName: String
        public var outputName: String
    }

    public struct Third: Sendable {
        public var modelData: Data
        /// 完整词表：`dict` + 末尾 blank 占位（`CTCDecoder` 要求 count == classes）。
        public var vocabulary: [String]
        public var asset: ThirdAsset
        public var modelSHA256: String
        public var displayName: String
    }

    /// PP-OCRv6 det 资产（无字典；检测后处理参数随 catalog 冻结）。
    public struct DetectorAsset: Codable, Sendable {
        public var file: String
        public var bytes: Int
        public var sha256: String
        public var inputName: String
        public var outputName: String
        public var maxSide: Int
        public var thresh: Double
        public var boxThresh: Double
        public var unclipRatio: Double
        public var maxCandidates: Int
        public var mean: [Double]
        public var std: [Double]
        public var channelOrder: String
    }

    public struct Detector: Sendable {
        public var modelData: Data
        public var asset: DetectorAsset
        public var modelSHA256: String
        public var displayName: String
    }

    public struct Loaded: Sendable {
        public var modelData: Data
        public var vocabulary: [String]
        public var catalog: Catalog
        public var asset: Catalog.Asset
        public var modelSHA256: String
        public var displayName: String
    }

    public static let shared = OCRModelStore()

    private var cached: Loaded?
    private var attempted = false
    private var cachedDetector: Detector?
    private var detectorAttempted = false
    private var cachedThird: Third?
    private var thirdAttempted = false

    public init() {}

    public func load() -> Loaded? {
        if attempted { return cached }
        attempted = true
        guard let directory = Bundle.main.url(forResource: "OCRModels", withExtension: nil),
              let catalogURL = Bundle.main.url(forResource: "catalog", withExtension: "json",
                                               subdirectory: "OCRModels"),
              let catalogData = try? Data(contentsOf: catalogURL),   // try?-ok: 缺件按模型不可用降级
              let catalog = try? JSONDecoder().decode(Catalog.self, from: catalogData),   // try?-ok: 目录损坏按不可用降级
              let asset = catalog.assets["rec"],
              let modelData = try? Data(contentsOf: directory.appendingPathComponent(asset.file)),   // try?-ok: 缺件降级
              let dictData = try? Data(contentsOf: directory.appendingPathComponent(asset.dictFile)),   // try?-ok: 缺件降级
              let dict = try? JSONDecoder().decode([String].self, from: dictData),   // try?-ok: 字典损坏降级
              modelData.count == asset.bytes, dictData.count == asset.dictBytes,
              Self.sha256Hex(modelData) == asset.sha256.lowercased(),
              Self.sha256Hex(dictData) == asset.dictSha256.lowercased(),
              dict.count == asset.dictCount else {
            cached = nil
            return nil
        }
        var vocabulary = [""]
        vocabulary.append(contentsOf: dict)
        vocabulary.append(" ")
        guard vocabulary.count == asset.classes else {
            cached = nil
            return nil
        }
        let loaded = Loaded(modelData: modelData, vocabulary: vocabulary, catalog: catalog,
                            asset: asset, modelSHA256: asset.sha256.lowercased(),
                            displayName: "\(catalog.family)@\(catalog.version)")
        cached = loaded
        return loaded
    }

    /// 加载 det 模型（Paddle-primary）。与 rec 同样做字节数/sha256 校验；
    /// det 无字典，任一项缺失/不符返回 nil（调用方回退 Vision）。
    public func loadDetector() -> Detector? {
        if detectorAttempted { return cachedDetector }
        detectorAttempted = true
        guard let directory = Bundle.main.url(forResource: "OCRModels", withExtension: nil),
              let catalogURL = Bundle.main.url(forResource: "catalog", withExtension: "json",
                                               subdirectory: "OCRModels"),
              let catalogData = try? Data(contentsOf: catalogURL),   // try?-ok: 缺件按模型不可用降级
              let catalog = try? JSONDecoder().decode(Catalog.self, from: catalogData),   // try?-ok: 目录损坏按不可用降级
              let asset = catalog.det,
              !asset.inputName.isEmpty, !asset.outputName.isEmpty,
              asset.maxSide > 0, asset.maxCandidates > 0,
              asset.mean.count == 3, asset.std.count == 3,
              let modelData = try? Data(contentsOf: directory.appendingPathComponent(asset.file)),   // try?-ok: 缺件降级
              modelData.count == asset.bytes,
              Self.sha256Hex(modelData) == asset.sha256.lowercased() else {
            cachedDetector = nil
            return nil
        }
        let detector = Detector(modelData: modelData, asset: asset,
                                modelSHA256: asset.sha256.lowercased(),
                                displayName: "\(catalog.family)@\(catalog.version)-det")
        cachedDetector = detector
        return detector
    }

    /// 加载第三识别源（CnOCR doc-densenet_lite_136-gru）。
    ///
    /// 与 rec/det 同样 fail-closed：字节数/sha256/字典计数/blank 位置任一不符即 nil，
    /// 调用方保持「Paddle + Vision」两源，绝不因第三源缺件降低现有识别能力。
    public func loadThird() -> Third? {
        if thirdAttempted { return cachedThird }
        thirdAttempted = true
        guard let directory = Bundle.main.url(forResource: "OCRModels", withExtension: nil),
              let catalogURL = Bundle.main.url(forResource: "catalog", withExtension: "json",
                                               subdirectory: "OCRModels"),
              let catalogData = try? Data(contentsOf: catalogURL),   // try?-ok: 缺件按第三源不可用降级
              let catalog = try? JSONDecoder().decode(Catalog.self, from: catalogData),   // try?-ok: 目录损坏降级
              let asset = catalog.third,
              asset.classes == asset.dictCount + 1,
              asset.blankIndex == asset.dictCount,
              asset.height > 0, asset.maxWidth > 0,
              !asset.inputName.isEmpty, !asset.lengthInputName.isEmpty, !asset.outputName.isEmpty,
              let modelData = try? Data(contentsOf: directory.appendingPathComponent(asset.file)),   // try?-ok: 缺件降级
              let dictData = try? Data(contentsOf: directory.appendingPathComponent(asset.dictFile)),   // try?-ok: 缺件降级
              let dict = try? JSONDecoder().decode([String].self, from: dictData),   // try?-ok: 字典损坏降级
              modelData.count == asset.bytes, dictData.count == asset.dictBytes,
              Self.sha256Hex(modelData) == asset.sha256.lowercased(),
              Self.sha256Hex(dictData) == asset.dictSha256.lowercased(),
              dict.count == asset.dictCount else {
            cachedThird = nil
            return nil
        }
        // CTCDecoder 用同一索引空间：词表第 blankIndex 项必须是空占位。
        let third = Third(modelData: modelData, vocabulary: dict + [""], asset: asset,
                          modelSHA256: asset.sha256.lowercased(),
                          displayName: "CnOCR-doc-densenet_lite_136-gru@\(asset.version)")
        cachedThird = third
        return third
    }

    private static func sha256Hex(_ data: Data) -> String {
        #if canImport(CryptoKit)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #else
        return ""
        #endif
    }
}
