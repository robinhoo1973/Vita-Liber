import Foundation

/// 通告载荷的本机版本地板（anti-rollback floor）：记录已验证解码载荷达到过的最高
/// `payloadVersion` 与其 identity（=`update-payload-<sha256(明文)>` 的 64hex 段）。
///
/// 与 `MedicalCatalogTrustStore` 同一先例（平台中立 Foundation、读-验-写全程持锁、
/// 同目录 rename(2) 原子替换、损坏按「尚无 floor」处理）。floor 只由**解码+校验通过
/// 的载荷**推进；推进失败（回退/同版异文）不回滚内存态。
public final class UpdateAdviceFloorStore: @unchecked Sendable {
    public enum Failure: Error, Equatable {
        case rollback
        case equivocation
        case invalidState
    }

    public struct ObservedFloor: Sendable, Equatable {
        public let payloadVersion: Int
        public let identityHex: String
    }

    private static let schemaVersion = 1
    private static let maxBytes = 4 * 1024

    private let fileURL: URL
    private let lock = NSLock()
    private var floor: Floor?

    private struct Floor: Codable, Equatable {
        let schemaVersion: Int
        let payloadVersion: Int
        let identityHex: String
    }

    public init(fileURL: URL) {
        self.fileURL = fileURL
        guard let data = MedicalCatalogSupportFile.read(fileURL, maxBytes: Self.maxBytes) else { return }
        do {
            let decoded = try JSONDecoder().decode(Floor.self, from: data)
            guard decoded.schemaVersion == Self.schemaVersion, decoded.payloadVersion > 0,
                  Self.isHex64(decoded.identityHex) else { return }
            floor = decoded
        } catch {
            // 损坏状态按「尚无 floor」处理，不阻断启动（同 TrustStore 先例）。
        }
    }

    /// 生产落盘位置：与医疗服务同支持目录、独立文件。
    public static func production(supportDirectory: URL) -> UpdateAdviceFloorStore {
        UpdateAdviceFloorStore(fileURL: supportDirectory.appendingPathComponent("update-advice-floor.json"))
    }

    public var observedFloor: ObservedFloor? {
        lock.lock(); defer { lock.unlock() }
        return floor.map { ObservedFloor(payloadVersion: $0.payloadVersion, identityHex: $0.identityHex) }
    }

    /// 唯一改动落盘状态的方法（读-验-写全程持锁，先落盘后换内存态）：
    /// 更低版本 = rollback；同版本同 identity = 幂等；同版本异 identity = equivocation。
    public func accept(payloadVersion: Int, identityHex: String) throws {
        guard payloadVersion > 0, Self.isHex64(identityHex) else { throw Failure.invalidState }
        lock.lock()
        defer { lock.unlock() }
        if let current = floor {
            guard payloadVersion >= current.payloadVersion else { throw Failure.rollback }
            if payloadVersion == current.payloadVersion {
                if identityHex == current.identityHex { return }
                throw Failure.equivocation
            }
        }
        let next = Floor(schemaVersion: Self.schemaVersion, payloadVersion: payloadVersion, identityHex: identityHex)
        let data = try JSONEncoder().encode(next)
        guard data.count <= Self.maxBytes else { throw Failure.invalidState }
        try MedicalCatalogSupportFile.write(data, to: fileURL)
        floor = next
    }

    private static func isHex64(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}
