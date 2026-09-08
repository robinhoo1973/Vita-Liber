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
                                         .temperature, .heartRate, .bloodOxygen]

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
                        VoiceDictationButton { text, confidence in
                            let drafts = VoiceStructuringEngine.extractMetric(
                                text, rules: VoiceGrammarDefaults.metricRules)
                            // 与指标总览同款兜底：抽取零命中回落原文草稿（确认卡
                            // 可编辑）——绝不让用户看到零字段空确认卡
                            confirmSet = VoiceInputTemplate.confirmationSet(
                                drafts: drafts.isEmpty
                                    ? [VoiceInputTemplate.fallbackDraft(value: text, confidence: confidence)]
                                    : drafts)
                        }
                        if metric == .bloodPressureSys {
                            // 血压双值联排：收缩压输完自动跳格舒张压（FR7.5 §5.13）
                            HStack {
                                TextField(L10n.metricSys, text: $primaryText)
                                    .keyboardType(.decimalPad)
                                    .onChange(of: primaryText) { _, v in
                                        // 输完自动跳格：三位数恒跳；两位数在构成真实
                                        // 收缩压值（≥60 mmHg，90-99 常见于低血压/老年
                                        // 用户）时也跳——此前 count>=3 规则对两位数
                                        // 永不跳格，须手动点舒张压框
                                        if v.count >= 3
                                            || (v.count >= 2 && (NumberNormalizer.parseDecimal(v) ?? 0) >= 60) {
                                            focusField = true
                                        }
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
            // 统一失败弹窗（设计系统 SaveFailedAlert——此前为视图内复制的
            // alert 三元组，全仓第七个表单入口已收敛至该修饰器）
            .saveFailedAlert(title: L10n.metricEntryErrorTitle,
                             hint: entryError ?? "",
                             isPresented: Binding(get: { entryError != nil },
                                                  set: { if !$0 { entryError = nil } }))
            .onAppear {
                // §5.13 记忆上次选择（V3.72）：此前恒为血糖，六类指标每次都要重选。
                // 键构造收敛 Domain SettingsRules（与单位记忆键同族单一事实源）
                if let last = UserDefaults.standard.string(forKey: SettingsRules.lastSelectedMetricKey),
                   let m = MetricType(rawValue: last) {
                    metric = m
                }
                // 单位记忆（FR7.8：每种指标记忆上次单位）
                unitText = state.rememberedUnit(for: metric)
                // FR17.9 面板确认草稿预填（类型化 pendingVoiceIntent 一次性投递）
                if let draft = router.pendingVoiceIntent {
                    router.pendingVoiceIntent = nil
                    applyDraft(draft.keyedValues)
                }
                routeMonitor.start()
            }
            .onChange(of: metric) { _, newMetric in
                unitText = state.rememberedUnit(for: newMetric)
                UserDefaults.standard.set(newMetric.rawValue, forKey: SettingsRules.lastSelectedMetricKey)
            }
            .onDisappear { routeMonitor.stop() }
            // FR17.13-entry：指标语音草稿 —— 统一确认模板，不自建确认逻辑
            .voiceConfirmSheet($confirmSet, route: routeMonitor.route) { confirmed in
                applyConfirmed(confirmed)
                confirmSet = nil
            }
        }
    }

    /// 确认后的指标字段 → 录入框（血压双值分别落收缩压/舒张压）；
    /// 键匹配走 MetricType(grammarKey:) Domain 单一映射（文法键词汇一处维护）。
    /// 与面板草稿预填（pendingVoiceDraft）共用同一映射——两入口语义一处维护。
    private func applyConfirmed(_ set: OcrConfirmationSet) {
        applyDraft(set.keyedValues)
    }

    private func applyDraft(_ map: [String: String]) {
        // 审查修复（错误轴落库）：此前只取数值、不改 metric——上一次用体温
        // 时语音说「血糖 5.6」会把 5.6 存成体温读数。草稿的 grammar 键
        // 必须同时选中对应指标类型（单位记忆随 onChange(of: metric) 刷新）。
        if let key = map.keys.first(where: { MetricType(grammarKey: $0) != nil }),
           let m = MetricType(grammarKey: key) {
            metric = m
        }
        if let sys = map.first(where: { MetricType(grammarKey: $0.key) == .bloodPressureSys })?.value {
            primaryText = sys
            if let dia = map.first(where: { MetricType(grammarKey: $0.key) == .bloodPressureDia })?.value {
                secondaryText = dia
            }
        } else if let v = map.first(where: { $0.key != "title" && !$0.value.isEmpty })?.value {
            primaryText = v
        }
    }

    private func save() {
        // 审查修复：逗号小数点（部分区域 decimalPad 产出）归一后解析；
        // 解析失败必须可见反馈，绝不静默丢弃读数。
        // 第八轮修复：解析经 Domain 单一出口 NumberNormalizer.parseDecimal
        guard let value = NumberNormalizer.parseDecimal(primaryText) else {
            entryError = L10n.metricInvalidValue
            return
        }
        // 舒张压非空但不可解析 → 响亮拒绝（FR7.5 绝不静默丢弃读数——
        // 此前解析失败退化为 nil，血压在用户不知情下只落收缩压）
        let secondary: Double?
        if secondaryText.isEmpty {
            secondary = nil
        } else {
            guard let v = NumberNormalizer.parseDecimal(secondaryText) else {
                entryError = L10n.metricInvalidValue
                return
            }
            secondary = v
        }
        // 无单位留空即可——此前 "1" 被存进库并在宫格大数字旁显示为单位「1」，
        // 且经单位记忆把「1」预填进下次录入
        let unit = unitText.trimmingCharacters(in: .whitespaces)
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
    /// FR7.8 每种指标记忆上次单位（键构造经 Domain SettingsRules 单一事实源
    /// ——第八轮修复：原视图层内联拼装键，第二设置通道与 AppSettings 脱钩）
    func rememberedUnit(for metric: MetricType) -> String {
        UserDefaults.standard.string(forKey: SettingsRules.rememberedUnitKey(for: metric.rawValue)) ?? ""
    }

    private func rememberUnit(_ unit: String, for metric: MetricType) {
        UserDefaults.standard.set(unit, forKey: SettingsRules.rememberedUnitKey(for: metric.rawValue))
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
            // 审查修复：此前 reload 走 load()（90 天血糖默认序列）——刚保存的
            // 血压根本不在该序列里，白查一整趟；改刷新指标总览最新点（宫格
            // 消费方），趋势详情页经自己的 .task(id:) 在进入时重载。
            // 经 refreshLatestIfCurrent（不重盖 loadingPatientId 标记）——
            // 写路径刷新若重盖标记，成员切换后新成员的加载结果会被误弃
            await refreshLatestIfCurrent(patientId: patientId)
            return true
        } catch {
            // 失败保留输入可重试（错误经调用侧呈现）
            return false
        }
    }

    /// FR7.4 排除/恢复（软删语义；App 层接线——此前挂载点不传 onToggleExcluded）。
    /// 排除后按 metricKey 重载**详情**序列——此前调用 load() 刷新的是 90 天
    /// 血糖默认序列，趋势详情页上排除动作后曲线纹丝不动。
    /// 经 refreshDetailIfCurrent（不重盖成员/指标标记，同 addSample 纪律）。
    func toggleExcluded(_ point: TrendPoint, patientId: UUID, metricKey: String) async {
        do {
            try await store.setExcluded(point.id, patientId: patientId, excluded: !point.excluded)
            await refreshDetailIfCurrent(patientId: patientId, metricKey: metricKey)
        } catch {
            // 失败保留原状可重试；软删失败无数据损失
        }
    }
}

// MARK: - §5.45 指标总览宫格数据（V3.72）

