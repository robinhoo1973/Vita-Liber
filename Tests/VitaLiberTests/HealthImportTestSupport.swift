import XCTest
import Foundation
import Domain
import Infrastructure

/// 测试共用支持（审查修复 2026-09-18 收敛）：
/// - HealthImportStore 的 history 道默认便捷：HealthImportAcceptanceTests 与
///   HealthKitSyncServiceTests 两份**逐字重复**的 private extension 收敛为
///   单一出口（private 文件级扩展无法跨文件共享——语义变更只改一份时，
///   另一份仍在测旧道、与生产 API 漂移）。
/// - Asia/Shanghai 固定日历：Stock 三份测试各写一份同构构造
///   （StockAppointmentAcceptanceTests 注释自称「下沉为单一出口」，但三处
///   仍各持副本）——收敛为 XCTestCase 单一计算属性；对账/物化/补录的
///   时区语义测试共用同一时区事实源。

/// 测试便捷：既有用例以 2023 年样本验证检查点/删除证明语义，全部落 history 道；
/// 生产 API 保持 lane 显式，不提供默认道。
extension HealthImportStore {
    func anchor(binding: Binding, kind: HealthDataKind) async throws -> Data? {
        try await anchor(binding: binding, kind: kind, lane: .history)
    }

    func stage(binding: Binding, kind: HealthDataKind, previousAnchor: Data?, page: HealthChangeBatch) async throws -> PendingBatch {
        let history = HealthFetchScope(lane: .history,
                                       cutoff: HealthFetchScope.cutoff(connectedAt: binding.connectedAt, calendar: binding.calendar))
        return try await stage(binding: binding, kind: kind, scope: history, previousAnchor: previousAnchor, page: page)
    }
}

/// 时区固定 Asia/Shanghai 的日历（对账/物化/补录的时区语义依赖）
extension XCTestCase {
    var shanghaiCalendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }
}
