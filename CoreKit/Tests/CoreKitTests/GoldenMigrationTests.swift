import Foundation
import Testing
@testable import Domain
@testable import Infrastructure

@Suite("Golden · M0 迁移金样（Sprint-1）")
struct GoldenMigrationTests {
    @Test func 空数组正常迁移零条() {
        #expect(MigrationEngine.migrate(recordsJSON: Data("[]".utf8)) == .migrated(count: 0))
    }
    @Test func 损坏JSON只读降级不落种子() {
        #expect(MigrationEngine.migrate(recordsJSON: Data("{\"broken".utf8)) == .degraded)
    }
    @Test func 未确认字段不得入时间轴_BR003() {
        var f = FieldConfirmation.ocrUnconfirmed
        #expect(!f.isUsableInTimeline)
        f.confirm()
        #expect(f.isUsableInTimeline && f == .confirmed)
    }
    @Test func DDL外键引用目标已定义() {
        #expect(MigrationEngine.schemaV1.contains("REFERENCES patient_profile(id)"))
    }
}
