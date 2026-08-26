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

@Suite("Golden · M0 Sprint-3 三类补充")
struct GoldenClassifyTests {
    static let fixtures = Bundle.module.bundlePath + "/Fixtures"
    func load(_ name: String) throws -> [LegacyRecord] {
        try JSONDecoder().decode([LegacyRecord].self, from: Data(contentsOf: URL(fileURLWithPath: Self.fixtures + "/" + name)))
    }
    @Test func 处方类识别与置信度分级() throws {
        let r = try load("prescription_v1.json")[0]
        #expect(GoldenRules.classify(recordType: r.recordType, assets: r.assets) == .prescription)
        #expect(GoldenRules.confidenceTier(0.91) == "high" && GoldenRules.confidenceTier(0.62) == "mid")
    }
    @Test func 化验类识别() throws {
        let r = try load("lab_v1.json")[0]
        #expect(GoldenRules.classify(recordType: r.recordType, assets: r.assets) == .lab)
    }
    @Test func OCR分隔块优先于类型判断() throws {
        let r = try load("ocr_blocks_v1.json")[0]
        #expect(GoldenRules.classify(recordType: r.recordType, assets: r.assets) == .ocrBlock)
        #expect(GoldenRules.confidenceTier(0.85) == "high")
    }
}

@Suite("Golden · M0 Sprint-4 LoadGate/审计")
struct LoadGateAuditTests {
    @Test func LoadGate并发仅加载一次() async {
        let gate = LoadGate()
        actor Counter { var n = 0; func inc() { n += 1 }; var v: Int { n } }
        let c = Counter()
        await withTaskGroup(of: Void.self) { g in
            for _ in 0..<20 { g.addTask { try await gate.enter { await c.inc() } } }
        }
        #expect(await c.v == 1)                       // 幂等：20 并发只触发一次加载
        #expect(await gate.currentState == .ready)
    }
    @Test func 审计表外键指向已定义表() {
        #expect(MigrationEngine.schemaV1.contains("audit_event"))
        #expect(MigrationEngine.schemaV1.contains("REFERENCES patient_profile(id)"))
    }
}
