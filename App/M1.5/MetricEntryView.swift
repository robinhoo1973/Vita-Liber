import SwiftUI
import Domain
import Infrastructure

// MARK: - FR7.5 自测指标两步录入（SP-13 快速录入 · ui-ux §5.13）

/// 两步：类型宫格（血压/血糖/体重/体温/心率/血氧 + 记忆上次高亮）
/// → 数字面板（单位记忆、测量时间默认现在）→ 保存即入趋势。
/// 血压双值联排键位：收缩压输完自动跳格舒张压。
/// 保存成功 Toast 附带「查看趋势」快捷链；空态引导语强调「自测数据仅作观察记录」。
struct MetricQuickEntryView: View {
    @Environment(AppState.self) private var app
    @Environment(TrendEntryState.self) private var state
    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss

    @State private var step = 1
    @State private var metric = MetricType.glucose
    @State private var primaryText = ""
    @State private var secondaryText = ""
    @State private var unitText = ""
    @State private var measuredAt = Date()
    @State private var saved = false
    @FocusState private var focusField: Bool

    private let metrics: [MetricType] = [.bloodPressureSys, .glucose, .weight,
                                         .heartRate, .bloodOxygen]

    var body: some View {
        NavigationStack {
            Form {
                if step == 1 {
                    Section {
                        // 类型宫格（FR7.5 预设 + 记忆上次选择——本入口默认高亮当前 metric）
                        ForEach(metrics, id: \.rawValue) { m in
                            Button {
                                metric = m
                            } label: {
                                HStack {
                                    Text(L10n.metricName(m))
                                    Spacer()
                                    if metric == m {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(Color("brand-primary", bundle: .main))
                                    }
                                }
                            }
                        }
                    } header: {
                        Text(L10n.metricStep1)
                    } footer: {
                        Text(L10n.metricSelfMeasureNote)
                    }
                } else {
                    Section(L10n.metricStep2) {
                        if metric == .bloodPressureSys {
                            // 血压双值联排：收缩压输完自动跳格舒张压（FR7.5 §5.13）
                            HStack {
                                TextField(L10n.metricSys, text: $primaryText)
                                    .keyboardType(.decimalPad)
                                    .onChange(of: primaryText) { _, v in
                                        if v.count >= 3 { focusField = true }
                                    }
                                Text("/")
                                TextField(L10n.metricDia, text: $secondaryText)
                                    .keyboardType(.decimalPad)
                                    .focused($focusField)
                            }
                        } else {
                            TextField(L10n.metricValue, text: $primaryText)
                                .keyboardType(.decimalPad)
                        }
                        TextField(L10n.metricUnit, text: $unitText)
                        DatePicker(L10n.metricMeasuredAt, selection: $measuredAt, in: ...Date())
                    }
                }
            }
            .navigationTitle(L10n.metricEntryTitle)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.commonCancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if step == 1 {
                        Button(L10n.allergyNext) { step = 2 }
                    } else {
                        Button(L10n.reminder_save) { save() }
                            .disabled(primaryText.isEmpty)
                            .accessibilityIdentifier("SP-13.metric.save")
                    }
                }
            }
            .alert(L10n.metricSaved, isPresented: $saved) {
                Button(L10n.metricViewTrend) {
                    router.navigate(to: .trendChart(patientId: app.currentPatientId,
                                                    metric: metric.rawValue))
                    dismiss()
                }
                Button(L10n.onboard_gotIt, role: .cancel) { dismiss() }
            }
            .onAppear {
                // 单位记忆（FR7.8：每种指标记忆上次单位）
                unitText = state.rememberedUnit(for: metric)
            }
            .onChange(of: metric) { _, newMetric in
                unitText = state.rememberedUnit(for: newMetric)
            }
        }
    }

    private func save() {
        guard let value = Double(primaryText) else { return }
        let secondary = secondaryText.isEmpty ? nil : Double(secondaryText)
        let unit = unitText.isEmpty ? "1" : unitText
        Task {
            await state.addSample(patientId: app.currentPatientId, metric: metric,
                                  value: value, secondaryValue: secondary, unit: unit,
                                  measuredAt: measuredAt)
            saved = true
        }
    }
}

// MARK: - FR7.5/7.8 TrendEntryState 扩展（录入 + 单位记忆 + 排除接线）

extension TrendEntryState {
    /// FR7.8 每种指标记忆上次单位（UserDefaults 键由本扩展承载；键登记于 AppSettings 语义之外）
    func rememberedUnit(for metric: MetricType) -> String {
        UserDefaults.standard.string(forKey: "metric.unit.\(metric.rawValue)") ?? ""
    }

    private func rememberUnit(_ unit: String, for metric: MetricType) {
        UserDefaults.standard.set(unit, forKey: "metric.unit.\(metric.rawValue)")
    }

    /// FR7.5 自测两步录入落库（C 级 + selfMeasured 标志）
    func addSample(patientId: UUID, metric: MetricType, value: Double,
                   secondaryValue: Double?, unit: String, measuredAt: Date) async {
        do {
            _ = try await store.addSample(patientId: patientId, metric: metric, value: value,
                                          secondaryValue: secondaryValue, unit: unit,
                                          measuredAt: measuredAt)
            rememberUnit(unit, for: metric)
            await load(patientId: patientId)
        } catch {
            // 失败保留输入可重试（错误经调用侧呈现）
        }
    }

    /// FR7.4 排除/恢复（软删语义；App 层接线——此前挂载点不传 onToggleExcluded）
    func toggleExcluded(_ point: TrendPoint, patientId: UUID) async {
        do {
            try await store.setExcluded(point.id, patientId: patientId, excluded: !point.excluded)
            await load(patientId: patientId)
        } catch {
            // 同上
        }
    }
}
