import Foundation
import Domain
import Infrastructure

/// FR2.1 统一提醒聚合中心数据装配（App 层映射器，tech §5.33）：
/// 各源仓投影 → [AggregatedReminderItem] → 交 `ReminderAggregationCenter.aggregate`
/// （Domain 纯函数）统一去重/窗口/置顶/压缩/排序。本文件只做**映射**，
/// 不做业务判定（判定全部在 Domain）。
///
/// **分级纪律（FR16.2 / data-flow §4.4 双流裁决，2026-09-09 协调方约束）**：
/// - 每笔导入读数**不是卡片**：只有跨持续性门槛的 L1+ 才是证据卡入口
///   （级别徽章 + 置顶 + 点击进 SP-30 五段证据卡）；小时聚合只进趋势
///   （metric_sample），不进本列表。
/// - L0 读数事件 = 应用内软提示（弱化行 + 「观察记录」注记，绝不弹通知），
///   severity 经 `status` 字段透传（"L0"/"L1"/"L2"/"L3"），行渲染按此分流。
/// - 聚合中心不做任何生成式解释（ADR-010），行文案全部为源事实标题。
enum ReminderHubLoader {

    /// 用药时段（今日待办）→ 周期计划压缩源。planID 从剂量通知 ID
    /// （dose-{planId}-{epochSlot}，DoseSlot 身份契约）提取，供
    /// ReminderAggregationCenter 按 (planID, window) 压缩。
    static func doseItems(_ slots: [DoseSlot], memberId: UUID) -> [AggregatedReminderItem] {
        slots.map { slot in
            let meds = slot.records.map { $0.medicationName ?? $0.dose.notifyId }.joined(separator: "、")
            return AggregatedReminderItem(
                id: .init(kind: "dose_slot", sourceId: slot.id),
                aggregationKind: .medication,
                occurredAt: slot.anchorTime,
                title: meds.isEmpty ? L10n.homeDoseSlot : meds,
                patientID: memberId,
                priority: slot.allTaken ? 0 : 1,
                routeKey: "reminderToday",
                planID: slot.records.first.flatMap { planId(fromNotifyId: $0.dose.notifyId ?? "") })
        }
    }

    /// 预约（未来窗口）→ appointment 类别。
    static func appointmentItems(_ rows: [AppointmentRow], memberId: UUID) -> [AggregatedReminderItem] {
        rows.map { row in
            AggregatedReminderItem(
                id: .init(kind: "appointment", sourceId: row.id.uuidString),
                aggregationKind: .appointment,
                occurredAt: row.startsAt,
                title: "\(row.hospital)·\(row.department)",
                patientID: memberId,
                routeKey: "appointmentList")
        }
    }

    /// 库存：续药（安全线 t14/t7/t3 已在仓侧判定，此处仅映射）与批次补录待办。
    static func inventoryItems(_ items: [MedicationStore.InventorySummaryItem],
                               memberId: UUID) -> [AggregatedReminderItem] {
        items.compactMap { item in
            if item.refillTier != nil {
                return AggregatedReminderItem(
                    id: .init(kind: "refill", sourceId: item.lotId.uuidString),
                    aggregationKind: .medication,
                    occurredAt: Date(),
                    title: L10n.homeExpiryMed(item.medicationName),
                    patientID: memberId,
                    routeKey: "medicationCabinet",
                    planID: nil)
            }
            if item.expireAt == nil || (item.storageNote ?? "").isEmpty {
                return AggregatedReminderItem(
                    id: .init(kind: "stock_backlog", sourceId: item.lotId.uuidString),
                    aggregationKind: .medication,
                    occurredAt: Date(),
                    title: L10n.homeStockBacklog(item.medicationName),
                    patientID: memberId,
                    routeKey: "medicationCabinet",
                    planID: nil)
            }
            return nil
        }
    }

    /// alert_event 分级映射（FR16.2 双流裁决）：L0 = 软提示行（priority 0，
    /// status "L0"，不置顶不通知）；L1+ = 证据卡入口（priority 2 置顶，
    /// status 级别徽章，点击 SP-30）。每笔读数本身不在此列。
    static func alertItems(_ events: [GuidelineStore.AlertEvent],
                           memberId: UUID) -> [AggregatedReminderItem] {
        events.compactMap { event in
            guard event.patientId == memberId, event.qualified, event.severity != .L0 else { return nil }
            let severity = event.severity
            let pinned = severity != .L0
            return AggregatedReminderItem(
                id: .init(kind: "alert_event", sourceId: event.id.uuidString),
                aggregationKind: .alert,
                occurredAt: event.createdAt,
                title: event.card.summaryTitle ?? severity.rawValue,
                patientID: memberId,
                priority: pinned ? 2 : 0,
                status: severity.rawValue,
                routeKey: "alertEvidence")
        }
    }

    /// 待确认 OCR（BR-003 催办）：逾期（PendingOcrRules，Domain 单一出口）
    /// 置顶 priority 2；未逾期常规展示。点击进 SP-53 待确认队列。
    static func ocrItems(_ docs: [DocumentStore.DocumentRow], memberId: UUID) -> [AggregatedReminderItem] {
        docs.filter(\.isPendingConfirmation).map { doc in
            AggregatedReminderItem(
                id: .init(kind: "ocr", sourceId: doc.id.uuidString),
                aggregationKind: .ocr,
                occurredAt: doc.createdAt,
                title: L10n.homePendingOcrCount(1),
                patientID: memberId,
                priority: PendingOcrRules.isOverdue(createdAt: doc.createdAt) ? 2 : 0,
                routeKey: "pendingOcrQueue")
        }
    }

    /// 系统类（期一单一来源）：档案完善提示（注册补全）。
    /// 通知中心铃铛/横幅走既有 ReminderStore 链路，不在此重复投影。
    static func systemItems(done: Int, total: Int, memberId: UUID) -> [AggregatedReminderItem] {
        guard done < total else { return [] }
        return [AggregatedReminderItem(
            id: .init(kind: "profile_progress", sourceId: "profile"),
            aggregationKind: .system,
            occurredAt: Date(),
            title: L10n.homeProfileProgressTitle,
            patientID: memberId,
            routeKey: "voiceGuideProfile")]
    }

    /// notifyId（dose-{planId}-{epochSlot}）→ planId；解析失败返回 nil
    /// （该条目不参与周期压缩，仍正常展示——压缩是密度优化不是正确性前提）。
    static func planId(fromNotifyId notifyId: String) -> String? {
        let parts = notifyId.split(separator: "-")
        guard parts.count >= 2, parts[0] == "dose" else { return nil }
        return String(parts[1])
    }
}
