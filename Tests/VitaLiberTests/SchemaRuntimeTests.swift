import XCTest
import Foundation
import Domain
import Infrastructure

/// TC-M0-06 运行时半场（test-plan-spec §4.1）——闭合 dev-pm §3.1 退出准则
/// 「审计表/软删视图/索引按 §4.3 建库可执行，`PRAGMA foreign_keys=ON` 断言通过」。
///
/// 为什么放在 iOS 单元测试目标而不是 CoreKitTests：GRDB 只在 iOS/macOS 链接
/// （ERR#8，见 Package.swift 平台条件依赖），而 CoreKit 的 SPM 测试目标在 CI 上
/// 跑在 Linux 容器里——那里 GRDBStore 整体被平台守卫编译排除，断言无处落脚。
/// 本目标由 l1-unit-shards 在 iOS 模拟器上执行，是这些断言唯一真实生效的位置。
final class SchemaRuntimeTests: XCTestCase {

    /// L0 只能静态断言「DDL 文本里有 foreign_keys 字样」；此处断言连接**运行时真的开着**。
    func test_外键运行时确为开启() throws {
        let store = try GRDBStore.inMemory()
        XCTAssertTrue(store.foreignKeysOn, "PRAGMA foreign_keys 必须返回 1（tech-spec §4.3）")
    }

    /// 悬空外键必须被拒——外键「开着」但不生效等于没开。
    func test_悬空外键被拒绝() throws {
        let store = try GRDBStore.inMemory()
        XCTAssertThrowsError(
            try store.writer.write { db in
                try db.execute(
                    sql: "INSERT INTO document_file (id, patient_id, title, created_at) VALUES (?, ?, ?, ?)",
                    arguments: ["d1", "ghost-patient-id", "悬空引用", 0.0])
            },
            "patient_id 指向不存在的 patient_profile，必须被外键约束拒绝")
    }

    /// 合法外键必须可写入——避免上一条用例被「什么都写不进去」这种假象满足。
    func test_合法外键可写入() throws {
        let store = try GRDBStore.inMemory()
        let profile = PatientProfile(displayName: "本人")
        try store.insert(profile: profile)
        try store.writer.write { db in
            try db.execute(
                sql: "INSERT INTO document_file (id, patient_id, title, created_at) VALUES (?, ?, ?, ?)",
                arguments: ["d2", profile.id.uuidString, "处方", 0.0])
        }
        let count = try store.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM document_file") ?? -1
        }
        XCTAssertEqual(count, 1)
    }

    /// §4.3 审计表与索引必须建库可执行（DDL 可执行性，不只是文本存在）。
    func test_审计表与索引建库可执行() throws {
        let store = try GRDBStore.inMemory()
        let tables = try store.writer.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")
        }
        XCTAssertTrue(tables.contains("audit_event"))
        XCTAssertTrue(tables.contains("patient_profile"))
        XCTAssertTrue(tables.contains("document_file"))
        let indexes = try store.writer.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='index'")
        }
        XCTAssertTrue(indexes.contains("idx_audit_time"), "§4.3 审计时间倒序索引必须建立")
    }
}
