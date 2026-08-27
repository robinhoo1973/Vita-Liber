import XCTest
import Foundation
import GRDB
import Domain
import Infrastructure
import Protocols
@testable import VitaLiber

// binds: SU-M2-F16 — 信源库单一事实源 + 离线预警事件链（TC-M2-04）
/// F16 落库半场：信源库种子/检索、预警事件只存事实、历史查询。
/// Domain 半场（四级定级/连续三次/五段卡/负清单）在 CoreKitTests。
@MainActor
final class M2F16AcceptanceTests: XCTestCase {

    private func makeStore() async throws -> (GRDBStore, GuidelineStore, UUID) {
        let store = try GRDBStore.inMemory()
        let guidelines = GuidelineStore(writer: store.writer)
        let patient = UUID()
        try await store.writer.write { db in
            try db.execute(sql: """
                INSERT INTO patient_profile (id, display_name, relation, created_at, updated_at)
                VALUES (?, 'F16 测试患者', '本人', 0, 0)
                """, arguments: [patient.uuidString])
        }
        return (store, guidelines, patient)
    }

    /// 信源库：种子入库幂等、按指标检索命中、零网络即可用
    func test_信源库种子幂等且离线可检索() async throws {
        let (store, guidelines, _) = try await makeStore()

        let first = try await guidelines.seedBundled()
        XCTAssertGreaterThan(first, 0, "内置信源种子必须入库")
        let second = try await guidelines.seedBundled()
        XCTAssertEqual(second, 0, "种子必须幂等——重复调用不得重复插入或覆盖")

        // XCTUnwrap 是 autoclosure，不支持并发调用——先 await 再解包（Swift 6.0 错误）
        let glucoseEntry = try await guidelines.entry(for: "glucose")
        let glucose = try XCTUnwrap(glucoseEntry)
        XCTAssertEqual(glucose.metricKey, "glucose")
        XCTAssertEqual(glucose.unit, "mmol/L")
        XCTAssertNotNil(glucose.l3High, "阈值数字必须随种子入库（FR16.4 单一事实源）")

        let all = try await guidelines.all()
        XCTAssertFalse(all.isEmpty)
        XCTAssertTrue(all.allSatisfy { !$0.citationUrl.isEmpty },
                      "每条信源必须带可打开的原文链接（F16 验收：信源链接可打开原文）")
        XCTAssertTrue(all.allSatisfy { !$0.org.isEmpty && $0.year > 1900 },
                      "FR16.4 准入：权威机构 + 年份缺一不可")
    }

    /// 无适用范围 → 拒绝定级而非臆造（范围不可用是独立状态，不显示通用范围）
    func test_无信源无报告范围拒绝定级() async throws {
        let (_, guidelines, patient) = try await makeStore()
        let reading = MetricReading(metricKey: "custom_metric", value: 3.0, unit: "x",
                                    origin: .manual, measuredAt: Date())
        do {
            _ = try await guidelines.evaluateAndRecord(reading: reading, patientId: patient)
            XCTFail("无适用范围必须拒绝定级——臆造阈值违反单一事实源")
        } catch GuidelineStore.StoreError.noApplicableRange {
            // 期望路径
        }
    }

    /// 预警事件：只存事实（定级 + 证据卡 JSON），历史可查且措辞过负清单
    func test_预警事件落库与历史查询() async throws {
        let (_, guidelines, patient) = try await makeStore()
        _ = try await guidelines.seedBundled()

        let reading = MetricReading(metricKey: "glucose", value: 17.2, unit: "mmol/L",
                                    origin: .device, measuredAt: Date())
        let event = try await guidelines.evaluateAndRecord(reading: reading, patientId: patient)
        XCTAssertEqual(event.severity, .L3, "17.2 超出 l3High=16.7 应定 L3")
        XCTAssertNil(WordingBlacklist.violation(in: event.card.facts),
                     "落库事实句式过措辞负清单（一票否决）")
        XCTAssertNotNil(event.card.sourceRef)

        let history = try await guidelines.history(patientId: patient)
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history[0].severity, .L3)
        XCTAssertEqual(history[0].card.facts, event.card.facts)
        // 成员隔离：他人查不到
        let others = try await guidelines.history(patientId: UUID())
        XCTAssertTrue(others.isEmpty, "BR-001：跨成员预警历史必须隔离")
    }

    /// 连续 3 次越限触发 L1：序列走落库链（每读数一条事件），最后一条定级 L1
    func test_连续三次越限落库链() async throws {
        let (_, guidelines, patient) = try await makeStore()
        _ = try await guidelines.seedBundled()
        var readings: [MetricReading] = []
        for i in 0..<3 {
            readings.append(MetricReading(metricKey: "glucose", value: 7.8, unit: "mmol/L",
                                          origin: .device,
                                          measuredAt: Date(timeIntervalSince1970: TimeInterval(1_000 + i * 60))))
            _ = try await guidelines.evaluateAndRecord(reading: readings[i], patientId: patient)
        }
        let escalate = AlertRuleEngine.escalate(recent: readings,
                                                guideline: try await guidelines.entry(for: "glucose"))
        XCTAssertEqual(escalate, .L1, "连续 3 次越限必须触发 L1（FR16.2 验收句）")
        let history = try await guidelines.history(patientId: patient)
        XCTAssertEqual(history.count, 3, "每次读数都应留痕（L1+ 摘要卡从历史提取）")
    }

    /// 迁移 v3：v2 库升级后 guideline_source 具备阈值列
    func test_迁移v3补齐信源阈值列() async throws {
        let queue = try DatabaseQueue(configuration: GRDBStore.configuration())
        try await queue.write { db in
            try db.execute(sql: """
                CREATE TABLE guideline_source (
                  id TEXT PRIMARY KEY, title TEXT NOT NULL, org TEXT NOT NULL,
                  year INTEGER NOT NULL, clause_ref TEXT NOT NULL,
                  citation_url TEXT NOT NULL, version TEXT NOT NULL,
                  checked_at REAL NOT NULL, retired_at REAL);
                PRAGMA user_version = 2;
                """)
        }
        _ = try GRDBStore(writer: queue)   // 触发 v3 迁移
        let cols = try await queue.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('guideline_source')")
        }
        for c in ["thresholds_json", "metric_key", "unit"] {
            XCTAssertTrue(cols.contains(c), "迁移未补齐 \(c)")
        }
    }
}
