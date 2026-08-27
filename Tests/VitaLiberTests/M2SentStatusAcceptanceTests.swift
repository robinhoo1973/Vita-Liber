import XCTest
import Foundation
import GRDB
import Domain
import Infrastructure
import Protocols
@testable import VitaLiber

// binds: SU-M2-CARE — FR24.2 发送状态落库（只记状态不存原文 + 迁移白名单）
@MainActor
final class M2SentStatusAcceptanceTests: XCTestCase {

    private func makeStore() async throws -> (GRDBStore, MessageDeliveryStore, UUID) {
        let store = try GRDBStore.inMemory()
        let messages = MessageDeliveryStore(writer: store.writer)
        let patient = UUID()
        try await store.writer.write { db in
            try db.execute(sql: """
                INSERT INTO patient_profile (id, display_name, relation, created_at, updated_at)
                VALUES (?, '发送状态测试', '本人', 0, 0)
                """, arguments: [patient.uuidString])
        }
        return (store, messages, patient)
    }

    /// 记录发送 → 列表可查；**原文零落库**（表结构上就没有原文列）
    func test_记录与列表() async throws {
        let (_, messages, patient) = try await makeStore()
        let sent = try await messages.recordSent(patientId: patient, kind: "helpCard", recipient: "家人")
        XCTAssertEqual(sent.status, .sent)
        let list = try await messages.list(patientId: patient)
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].recipient, "家人")
        // 表无原文列：列出列名验证最小必要
        let cols = try await messagesCols()
        XCTAssertFalse(cols.contains("body") || cols.contains("content") || cols.contains("text"),
                       "发送状态表不得存消息原文（最小必要 FR24.2）")
    }

    /// 状态迁移白名单：合法迁移成功、回退/旁路被拒（Domain 规则 + 仓储强制）
    func test_状态迁移白名单() async throws {
        let (_, messages, patient) = try await makeStore()
        let sent = try await messages.recordSent(patientId: patient, kind: "sos", recipient: "女儿")

        try await messages.updateStatus(id: sent.id, to: .ackPending)   // sent → ackPending 合法
        var list = try await messages.list(patientId: patient)
        XCTAssertEqual(list[0].status, .ackPending)

        do {
            try await messages.updateStatus(id: sent.id, to: .sent)     // 回退必须被拒
            XCTFail("acked/ackPending 回退 sent 必须拒绝——状态不可伪造")
        } catch MessageDeliveryStore.StoreError.illegalTransition {
            // 期望路径
        }
        try await messages.updateStatus(id: sent.id, to: .acked)        // ackPending → acked
        list = try await messages.list(patientId: patient)
        XCTAssertEqual(list[0].status, .acked)
    }

    /// 成员隔离（BR-001）
    func test_成员隔离() async throws {
        let (_, messages, patient) = try await makeStore()
        _ = try await messages.recordSent(patientId: patient, kind: "helpCard", recipient: "家人")
        let others = try await messages.list(patientId: UUID())
        XCTAssertTrue(others.isEmpty, "跨成员发送记录必须隔离")
    }

    private func messagesCols() async throws -> [String] {
        let queue = try DatabaseQueue(configuration: GRDBStore.configuration())
        _ = try GRDBStore(writer: queue)
        return try await queue.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('sent_message')")
        }
    }
}
