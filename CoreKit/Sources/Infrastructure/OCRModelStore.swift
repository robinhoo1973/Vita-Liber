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

    private static func sha256Hex(_ data: Data) -> String {
        #if canImport(CryptoKit)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #else
        return ""
        #endif
    }
}
