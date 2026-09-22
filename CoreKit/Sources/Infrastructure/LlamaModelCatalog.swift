import Foundation

/// T2 本机 LLM 多模型目录（2026-09-21；业主裁决「共存」）：
/// catalog 驱动的 **id 级模型寻址**——`Resources/LLMModels/catalog.json`
/// 多条目为唯一事实源（CI `materialize-llama-model.py` 按逐条 bytes+sha256
/// 取模落位，模型文件不入库、不入仓）。默认模型保持 qwen2.5-0.5b
/// （legacy 单模型 API 原样保留，行为不变）。
///
/// 医疗小模型（minimind-medical 训练产物）以**追加条目**共存：
/// 条目缺失或文件未就绪时 `preferredMedicalModelURL()` 返回 nil，引擎装配点
/// 回落默认模型——**绝不因新模型缺席而失能**，也绝不假装可用。
extension LlamaModelManager {

    /// 医疗小模型 id（训练侧 `integrate_to_vitaliber.py` 追加条目同名）。
    public static let medicalModelID = "medical-llm-64m-q4-k-m"

    /// catalog 条目（bundle 内 catalog.json 单条）。
    public struct CatalogEntry: Sendable, Equatable {
        public var id: String
        public var fileName: String
        /// 钉版字节数（0 = 未钉版，就绪判定退化为仅可读）
        public var bytes: Int64
        /// 是否随包（CI materialize 落位进 bundle）
        public var bundled: Bool

        public init(id: String, fileName: String, bytes: Int64, bundled: Bool = true) {
            self.id = id
            self.fileName = fileName
            self.bytes = bytes
            self.bundled = bundled
        }
    }

    /// catalog 解析（纯函数，单测直测）：字段缺失/类型不符的条目**跳过**——
    /// 残缺条目绝不参与就绪判定（与 2026-09-19 截断包体审查修复同纪律）。
    static func parseCatalog(_ data: Data) -> [CatalogEntry] {
        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: data)
        } catch {
            return []
        }
        guard let dictionary = root as? [String: Any],
              let models = dictionary["models"] as? [[String: Any]] else { return [] }
        return models.compactMap { model in
            guard let id = model["id"] as? String,
                  let fileName = model["fileName"] as? String else { return nil }
            let bytes = (model["bytes"] as? NSNumber)?.int64Value ?? 0
            let bundled = (model["bundled"] as? Bool) ?? true
            return CatalogEntry(id: id, fileName: fileName, bytes: bytes, bundled: bundled)
        }
    }

    /// bundle 内 catalog 全量条目（缺失/损坏 → 空数组：就绪判定随之全假）。
    public static func catalogEntries() -> [CatalogEntry] {
        guard let url = Bundle.main.url(forResource: "catalog", withExtension: "json",
                                        subdirectory: bundleSubdirectory) else { return [] }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return []
        }
        return parseCatalog(data)
    }

    public static func entry(id: String) -> CatalogEntry? {
        catalogEntries().first { $0.id == id }
    }

    /// 按 id 取模型路径（随包资源唯一来源）。
    public static func modelURL(id: String) -> URL? {
        guard let entry = entry(id: id) else { return nil }
        return Bundle.main.url(forResource: entry.fileName, withExtension: nil,
                               subdirectory: bundleSubdirectory)
    }

    /// 按 id 就绪判定：可读 + 字节与 catalog 钉版一致（字节 0 = 未钉版 → 仅可读）。
    public static func isModelReady(id: String) -> Bool {
        guard let entry = entry(id: id) else { return false }
        guard let url = modelURL(id: id),
              FileManager.default.isReadableFile(atPath: url.path) else { return false }
        guard entry.bytes > 0 else { return true }
        return fileSize(at: url) == entry.bytes
    }

    public static func modelSize(id: String) -> Int64 {
        guard let url = modelURL(id: id) else { return 0 }
        return fileSize(at: url)
    }

    /// 共存裁决的引擎装配接线点：医疗模型「条目在 catalog 且文件就绪」时
    /// 返回其 URL，否则 nil——调用方 nil 即回落默认模型（行为不因缺席而变）。
    public static func preferredMedicalModelURL() -> URL? {
        guard isModelReady(id: medicalModelID) else { return nil }
        return modelURL(id: medicalModelID)
    }

    private static func fileSize(at url: URL) -> Int64 {
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            return (attrs[.size] as? Int64) ?? 0
        } catch {
            return 0
        }
    }
}
