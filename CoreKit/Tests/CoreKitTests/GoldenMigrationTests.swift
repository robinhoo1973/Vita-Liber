import Foundation
import Testing
@testable import Domain
@testable import Infrastructure

// binds: SU-M0-GOLDEN — TC-M0-01~05
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

// binds: SU-M1a-GOLDEN — 阶段金样扩充
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
            for _ in 0..<20 { g.addTask { await gate.enter { await c.inc() } } }
        }
        #expect(await c.v == 1)                       // 幂等：20 并发只触发一次加载
        #expect(await gate.currentState == .ready)
    }
    @Test func 审计表外键指向已定义表() {
        #expect(MigrationEngine.schemaV1.contains("audit_event"))
        #expect(MigrationEngine.schemaV1.contains("REFERENCES patient_profile(id)"))
    }

    /// 评审 S1-1 修正用例：load 抛错 → gate 回 .idle（可重试），等待者被唤醒，
    /// 错误只 rethrow 给发起方；重试成功后正常进 .ready。
    @Test func LoadGate失败回idle且可重试() async throws {
        struct Boom: Error {}
        let gate = LoadGate()
        var attempt = 0
        var firstErrorReachedCaller = false
        do {
            try await gate.enter {
                attempt += 1
                if attempt == 1 { throw Boom() }
            }
        } catch {
            firstErrorReachedCaller = true  // 第一次失败，错误到达发起方
        }
        #expect(firstErrorReachedCaller)
        #expect(await gate.currentState == .idle)          // 失败不得置 ready
        try await gate.enter { attempt += 1 }              // 重试走 idle 分支
        #expect(await gate.currentState == .ready)
        #expect(attempt == 2)
    }

    /// dev-pm §3.1：金样五类样本 + flutter 版真实备份样本一份。
    /// 混型样本覆盖 prescription/lab/medication/other/空资产五种形态——
    /// 断言「迁移条数等于输入条数」且「分类路由与实际类型一致」。
    @Test func flutter真实备份样本无损迁移() throws {
        let fixture = Bundle.module.bundlePath + "/Fixtures/flutter_backup_v1.json"
        let data = try Data(contentsOf: URL(fileURLWithPath: fixture))
        #expect(MigrationEngine.migrate(recordsJSON: data) == .migrated(count: 6))
        let records = try JSONDecoder().decode([LegacyRecord].self, from: data)
        #expect(GoldenRules.classify(recordType: records[0].recordType, assets: records[0].assets) == .prescription)
        #expect(GoldenRules.classify(recordType: records[1].recordType, assets: records[1].assets) == .lab)
        #expect(GoldenRules.classify(recordType: records[2].recordType, assets: records[2].assets) == .ocrBlock)  // other+OCR块→兜底
        #expect(GoldenRules.classify(recordType: records[3].recordType, assets: records[3].assets) == .generic)
        #expect(GoldenRules.classify(recordType: records[4].recordType, assets: records[4].assets) == .generic)  // 未知类型+无资产
        #expect(GoldenRules.classify(recordType: records[5].recordType, assets: records[5].assets) == .prescription)  // medication→处方
    }

    /// §4.3 自洽性（静态半场的补强，Linux 即可执行）：全量 DDL 里每个 REFERENCES
    /// 目标表都必须有 CREATE TABLE——与 L0 [3/7] 同语义，但直接作用在规范 DDL 上，
    /// 防「表名拼写漂移」类缺陷在 iOS 建库时才爆炸。
    @Test func 全量DDL引用目标自洽() {
        let ddl = MigrationEngine.schemaV1
        let created = Set(ddl
            .replacingOccurrences(of: "IF NOT EXISTS ", with: "")
            .split(separator: ";")
            .compactMap { stmt -> String? in
                let s = String(stmt)
                guard let r = s.range(of: "CREATE TABLE ") else { return nil }
                let rest = String(s[r.upperBound...])
                return rest.prefix(while: { $0 != "(" && $0 != " " }).description.trimmingCharacters(in: .whitespaces)
            })
        let refs = Set(ddl
            .split(separator: ";")
            .compactMap { stmt -> String? in
                let s = String(stmt)
                guard let r = s.range(of: "REFERENCES ") else { return nil }
                let rest = String(s[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                return rest.prefix(while: { $0 != "(" && $0 != " " && $0 != "\n" }).description
            })
        let missing = refs.subtracting(created)
        #expect(missing.isEmpty, "悬空 REFERENCES 目标: \(missing.sorted())")
    }
}

@Suite("M0 · MockFactory 三实体（Preview 出口准则）")
struct MockFactoryTests {
    @Test func 三类工厂产出合法关联实体() {
        let p = MockFactory.patient()
        let d = MockFactory.document(for: p)
        let m = MockFactory.plan(for: p)
        #expect(d.patientId == p.id && m.patientId == p.id)
        #expect(m.status == .active && !p.displayName.isEmpty)
    }
}
