import Foundation
import SwiftUI
import os
import Domain
import Infrastructure
import Protocols

/// M2 各页共用的装配状态仓（@Observable，@MainActor）。
///
/// 把 M2 新增仓储（药箱/急救卡/疫苗/报销/发送状态/信源库）统一加载与写入，
/// 让 SettingsView 的「健康档案」入口可以真正挂上数据——**特性可达才有验收**。
/// 本仓不做任何业务判定：判定全在 Domain（InventoryRules/EmergencyCardService/
/// MessageStatusRules…），这里只做加载与透传。
@MainActor
@Observable
final class M2HubStore {
    // 药箱
    private(set) var inventoryItems: [MedicationStore.InventorySummaryItem] = []
    // 急救卡
    private(set) var emergencyCandidates = EmergencyCard(patientId: UUID())
    private(set) var emergencySelected = EmergencyCard(patientId: UUID())
    private(set) var emergencySelectedIds: Set<UUID> = []
    private(set) var bloodType: String?
    // 疫苗
    private(set) var immunizationRecords: [ImmunizationStore.Record] = []
    // 报销
    private(set) var claimRows: [ClaimStore.ClaimRow] = []
    private(set) var claimTotals = ClaimStore.Totals(totalAmount: 0, itemCount: 0, currency: "CNY")
    // 发送状态
    private(set) var sentMessages: [SentMessage] = []    // 信源库
    private(set) var guidelineEntries: [GuidelineEntry] = []
    // F16 预警事件（FR2.1⑥ 首页观察提示摘要卡 + FR16.10 预警历史页共用）
    private(set) var alertEvents: [GuidelineStore.AlertEvent] = []

    private let meds: MedicationStore
    private let emergency: EmergencyCardStore
    private let immunizations: ImmunizationStore
    private let claims: ClaimStore
    private let messages: MessageDeliveryStore
    private let guidelines: GuidelineStore
    /// FR9.13a/FR24.2 药品信息外发审计（FR14.2 审计清单之一）
    private let audit: AuditLogWriter
    private let logger = Logger(subsystem: "com.vitaliber", category: "m2hub")

    /// 最近一次请求的成员（BR-001 成员隔离：只允许最新请求写回状态）
    private var loadingPatientId: UUID?

    init(meds: MedicationStore, emergency: EmergencyCardStore,
         immunizations: ImmunizationStore, claims: ClaimStore,
         messages: MessageDeliveryStore, guidelines: GuidelineStore,
         audit: AuditLogWriter) {
        self.meds = meds
        self.emergency = emergency
        self.immunizations = immunizations
        self.claims = claims
        self.messages = messages
        self.guidelines = guidelines
        self.audit = audit
    }

    /// 分节加载助手：取回 → 成员代际守卫 → 一次性提交 → 独立错误隔离。
    /// 六节共用同一惯用法（BR-001 成员隔离只存在这一处），且经 async let
    /// 并发发起——节间互不依赖，串行等待使成员切换延迟 = 各查询之和
    /// （ADR-001 共享 DatabasePool 支持并发读）。@MainActor：async let 子任务
    /// 继承 MainActor 隔离（SE-0338），状态提交合法；并发发生在各节 await
    /// Store actor 的挂起点，主线程只承担提交。
    @MainActor
    private func loadSection<T>(patientId: UUID, label: String,
                                fetch: () async throws -> T,
                                commit: (T) -> Void) async {
        do {
            let value = try await fetch()
            guard loadingPatientId == patientId else { return }
            commit(value)
        } catch {
            logger.error("\(label): \(error)")
        }
    }

    func load(patientId: UUID) async {
        loadingPatientId = patientId
        // 先全部取回本地变量，再一次性提交。逐项直接赋值的话，成员切换会让
        // 甲的药箱和乙的急救卡同时出现在界面上（跨成员脏读，BR-001 成员隔离）。
        // 审查修复：单项失败隔离——原实现 8 个 fetch 串在同一个 do/catch，
        // 任意一项抛错即全量放弃（续药卡/预警摘要/药箱待办一起消失）。
        async let s1: Void = loadSection(patientId: patientId, label: "药箱加载失败",
            fetch: { try await meds.inventorySummary(patientId: patientId, now: Date()) },
            commit: { inventoryItems = $0 })
        async let s2: Void = loadSection(patientId: patientId, label: "急救卡加载失败",
            fetch: {
                async let c = emergency.candidates(patientId: patientId)
                async let s = emergency.selected(patientId: patientId)
                async let b = emergency.bloodType(patientId: patientId)
                let (candidates, selected, blood) = try await (c, s, b)
                let ids = Set((selected.allergies + selected.medications
                               + selected.healthProblems + selected.contacts).map(\.id))
                return (candidates, selected, ids, blood)
            },
            commit: { values in
                emergencyCandidates = values.0
                emergencySelected = values.1
                emergencySelectedIds = values.2
                bloodType = values.3
            })
        async let s3: Void = loadSection(patientId: patientId, label: "疫苗加载失败",
            fetch: { try await immunizations.list(patientId: patientId) },
            commit: { immunizationRecords = $0 })
        async let s4: Void = loadSection(patientId: patientId, label: "报销加载失败",
            fetch: {
                async let l = claims.list(patientId: patientId)
                async let t = claims.totals(patientId: patientId)
                return try await (l, t)
            },
            commit: { values in
                claimRows = values.0
                claimTotals = values.1
            })
        async let s5: Void = loadSection(patientId: patientId, label: "发送状态加载失败",
            fetch: { try await messages.list(patientId: patientId) },
            commit: { sentMessages = $0 })
        async let s6: Void = loadSection(patientId: patientId, label: "信源库/预警加载失败",
            fetch: {
                async let e = guidelines.all()
                async let h = guidelines.history(patientId: patientId)
                return try await (e, h)
            },
            commit: { values in
                guidelineEntries = values.0
                alertEvents = values.1
            })
        _ = await (s1, s2, s3, s4, s5, s6)
    }

    // MARK: - 药箱

    func reconcileLot(item: MedicationStore.InventorySummaryItem, physicalCount: Double) async {
        do {
            try await meds.reconcileLot(lotId: item.lotId, physicalCount: physicalCount, at: Date())
            // 审查修复：盘点归真后重载缓存——原实现只写库，药箱继续显示
            // 盘点前的旧余量/旧续药档位，直到下次全量 load
            if let patientId = loadingPatientId {
                inventoryItems = try await meds.inventorySummary(patientId: patientId, now: Date())
            }
        } catch {
            logger.error("盘点归真失败: \(error)")
        }
    }

    func dispenseCSV() -> String {
        let rows = inventoryItems.map { item in
            DispenseListRules.Row(name: item.medicationName, spec: item.spec,
                                  unitKind: item.unitKind,
                                  planUnits: item.remainingPlanUnits,
                                  confirmedUnits: item.remainingConfirmedUnits,
                                  expireAt: item.expireAt)
        }
        return DispenseListRules.csv(rows: rows)
    }

    // MARK: - 急救卡

    func toggleEmergency(item: EmergencyCardItem, selected: Bool, patientId: UUID) async {
        do {
            if selected {
                try await emergency.select(patientId: patientId, itemId: item.id, kind: item.kind)
            } else {
                try await emergency.deselect(patientId: patientId, itemId: item.id)
            }
            emergencySelected = try await emergency.selected(patientId: patientId)
            emergencySelectedIds = Set((emergencySelected.allergies + emergencySelected.medications
                                        + emergencySelected.healthProblems + emergencySelected.contacts)
                                        .map(\.id))
            // FR15.4 卡片内容变更写审计（select/deselect 均记录）
            try await audit.record(action: "update", entityType: "emergency_card",
                                   entityId: item.id.uuidString, actorLocal: "owner",
                                   meta: "\(selected ? "select" : "deselect") kind=\(item.kind)")
        } catch {
            logger.error("急救卡选择失败: \(error)")
        }
    }

    // MARK: - 疫苗 / 报销

    func createImmunization(patientId: UUID, name: String, dose: Int,
                            date: Date?, provider: String, lot: String) async {
        do {
            try await immunizations.create(patientId: patientId, vaccineName: name,
                                           doseNumber: dose, administeredAt: date,
                                           provider: provider, lotNumber: lot)
            immunizationRecords = try await immunizations.list(patientId: patientId)
        } catch {
            logger.error("疫苗记录失败: \(error)")
        }
    }

    func createClaim(patientId: UUID, type: String, amount: Double,
                     date: Date, merchant: String, summary: String) async {
        do {
            try await claims.create(patientId: patientId, itemType: type, amount: amount,
                                    date: date, merchant: merchant, summary: summary)
            claimRows = try await claims.list(patientId: patientId)
            claimTotals = try await claims.totals(patientId: patientId)
        } catch {
            logger.error("报销票据失败: \(error)")
        }
    }

    // MARK: - 发送状态（FR24.2）

    func recordSent(patientId: UUID, kind: String, recipient: String) async {
        do {
            _ = try await messages.recordSent(patientId: patientId, kind: kind, recipient: recipient)
            sentMessages = try await messages.list(patientId: patientId)
        } catch {
            logger.error("发送状态记录失败: \(error)")
        }
    }

    /// FR9.13a/FR24.2 每次分享写审计（药品信息外发——FR14.2 审计清单之一）
    func auditHelpCardSent(recipient: String) {
        Task {
            do {
                try await audit.record(action: "export", entityType: "sent_message",
                                       entityId: recipient, actorLocal: "owner",
                                       meta: "kind=helpCard")
            } catch {
                logger.error("求助卡发送审计失败: \(error)")
            }
        }
    }

    /// FR24.2 P0 手动「标记已送达」占位（无服务端时不伪造回执——
    /// 用户确认对方收到后手动推进 sent → ackPending，等待回执）
    func markDelivered(messageId: UUID, patientId: UUID) async {
        do {
            try await messages.updateStatus(id: messageId, to: .ackPending)
            sentMessages = try await messages.list(patientId: patientId)
        } catch {
            logger.error("标记已送达失败: \(error)")
        }
    }
}
