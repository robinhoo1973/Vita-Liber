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

    func load(patientId: UUID) async {
        loadingPatientId = patientId
        do {
            // 先全部取回本地变量，再一次性提交。逐项直接赋值的话，成员切换会让
            // 甲的药箱和乙的急救卡同时出现在界面上（跨成员脏读，BR-001 成员隔离）。
            let inventory = try await meds.inventorySummary(patientId: patientId, now: Date())
            let candidates = try await emergency.candidates(patientId: patientId)
            let selected = try await emergency.selected(patientId: patientId)
            let selectedIds = Set((selected.allergies + selected.medications
                                   + selected.healthProblems + selected.contacts).map(\.id))
            let blood = try await emergency.bloodType(patientId: patientId)
            let immunizations = try await self.immunizations.list(patientId: patientId)
            let claimList = try await claims.list(patientId: patientId)
            let totals = try await claims.totals(patientId: patientId)
            let sent = try await messages.list(patientId: patientId)
            let entries = try await guidelines.all()
            let alerts = try await guidelines.history(patientId: patientId)

            // 晚到的旧成员结果一律丢弃（切换成员会取消 .task，但飞行中的调用仍会返回）
            guard loadingPatientId == patientId else { return }
            inventoryItems = inventory
            emergencyCandidates = candidates
            emergencySelected = selected
            emergencySelectedIds = selectedIds
            bloodType = blood
            immunizationRecords = immunizations
            claimRows = claimList
            claimTotals = totals
            sentMessages = sent
            guidelineEntries = entries
            alertEvents = alerts
        } catch {
            logger.error("M2 装配加载失败: \(error)")
        }
    }

    // MARK: - 药箱

    func reconcileLot(item: MedicationStore.InventorySummaryItem, physicalCount: Double) async {
        do {
            try await meds.reconcileLot(lotId: item.lotId, physicalCount: physicalCount, at: Date())
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
