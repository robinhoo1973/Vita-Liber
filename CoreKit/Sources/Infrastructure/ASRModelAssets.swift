// 平台守卫镜像 Package.swift（ERR#8 纪律）：CryptoKit/SherpaOnnxC 仅 Apple 平台链接；
// Linux 为 CoreKit 本机测试宿主，本文件整体排除，勿用 canImport 静默隐藏缺失的真实 C 模块。
#if os(iOS) || os(macOS)
// linux-blind: CryptoKit 哈希（Apple 专属模块，Linux 不可用） —— Linux 型检编译空单元，改动须经 macOS CI 验证
import Foundation
import CryptoKit
import Domain
import SherpaOnnxC // 缺少真实C模块必须编译失败，不能被canImport分支静默隐藏。

/// 构建机供应模型，App只验证Bundle内文件。绝不通过运行时联网修复缺件。
public struct ASRModelAssets: Sendable {
    struct Manifest: Decodable { let formatVersion: Int; let models: [Model]; let shared: [File]; let sourceDigest: String? }
    struct Model: Decodable { let id: String; let license: String; let revision: String; let files: [File]; let archive: Archive? }
    struct Archive: Decodable { let parts: [Part]; let bytes: Int64? }
    struct Part: Decodable { let role: String; let path: String }
    struct File: Decodable { let role: String; let path: String; let bytes: Int64; let sha256: String }
    public struct Validated: Sendable {
        let paths: [String: String]
        /// 全部模型文件字节和（round5 Q3：`ModelMemoryBudget` 的体积输入——清单已逐文件校验字节，此处求和零 IO）。
        public let totalBytes: Int64
        func path(_ role: String) throws -> String {
            guard let path = paths[role] else { throw TranscriptionError.engineUnavailable }
            return path
        }
    }
    private let root: URL?
    private let packageSHA256: String?
    private let trust: ModelCatalogTrustStore
    public init(root: URL? = Bundle.main.url(forResource: "ASRModels", withExtension: nil),
                packageSHA256: String? = nil, trust: ModelCatalogTrustStore = .shared) {
        self.root = root; self.packageSHA256 = packageSHA256; self.trust = trust
    }
    /// 每次会话/池获取都执行；旧委托持有的资产不能绕过后来收到的撤销。
    func checkPackageAuthorization() throws {
        if let packageSHA256, trust.isRevoked(packageSHA256) { throw TranscriptionError.engineUnavailable }
    }
    /// 下载版使用不可变内容目录；根路径＋安装代次同时进入委托与 native runtime 缓存键。
    /// 2026-09-19 审查修复：代次曾为**进程全局**计数器——任一模型安装/检查更新
    /// 后所有档位的 identity 一起变，未变文件的模型也全部重载+重哈希（下载后
    /// 按压冻结主因之一）。改为按根路径分代：只推进被安装/失效的那棵目录。
    public var identity: String {
        let path = root?.standardizedFileURL.path ?? "missing"
        return "\(path)|\(Self.generation.value(for: path))"
    }
    private static let generation = Generation()
    private static let leases = Leases()
    final class Lease: @unchecked Sendable {
        private let path: String?
        init(root: URL?) {
            path = root?.standardizedFileURL.path
            if let path { ASRModelAssets.leases.retain(path) }
        }
        deinit { if let path { ASRModelAssets.leases.release(path) } }
    }
    private final class Leases: @unchecked Sendable {
        private let lock = NSLock()
        private var counts: [String: Int] = [:]
        func retain(_ path: String) { lock.lock(); counts[path, default: 0] += 1; lock.unlock() }
        func release(_ path: String) {
            lock.lock(); defer { lock.unlock() }
            let count = counts[path, default: 0] - 1
            if count <= 0 { counts[path] = nil } else { counts[path] = count }
        }
        func removeIfUnused(_ url: URL) throws {
            lock.lock(); defer { lock.unlock() }
            guard counts[url.standardizedFileURL.path, default: 0] == 0 else { return }
            try FileManager.default.removeItem(at: url)
        }
    }
    func acquireLease() -> Lease { Lease(root: root) }
    static func removeIfUnused(_ url: URL) throws { try leases.removeIfUnused(url) }
    private final class Generation: @unchecked Sendable {
        private let lock = NSLock()
        private var counters: [String: UInt64] = [:]
        func value(for root: String) -> UInt64 {
            lock.lock(); defer { lock.unlock() }
            return counters[root, default: 0]
        }
        /// 推进指定根（2026-09-19 审查修复：nil=推进全部的分支是全仓零调用的
        /// 死代码，且语义残缺——只推进**已有条目**的根，无条目的根（代次隐含 0）
        /// 根本不会被推——全量失效入口一旦被未来调用方使用即静默漏推。删除。）
        func advance(for root: String) {
            lock.lock(); counters[root, default: 0] &+= 1; lock.unlock()
        }
    }

    /// FR17.15（业主 2026-09-12 决定）：**资产双路径解析**——优先使用运行时下载并校验过的版本
    /// （`Application Support/ASRModels/<id>/<version>`，指针 `active.json`），否则回落随包
    /// `Bundle/ASRModels`。两条路径共用同一 `manifest` 校验逻辑，调用方无感。
    /// 下载目录必须通过存在性校验才选用：损坏/过期的下载树不得遮蔽完好的随包模型
    /// （存在性判定按 root+choice 进程级缓存，热路径只付一次解码+stat）。
    public static func resolve(for choice: VoiceEngineChoice) -> ASRModelAssets {
        if let assets = ASRModelDownloadService.activeAssets(for: choice) {
            if assets.isPresent(choice) { return assets }
        }
        return ASRModelAssets()
    }

    /// 进程级存在性缓存：应用包内容不可变，缺件判定结果恒定。旧实现每次
    /// 调用都读+解码 manifest（含 sourceDigest 校验）并逐文件 stat——
    /// capability 计算属性在每次按压/实验室刷新被多次读取（auto 档还
    /// 逐模型遍历），同一磁盘结论重复计算数十次。缓存按 root+choice 键控。
    private static let presenceCache = LockedCache<Bool>()
    /// 清单解码缓存（与 isPresent 的存在性缓存同法；清单为随包不可变内容）。
    private static let manifestCache = LockedCache<Manifest?>()

    /// 锁保护的进程级键值缓存（presence/manifest 共用同一形态——两个近复制
    /// 类收敛为一个泛型；Value = Manifest? 时下标层级与旧实现逐位同语义）。
    /// 2026-09-19 审查修复：value 改为 rethrows + **锁内计算**（computeIfAbsent
    /// 单一形态）——旧 peek+set 是拆开的 check-then-act：并发校验同一文件时
    /// 双方都漏缓存、GB 级文件重复流式哈希（备忘录要消除的正是这份重复工作）。
    private final class LockedCache<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: Value] = [:]
        func value(key: String, compute: () throws -> Value) rethrows -> Value {
            lock.lock(); defer { lock.unlock() }
            if let cached = values[key] { return cached }
            let computed = try compute()
            values[key] = computed
            return computed
        }
        func removeAll() {
            lock.lock(); values.removeAll(); lock.unlock()
        }
        /// 按路径前缀逐出（per-root 失效：只清该目录树下的键）。
        func removeAll(wherePrefix prefix: String) {
            lock.lock(); defer { lock.unlock() }
            values = values.filter { $0.key != prefix && !$0.key.hasPrefix(prefix + "/") }
        }
    }
    /// 2026-09-19 审查修复：逐文件 SHA-256 流式哈希的进程级备忘（键=文件路径）。
    /// 此前每次 warmUp/按压/池重载都全量重哈希（下载后按压冻结主因之二）——
    /// 目录内容在代次内不可变（安装替换目录并推进分代 → 本缓存在 invalidateCaches
    /// 按该根路径前缀逐出），哈希结论在代次内恒定，备忘不削弱防篡改链
    /// （文件变更必然伴随分代推进与逐出）。
    private static let validatedCache = LockedCache<String>()

    public func isPresent(_ choice: VoiceEngineChoice) -> Bool {
        if let packageSHA256, trust.isRevoked(packageSHA256) { return false }
        // CI 34652541174 修复：实例方法内不得无 Self. 限定引用静态成员。
        return Self.presenceCache.value(key: "\(root?.path ?? "nil")|\(choice.rawValue)") {
            do { _ = try files(choice, hash: false); return true }
            catch { return false }
        }
    }

    /// 安装/指针切换后失效进程级缓存（presence/manifest/validated）：同版本重装或指针切换后，
    /// 旧判定（如曾因缺件缓存 false）不得继续遮蔽新目录（安全审查 2026-09-12 发现）。
    /// 2026-09-19 审查修复二：validatedCache 改为**按根路径前缀**逐出——旧实现
    /// 全局 removeAll 把其他档位的哈希备忘一并抹掉（per-root 分代只保住了 identity，
    /// 未变文件的哈希结果仍被清空，安装 A 后按压 B 又全量重哈希 GB 级文件——
    /// 备忘要消除的冻结半复发）；presence/manifest 体量小、全局清无碍。
    public static func invalidateCaches(forRoot root: URL) {
        let path = root.standardizedFileURL.path
        presenceCache.removeAll()
        manifestCache.removeAll()
        validatedCache.removeAll(wherePrefix: path)
        generation.advance(for: path)
    }

    /// 2026-09-19 审查修复：只清缓存、不推分代——目录索引刷新（检查更新）用。
    /// 索引变化不影响已装文件的身份（撤销走 trust 每调用检查），此前 fetchIndex
    /// 走全量 invalidateCaches 会把所有档位 identity 一起推进 → 未变文件全重载。
    /// 2026-09-19 审查修复二：validatedCache 不再随索引刷新清空——索引刷新
    /// 不可能改写已装文件（写入面只有 install 的 moveItem + 暂存目录），
    /// 每次点「检查更新」后按压若全量重哈希，备忘录同样半失效。
    public static func clearCaches() {
        presenceCache.removeAll()
        manifestCache.removeAll()
    }

    public func byteCount(_ choice: VoiceEngineChoice) -> Int64? {
        guard let root else { return nil }
        // 审查修复：清单不可变，逐调用读盘解码（设置页 ForEach 每次渲染
        // 触发）浪费主线程 IO——与 isPresent 同法按 root 缓存解码结果。
        let manifest = Self.manifestCache.value(key: root.path) {
            try? readManifest(root)   // try?-ok: 清单解码失败=无体积信息（纯展示列），不阻断验证链
        }
        guard let manifest else { return nil }
        // CI 34652541174 修复：单链长表达式超出类型检查预算——拆子表达式。
        let model = manifest.models.first { $0.id == choice.rawValue }
        guard let model else { return nil }
        let sum = model.files.reduce(Int64(0)) { $0 + $1.bytes }
        if sum > 0 { return sum }
        // 清单以 archive 分卷形态发布（如 qwen3 的 files:[] + archive）时
        // 无逐文件字节——以 archive.bytes 呈现，避免设置页对随包模型
        // 显示「0 字节」的矛盾信息（owner round10 实测「模型显示不完整」）。
        guard let archiveBytes = model.archive?.bytes else { return nil }
        return archiveBytes
    }

    /// 仅在后台推理队列加载前调用；流式hash，不能将几百MB的Data放在主线程。
    public func validate(_ choice: VoiceEngineChoice) throws -> Validated { try files(choice, hash: true) }

    private func files(_ choice: VoiceEngineChoice, hash: Bool) throws -> Validated {
        try checkPackageAuthorization()
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
        var filePaths = Set<String>()
        var totalBytes: Int64 = 0
        for file in selected {
            let url = root.appendingPathComponent(file.path).standardizedFileURL
            // Model/VAD LICENSE 都可叫 notice；它们必须验字节/SHA，但不是唯一推理角色。
            let role = file.role == "notice" ? "metadata:\(file.path)" : file.role
            guard !file.path.hasPrefix("/"), !file.path.split(separator: "/").contains(".."),
                  url.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/"),
                  paths[role] == nil, filePaths.insert(url.path).inserted, file.bytes > 0,
                  file.sha256.count == 64, file.sha256.allSatisfy({ $0.isHexDigit }) else { throw TranscriptionError.engineUnavailable }
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  (attributes[.size] as? NSNumber)?.int64Value == file.bytes else { throw TranscriptionError.engineUnavailable }
            if hash {
                // 2026-09-19 审查修复：computeIfAbsent 单一形态（锁内计算）——
                // 并发校验同一文件时旧 peek+set 双方都漏缓存、重复流式哈希。
                let actual = try Self.validatedCache.value(key: url.path) {
                    let handle = try FileHandle(forReadingFrom: url)
                    defer { do { try handle.close() } catch { /* 只读描述符关闭失败不覆盖hash结果 */ } }
                    var digest = CryptoKit.SHA256()
                    while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty { digest.update(data: chunk) }
                    return digest.finalize().map { String(format: "%02x", $0) }.joined()
                }
                guard actual == file.sha256 else { throw TranscriptionError.engineUnavailable }
            }
            paths[role] = url.path
            totalBytes += file.bytes
        }
        // 2026-09-20 修复（业主「下载解压完成后引擎仍报不可用」纵深防御）：
        // 清单此前只做自洽校验（文件集 ↔ 清单自身一致、字节/SHA 逐文件比对）——
        // 若发布包把运行时必需角色命名成别的 role（如 VAD 文件叫 silero_vad、
        // 缺 vocab），校验通过、设置页显示「可用/已装」，而 `SherpaASRRuntime`
        // 在 `assets.path("vad")/("vocab")/("frontend")` 处抛 engineUnavailable，
        // 每次按压必失败且与「模型缺失」无法区分。此处按运行时固定角色集
        // （与 `SherpaASRRuntime` 装配一一对应）交叉校验——校验与加载同源，
        // 缺角色在安装期/可用性判定即红，绝不等到按压。
        for role in Self.runtimeRoles(for: choice) where paths[role] == nil {
            throw TranscriptionError.engineUnavailable
        }
        return Validated(paths: paths, totalBytes: totalBytes)
    }

    /// 运行时必需角色（单一事实源与 `SherpaASRRuntime` 的 assets.path 装配一一对应；
    /// vad 为 sherpa 轨共用组件）。
    private static func runtimeRoles(for choice: VoiceEngineChoice) -> Set<String> {
        switch choice {
        // zipformer 走在线流式分支，不装配 VAD（SherpaASRRuntime init 的 else 分支才加载 vad）
        case .zipformer: return ["tokens", "encoder", "decoder", "joiner", "bpe"]
        case .qwen3: return ["frontend", "encoder", "decoder", "vocab", "vad"]
        // dolphin/whisper 走 `assets.path("tokens")`（仅 qwen3 以空串替代 tokens）
        case .whisper: return ["encoder", "decoder", "tokens", "vad"]
        case .dolphin: return ["model", "tokens", "vad"]
        case .auto, .classic, .advanced, .dictation: return []
        }
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
#endif
