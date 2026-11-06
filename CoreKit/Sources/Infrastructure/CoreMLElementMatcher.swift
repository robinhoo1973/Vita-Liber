import Foundation
import Domain
import Protocols

#if canImport(CoreML)
import CoreML
#endif

/// Core ML 信息元匹配（2026-11-06 业主：提取信息元用 Core ML 执行）。
///
/// 资产契约（`Resources/CoreMLModels/catalog.json`）：
/// - `modelFile`：已编译的 `.mlmodelc`（Create ML 文本分类器）；
/// - `inputName`：字符串输入（一行文本）；
/// - `labelOutputName`：分类标签输出（字段键）；
/// - `probabilityOutputName`：`[String: Double]` 概率字典；
/// - `keys`：允许的字段键白名单（模型输出不在白名单 → 丢弃，fail-closed）；
/// - `minimumConfidence`：低于阈值的候选丢弃。
///
/// 缺 catalog/模型/任一输出 → `isAvailable == false`，注册表回落规则轨；
/// 绝不因为 Core ML 缺失而阻断 OCR 导入。
public actor CoreMLElementMatcher: InformationElementMatching {
    public struct Catalog: Codable, Sendable {
        public var formatVersion: Int
        public var modelFile: String
        public var version: String
        public var inputName: String
        public var labelOutputName: String
        public var probabilityOutputName: String
        public var keys: [String]
        public var minimumConfidence: Double
    }

    public nonisolated let modelID: String
    private let catalog: Catalog?
    private let modelURL: URL?

    #if canImport(CoreML)
    private var model: MLModel?
    private var loadAttempted = false
    #endif

    public init(bundle: Bundle = .main) {
        let directory = bundle.url(forResource: "CoreMLModels", withExtension: nil)
        let catalogURL = directory?.appendingPathComponent("catalog.json")
        let data = catalogURL.flatMap { try? Data(contentsOf: $0) }   // try?-ok: 缺件按不可用降级
        let catalog = data.flatMap { try? JSONDecoder().decode(Catalog.self, from: $0) }   // try?-ok: 目录损坏降级
        self.catalog = catalog
        if let catalog, let directory {
            self.modelURL = directory.appendingPathComponent(catalog.modelFile)
            self.modelID = "\(catalog.modelFile)@\(catalog.version)"
        } else {
            self.modelURL = nil
            self.modelID = "coreml-unavailable"
        }
    }

    /// 工厂前置判定：catalog + 模型文件都存在才注册该轨（不加载模型）。
    public nonisolated static func hasBundledModel(bundle: Bundle = .main) -> Bool {
        guard let directory = bundle.url(forResource: "CoreMLModels", withExtension: nil),
              let data = try? Data(contentsOf: directory.appendingPathComponent("catalog.json")),   // try?-ok: 缺件=未装配
              let catalog = try? JSONDecoder().decode(Catalog.self, from: data)   // try?-ok: 目录损坏=未装配
        else { return false }
        return FileManager.default.fileExists(atPath: directory.appendingPathComponent(catalog.modelFile).path)
    }

    public func isAvailable() async -> Bool {
        guard catalog != nil, modelURL != nil else { return false }
        #if canImport(CoreML)
        return loadModel() != nil
        #else
        return false
        #endif
    }

    public func match(lines: [String], documentTypeKey: String?) async throws -> [InformationElementMatch] {
        guard let catalog else { throw ExtractionEngineError.unavailable }
        #if canImport(CoreML)
        guard let model = loadModel() else { throw ExtractionEngineError.unavailable }
        let allowed = Set(catalog.keys)
        var out: [InformationElementMatch] = []
        for (index, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let input = try MLDictionaryFeatureProvider(dictionary: [catalog.inputName: line])
            let output = try model.prediction(from: input)
            guard let label = output.featureValue(for: catalog.labelOutputName)?.stringValue,
                  allowed.contains(label),
                  let probabilityMap = output.featureValue(for: catalog.probabilityOutputName)?.dictionaryValue
            else { continue }
            var probability = 0.0
            for (key, value) in probabilityMap {
                if let key = key as? String, key == label {
                    probability = value.doubleValue
                }
            }
            guard probability >= catalog.minimumConfidence else { continue }
            out.append(InformationElementMatch(key: label, value: line,
                                               confidence: probability,
                                               sourceLineIndex: index))
        }
        return out
        #else
        throw ExtractionEngineError.unavailable
        #endif
    }

    #if canImport(CoreML)
    private func loadModel() -> MLModel? {
        if loadAttempted { return model }
        loadAttempted = true
        guard let catalog, let modelURL else { return nil }
        guard let loaded = try? MLModel(contentsOf: modelURL) else { return nil }   // try?-ok: 加载失败=本轨不可用，规则轨兜底
        // 契约自检（catalog 特征名必须真实存在于模型描述）：拼错的 input/label/
        // probability 若放行，会在首次预测时变成运行期 engineError，或在
        // 错输出名下静默零产出；此处按「任一输出缺失 → 不可用」降级（文件头契约）。
        let description = loaded.modelDescription
        guard description.inputDescriptionsByName[catalog.inputName] != nil,
              description.outputDescriptionsByName[catalog.labelOutputName] != nil,
              description.outputDescriptionsByName[catalog.probabilityOutputName] != nil
        else { return nil }
        model = loaded
        return loaded
    }
    #endif
}
