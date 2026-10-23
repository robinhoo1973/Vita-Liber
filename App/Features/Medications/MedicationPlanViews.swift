import SwiftUI
import Domain
import Infrastructure
import Perception

// MARK: - FR9.15/SP-15 用药计划列表

/// 用药计划列表（SP-15 切片）：按状态分组（进行中/已暂停/已结束）。
/// 入口：提醒模块顶部；计划行点击进入详情（§5.26 生命周期操作）。
struct MedicationPlanListView: View {
    // v42（2026-10-23 业主裁决）：用药计划 = 时段模板，与药品解耦。
    // 列表/新建/编辑入口统一由 MedicationScheduleListView 承载；
    // 药品绑定行在各模板详情内展示（用药提醒）。
    var body: some View {
        MedicationScheduleListView()
    }
}

// MARK: - FR9.15/§5.9/§5.26 计划详情

/// 用药计划详情：头部（药名/规格/状态）+ 本周日程条（FR9.16 补记）+
/// 今日剂量队列 + 医嘱原文引用块 + 生命周期操作区 + 计划历史时间轴。
/// 系统不提供任何建议性措辞（BR-006）；结束用药必须用户显式操作并选填原因。
struct MedicationPlanDetailView: View {
    let planId: UUID
    @Environment(AppState.self) private var app
    @Environment(ReminderStore.self) private var reminders
    @State private var plan: MedicationStore.PlanRow?
    @State private var weekLog: [MedicationStore.DoseLogRow] = []
    @State private var history: [PlanLifecycleEvent] = []
    @State private var showEndConfirm = false
    @State private var showBackfill = false
    @State private var backfillTarget: Date?
    /// 瞬态读失败与真「不存在」分离：读失败呈现重试，不冒充「计划不存在」
    @State private var loadFailed = false

    var body: some View {
        WithPerceptionTracking {
            List {
                if let plan {
                    Section {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(plan.medicationName).font(.headline)
                                if let spec = plan.spec {
                                    Text(spec).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            PlanStatusBadge(status: plan.status)
                        }
                    }
                    .accessibilityIdentifier("SP-15.detail.header")

                    // FR9.16 日程条：本周七日格，已服实心✓/漏服空心!/未来灰
                    Section(L10n.planWeekStrip) {
                        WeekStrip(rows: weekLog) { row in
                            guard row.action == nil || row.action == .missed else { return }
                            backfillTarget = row.scheduledFor
                            showBackfill = true
                        }
                        .accessibilityIdentifier("SP-15.detail.week")
                    }

                    // 今日剂量队列（当前时段项放大高亮）
                    Section(L10n.planTodayDoses) {
                        ForEach(todayRows) { row in
                            HStack {
                                Text(row.scheduledFor.formatted(date: .omitted, time: .shortened))
                                    .font(.subheadline).monospacedDigit()
                                Spacer()
                                Text(actionLabel(row.action)).font(.caption)
                                    .foregroundStyle(actionColor(row.action))
                            }
                        }
                        if todayRows.isEmpty {
                            Text(L10n.planNoTodayDose).font(.caption).foregroundStyle(.secondary)
                        }
                    }

                    // 医嘱原文引用块（A/C 来源徽章；不可编辑）
                    if let advice = planAdviceText, !advice.isEmpty {
                        Section(L10n.planAdviceText) {
                            Text(advice)
                                .font(.body)
                                .padding(.leading, 8)
                                .overlay(alignment: .leading) {
                                    Rectangle().fill(Color("brand-primary", bundle: .main))
                                        .frame(width: 3)
                                }
                            Text(L10n.planAdviceSource)
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }

                    // §5.26 生命周期操作区（按钮随状态变化；拆子视图控制类型检查预算）
                    lifecycleSection(status: plan.status)

                    // FR9.15 计划历史时间轴（开始/调整/暂停/恢复/结束）
                    historySection()
                } else {
                    emptyState()
                }
            }
            .scrollContentBackground(.hidden)   // ui-ux §3.0 surface/tint：渐变画布透出
            .tintedCanvas()   // 渐变直挂本容器（根级背景会被 TabView/导航栈系统底色覆盖，V4.06 修正）
            .navigationTitle(L10n.planDetailTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if let plan {
                    ToolbarItem(placement: .topBarTrailing) {
                        // FR9.9 药品知识卡入口
                        NavigationLink {
                            MedicationKnowledgeCardView(plan: plan)
                        } label: {
                            Image(systemName: "info.circle")
                        }
                        .accessibilityIdentifier("SP-15.detail.knowledge")
                    }
                }
            }
            .confirmationDialog(L10n.planEndConfirmTitle, isPresented: $showEndConfirm, titleVisibility: .visible) {
                ForEach(PlanEndReason.allCases, id: \.rawValue) { reason in
                    Button(endReasonLabel(reason), role: .destructive) {
                        Task {
                            await reminders.endPlan(planId: planId, reason: reason,
                                                    patientId: app.currentPatientId)
                            await load()
                        }
                    }
                }
                Button(L10n.commonCancel, role: .cancel) { }
            } message: {
                Text(L10n.planEndConfirmBody)
            }
            .sheet(isPresented: $showBackfill, onDismiss: {
                // 审查修复：补记后重载——原 dismiss 无回调，漏服格继续显示「!」
                Task { await load() }
            }) {
                if let target = backfillTarget, let plan {
                    BackfillSheet(plan: plan, targetTime: target)
                }
            }
            .task(id: planId) { await load() }
            .onChangeCompat(of: app.currentPatientId) { _, _ in
                Task { await load() }
            }
        }
    }

    /// §5.26 生命周期操作区（按钮随状态变化；拆子视图控制类型检查预算——
    /// CI 实测 189 行类型检查超时，收敛表达式体量）
    @ViewBuilder
    private func lifecycleSection(status: String) -> some View {
        Section {
            switch status {
            case "active":
                Button(L10n.planPause) {
                    // 审查修复：操作后重载本地 @State——原实现写库不重载，
                    // 状态徽标/按钮停留在旧态（可重复提交同一操作）
                    Task {
                        await reminders.pausePlan(planId: planId, patientId: app.currentPatientId)
                        await load()
                    }
                }
                .accessibilityIdentifier("SP-15.detail.pause")
                Button(L10n.planEnd, role: .destructive) {
                    showEndConfirm = true
                }
                .accessibilityIdentifier("SP-15.detail.end")
            case "paused":
                Button(L10n.planResume) {
                    Task {
                        await reminders.resumePlan(planId: planId, patientId: app.currentPatientId)
                        await load()
                    }
                }
                .accessibilityIdentifier("SP-15.detail.resume")
                Button(L10n.planEnd, role: .destructive) {
                    showEndConfirm = true
                }
            default:
                Text(L10n.planEndedNote).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// FR9.15 计划历史时间轴（拆子视图控制类型检查预算）
    @ViewBuilder
    private func historySection() -> some View {
        if !history.isEmpty {
            Section(L10n.planHistory) {
                ForEach(history) { event in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: eventIcon(event.kind))
                            .foregroundStyle(Color("brand-primary", bundle: .main))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(eventLabel(event)).font(.caption)
                            if let note = event.note, !note.isEmpty {
                                Text(note)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Text(event.at.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
    }

    /// 加载失败/不存在两态分离（拆子视图控制类型检查预算）
    @ViewBuilder
    private func emptyState() -> some View {
        if loadFailed {
            // title+systemImage 便捷构造器无 actions 重载——按钮须走 label/actions 闭包形式
            VLUnavailableView {
                Label(L10n.planLoadFailed, systemImage: "arrow.clockwise.circle")
            } actions: {
                Button(L10n.retry) {
                    Task { await load() }
                }
                .buttonStyle(.borderedProminent)
                .frame(minHeight: 44)   // 触点≥44pt（设计系统）
            }
        } else {
            VLUnavailableView(L10n.planNotFound, systemImage: "pills")
        }
    }

    private var todayRows: [MedicationStore.DoseLogRow] {
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        // 第八轮修复：日界统一经 DayArithmetic 出口（DST 纪律单一事实源）
        let end = DayArithmetic.offset(days: 1, from: start, calendar: cal)
        return weekLog.filter { $0.scheduledFor >= start && $0.scheduledFor < end }
    }

    private var planAdviceText: String? {
        nil   // 医嘱原文来自 prescription 表（Phase 3 就诊/处方联合查询挂接）
    }

    private func load() async {
        do {
            let fetched = try await reminders.plan(id: planId)
            // 真不存在（已删除）→ 「计划不存在」；取回成功才继续副表
            guard let fetched else {
                plan = nil
                loadFailed = false
                return
            }
            plan = fetched
            loadFailed = false
            history = try await reminders.lifecycleEvents(planId: planId)
            let cal = Calendar.current
            // DST 纪律：日历加一天，禁止固定 86400 秒（切换日 ±1 小时漂移）
            // 第八轮修复：统一经 DayArithmetic 出口
            let weekStart = DayArithmetic.offset(days: -6,
                                                 from: cal.startOfDay(for: Date()),
                                                 calendar: cal)
            let weekEnd = DayArithmetic.offset(days: 7,
                                               from: cal.startOfDay(for: Date()),
                                               calendar: cal)
            weekLog = try await reminders.doseLog(planId: planId, from: weekStart,
                                                  to: weekEnd)
        } catch {
            // 瞬态读失败：清空并呈现重试态——不得把存在的计划渲染成
            // 「计划不存在」，也不得带着半载数据（history/weekLog 部分
            // 写入）冒充完整详情。plan 必须置 nil：loadFailed 只在
            // plan==nil 分支被读取，plan 残留时错误态永远不可见
            plan = nil
            loadFailed = true
        }
    }

    private func actionLabel(_ action: DoseUserAction?) -> String {
        switch action {
        case .taken: return L10n.planActionTaken
        case .skipped: return L10n.planActionSkipped
        case .missed: return L10n.planActionMissed
        case .discomfort: return L10n.planActionDiscomfort
        case .snoozed: return L10n.planActionSnoozed
        case nil: return L10n.planActionPending
        }
    }

    private func actionColor(_ action: DoseUserAction?) -> Color {
        switch action {
        case .taken: return Color("semantic-success", bundle: .main)
        case .missed, .discomfort: return Color("semantic-warning", bundle: .main)
        case .skipped, .snoozed: return .secondary
        case nil: return Color("brand-primary", bundle: .main)
        }
    }

    private func eventIcon(_ kind: PlanLifecycleEvent.Kind) -> String {
        switch kind {
        case .started: return "play.circle"
        case .edited: return "pencil.circle"
        case .paused: return "pause.circle"
        case .resumed: return "arrow.clockwise.circle"
        case .ended: return "stop.circle"
        }
    }

    private func eventLabel(_ event: PlanLifecycleEvent) -> String {
        switch event.kind {
        case .started: return L10n.planEventStarted
        case .edited: return L10n.planEventEdited
        case .paused: return L10n.planEventPaused
        case .resumed: return L10n.planEventResumed
        case .ended: return L10n.planEventEnded(endReasonLabelText(event.note))
        }
    }

    private func endReasonLabel(_ reason: PlanEndReason) -> String {
        switch reason {
        case .doctorInstruction: return L10n.planEndDoctor
        case .courseCompleted: return L10n.planEndCourse
        case .adverseReaction: return L10n.planEndAdverse
        case .noLongerNeeded: return L10n.planEndNoLonger
        case .other: return L10n.planEndOther
        }
    }

    private func endReasonLabelText(_ raw: String?) -> String {
        guard let raw, let reason = PlanEndReason(rawValue: raw) else { return "" }
        return endReasonLabel(reason)
    }
}

/// FR9.16 日程条：本周七日格。已服实心✓ / 漏服空心!（可点补记）/ 未来灰。
private struct WeekStrip: View {
    let rows: [MedicationStore.DoseLogRow]
    let onBackfill: (MedicationStore.DoseLogRow) -> Void

    var body: some View {
        WithPerceptionTracking {
            let cal = Calendar.current
            let today = cal.startOfDay(for: Date())
            // 日算术走 Domain DayArithmetic 单一出口（DST 漂移防护——Appointments/
            // Trends 已统一经此出口，裸 calendar.date(byAdding:) 是漏网第三处）
            let days = (0..<7).map { offset in
                DayArithmetic.offset(days: offset - 6, from: today, calendar: cal)
            }
            HStack(spacing: 6) {
                ForEach(days, id: \.self) { day in
                    let dayRows = rows.filter {
                        cal.isDate($0.scheduledFor, inSameDayAs: day)
                    }
                    // 日程条为「今日回溯 6 天」的尾随七日（days = today-6…today），
                    // 未来日从不渲染——FR9.16 未来灰门槛在此布局下不可达
                    // （此前加的 day > today 守卫与 future 参数为死代码）
                    Button {
                        // 漏服格可点补记（FR9.16）；已服格不可点
                        if let missed = dayRows.first(where: { $0.action == nil || $0.action == .missed }) {
                            onBackfill(missed)
                        }
                    } label: {
                        VStack(spacing: 4) {
                            Text(day.formatted(.dateTime.weekday(.narrow)))
                                .font(.caption2).foregroundStyle(.secondary)
                            Image(systemName: daySymbol(dayRows))
                                .font(.body)
                                .foregroundStyle(daySymbolColor(dayRows))
                            Text(day.formatted(.dateTime.day()))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 8)
                            .fill(cal.isDate(day, inSameDayAs: today)
                                  ? Color("brand-primary", bundle: .main).opacity(0.08)
                                  : Color.clear))
                    }
                    .buttonStyle(PressScaleButtonStyle())   // 按压反馈统一（§3.3 V4.05）
                }
            }
        }
    }

    /// 单日格三态（符号与颜色共用同一判定，此前两份同构条件各写一遍）
    private enum DayCellState { case empty, done, pending }

    /// 全部剂量已处理才 done（✓）——此前任一已服即 ✓，同日第二剂漏服被
    /// 掩藏（残留未确认剂量从日程条不可见）。「已处理」含 skipped（用户主动跳过
    /// 是终端态）；nil/snoozed/missed 为待处理 → 空心！
    /// 全仓审查 2026-09-18（F-A5-03）：snoozed 从「已处理」移出——「稍后」是挂起不是决议
    /// （Domain `DoseUserAction.isResolved` 单一口径）。
    private func dayState(_ rows: [MedicationStore.DoseLogRow]) -> DayCellState {
        if rows.isEmpty { return .empty }
        if rows.allSatisfy({ $0.action == .taken || $0.action == .discomfort || $0.action == .skipped }) {
            return .done
        }
        if rows.contains(where: { $0.action == nil || $0.action == .snoozed || $0.action == .missed }) {
            return .pending
        }
        return .empty
    }

    private func daySymbol(_ rows: [MedicationStore.DoseLogRow]) -> String {
        switch dayState(rows) {
        case .done: return "checkmark.circle.fill"
        case .pending: return "exclamationmark.circle"
        case .empty: return "minus"
        }
    }

    private func daySymbolColor(_ rows: [MedicationStore.DoseLogRow]) -> Color {
        switch dayState(rows) {
        case .done: return Color("semantic-success", bundle: .main)
        case .pending: return Color("semantic-warning", bundle: .main)
        case .empty: return Color(.systemGray3)
        }
    }
}

/// FR9.16 补记 Sheet：实际时间选择器（默认当前，可改）→ 落库后如实呈现
private struct BackfillSheet: View {
    let plan: MedicationStore.PlanRow
    let targetTime: Date
    @Environment(ReminderStore.self) private var reminders
    @Environment(\.dismiss) private var dismiss
    // 第九轮审查修复：`targetTime` 此前是死参数（声明后从未读取）——实际服药
    // 时间默认恒为 Date()，补记几天前的漏服格时 actualTime=now，窄窗（±30min）
    // 与宽窗（±12h）都够不到那剂 missed 行 → 走 INSERT 新行按 taken 全额扣双轨
    // （计划轨已被 materializeMissed 扣过 = 双扣），原 missed 行保持不消（补记后
    // 「!」仍在）。默认值改为所点剂量的 scheduledFor（可继续手改）；上界仍
    // `...Date()`，故取 min。
    @State private var actualTime: Date

    init(plan: MedicationStore.PlanRow, targetTime: Date) {
        self.plan = plan
        self.targetTime = targetTime
        _actualTime = State(initialValue: min(targetTime, Date()))
    }

    var body: some View {
        WithPerceptionTracking {
            NavigationStack {
                Form {
                    DatePicker(L10n.planBackfillActualTime, selection: $actualTime, in: ...Date())
                    // 单剂基线缺失：响亮拒绝——此前 ?? 1 静默按 1.0/次扣账
                    // （「半片」医嘱被安全线按整片扣减，续药档位失准）
                    if plan.dosePlanUnits == nil {
                        Section {
                            Label(L10n.planBackfillNoBaseline, systemImage: "exclamationmark.triangle")
                                .font(.footnote)
                                .foregroundStyle(Color("semantic-warning", bundle: .main))
                        }
                    }
                }
                .navigationTitle(L10n.planBackfillTitle)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L10n.reminder_save) {
                            Task {
                                guard let units = plan.dosePlanUnits else { return }
                                await reminders.backfillTaken(
                                    planId: plan.id, patientId: plan.patientId,
                                    medicationId: plan.medicationId,
                                    actualTime: actualTime,
                                    doseUnits: units)
                                dismiss()
                            }
                        }
                        .disabled(plan.dosePlanUnits == nil)
                        .accessibilityIdentifier("SP-15.detail.backfill.save")
                    }
                }
            }
            .presentationDetents([.height(220)])
        }
    }
}

// MARK: - FR9.1-9.3 计划创建表单（处方字段全集 + 初始批次 FR9.10）

/// 用药计划创建表单：药名/商品名/规格/单次剂量/每日次数/给药方式/餐食关系/
/// 疗程起止/医院医生/医嘱原文 + 调度选择 + 初始批次（必询效期与存储位置，
/// 未知进待办队列不阻塞保存）。
/// 保存经 MedicationPlanComposer 五表原子创建（BR-003：手工来源默认全确认）。
struct MedicationPlanFormView: View {
    /// v42：从「用药计划」模板发起绑定时传入——时刻由模板提供，表单不再编辑时段
    /// （计划 = 时段，提醒 = 药品 × 计划）。
    var scheduleTemplate: MedicationScheduleStore.TemplateRow? = nil
    @Environment(AppState.self) private var app
    @Environment(ReminderStore.self) private var reminders
    @Environment(\.dismiss) private var dismiss

    @State private var genericName = ""
    @State private var brandName = ""
    @State private var spec = ""
    @State private var dosePerTake = ""
    @State private var saveFailed = false
    /// E③（收口批，FR9.19）：保存前的排程冲突提示（非阻断——[仍要保存] 继续）
    @State private var pendingConflicts: [DoseConflictRules.Conflict] = []
    @State private var conflictAcknowledged = false

    /// 第八轮全仓审查修复：非空但不可解析的剂量文本就地报错并禁用保存
    /// （响亮拒绝）——绝不静默落 NULL 后被安全线按 1.0/次扣账
    private var doseParseFailed: Bool {
        let trimmed = dosePerTake.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && DoseScheduleEngine.DoseInputParser.parse(trimmed) == nil
    }
    @State private var route = ""
    @State private var mealRelation = ""
    @State private var hospital = ""
    @State private var doctor = ""
    @State private var adviceText = ""
    @State private var isLongTerm = true
    @State private var isAsNeeded = false
    @State private var startDate = Date()
    @State private var endDate = DayArithmetic.offset(days: 30)
    @State private var hasEndDate = false
    /// FR9.4 服药时段（2026-10-23 业主指令）：默认早餐前一个时段；
    /// 用户勾选一天中的固定锚点时段，并可逐时段调整提醒时刻。
    @State private var selectedSlots: Set<DoseTimeSlot> = [.beforeBreakfast]
    @State private var slotTimeTexts: [DoseTimeSlot: String] = [:]
    /// 自由补充时刻（保留旧能力：时段之外的任意 HH:mm；逗号分隔）。
    @State private var customTimes = ""
    // FR9.10 初始批次
    @State private var lotUnits = 30.0
    @State private var lotUnitKind = "tablet"
    @State private var lotExpireDate = DayArithmetic.offset(days: 180)
    @State private var lotExpireUnknown = false
    @State private var storageNote = ""

    /// 选中时段按枚举顺序（起床 → 三餐 → 睡前）呈现；时刻排序在 times 内完成。
    private var selectedSlotList: [DoseTimeSlot] {
        DoseTimeSlot.allCases.filter { selectedSlots.contains($0) }
    }

    /// 时段 → 提醒时刻（用户覆盖优先；单一规则在 Domain，视图不复制）。
    private var slotTimes: [String] {
        DoseTimeSlotRules.times(selectedSlotList, overrides: slotTimeTexts)
    }

    /// 自由补充时刻的原文（保留空串项交给 allTimes 过滤；非法项由 save() 拒绝）。
    private var customTimeList: [String] {
        customTimes.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// 最终提醒时刻：时段 + 自定义，去重、丢弃非法项、按分钟升序。
    /// 时段侧已由 Domain `DoseTimeSlotRules.times` 完成覆盖/过滤/去重/排序；
    /// 此处只为并入自定义时刻再按分钟去重一次（去重口径与重复闸门一致）。
    private var allTimes: [String] {
        var seen = Set<Int>()
        return (slotTimes + customTimeList)
            .filter { DoseScheduleEngine.isValidTime($0) }
            .filter { seen.insert(DoseTimeSlotRules.minutes($0)).inserted }
            .sorted { DoseTimeSlotRules.minutes($0) < DoseTimeSlotRules.minutes($1) }
    }

    /// 时段自带餐食关系（FR9.4 token）；仅当所有选中时段关系一致时回填处方，
    /// 混合关系（如早餐前 + 晚餐后）不静默归并成一个串——逐时刻关系仍由
    /// `mealRelation(for:)` 在冲突检查中分别使用。
    private var derivedMealRelation: String? {
        // 审查修正（产品席）：原先 compactMap 丢掉 nil，使「起床后(nil) + 早餐前」
        // 被判为一致并回填 beforeBreakfast——但其中一剂并无餐食语义。
        // 只有全部时段都有且只有一个相同关系时才回填。
        let tokens = selectedSlotList.map(\.mealRelation)
        guard tokens.allSatisfy({ $0 != nil }), let first = tokens.first ?? nil else { return nil }
        return tokens.allSatisfy({ $0 == first }) ? first : nil
    }

    /// 绑定模板时以模板时刻为准；否则用表单时段。
    private var effectiveTimes: [String] {
        if let scheduleTemplate {
            return MedicationScheduleTemplateRules.normalize(scheduleTemplate.times)
        }
        return allTimes
    }

    /// 非按需计划至少需要一个时段/自定义时刻——禁止静默落 08:00 默认。
    private var missingScheduleTime: Bool {
        !isAsNeeded && effectiveTimes.isEmpty
    }

    /// 自定义时刻里的非法项（"8点"/"25:99"）——响亮拒绝，绝不静默丢弃后
    /// 让计划以零剂量建成（fixed 通道零剂量事故的同款闸门）。
    private var invalidCustomTime: Bool {
        !isAsNeeded && customTimeList.contains { !DoseScheduleEngine.isValidTime($0) }
    }

    /// 重复时刻（多个时段/自定义填了同一 HH:mm）。`allTimes` 去重后只排
    /// 一次剂量——用户选了 2 个时段却只得到 1 次/日且无任何提示（BR-004：
    /// 少提醒一次 = 少一次服药确认），因此保存前阻断并要求调整时刻。
    private var duplicateScheduleTimes: Bool {
        // 按需计划不生成任何剂量：时段重复不构成少提醒，不能误阻保存。
        guard !isAsNeeded else { return false }
        // 按分钟比较：`isValidTime` 接受 "8:30"，若按原始字符串去重，
        // "08:30" 与 "8:30" 会各排一剂（同一分钟两次提醒，审查修正）。
        // 非法自定义时刻返回 nil 被剔除——它们由 `invalidCustomTime` 单独报错，
        // 不能在这里塌缩成 0 分而误报「重复时刻」（审查修正）。
        let minutes = (selectedSlotList.map { slotTimeTexts[$0] ?? $0.defaultTime } + customTimeList)
            .compactMap { DoseScheduleEngine.minutes($0) }
        return Set(minutes).count != minutes.count
    }

    /// 排程冲突/处方记录使用的餐食关系：用户手填优先，空时取所选时段的 token。
    private var effectiveMealRelation: String? {
        mealRelation.isEmpty ? derivedMealRelation : mealRelation
    }

    var body: some View {
        WithPerceptionTracking {
            NavigationStack {
                Form {
                    Section(L10n.planFormMedication) {
                        TextField(L10n.planFormGenericName, text: $genericName)
                        TextField(L10n.planFormBrandName, text: $brandName)
                        TextField(L10n.planFormSpec, text: $spec)
                        TextField(L10n.planFormDosePerTake, text: $dosePerTake)
                        // 第八轮全仓审查修复（响亮拒绝）：非空但不可解析的剂量
                        // 文本（"1/2"/"半"曾可解析，反例 "abc"）就地报错并禁用
                        // 保存——绝不静默落 NULL 后被安全线按 1.0/次扣账
                        if doseParseFailed {
                            Text(L10n.planFormDoseParseError)
                                .font(.caption)
                                .foregroundStyle(Color("semantic-danger", bundle: .main))
                        }
                        TextField(L10n.planFormRoute, text: $route)
                        TextField(L10n.planFormMeal, text: $mealRelation)
                    }
                    // FR9.4（2026-10-23 业主）：按一天中的固定时段选择提醒时刻，
                    // 不再要求用户手输逗号分隔的 HH:mm。
                    Section {
                        // 按需计划不生成剂量：不呈现任何不生效的时段控件
                        // （诚实呈现；关闭按需后原选择仍在，恢复可见）。
                        if let scheduleTemplate {
                            // 时刻来自所选用药计划；此处只读呈现（与药品解耦）。
                            Text(scheduleTemplate.name ?? L10n.planScheduleUntitled)
                            Text(MedicationScheduleTemplateRules.summary(scheduleTemplate.times))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if !isAsNeeded {
                            ForEach(DoseTimeSlot.allCases, id: \.self) { slot in
                                HStack(spacing: 8) {
                                    Toggle(slot.localizedTitle, isOn: slotBinding(slot))
                                    if selectedSlots.contains(slot) {
                                        DatePicker("", selection: slotTimeBinding(slot),
                                                   displayedComponents: .hourAndMinute)
                                            .labelsHidden()
                                            .accessibilityLabel(L10n.planFormSlotTimeFmt(slot.localizedTitle))
                                    }
                                }
                                .accessibilityElement(children: .contain)
                                .accessibilityIdentifier("SP-15.form.slot.\(slot.rawValue)")
                            }
                            TextField(L10n.planFormFixedTimes, text: $customTimes)
                                .keyboardType(.numbersAndPunctuation)
                        }
                        if missingScheduleTime {
                            Text(L10n.planFormSlotMissing)
                                .font(.caption)
                                .foregroundStyle(Color("semantic-danger", bundle: .main))
                        }
                        if scheduleTemplate == nil, invalidCustomTime {
                            Text(L10n.planFormCustomTimesInvalid)
                                .font(.caption)
                                .foregroundStyle(Color("semantic-danger", bundle: .main))
                        }
                        if scheduleTemplate == nil, !isAsNeeded, duplicateScheduleTimes {
                            Text(L10n.planFormSlotDuplicate)
                                .font(.caption)
                                .foregroundStyle(Color("semantic-danger", bundle: .main))
                        }
                        LabeledContent(L10n.planFormTimesPerDay,
                                       value: isAsNeeded ? "—" : "\(effectiveTimes.count)")
                        Toggle(L10n.planFormAsNeeded, isOn: $isAsNeeded)
                        DatePicker(L10n.planFormStartDate, selection: $startDate, displayedComponents: .date)
                        Toggle(L10n.planFormHasEndDate, isOn: $hasEndDate)
                        if hasEndDate {
                            DatePicker(L10n.planFormEndDate, selection: $endDate, displayedComponents: .date)
                        }
                        Toggle(L10n.planFormLongTerm, isOn: $isLongTerm)
                    } header: {
                        Text(L10n.planFormSchedule)
                    } footer: {
                        Text(L10n.planFormSlotsHint)
                    }
                    Section(L10n.planFormSource) {
                        TextField(L10n.planFormHospital, text: $hospital)
                        TextField(L10n.planFormDoctor, text: $doctor)
                        TextField(L10n.planFormAdvice, text: $adviceText, axis: .vertical)
                            .lineLimit(3...6)
                    }
                    // FR9.10：录入时必须询问失效日期与存储位置（未知进待办队列）
                    Section {
                        Stepper(L10n.planFormLotUnits(Double(Int(lotUnits))), value: $lotUnits, in: 1...1000)
                        Picker(L10n.planFormLotUnit, selection: $lotUnitKind) {
                            Text(L10n.lotUnitTablet).tag("tablet")
                            Text(L10n.lotUnitCapsule).tag("capsule")
                            Text(L10n.lotUnitPatch).tag("patch")
                            Text(L10n.lotUnitVial).tag("vial")
                        }
                        Toggle(L10n.planFormExpireUnknown, isOn: $lotExpireUnknown)
                        if !lotExpireUnknown {
                            DatePicker(L10n.planFormExpireDate, selection: $lotExpireDate, displayedComponents: .date)
                        }
                        TextField(L10n.planFormStorageNote, text: $storageNote)
                    } header: {
                        Text(L10n.planFormLotSection)
                    } footer: {
                        Text(L10n.planFormLotHint)
                    }
                }
                .navigationTitle(L10n.planFormTitle)
                // FR9.19（V4.48）：计划表单改由固定时段承载提醒时刻，默认时刻取
                // 医院常用锚点（与 `DoseScheduleEngine.mealDefaultTime` 同源），
                // 不再按频率预填、也不覆盖用户手改。`DoseScheduleAdvisor` 的推荐表
                // 仍按其登记裁决保留给其他入口——其 08:00/20:00 等铺开值与时段默认
                // 并不相同，两者不得互相冒充（审查修正：原注释称「一致」不实）。
                .saveFailedAlert(title: L10n.planFormSaveFailed,
                                 hint: L10n.planFormSaveFailedHint,
                                 isPresented: $saveFailed)
                // E③（FR9.19）：排程冲突提示——非阻断（[仍要保存] 继续；[取消] 返回修改）
                .alert(L10n.planConflictTitle, isPresented: Binding(
                    get: { !pendingConflicts.isEmpty },
                    set: { if !$0 { pendingConflicts = [] } })) {
                    Button(L10n.planConflictProceed) {
                        conflictAcknowledged = true
                        pendingConflicts = []
                        performSave()
                    }
                    Button(L10n.commonCancel, role: .cancel) { pendingConflicts = [] }
                } message: {
                    Text(pendingConflicts.map(conflictText).joined(separator: "\n"))
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L10n.commonCancel) { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L10n.reminder_save) { save() }
                            .disabled(genericName.trimmingCharacters(in: .whitespaces).isEmpty
                                      || doseParseFailed
                                      || missingScheduleTime
                                      || invalidCustomTime
                                      || duplicateScheduleTimes)
                            .accessibilityIdentifier("SP-15.form.save")
                    }
                }
            }
        }
    }

    private func save() {
        // 时段时刻来自 DatePicker（恒合法）；自定义时刻走 Domain 单一闸门。
        // 非法/空排程必须响亮拒绝——固定闸门的历史事故是零剂量计划静默建成。
        if scheduleTemplate == nil {
            guard !invalidCustomTime, !duplicateScheduleTimes else {
                saveFailed = true
                return
            }
        }
        let times = effectiveTimes
        if !isAsNeeded, times.isEmpty {
            saveFailed = true
            return
        }
        // E③（收口批，FR9.19）：保存前冲突提示——纯排程事实、非阻断：
        // 有冲突先弹提示，[仍要保存] 置 ack 后重入；时刻非法已在上面拦截。
        // 按需计划不新增任何剂量：既有剂量之间的冲突与本计划无关，
        // 不能用一个无关弹窗阻断保存。
        if !isAsNeeded, !conflictAcknowledged {
            let conflicts = dosingConflicts(times: times)
            if !conflicts.isEmpty {
                pendingConflicts = conflicts
                return
            }
        }
        performSave()
    }

    /// E③（FR9.19）同日排程冲突（Domain `DoseConflictRules` 单一出口）。
    /// 现况注记（审查登记）：间距阈值按业主 Q5=A 在过医学审核前传 nil（间距类
    /// 整体不出现）；餐时互斥需要既有剂量携带 mealRelation（物化链路当前丢
    /// mealRelation——见审查报告 D1#3）——本接线就位，随数据面/审校闸放开自动生效。
    private func dosingConflicts(times: [String]) -> [DoseConflictRules.Conflict] {
        var refs: [DoseConflictRules.DoseRef] = []
        for slot in reminders.todaySlots {
            for record in slot.records {
                refs.append(.init(id: record.id, label: record.medicationName ?? "",
                                  dueAt: record.dose.dueAt, mealRelation: record.dose.mealRelation))
            }
        }
        if !isAsNeeded {
            let day = Calendar.current.startOfDay(for: startDate)
            for time in times {
                guard let due = DoseTimeSlotRules.date(for: time, on: day) else { continue }
                // 每个时刻用**自己的**餐食关系：多时段计划此前把
                // "beforeBreakfast,afterDinner" 整串塞给单剂 ref，
                // DoseConflictRules 的 hasPrefix("before"/"after") 分类
                // 因此把晚餐后误判成早餐前（餐时互斥漏报/误报）。
                refs.append(.init(id: "new-plan", label: genericName, dueAt: due,
                                  mealRelation: mealRelation(for: time)))
            }
        }
        return DoseConflictRules.conflicts(doses: refs, spacingThresholdMinutes: nil)
    }

    /// 某时刻对应的餐食关系：用户手填优先；否则取该时刻所属时段的 token；
    /// 自由补充时刻无关系 → nil（不猜测）。
    private func mealRelation(for time: String) -> String? {
        if !mealRelation.isEmpty { return mealRelation }
        for slot in selectedSlotList
        where (slotTimeTexts[slot] ?? slot.defaultTime) == time {
            return slot.mealRelation
        }
        return nil
    }

    private func conflictText(_ conflict: DoseConflictRules.Conflict) -> String {
        switch conflict {
        case .mealWindowMismatch(let first, let second, _):
            return L10n.planConflictMeal(first, second)
        case .spacingBelowThreshold(let first, let second, let gap, let threshold):
            return L10n.planConflictSpacing(first, second, gap, threshold)
        }
    }

    // MARK: - 时段绑定

    private func slotBinding(_ slot: DoseTimeSlot) -> Binding<Bool> {
        Binding(
            get: { selectedSlots.contains(slot) },
            set: { isOn in
                if isOn { selectedSlots.insert(slot) } else { selectedSlots.remove(slot) }
            })
    }

    private func slotTimeBinding(_ slot: DoseTimeSlot) -> Binding<Date> {
        Binding(
            get: { DoseTimeSlotRules.date(for: slotTimeTexts[slot] ?? slot.defaultTime) ?? Date() },
            set: { slotTimeTexts[slot] = DoseTimeSlotRules.timeString(from: $0) })
    }

    private func performSave() {
        let times = allTimes
        // 非按需计划的空时刻在 save() 已被拒绝；此兜底只防程序路径绕过 UI 闸门
        // （固定时刻 08:00 与 DoseScheduleAdvisor qd 默认一致）。
        let schedule: MedicationSchedule = isAsNeeded
            ? .asNeeded
            : .fixed(times: times.isEmpty ? ["08:00"] : times)   // 模板路径下 times 非空
        // 按需计划没有时段：不挂模板（否则模板删除守卫会被虚假引用挡住）
        let scheduleId = isAsNeeded ? nil : scheduleTemplate?.id
        let source: PrescriptionSource = .manual
        let rx = Prescription(
            patientId: app.currentPatientId,
            source: source,
            genericName: genericName, brandName: brandName.isEmpty ? nil : brandName,
            spec: spec, dosePerTake: dosePerTake.isEmpty ? nil : dosePerTake,
            timesPerDay: isAsNeeded ? nil : max(times.count, 1),
            route: route.isEmpty ? nil : route,
            timingMeal: effectiveMealRelation,
            durationStart: startDate,
            durationEnd: hasEndDate ? endDate : nil,
            hospital: hospital.isEmpty ? nil : hospital,
            doctor: doctor.isEmpty ? nil : doctor,
            adviceText: adviceText,
            isLongTerm: isLongTerm, isAsNeeded: isAsNeeded,
            confirmedFields: PrescriptionConfirmation.initialConfirmedFields(source: source))
        // D1：dosePerTake 解析落 MedicationPlanDraft → composer 写 dose_plan_units
        // （安全线单剂基线）；此前只留在 Prescription 展示字符串里被丢弃。
        // 第八轮修复：裸 Double() 对「1/2/半/0.5片」全 nil → composer 落
        // NULL、物化链路 ?? 1——医嘱「半片」被安全线按 1.0/次扣账。改经
        // Domain DoseInputParser（词尾单位剥离/半/分数/中文数字归一），
        // 不可解析时保存按钮已禁用（响亮拒绝）。
        let parsedDosePerTake = DoseScheduleEngine.DoseInputParser.parse(dosePerTake)
        let draft = MedicationPlanDraft(schedule: schedule, startDate: startDate,
                                        endDate: hasEndDate ? endDate : nil,
                                        dosePerTake: parsedDosePerTake)
        let lot = StockLotDraft(totalUnits: lotUnits, unitKind: lotUnitKind,
                                expireAt: lotExpireUnknown ? nil : lotExpireDate,
                                storageNote: storageNote)
        Task {
            do {
                try await reminders.createPlanFromPrescription(prescription: rx,
                                                               plan: draft, initialLot: lot,
                                                               scheduleId: scheduleId)
                dismiss()
            } catch {
                // 保存失败必须可见（响亮拒绝纪律）——此前仅注释吞错，按钮
                // 无响应、无提示，用户以为计划已建而提醒从未排期
                saveFailed = true
            }
        }
    }
}

// MARK: - 时段文案（App 层本地化；Domain 只持有 token）

extension DoseTimeSlot {
    /// 时段标题（L10n 单一出口；Domain 不持文案）。
    var localizedTitle: String {
        switch self {
        case .afterWake: return L10n.slotAfterWake
        case .beforeBreakfast: return L10n.slotBeforeBreakfast
        case .afterBreakfast: return L10n.slotAfterBreakfast
        case .beforeLunch: return L10n.slotBeforeLunch
        case .afterLunch: return L10n.slotAfterLunch
        case .beforeDinner: return L10n.slotBeforeDinner
        case .afterDinner: return L10n.slotAfterDinner
        case .beforeSleep: return L10n.slotBeforeSleep
        }
    }
}

// MARK: - FR9.9 药品知识卡（§5.40）

/// 药品知识卡：医嘱原文（A/C 来源）+ 储存条件与注意事项（用户记录）+ 固定话术。
/// BR-006：涉及禁忌、相互作用、特殊人群一律给「引导咨询医生药师」固定话术，
/// 不给任何结论。说明书写法要点不内置药典数据——只如实呈现用户自己的记录。
struct MedicationKnowledgeCardView: View {
    let plan: MedicationStore.PlanRow
    @Environment(ReminderStore.self) private var reminders
    @State private var advice: String?

    var body: some View {
        WithPerceptionTracking {
            List {
                Section {
                    Text(plan.medicationName).font(.headline)
                    if let spec = plan.spec {
                        Text(spec).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section(L10n.knowledgeAdvice) {
                    if let advice, !advice.isEmpty {
                        Text(advice)
                            .padding(.leading, 8)
                            .overlay(alignment: .leading) {
                                Rectangle().fill(Color("brand-primary", bundle: .main)).frame(width: 3)
                            }
                        // 评审修正 U2：手写徽章变体 → GradeBadge 唯一出口。
                        // 医嘱文本在 PlanRow 无医院原文溯源（A 需要来源链路），
                        // 用户记录口径取 C（用户确认）。
                        GradeBadge(grade: GradeBadge.gradeConfirmed)
                    } else {
                        Text(L10n.knowledgeNoAdvice).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section(L10n.knowledgeStorage) {
                    Text(L10n.knowledgeStorageHint)
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section(L10n.knowledgeCaution) {
                    // BR-006 固定话术：涉及禁忌/相互作用/特殊人群不给结论
                    Text(L10n.knowledgeCautionText)
                        .font(.footnote)
                        .foregroundStyle(Color("semantic-warning", bundle: .main))
                }
            }
            .scrollContentBackground(.hidden)   // ui-ux §3.0 surface/tint：渐变画布透出
            .tintedCanvas()   // 渐变直挂本容器（根级背景会被 TabView/导航栈系统底色覆盖，V4.06 修正）
            .navigationTitle(L10n.knowledgeTitle)
            .task { await loadAdvice() }
        }
    }

    private func loadAdvice() async {
        do {
            advice = try await reminders.medicationAdvice(medicationId: plan.medicationId)
        } catch {
            advice = nil
        }
    }
}

// MARK: - 组件

struct PlanStatusBadge: View {
    let status: String
    var body: some View {
        WithPerceptionTracking {
            Text(statusLabel)
                .font(.caption2)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Capsule().fill(color.opacity(0.15)))
                .foregroundStyle(color)
        }
    }
    private var statusLabel: String {
        switch status {
        case "active": return L10n.planStatusActive
        case "paused": return L10n.planStatusPaused
        case "ended": return L10n.planStatusEnded
        default: return status
        }
    }
    private var color: Color {
        switch status {
        case "active": return Color("brand-primary", bundle: .main)
        case "paused": return Color("semantic-warning", bundle: .main)
        case "ended": return Color("text-secondary", bundle: .main)
        default: return .secondary
        }
    }
}
