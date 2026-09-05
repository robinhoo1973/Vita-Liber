import SwiftUI
import Domain
import Infrastructure

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
        // Group 承载修饰器：if/else 分支并集上直接挂 .toolbar 有类型歧义
        // （CI「no exact matches in call to instance method 'toolbar'」，
        // 与 RootAdaptiveView 同族）
        Group {
            if items.isEmpty {
                ContentUnavailableView(L10n.inventory_empty, systemImage: "pills",
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

/// 续药档位徽章：≤7 天卡片 / ≤3 天通知 / 当日置顶（FR9.8.3）
struct RefillBadge: View {
    let tier: InventoryRules.RefillTier

    var body: some View {
        Text(label)
            .font(.caption2).bold()
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(Color("surface-tint-start", bundle: .main)))
            .foregroundStyle(Color("brand-primary", bundle: .main))
            .accessibilityLabel(label)
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

    /// 滑杆 step:1 只能产出整数，账面可能是半片（4.5）——用精确 == 判「与账面一致」
    /// 会让这类批次永远显示差异、永远多一步确认。按半个最小单位容差判等。
    private var isEqualToBook: Bool { abs(difference) < 0.5 }

    var body: some View {
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

// MARK: - 消耗差异月报（FR9.8.5）

/// 纯事实句式由 Domain 唯一产出；本页只呈现 + 过期负清单的 UI 兜底
/// （若 statement 违规则不渲染——负清单一票否决，不展示比展示错误更安全）。
struct InventoryMonthlyReportView: View {
    let report: InventoryMonthlyReport

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.inventoryMonthlySuffix(report.periodStart.formatted(.dateTime.month(.wide).year()))).font(.headline)
            if InventoryReportRules.violation(in: report.statement) != nil {
                // 一票否决路径：违反负清单的文案不得上屏（BR-006 延伸）
                Text(L10n.inventory_reportBlocked)
                    .foregroundStyle(Color("grade-d", bundle: .main))
                    .accessibilityIdentifier("FR9.8.report.blocked")
            } else {
                Text(report.statement)
                    .font(.title3)
                    .accessibilityIdentifier("FR9.8.report.statement")
                Text(L10n.inventory_reportFact)
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
        .navigationTitle(L10n.inventory_reportTitle)
    }
}
