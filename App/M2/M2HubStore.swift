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
    private(set) var sentMessages: [SentMessage] = []
    // 信源库
    private(set) var guidelineEntries: [GuidelineEntry] = []

    private let meds: MedicationStore
    private let emergency: EmergencyCardStore
    private let immunizations: ImmunizationStore
    private let claims: ClaimStore
    private let messages: MessageDeliveryStore
    private let guidelines: GuidelineStore
    private let logger = Logger(subsystem: "com.vitaliber", category: "m2hub")

    init(meds: MedicationStore, emergency: EmergencyCardStore,
         immunizations: ImmunizationStore, claims: ClaimStore,
         messages: MessageDeliveryStore, guidelines: GuidelineStore) {
        self.meds = meds
        self.emergency = emergency
        self.immunizations = immunizations
        self.claims = claims
        self.messages = messages
        self.guidelines = guidelines
    }

    func load(patientId: UUID) async {
        do {
            inventoryItems = try await meds.inventorySummary(patientId: patientId, now: Date())
            emergencyCandidates = try await emergency.candidates(patientId: patientId)
            emergencySelected = try await emergency.selected(patientId: patientId)
            emergencySelectedIds = Set((emergencySelected.allergies + emergencySelected.medications
                                        + emergencySelected.healthProblems + emergencySelected.contacts)
                                        .map(\.id))
            bloodType = try await emergency.bloodType(patientId: patientId)
            immunizationRecords = try await immunizations.list(patientId: patientId)
            claimRows = try await claims.list(patientId: patientId)
            claimTotals = try await claims.totals(patientId: patientId)
            sentMessages = try await messages.list(patientId: patientId)
            guidelineEntries = try await guidelines.all()
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
}
