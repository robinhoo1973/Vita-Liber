import Foundation
import CryptoKit
import Domain
#if os(iOS) || os(macOS)
import SherpaOnnxC // 缺少真实C模块必须编译失败，不能被canImport分支静默隐藏。
#endif

/// 构建机供应模型，App只验证Bundle内文件。绝不通过运行时联网修复缺件。
public struct ASRModelAssets: Sendable {
    struct Manifest: Decodable { let formatVersion: Int; let models: [Model]; let shared: [File]; let sourceDigest: String? }
    struct Model: Decodable { let id: String; let license: String; let revision: String; let files: [File]; let archive: Archive? }
    struct Archive: Decodable { let parts: [Part] }
    struct Part: Decodable { let role: String; let path: String }
    struct File: Decodable { let role: String; let path: String; let bytes: Int64; let sha256: String }
    public struct Validated: Sendable {
        let paths: [String: String]
        func path(_ role: String) throws -> String {
            guard let path = paths[role] else { throw TranscriptionError.engineUnavailable }
            return path
        }
    }
    private let root: URL?
    public init(root: URL? = Bundle.main.url(forResource: "ASRModels", withExtension: nil)) { self.root = root }

    /// 进程级存在性缓存：应用包内容不可变，缺件判定结果恒定。旧实现每次
    /// 调用都读+解码 manifest（含 sourceDigest 校验）并逐文件 stat——
    /// capability 计算属性在每次按压/实验室刷新被多次读取（auto 档还
    /// 逐模型遍历），同一磁盘结论重复计算数十次。缓存按 root+choice 键控。
    private static let presenceCache = PresenceCache()
    private final class PresenceCache: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: Bool] = [:]
        func value(key: String, compute: () -> Bool) -> Bool {
            lock.lock(); defer { lock.unlock() }
            if let cached = values[key] { return cached }
            let computed = compute()
            values[key] = computed
            return computed
        }
    }

    public func isPresent(_ choice: VoiceEngineChoice) -> Bool {
        presenceCache.value(key: "\(root?.path ?? "nil")|\(choice.rawValue)") {
            do { _ = try files(choice, hash: false); return true }
            catch { return false }
        }
    }

    /// 清单解码缓存（与 isPresent 的存在性缓存同法；清单为随包不可变内容）。
    private static let manifestCache = ManifestCache()
    private final class ManifestCache: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: Manifest?] = [:]
        func value(key: String, compute: () -> Manifest?) -> Manifest? {
            lock.lock(); defer { lock.unlock() }
            if let cached = values[key] { return cached }
            let computed = compute()
            values[key] = computed
            return computed
        }
    }

    public func byteCount(_ choice: VoiceEngineChoice) -> Int64? {
        guard let root else { return nil }
        // 审查修复：清单不可变，逐调用读盘解码（设置页 ForEach 每次渲染
        // 触发）浪费主线程 IO——与 isPresent 同法按 root 缓存解码结果。
        let manifest = manifestCache.value(key: root.path) {
            try? readManifest(root)   // try?-ok: 清单解码失败=无体积信息（纯展示列），不阻断验证链
        }
        guard let manifest else { return nil }
        return manifest.models.first { $0.id == choice.rawValue }?.files.reduce(Int64(0)) { $0 + $1.bytes }
    }

    /// 仅在后台推理队列加载前调用；流式hash，不能将几百MB的Data放在主线程。
    public func validate(_ choice: VoiceEngineChoice) throws -> Validated { try files(choice, hash: true) }

    private func files(_ choice: VoiceEngineChoice, hash: Bool) throws -> Validated {
        guard let root, let descriptor = ASRModelCatalog.model(for: choice) else { throw TranscriptionError.engineUnavailable }
        let manifest = try readManifest(root)
        guard manifest.formatVersion == 1, let model = manifest.models.first(where: { $0.id == choice.rawValue }),
              model.license == descriptor.license, !model.files.isEmpty else { throw TranscriptionError.engineUnavailable }
        let original = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
        guard let expected = original.models.first(where: { $0.id == choice.rawValue }), expected.revision == model.revision else { throw TranscriptionError.engineUnavailable }
        let inventory = expected.archive?.parts.map { $0.role + ":" + $0.path } ?? expected.files.map { $0.role + ":" + $0.path }
        guard Set(model.files.map { $0.role + ":" + $0.path }) == Set(inventory), model.files.count == inventory.count else {
            throw TranscriptionError.engineUnavailable
        }
        let selected = model.files + (choice == .zipformer ? [] : manifest.shared)
        var paths: [String: String] = [:]
        for file in selected {
            let url = root.appendingPathComponent(file.path).standardizedFileURL
            guard !file.path.hasPrefix("/"), !file.path.split(separator: "/").contains(".."),
                  url.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/"),
                  paths[file.role] == nil, file.bytes > 0,
                  file.sha256.count == 64, file.sha256.allSatisfy({ $0.isHexDigit }) else { throw TranscriptionError.engineUnavailable }
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  (attributes[.size] as? NSNumber)?.int64Value == file.bytes else { throw TranscriptionError.engineUnavailable }
            if hash {
                let handle = try FileHandle(forReadingFrom: url)
                defer { do { try handle.close() } catch { /* 只读描述符关闭失败不覆盖hash结果 */ } }
                var digest = CryptoKit.SHA256()
                while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty { digest.update(data: chunk) }
                let actual = digest.finalize().map { String(format: "%02x", $0) }.joined()
                guard actual == file.sha256 else { throw TranscriptionError.engineUnavailable }
            }
            paths[file.role] = url.path
        }
        return Validated(paths: paths)
    }

    private func readManifest(_ root: URL) throws -> Manifest {
        let resolved = root.appendingPathComponent("resolved-manifest.json")
        let path = FileManager.default.fileExists(atPath: resolved.path) ? resolved : root.appendingPathComponent("manifest.json")
        let result = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: path))
        if path == resolved {
            let source = try Data(contentsOf: root.appendingPathComponent("manifest.json"))
            let hash = CryptoKit.SHA256.hash(data: source).map { String(format: "%02x", $0) }.joined()
            guard result.sourceDigest == hash else { throw TranscriptionError.engineUnavailable }
        }
        return result
    }
}
