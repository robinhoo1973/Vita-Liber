import Foundation
import Domain
import Protocols

#if canImport(CoreML)
import CoreML
#endif
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Core ML 信息元匹配（2026-11-06 业主：提取信息元用 Core ML 执行）。
///
/// 资产契约（`Resources/CoreMLModels/catalog.json`）：
/// - `modelFile`：已编译的 `.mlmodelc`（行级字段分类器）；
/// - `featureVersion`/`featureDimension`：`char-ngram-fnv1a-v1` 哈希向量契约
///   （缺省为旧字符串输入）；
/// - `inputName`：模型输入（向量或字符串）；
/// - `labelOutputName`：分类标签输出（字段键）；
/// - `probabilityOutputName`：`[String: Double]` 概率字典；
/// - `keys`：允许的字段键白名单（模型输出不在白名单 → 丢弃，fail-closed）；
/// - `minimumConfidence`：低于阈值的候选丢弃；
/// - `modelID/sha256/bytes/hashFile`：身份与构建期完整性清单。
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
        // 2026-11-07 正式模型契约（tech-spec V3.80）：身份、来源、许可、体积与完整性。
        // 旧目录缺省这些键仍可加载（bundled 由代码签名兜底）；下载模型必须带 sha256。
        public var modelID: String?
        public var license: String?
        public var sourceURL: String?
        public var trainingRunID: String?
        public var cardKinds: [String]?
        /// 模型输入拼接模板，如 `{kind}\t{line}`；缺省只喂行文本。
        public var inputTemplate: String?
        /// 特征契约（`char-ngram-fnv1a-v1`）；缺省为字符串输入（旧 Create ML 契约）。
        public var featureVersion: String?
        /// 哈希向量维度（featureVersion 存在时必填）。
        public var featureDimension: Int?
        /// 完整性清单：`modelFile` 内被哈希文件的相对路径（目录形态的 .mlmodelc）。
        public var hashFile: String?
        public var sha256: String?
        public var bytes: Int?
    }

    public nonisolated let modelID: String
    private let catalog: Catalog?
    private let modelURL: URL?

    #if canImport(CoreML)
    private var model: MLModel?
    private var loadAttempted = false
    #endif

    public init(bundle: Bundle = .main) {
        self.init(directory: bundle.url(forResource: "CoreMLModels", withExtension: nil))
    }

    /// 指定模型目录（随包或端侧安装目录）；catalog/模型缺失 → 不可用。
    public init(directory: URL?) {
        let catalogURL = directory?.appendingPathComponent("catalog.json")
        let data = catalogURL.flatMap { try? Data(contentsOf: $0) }   // try?-ok: 缺件按不可用降级
        let catalog = data.flatMap { try? JSONDecoder().decode(Catalog.self, from: $0) }   // try?-ok: 目录损坏降级
        // 未知格式版本 fail-closed：未来目录可能改变特征契约，旧客户端不得猜测。
        self.catalog = catalog?.formatVersion == 1 ? catalog : nil
        if let catalog, let directory {
            self.modelURL = directory.appendingPathComponent(catalog.modelFile)
            self.modelID = catalog.modelID ?? "\(catalog.modelFile)@\(catalog.version)"
        } else {
            self.modelURL = nil
            self.modelID = "coreml-unavailable"
        }
    }

    /// 工厂前置判定：catalog + 模型文件存在、且声明的完整性校验通过才注册该轨（不加载模型）。
    public nonisolated static func hasBundledModel(bundle: Bundle = .main) -> Bool {
        guard let directory = bundle.url(forResource: "CoreMLModels", withExtension: nil),
              let data = try? Data(contentsOf: directory.appendingPathComponent("catalog.json")),   // try?-ok: 缺件=未装配
              let catalog = try? JSONDecoder().decode(Catalog.self, from: data)   // try?-ok: 目录损坏=未装配
        else { return false }
        guard catalog.formatVersion == 1 else { return false }
        let modelURL = directory.appendingPathComponent(catalog.modelFile)
        guard FileManager.default.fileExists(atPath: modelURL.path) else { return false }
        return verifiesIntegrity(modelURL: modelURL, catalog: catalog)
    }

    /// 目录声明的完整性：`sha256` 存在即校验 `hashFile`（缺省 `weights.bin`）的
    /// 字节数与摘要；未声明则视为随包资产，由代码签名兜底。
    static func verifiesIntegrity(modelURL: URL, catalog: Catalog) -> Bool {
        guard let expected = catalog.sha256 else { return true }
        guard expected.count == 64, expected.allSatisfy({ $0.isHexDigit }) else { return false }
        let file = catalog.hashFile ?? "weights.bin"
        // `.mlmodel` 单文件：hashFile 为空串 → 直接哈希模型文件本身；
        // `.mlmodelc` 目录：哈希构建期写入的相对路径。
        let fileURL = file.isEmpty ? modelURL : modelURL.appendingPathComponent(file)
        guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else { return false }   // try?-ok: 哈希失败=不可用
        if let bytes = catalog.bytes, data.count != bytes { return false }
        #if canImport(CryptoKit)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return digest == expected.lowercased()
        #else
        return true   // Linux 型检无 CryptoKit；CoreML 本身只在 Apple 加载
        #endif
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
            let text = Self.inputText(line: line, kind: documentTypeKey,
                                      template: catalog.inputTemplate)
            let feature: MLFeatureValue
            if catalog.featureVersion == CharNGramVectorizer.version,
               let dimension = catalog.featureDimension, dimension > 0 {
                let vector = CharNGramVectorizer.vector(text: text, kind: documentTypeKey,
                                                        dimension: dimension)
                let array = try MLMultiArray(shape: [NSNumber(value: dimension)], dataType: .double)
                for index in 0..<dimension { array[index] = NSNumber(value: vector[index]) }
                feature = MLFeatureValue(multiArray: array)
            } else {
                feature = MLFeatureValue(string: text)
            }
            let input = try MLDictionaryFeatureProvider(dictionary: [catalog.inputName: feature])
            let output = try await model.prediction(from: input)
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

    /// 模型输入拼接（训练/服务同一模板）：`{kind}` = 卡类键，`{line}` = OCR 行。
    /// 模板为空 → 原行文本。训练脚本必须使用同一模板生成语料。
    static func inputText(line: String, kind: String?, template: String?) -> String {
        guard let template, !template.isEmpty else { return line }
        return template
            .replacingOccurrences(of: "{kind}", with: kind ?? "")
            .replacingOccurrences(of: "{line}", with: line)
    }

    #if canImport(CoreML)
    private func loadModel() -> MLModel? {
        if loadAttempted { return model }
        loadAttempted = true
        guard let catalog, let modelURL else { return nil }
        guard Self.verifiesIntegrity(modelURL: modelURL, catalog: catalog) else { return nil }
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
