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
    @State private var confirmSet: OcrConfirmationSet?
    @State private var entryError: String?
    @State private var routeMonitor = AudioRouteMonitor()
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
                        // 语音录入（举一反三修复：指标速记面板「指标」chip 进入后
                        // 原本只能手输——接入听写 + 统一确认模板，与观察/提醒同路径）
                        VoiceDictationButton { text, _ in
                            let drafts = VoiceStructuringEngine.extractMetric(
                                text, rules: VoiceGrammarDefaults.metricRules)
                            confirmSet = VoiceInputTemplate.confirmationSet(drafts: drafts)
                        }
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
            // 解析失败/写失败可见反馈（FR7.5：绝不静默丢弃读数）
            .alert(L10n.metricEntryErrorTitle,
                   isPresented: Binding(get: { entryError != nil },
                                        set: { if !$0 { entryError = nil } })) {
                Button(L10n.onboard_gotIt, role: .cancel) { entryError = nil }
            } message: {
                Text(entryError ?? "")
            }
            .onAppear {
                // 单位记忆（FR7.8：每种指标记忆上次单位）
                unitText = state.rememberedUnit(for: metric)
                routeMonitor.start()
            }
            .onChange(of: metric) { _, newMetric in
                unitText = state.rememberedUnit(for: newMetric)
            }
            .onDisappear { routeMonitor.stop() }
            // FR17.13-entry：指标语音草稿 —— 统一确认模板，不自建确认逻辑
            .sheet(item: $confirmSet) { set in
                VoiceConfirmSheet(
                    set: set,
                    decision: ReadbackPolicy.decide(route: routeMonitor.route,
                                                    preference: app.readbackPreference,
                                                    careMode: app.careMode),
                    onSpeak: { app.speak($0) },
                    onConfirm: { confirmed in
                        applyConfirmed(confirmed)
                        confirmSet = nil
                    },
                    onRetry: { confirmSet = nil },
                    onCancel: { confirmSet = nil })
                .presentationDetents([.medium])
            }
        }
    }

    /// 确认后的指标字段 → 录入框（血压双值分别落收缩压/舒张压）
    private func applyConfirmed(_ set: OcrConfirmationSet) {
        let fields = set.confirmedFields
        if let sys = fields.first(where: { $0.key == "blood_pressure_sys" })?.value {
            primaryText = sys
            if let dia = fields.first(where: { $0.key == "blood_pressure_dia" })?.value {
                secondaryText = dia
            }
        } else if let v = fields.first(where: { $0.key != "title" && !$0.value.isEmpty })?.value {
            primaryText = v
        }
    }

    private func save() {
        // 审查修复：逗号小数点（部分区域 decimalPad 产出）归一后解析；
        // 解析失败必须可见反馈，绝不静默丢弃读数
        guard let value = Double(primaryText.replacingOccurrences(of: ",", with: ".")) else {
            entryError = L10n.metricInvalidValue
            return
        }
        let secondary = secondaryText.isEmpty ? nil
            : Double(secondaryText.replacingOccurrences(of: ",", with: "."))
        let unit = unitText.isEmpty ? "1" : unitText
        Task {
            let ok = await state.addSample(patientId: app.currentPatientId, metric: metric,
                                           value: value, secondaryValue: secondary, unit: unit,
                                           measuredAt: measuredAt)
            if ok {
                saved = true
            } else {
                // 写失败：保留输入，可见错误（FR7.5 绝不假装保存成功）
                entryError = L10n.metricSaveFailed
            }
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

    /// FR7.5 自测两步录入落库（C 级 + selfMeasured 标志）。
    /// 返回是否成功——审查修复：原实现吞掉 store 错误且调用方无条件弹
    /// 「保存成功」，写失败时用户以为已记录、健康读数静默丢失。
    @discardableResult
    func addSample(patientId: UUID, metric: MetricType, value: Double,
                   secondaryValue: Double?, unit: String, measuredAt: Date) async -> Bool {
        do {
            _ = try await store.addSample(patientId: patientId, metric: metric, value: value,
                                          secondaryValue: secondaryValue, unit: unit,
                                          measuredAt: measuredAt)
            rememberUnit(unit, for: metric)
            await load(patientId: patientId)
            return true
        } catch {
            // 失败保留输入可重试（错误经调用侧呈现）
            return false
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
