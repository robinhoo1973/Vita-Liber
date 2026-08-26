import Foundation
import Domain
import Infrastructure

/// tech-spec §3 组装根：唯一共享 DatabasePool(WAL) + StoresBundle。
/// 评审 S1-4/S2-4 修正——M0 落地组装根，生产/Preview/测试三装配
/// 全部经此注入；Preview 与单测禁连生产库（MockFactory 纪律）。
struct AppContainer {
    let store: GRDBStore
    let audit: AuditLogWriter

    /// 生产装配：文件库 + WAL（§4.4）。
    static func live(databasePath: String) throws -> AppContainer {
        let pool = try GRDBStore.pool(at: databasePath)
        return AppContainer(store: pool, audit: AuditLogWriter(writer: pool.writer))
    }

    /// Preview/测试装配：内存库。
    static func preview() throws -> AppContainer {
        let store = try GRDBStore.inMemory()
        return AppContainer(store: store, audit: AuditLogWriter(writer: store.writer))
    }
}
