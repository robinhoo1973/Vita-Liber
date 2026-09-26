import Foundation

/// App 本机观察到的目录版本地板（anti-rollback floor）：只记录已验证 installable
/// candidate 达到过的最高 `catalogVersion` 及其规范 pointer 摘要（`signedPointerDigest`）。
/// 平台中立 Foundation 实现——Linux 可编译可测，不依赖 CryptoKit/GRDB。
///
/// floor 只由「已完成元数据校验」推进：`acceptVerifiedInstallable(catalogVersion:payloadDigest:)`
/// 是唯一改动落盘状态的方法，调用方（Task 7 的 resolver/installer）必须只在 pinned-root
/// 验签 + 全部元数据校验通过、且候选 `installable == true` 之后调用——**安装本身
/// （下载/解密/激活）失败绝不调用本方法**，floor 因而绝不因安装失败而回退。
/// `accept(_:)` 是结构性保证入口：接一整个 `VerifiedMedicalCatalogCandidate`，
/// `installable == false`（progress pointer）在这里就地拒绝，不转发到落盘方法；
/// `installable == true` 才转发 `(catalogVersion, signedPointerDigest)`。
///
/// 落盘用同目录 `rename(2)` 原子替换，版本化 + 限长 JSON；状态损坏/缺失按
/// 「尚无 floor」处理——与 `ModelCatalogTrustStore` 同一先例：本机状态丢失只回到
/// 首次安装态，不构成越权（沙盒内文件系统层面能篡改此文件的攻击者本就能替换整个 App）。
public final class MedicalCatalogTrustStore: @unchecked Sendable {
    public enum Failure: Error, Equatable {
        /// 唯一入口收到 `installable == false`（progress pointer）——API 级拒绝，
        /// 不存在能让 progress 候选推进 floor 的路径。
        case notInstallable
        case rollback
        case equivocation
        case invalidState
    }

    public struct ObservedFloor: Sendable, Equatable {
        public let catalogVersion: Int64
        public let payloadDigest: String
    }

    private static let schemaVersion = 1
    private static let maxBytes = 4 * 1024

    private let fileURL: URL
    private let lock = NSLock()
    private var floor: Floor?

    private struct Floor: Codable, Equatable {
        let schemaVersion: Int
        let catalogVersion: Int64
        let payloadDigest: String
    }

    /// `fileURL`：注入的落盘位置（同卷目录库支持目录下的独立文件，与激活 journal
    /// 分文件存放）。测试可指向隔离临时目录，验证「失败的原子写不改变已持久化状态」。
    public init(fileURL: URL) {
        self.fileURL = fileURL
        guard let data = MedicalCatalogSupportFile.read(fileURL, maxBytes: Self.maxBytes) else { return }
        do {
            let decoded = try JSONDecoder().decode(Floor.self, from: data)
            guard decoded.schemaVersion == Self.schemaVersion, decoded.catalogVersion > 0,
                  MedicalCatalogReleaseProtocol.isLowercaseSHA256(decoded.payloadDigest) else { return }
            floor = decoded
        } catch {
            // 损坏状态按"尚无 floor"处理，不阻断启动（同 ModelCatalogTrustStore 先例）。
        }
    }

    /// 生产落盘位置：与激活 journal 同支持目录、分文件存放
    /// （tech-spec §5.53 ④：App TrustStore 须在 Store 打开前恢复——装配根构造即恢复）。
    public static func production(supportDirectory: URL) -> MedicalCatalogTrustStore {
        MedicalCatalogTrustStore(fileURL: supportDirectory.appendingPathComponent("medical-catalog-trust.json"))
    }

    public var observedFloor: ObservedFloor? {
        lock.lock(); defer { lock.unlock() }
        return floor.map { ObservedFloor(catalogVersion: $0.catalogVersion, payloadDigest: $0.payloadDigest) }
    }

    /// 结构性保证入口：接一整个已验签候选。`installable == false`（progress pointer）
    /// 在这里就地拒绝（`Failure.notInstallable`），不转发到 `acceptVerifiedInstallable`——
    /// 没有第二条能让 progress 候选推进 floor 的路径。
    public func accept(_ candidate: VerifiedMedicalCatalogCandidate) throws {
        guard candidate.installable else { throw Failure.notInstallable }
        try acceptVerifiedInstallable(catalogVersion: candidate.catalogVersion, payloadDigest: candidate.signedPointerDigest)
    }

    /// 唯一改动落盘状态的方法。调用方（Task 7 的 resolver/installer）只能在
    /// pinned-root 验签 + 全部元数据校验通过、且候选 `installable == true` 之后调用；
    /// progress pointer 走 `accept(_:)` 即被拒绝，绝不会调用到这里。
    ///
    /// - 更低 `catalogVersion`：`Failure.rollback`。
    /// - 相同 `catalogVersion`、相同 `payloadDigest`：幂等空操作（不重复落盘）。
    /// - 相同 `catalogVersion`、不同 `payloadDigest`：`Failure.equivocation`
    ///   （同一版本号出现两份不同签名内容——发布方或传输层已不可信）。
    public func acceptVerifiedInstallable(catalogVersion: Int64, payloadDigest: String) throws {
        guard catalogVersion > 0, MedicalCatalogReleaseProtocol.isLowercaseSHA256(payloadDigest) else {
            throw Failure.invalidState
        }

        // 读-验-写全程持锁（2026-09-26 审查修复）：此前「锁内读 floor、锁外判定与
        // 落盘、再锁回写内存态」——两个并发调用都对着同一份旧 floor 快照通过判定，
        // 交错落盘后磁盘 floor 回退到低版本、或同版本双 digest 同时通过（equivocation
        // 判据失守）。反回退/反等价都以「落盘瞬间」的 floor 为基准，不容交错。
        // 先落盘、后换内存态：落盘失败（如卷只读）时已持久化状态与内存态都保持推进前的值。
        lock.lock()
        defer { lock.unlock() }
        let current = floor
        if let current {
            guard catalogVersion >= current.catalogVersion else { throw Failure.rollback }
            if catalogVersion == current.catalogVersion {
                if payloadDigest == current.payloadDigest { return }
                throw Failure.equivocation
            }
        }
        let next = Floor(schemaVersion: Self.schemaVersion, catalogVersion: catalogVersion, payloadDigest: payloadDigest)
        let data = try JSONEncoder().encode(next)
        guard data.count <= Self.maxBytes else { throw Failure.invalidState }
        try MedicalCatalogSupportFile.write(data, to: fileURL)
        floor = next
    }
}

/// `MedicalCatalogTrustStore` 与 `MedicalCatalogActivationJournal` 共用的落盘原语：
/// 同目录临时文件 + `rename(2)`——单次改名要么整份新内容生效，要么维持旧文件不变，
/// 不存在半写状态；读侧对超限/损坏文件一律返回 nil（调用方按"无有效状态"处理）。
enum MedicalCatalogSupportFile {
    static func read(_ url: URL, maxBytes: Int) -> Data? {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {
            return nil
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber,
              size.int64Value > 0, size.int64Value <= maxBytes else { return nil }
        do {
            return try Data(contentsOf: url)
        } catch {
            return nil
        }
    }

    static func write(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temp = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try data.write(to: temp)
            #if os(iOS) || os(macOS)
            // 掉电窗口修复（2026-09-26 审查）：Data.write 不保证刷盘——rename 先于数据
            // 落盘时掉电会留下空/截断的新文件（journal 恢复与 floor 恢复都依赖此文件
            // 完整）。先 fsync 临时文件再改名；Foundation 的 .atomic 选项在 rename 失败时
            // 会静默退化为直接写，恰破坏本原语要求的「要么新内容、要么旧文件」语义，
            // 故不采用。
            let handle = try FileHandle(forWritingTo: temp)
            try handle.synchronizeFile()
            try handle.close()
            #endif
        } catch {
            // 写盘/fsync 失败同样清理半成品（2026-09-26 扫尾修复：原实现只在
            // rename 失败时清理——磁盘满/只读卷下 UUID 临时文件会残留成目录垃圾，
            // 与 +Install 解压器的失败清理路径不对称）。
            try? FileManager.default.removeItem(at: temp) // try?-ok: 清理失败不掩盖主错误（下面仍会抛出）
            throw error
        }
        guard rename(temp.path, url.path) == 0 else {
            try? FileManager.default.removeItem(at: temp) // try?-ok: 改名失败后清理临时文件，不掩盖上面的改名失败（下面仍会抛出）
            throw CocoaError(.fileWriteUnknown)
        }
    }
}
