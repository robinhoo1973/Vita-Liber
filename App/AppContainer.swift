import Foundation
import Domain
import Infrastructure
import Protocols

/// tech-spec §3 组装根：唯一共享 DatabasePool(WAL) + StoresBundle。
/// 评审修正（架构 A2）：M1a 起组装根被真实消费——VitaLiberApp 在此装配
/// 生产依赖（GRDB 库 + M1aPersisting + 审计写入口），AppState 只面向协议。
struct AppContainer {
    let store: GRDBStore
    let audit: AuditLogWriter
    let persistor: GRDBM1aPersistor
    let meds: MedicationStore
    let apts: AppointmentStore
    let reconciler: ReminderReconciler

    /// 生产装配：文件库 + WAL（§4.4）+ UNUserNotificationCenter 适配。
    static func live(databasePath: String) throws -> AppContainer {
        let store = try GRDBStore.pool(at: databasePath)
        return assemble(store: store, scheduler: UNReminderScheduler())
    }

    /// Preview/测试装配：内存库 + 内存调度器。
    static func preview() throws -> AppContainer {
        let store = try GRDBStore.inMemory()
        return assemble(store: store, scheduler: InMemoryReminderScheduler())
    }

    private static func assemble(store: GRDBStore, scheduler: any ReminderScheduling) -> AppContainer {
        let meds = MedicationStore(writer: store.writer)
        let apts = AppointmentStore(writer: store.writer, scheduler: scheduler)
        let reconciler = ReminderReconciler(scheduler: scheduler, source: meds)
        return AppContainer(store: store,
                            audit: AuditLogWriter(writer: store.writer),
                            persistor: GRDBM1aPersistor(store: store),
                            meds: meds,
                            apts: apts,
                            reconciler: reconciler)
    }

    /// Application Support 下的数据库路径（生产库位置）
    static func defaultDatabasePath() -> String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("VitaLiber", isDirectory: true)
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        catch { /* 目录创建失败由 GRDB 打开时报错，不在此吞掉 */ }
        return dir.appendingPathComponent("vitaliber.sqlite").path
    }
}
