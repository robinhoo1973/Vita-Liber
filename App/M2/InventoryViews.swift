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

    var body: some View {
        if items.isEmpty {
            ContentUnavailableView("药箱还没有记录", systemImage: "pills",
                                   description: Text("创建用药计划或补充批次后，余量与效期会出现在这里"))
                .accessibilityIdentifier("FR9.8.inventory.empty")
        } else {
            List(items, id: \.lotId) { item in
                InventoryRow(item: item, onReconcile: onReconcile)
                    .accessibilityIdentifier("FR9.8.inventory.row")
            }
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
                Text("约剩 \(days) 天 · 按计划估算")
                    .font(.subheadline)
                    .accessibilityIdentifier("FR9.8.inventory.approxDays")
            } else {
                Text("无进行中的用药计划，无法估算剩余天数")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("安全线 \(item.remainingPlanUnits, specifier: "%g") \(item.unitKind) · 确认 \(item.remainingConfirmedUnits, specifier: "%g") \(item.unitKind)")
                .font(.caption2).foregroundStyle(.secondary)
            if let expireAt = item.expireAt {
                Text("效期 \(expireAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            // 余量行常驻「修正为 X」校正入口（FR9.8.7）
            if let onReconcile {
                Button {
                    onReconcile(item)
                } label: {
                    HStack(spacing: 4) {
                        VLIcon.edit.resizable().frame(width: 16, height: 16)
                        Text("修正余量")
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
        case .t14: return "余量 ≤14 天"
        case .t7:  return "余量 ≤7 天"
        case .t3:  return "余量 ≤3 天"
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

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("修正 \(item.medicationName) 余量").font(.headline)
            Text("账面：\(item.remainingConfirmedUnits, specifier: "%g") \(item.unitKind)（确认线）")
                .font(.caption).foregroundStyle(.secondary)
            Slider(value: $count,
                   in: 0...max(item.remainingConfirmedUnits * 1.5, 1),
                   step: 1)
                .accessibilityIdentifier("FR9.8.reconcile.slider")
            HStack {
                Text("实物 \(count, specifier: "%g") \(item.unitKind)").monospacedDigit()
                Spacer()
                Text(difference == 0 ? "与账面一致" :
                     difference > 0 ? "比账面多 \(difference, specifier: "%g")" :
                     "比账面少 \(-difference, specifier: "%g")")
                    .foregroundStyle(difference == 0 ? .secondary : Color("grade-d", bundle: .main))
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("FR9.8.reconcile.difference")
            // 归真必须经确认（FR9.8.5）：差异非零时先显式确认一步
            if difference != 0 && !confirmVisible {
                Button("确认修正为 \(count, specifier: "%g") \(item.unitKind)") {
                    confirmVisible = true
                }
                .buttonStyle(.borderedProminent)
                .frame(minHeight: 44)
                .accessibilityIdentifier("FR9.8.reconcile.confirmStep")
            } else {
                HStack(spacing: 12) {
                    Button("取消") { dismiss() }.frame(minHeight: 44)
                    Button(difference == 0 ? "保存" : "确认并写入") {
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
            Text(report.periodStart.formatted(.dateTime.month(.wide).year())
                 + " 用药消耗").font(.headline)
            if InventoryReportRules.violation(in: report.statement) != nil {
                // 一票否决路径：违反负清单的文案不得上屏（BR-006 延伸）
                Text("月报生成异常，已拦截显示")
                    .foregroundStyle(Color("grade-d", bundle: .main))
                    .accessibilityIdentifier("FR9.8.report.blocked")
            } else {
                Text(report.statement)
                    .font(.title3)
                    .accessibilityIdentifier("FR9.8.report.statement")
                Text("本报告只呈现计划与确认次数的事实，不构成任何医疗评价。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
        .navigationTitle("消耗差异月报")
    }
}
