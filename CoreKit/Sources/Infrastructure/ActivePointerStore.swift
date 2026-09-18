#if os(iOS) || os(macOS)
import Foundation
import Domain

/// ASR 模型「活动指针」与安装目录生命周期（结构轮 2026-09-15 自 ASRModelDownloadService 拆出）：
/// active.json 读写 + 进程级指针缓存 + 运行时资产根/活动目录解析 + 崩溃残留暂存回收。
/// 单一职责：本类型只判「当前激活哪个已校验版本、目录在哪」；下载/解压/编排在门面与
/// ModelPackage* 协作类。门面保留同名 static 转发（消费点零改）。
enum ActivePointerStore {

    // MARK: - 路径

    static func applicationSupportRoot() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("ASRModels", isDirectory: true)
    }

    /// 已激活（校验过）的下载版本目录；无有效指针则返回 nil（调用方回落随包/Bundle）。
    static func activeRoot(for choice: VoiceEngineChoice) -> URL? {
        guard let pointer = activePointer(for: choice) else { return nil }
        return versionRoot(for: choice, pointer: pointer)
    }

    static func installedVersion(for choice: VoiceEngineChoice) -> String? {
        activePointer(for: choice)?.version
    }

    static func activeAssets(for choice: VoiceEngineChoice) -> ASRModelAssets? {
        guard let pointer = activePointer(for: choice), let hash = pointer.packageSHA256 else { return nil }
        return ASRModelAssets(root: versionRoot(for: choice, pointer: pointer), packageSHA256: hash)
    }

    /// 已激活版本的安装目录：applicationSupportRoot/<choice>/<directory ?? version>
    private static func versionRoot(for choice: VoiceEngineChoice,
                                    pointer: ASRModelDownloadService.ActivePointer) -> URL {
        applicationSupportRoot()
            .appendingPathComponent(choice.rawValue, isDirectory: true)
            .appendingPathComponent(pointer.directory ?? pointer.version, isDirectory: true)
    }

    // MARK: - 指针缓存（进程级；install 完成时失效）

    /// `active.json` 是低频变更文件，但被 resolve/installedVersion/updateAvailable
    /// 在设置页 body 与能力查询热路径反复同步读盘——进程级备忘，安装落盘后失效。
    static let pointerCacheLock = NSLock()
    /// 缓存值为装箱枚举而非 `ASRModelDownloadService.ActivePointer?`——字典对可选值赋 nil 会删键，
    /// 负缓存（未安装=无指针）随之失效，每次调用都重读 active.json（审查发现）。
    nonisolated(unsafe) private static var pointerCache: [String: PointerResult] = [:]

    private enum PointerResult: Sendable {
        case missing
        case pointer(ASRModelDownloadService.ActivePointer)
    }

    static func activePointer(for choice: VoiceEngineChoice) -> ASRModelDownloadService.ActivePointer? {
        pointerCacheLock.lock(); defer { pointerCacheLock.unlock() }
        switch pointerCache[choice.rawValue] {
        case .some(.missing): return nil
        case .some(.pointer(let pointer)):
            guard let hash = pointer.packageSHA256, !ModelCatalogTrustStore.shared.isRevoked(hash) else { return nil }
            return pointer
        case nil:
            let computed = computeActivePointer(for: choice)
            pointerCache[choice.rawValue] = computed.map(PointerResult.pointer) ?? PointerResult.missing
            return computed
        }
    }

    private static func computeActivePointer(for choice: VoiceEngineChoice) -> ASRModelDownloadService.ActivePointer? {
        let root = applicationSupportRoot().appendingPathComponent(choice.rawValue, isDirectory: true)
        guard let data = try? Data(contentsOf: root.appendingPathComponent("active.json")),   // try?-ok: 指针缺失=未下载（布尔判定，非错误吞没）
              let pointer = try? JSONDecoder().decode(ASRModelDownloadService.ActivePointer.self, from: data) else { return nil }   // try?-ok: 同上
        guard let hash = pointer.packageSHA256, ModelResourcePolicy.isSHA256(hash),
              !ModelCatalogTrustStore.shared.isRevoked(hash),
              pointer.choice == choice.rawValue, ModelResourcePolicy.isSlug(pointer.version),
              ModelResourcePolicy.isSlug(pointer.directory ?? pointer.version) else { return nil }
        let dir = root.appendingPathComponent(pointer.directory ?? pointer.version, isDirectory: true)
        guard FileManager.default.fileExists(atPath: dir.appendingPathComponent("manifest.json").path) else {
            return nil
        }
        return pointer
    }

    static func invalidatePointerCache() {
        pointerCacheLock.lock()
        pointerCache = [:]
        pointerCacheLock.unlock()
    }

    /// 崩溃残留暂存回收（结构轮：自门面迁入，与安装目录生命周期同域）。
    static func removeStaleStaging(in modelRoot: URL, fileManager: FileManager = .default) {
        guard let entries = try? fileManager.contentsOfDirectory(at: modelRoot, // try?-ok: 目录不存在/不可读=无可回收残留，非关键路径
                                                                 includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                                                                 options: []) else { return }
        for entry in entries where entry.lastPathComponent.hasPrefix(".staging-") {
            guard let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]), // try?-ok: 属性不可读则跳过该项
                  values.isDirectory == true, values.isSymbolicLink != true else { continue }
            try? ASRModelAssets.removeIfUnused(entry) // try?-ok: 残留回收失败只占空间，不影响本次安装主流程
        }
    }
}
#endif
