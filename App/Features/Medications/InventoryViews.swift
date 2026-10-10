import SwiftUI
import Domain
import Infrastructure
import Perception

/// F9.8 双轨库存全家桶 UI（M2）：
/// - 药箱总览：每批「约剩 N 天·按计划估算」（诚实性文案 FR9.8.7）+ 续药档位
/// - 盘点滑块（FR9.8.7 周盘点 30 秒流程）：归真必须经用户确认
/// - 消耗差异月报（FR9.8.5）：纯事实句式，负清单一票否决
///
/// 所有业务判定都在 Domain（`InventoryRules` / `InventoryReportRules`），
/// 本文件只渲染判定结果（tech-spec §1.1 规则 4）。

// MARK: - 药箱总览

struct InventoryListView: View {
    let items: [MedicationStore.InventorySummaryItem]
    var onReconcile: ((MedicationStore.InventorySummaryItem) -> Void)?
    var onExportDispenseList: (() -> Void)?

    var body: some View {
        WithPerceptionTracking {
            // Group 承载修饰器：if/else 分支并集上直接挂 .toolbar 有类型歧义
            // （CI「no exact matches in call to instance method 'toolbar'」，
            // 与 RootAdaptiveView 同族）
            Group {
                if items.isEmpty {
                    VLUnavailableView(L10n.inventory_empty, systemImage: "pills",
                                           description: Text(L10n.inventory_emptyHint))
                        .accessibilityIdentifier("FR9.8.inventory.empty")
                } else {
                    List(items) { item in
                        // SP-17：批次卡 → 详情页（编辑/盘点/废弃经详情页单宿主）
                        NavigationLink(value: AppRoute.stockLotDetail(item.lotId)) {
                            InventoryRow(item: item, onReconcile: onReconcile)
                        }
                        .accessibilityIdentifier("FR9.8.inventory.row")
                    }
                }
            }
            .toolbar {
                if let onExportDispenseList, !items.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        // FR13.8 配药清单单页导出：药品名/规格/当前余量——线下药店/复诊用
                        Button {
                            onExportDispenseList()
                        } label: {
                            Label(L10n.inventory_reportTitle, systemImage: "square.and.arrow.up").frame(minHeight: 44)
                        }
                        .accessibilityIdentifier("FR13.8.dispense.export")
                    }
                }
            }
        }
    }

    /// 把药箱摘要映射成配药清单行（纯数据映射，CSV 组装在 Domain DispenseListRules）
    func dispenseRows() -> [DispenseListRules.Row] {
        items.map { item in
            DispenseListRules.Row(name: item.medicationName, spec: item.spec,
                                  unitKind: item.unitKind,
                                  planUnits: item.remainingPlanUnits,
                                  confirmedUnits: item.remainingConfirmedUnits,
                                  expireAt: item.expireAt)
        }
    }
}

private struct InventoryRow: View {
    let item: MedicationStore.InventorySummaryItem
    var onReconcile: ((MedicationStore.InventorySummaryItem) -> Void)?

    var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(item.medicationName).font(.headline)
                    if let spec = item.spec {
                        Text(spec).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let tier = item.refillTier {
                        RefillBadge(tier: tier)
                    }
                }
                // FR9.8.7 诚实性文案：只写「约」，绝不给精确到小时的假象
                if let days = item.approxDaysLeft {
                    Text(L10n.inventoryApproxDays(days))
                        .font(.subheadline)
                        .accessibilityIdentifier("FR9.8.inventory.approxDays")
                } else {
                    Text(L10n.inventory_noPlanHint)
                        .font(.caption).foregroundStyle(.secondary)
                }
                // §4.11 InventoryBar 分段余量条（V3.72）：绿>50%/琥珀20-50%/红<20%
                InventoryBar(planUnits: item.remainingPlanUnits, confirmedUnits: item.remainingConfirmedUnits, unit: item.unitKind)
                Text(L10n.inventoryDualLine(MedicalNumberFormat.quantity(item.remainingPlanUnits), item.unitKind, MedicalNumberFormat.quantity(item.remainingConfirmedUnits)))
                    .font(.caption2).foregroundStyle(.secondary)
                if let expireAt = item.expireAt {
                    Text(L10n.inventoryExpiry(expireAt.formatted(date: .abbreviated, time: .omitted)))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                // 余量行常驻「修正为 X」校正入口（FR9.8.7）
                if let onReconcile {
                    Button {
                        onReconcile(item)
                    } label: {
                        HStack(spacing: 4) {
                            VLIcon.edit.resizable().frame(width: 16, height: 16)
                            Text(L10n.inventory_fixCount)
                        }
                        .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                    }
                    .accessibilityIdentifier("FR9.8.inventory.reconcile")
                }
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .contain)
        }
    }
}

/// 续药档位徽章：≤7 天卡片 / ≤3 天通知 / 当日置顶（FR9.8.3）
struct RefillBadge: View {
    let tier: InventoryRules.RefillTier

    var body: some View {
        WithPerceptionTracking {
            Text(label)
                .font(.caption2).bold()
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Capsule().fill(Color("surface-tint-start", bundle: .main)))
                .foregroundStyle(Color("brand-primary", bundle: .main))
                .accessibilityLabel(label)
        }
    }

    private var label: String {
        switch tier {
        case .t7:  return L10n.inventoryTier7
        case .t3:  return L10n.inventoryTier3
        case .t0:  return L10n.inventoryTier0
        }
    }
}

// MARK: - 盘点滑块（FR9.8.7 周盘点）

/// 拖到实际格数 → 确认，两轨同时重置为物理真值。差异非零必须确认后才写回。
struct InventoryReconcileSheet: View {
    let item: MedicationStore.InventorySummaryItem
    var onConfirm: ((Double) -> Void)
    @Environment(\.dismiss) private var dismiss

    @State private var count: Double = 0
    @State private var confirmVisible = false

    private var difference: Double { count - item.remainingConfirmedUnits }

    /// 审查修复（BR 规则下沉 Domain）：容差判等是 FR9.8.5 差异确认步骤的
    /// 业务规则，视图只消费 Domain 判定（架构规则 4——View 不得内联 BR）。
    private var isEqualToBook: Bool {
        InventoryRules.isEqualToBook(physical: count, confirmed: item.remainingConfirmedUnits)
    }

    var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 16) {
                Text(L10n.inventoryReconcileTitle(item.medicationName)).font(.headline)
                Text(L10n.inventoryBookValue(MedicalNumberFormat.quantity(item.remainingConfirmedUnits), item.unitKind))
                    .font(.caption).foregroundStyle(.secondary)
                Slider(value: $count,
                       in: 0...max(item.remainingConfirmedUnits * 1.5, 1),
                       step: 1)
                    .accessibilityIdentifier("FR9.8.reconcile.slider")
                HStack {
                    Text(L10n.inventoryPhysical(MedicalNumberFormat.quantity(count), item.unitKind)).monospacedDigit()
                    Spacer()
                    Text(isEqualToBook ? L10n.inventoryReconcileEqual :
                         difference > 0 ? L10n.inventoryReconcileMore(MedicalNumberFormat.quantity(difference)) :
                         L10n.inventoryReconcileLess(MedicalNumberFormat.quantity(-difference)))
                        .foregroundStyle(isEqualToBook ? .secondary : Color("grade-d", bundle: .main))
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("FR9.8.reconcile.difference")
                // 归真必须经确认（FR9.8.5）：差异非零时先显式确认一步
                if !isEqualToBook && !confirmVisible {
                    Button(L10n.inventoryReconcileConfirm(MedicalNumberFormat.quantity(count), item.unitKind)) {
                        confirmVisible = true
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("FR9.8.reconcile.confirmStep")
                } else {
                    HStack(spacing: 12) {
                        Button(L10n.commonCancel) { dismiss() }.frame(minHeight: 44)
                        Button(isEqualToBook ? L10n.commonSave : L10n.inventoryConfirmWrite) {
                            onConfirm(count)
                            dismiss()
                        }
                        .buttonStyle(.borderedProminent)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("FR9.8.reconcile.save")
                    }
                }
                Spacer()
            }
            .padding(20)
            .presentationDetents([.height(320)])
        }
    }
}

// MARK: - 消耗差异月报（FR9.8.5）

/// 纯事实句式由 Domain 唯一产出；本页只呈现 + 过期负清单的 UI 兜底
/// （若 statement 违规则不渲染——负清单一票否决，不展示比展示错误更安全）。
/// §4.11 InventoryBar（V3.72）：分段余量条——安全线占比三档着色
/// （绿 >50% / 琥珀 20-50% / 红 <20%），右侧「约剩 N 天 · 按计划估算」。
private struct InventoryBar: View {
    let planUnits: Double
    let confirmedUnits: Double
    let unit: String

    private var ratio: Double {
        guard confirmedUnits > 0 else { return 0 }
        return min(1, max(0, planUnits / confirmedUnits))
    }

    private var color: Color {
        switch ratio {
        case ..<0.2: return Color("semantic-danger", bundle: .main)
        case 0.2..<0.5: return Color("semantic-warning", bundle: .main)
        default: return Color("semantic-success", bundle: .main)
        }
    }

    var body: some View {
        WithPerceptionTracking {
            GeometryReader { geo in
                Capsule()
                    .fill(Color(.systemGray5))
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(color)
                            .frame(width: max(4, geo.size.width * ratio))
                    }
            }
            .frame(height: 6)
            // 2026-10-03 信息卡片评审 R1-2：原「余量约 X%」把双轨比（计划/确认）标成物理余量，
            // 语义错标（FR9.8.7 诚实性）。改复用 inventory.dualLine 双轨事实句（同屏下方可见行同句式）。
            .accessibilityLabel(L10n.inventoryDualLine(MedicalNumberFormat.quantity(planUnits), unit, MedicalNumberFormat.quantity(confirmedUnits)))
        }
    }
}

