import SwiftUI
import os
import Domain
import Infrastructure
import Protocols
import Perception

/// F19 关怀语音助手会话 UI（M3 零阻塞项的后半场）。
///
/// 状态机在 Domain（`VoiceConversationEngine`，纯函数）——本层只做三件事：
/// 1. 把用户输入（转写/键盘）喂给状态机，渲染事件（speak / askOptions /
///    requireRepeatObject / execute / rejectForbidden / exitGracefully）；
/// 2. TTS 经 `AppState.speak` 出口（SpeechSynthesizing 端口）；
/// 3. FR19.1：退出前台立即停止聆听（scenePhase 观察）。
///
/// 零业务判断（tech-spec §1.1 规则 4）：危险分级、拒绝、超时全部由状态机裁决。
///
/// 转写接入说明：`TranscriptionEngine` 端口已就绪，但语音结构化路径受
/// FR17.4 定标放行线门控（`FeatureFlags.voiceStructuringEnabled == false`）。
/// 因此当前会话态以键盘输入驱动（F19 的降级路径）；引擎接入后同一视图
/// 直接消费转写文本，交互状态零改动——这是刻意的：UI 不因能力开关分叉。

// MARK: - 会话状态仓

@MainActor
@Perceptible
final class VoiceSessionState {
    private(set) var engineState = ConversationState()
    private(set) var caption = ""              // 与播报一致的屏幕字幕（FR19.3）
    private(set) var options: [String] = []
    private(set) var pendingObject: String?    // 拨号复述对象（FR19.5）
    private(set) var rejected = false
    private(set) var isListening = false
    private(set) var ended = false

    private let logger = Logger(subsystem: "com.vitaliber", category: "voicesession")

    func clearPendingObject() { pendingObject = nil }
    // 审查修复：clearOptions 已删除——镜像清空收敛进 submit() 的相位
    // 不变量（phase != .selecting ⇒ options = []），散点调用反而会抹掉
    // handleExecution 刚挂出的新列选（翻页/多命中）
    func clearRejection() { rejected = false }
    func end() { ended = true; isListening = false }
    func start() { isListening = true }

    /// 第七轮全仓审查修复：执行结果反馈不得再经 submit 喂回状态机——
    /// 反馈句（如「已记录…为已服用」）被引擎当作用户输入解析为未识别轮，
    /// silentRounds 累积、字幕被「没听清」提示覆盖（动作成功后反而显示
    /// 没听清，且两轮未识别后整个会话被 exitGracefully 关闭）。
    /// 反馈只更新字幕 + 播报，不进状态机。
    func systemFeedback(_ text: String, speak: (String) -> Void) {
        caption = text
        speak(text)
    }

    /// BR-004 真实性单一出口：写库结果决定播报——成功/失败文案二选一，
    /// 绝不无条件播报「已记录」而数据未落账。各写命令共用本机制。
    func systemFeedback(success: String, failure: String,
                        speak: @escaping (String) -> Void,
                        perform: @escaping @MainActor () async -> Bool) {
        Task {
            let ok = await perform()
            systemFeedback(ok ? success : failure, speak: speak)
        }
    }

    /// 多命中歧义消除（FR19.4，第七轮接线）：进入列选相位——选定编号后
    /// 引擎以 pendingCommand 执行（不再回落 .todayMeds），载荷 = 所选条目。
    /// 此前仅测试调用 optionsPrompt，生产路径零接线：多命中确认是死胡同
    /// （用户复述药名被解析为未识别，BR-004 确认永远无法完成）。
    func presentOptions(_ opts: [String], for command: VoiceCommand, speak: (String) -> Void) {
        let (state, events) = VoiceConversationEngine.optionsPrompt(opts, pendingCommand: command)
        engineState = state
        options = state.options
        for event in events {
            if case .speak(let prompt) = event {
                let text = L10n.voicePromptText(prompt)
                caption = text
                speak(text)
            }
        }
    }
    func pause() { isListening = false }       // 退出前台（FR19.1）
    func resume() { isListening = true }

    /// 输入一轮（转写文本或键盘输入）→ 渲染事件。
    /// 返回需要执行的动作（callContact/callEmergency120 的拨号 payload、
    /// 导航落点）——执行由视图层承担，状态机不接触 UIApplication。
    @discardableResult
    func submit(_ text: String, speak: (String) -> Void) -> VoiceCommand? {
        let (newState, events) = VoiceConversationEngine.step(state: engineState,
                                                              transcript: text,
                                                              emergencyNumber: L10n.emergencyNumber)
        engineState = newState
        // 引擎相位是唯一事实源：离开复述相位即清除本地镜像
        if newState.phase != .repeatingObject { pendingObject = nil }
        // 视图侧 options 镜像与引擎状态同构（审查修复）：镜像只在
        // .askOptions 事件与 presentOptions 时赋值——列选命中/相位离开后
        // 引擎清空自身 options，镜像必须同步清空，否则幽灵芯片滞留、
        // 再点零动作（此前靠调用方散点 clearOptions，漏一处即滞留）。
        // 以相位为准（引擎不变量：phase != .selecting ⇒ options 为空）。
        if newState.phase != .selecting { options = [] }
        var executed: VoiceCommand?
        for event in events {
            switch event {
            case .speak(let prompt):
                // V3.68：提示语类型化——Domain 出 SpeechPrompt，本层经 L10n
                // 渲染后播报（TTS 与字幕一致，FR19.3）
                let text = L10n.voicePromptText(prompt)
                caption = text
                speak(text)
            case .askOptions(let opts):
                options = opts
            case .requireRepeatObject(let obj):
                pendingObject = obj
            case .execute(let command, let payload):
                executed = command
                caption = L10n.f19Executed(command.rawValue) + (payload.map { "（\($0)）" } ?? "")
                // 第六轮全仓审查修复：载荷镜像此前只对拨号类命令生效——
                // markTaken/recordMetric/recordQuestion/搜索的执行对象恒 nil，
                // handleExecution 全部落入 no-op（「已执行」宣告但什么都没做）
                pendingObject = payload
            case .rejectForbidden:
                rejected = true
            case .exitGracefully:
                ended = true
                isListening = false
            }
        }
        return executed
    }
}

// MARK: - 关怀模式首页入口卡（FR19.1：关怀模式首页大卡 [开始语音]）

struct VoiceSessionLaunchCard: View {
    @Environment(AppState.self) private var app
    @State private var showSession = false

    var body: some View {
        WithPerceptionTracking {
            if app.careMode {
                Button {
                    showSession = true
                } label: {
                    HStack(spacing: 12) {
                        VLIcon.mic.resizable().frame(width: 28, height: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L10n.f19_launch).font(.title3).bold()
                            Text(L10n.f19_listeningHint).font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        Spacer()
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, minHeight: 72)   // 关怀模式 72pt 大卡
                    .background(RoundedRectangle(cornerRadius: 16)
                        .fill(Color("bg-grouped", bundle: .main)))
                }
                .buttonStyle(PressScaleButtonStyle())   // 按压反馈统一（§3.3 V4.05）
                .accessibilityIdentifier("F19.session.launchCard")
                .fullScreenCover(isPresented: $showSession) {
                    VoiceSessionView()
                }
            }
        }
    }
}

// MARK: - 会话视图

struct VoiceSessionView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    // F19 附表执行矩阵的数据源（纯事实播报；写操作经既有 Store 路径）
    @Environment(ReminderStore.self) private var reminderStore
    @Environment(M2HubStore.self) private var hub
    @Environment(TrendEntryState.self) private var trendState
    @Environment(QuestionsState.self) private var questionsState
    @Environment(SearchViewState.self) private var searchState
    @Environment(AppRouter.self) private var router

    @State private var session = VoiceSessionState()
    @State private var typed = ""
    /// 附表①清单分页游标（「下一页」选项应答前进；新查询归零）
    @State private var todayMedsPage = 0
    /// 标记服药列选候选直连表（审查修复）：displayLabel 相同的多时段剂量
    /// 经标签再过滤永远回到「多命中 → 再列选」死循环——presentOptions 时
    /// 登记候选行，执行时按选项标签反查下标直连剂量行。
    @State private var markTakenOptions: [(label: String, record: DoseRecord)] = []

    var body: some View {
        WithPerceptionTracking {
            VStack(spacing: 16) {
                HStack {
                    VLIcon.waveform.resizable().frame(width: 28, height: 28)
                    Text(L10n.f19_sessionTitle).font(.title2).bold()
                    Spacer()
                    Button {
                        endSession()
                    } label: {
                        VLIcon.stopOctagon.resizable().frame(width: 24, height: 24)
                            .frame(width: 64, height: 64)
                    }
                    .accessibilityLabel(L10n.f19_end)
                    .accessibilityIdentifier("F19.session.end")
                }

                // 聆听状态（FR19.1：必须显示聆听状态与结束按钮）
                listeningIndicator

                captionBlock
                optionsBlock
                repeatConfirmBlock
                rejectionBlock

                Spacer()

                // 键盘降级输入（转写接入前驱动会话；接入后保留为兜底，FR19.6）
                HStack(spacing: 8) {
                    TextField(L10n.f19_typeHint, text: $typed, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...3)
                        .accessibilityIdentifier("F19.session.input")
                    Button {
                        let text = typed
                        typed = ""
                        if routeEmergencyIfNeeded(text) { return }
                        let executed = session.submit(text, speak: { app.speak($0) })
                        if let executed { handleExecution(executed, object: session.pendingObject) }
                    } label: {
                        VLIcon.send.resizable().frame(width: 22, height: 22)
                            .frame(width: 64, height: 64)
                    }
                    .disabled(typed.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityLabel(L10n.f19_sendA11y)
                    .accessibilityIdentifier("F19.session.send")
                }
                .padding(.horizontal, 12)
            }
            .padding(16)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("F19.session.view")
            .onAppear {
                session.start()
                // 审查修复：进入会话即加载 hub 数据——原缺此加载，未先访问
                // 药箱/急救卡页时「药还剩多少/联系人」全部报空（关怀模式
                // 核心场景空答）。今日时段/预约同源加载：首页物化在途时
                // 直接进会话，「今天吃什么药/药都吃了吗」不得空答。
                Task {
                    // 两路加载相互独立（药箱六节 vs 今日时段/预约）——并发发起，
                    // 就绪时延取最慢一路而非两者之和（关怀模式首问不得空答）
                    async let a: Void = hub.load(patientId: app.currentPatientId)
                    async let b: Void = reminderStore.refreshTriggered(patientId: app.currentPatientId,
                                                                       force: true)
                    _ = await (a, b)
                }
            }
            .onChangeCompat(of: scenePhase) { _, phase in
                // FR19.1：离开前台立即停止监听（不结束会话，回前台可继续）——
                // .inactive（App 切换器/控制中心覆盖）同样停，防快照期间继续收音
                if phase == .background || phase == .inactive {
                    session.pause()
                } else if phase == .active {
                    session.resume()
                }
            }
            .onChangeCompat(of: session.ended) { _, ended in
                if ended { dismiss() }
            }
        }
    }

    // 四个条件块独立成 computed var：单一大 body 在 Swift 6.0 触发
    // type-check 超时（CI 实证「unable to type-check in reasonable time」）

    @ViewBuilder
    private var captionBlock: some View {
        // 屏幕字幕（与播报一致，FR19.3）
        if !session.caption.isEmpty {
            Text(session.caption)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12)
                    .fill(Color("bg-grouped", bundle: .main)))
                .accessibilityIdentifier("F19.session.caption")
        }
    }

    @ViewBuilder
    private var optionsBlock: some View {
        // 列选（FR19.4：≤3 项编号）
        if !session.options.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(session.options.enumerated()), id: \.offset) { index, option in
                    Button {
                        handleChoice(number: index + 1)
                    } label: {
                        HStack {
                            Text("\(index + 1)").bold().frame(width: 28)
                            Text(option)
                            Spacer()
                        }
                        .padding(10)
                        .frame(minHeight: 64)     // 关怀模式 ≥64pt
                        .background(RoundedRectangle(cornerRadius: 12)
                            .fill(Color("surface-tint-start", bundle: .main).opacity(0.25)))
                    }
                    .buttonStyle(PressScaleButtonStyle())   // 按压反馈统一（§3.3 V4.05）
                    .accessibilityIdentifier("F19.session.option.\(index + 1)")
                }
            }
        }
    }

    @ViewBuilder
    private var repeatConfirmBlock: some View {
        // 拨号复述确认（FR19.5）
        if let obj = session.pendingObject {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.f19RepeatObject(obj)).font(.headline)
                    .accessibilityIdentifier("F19.session.repeatObject")
                HStack(spacing: 16) {
                    Button(L10n.f19_cancel) {
                        _ = session.submit(VoiceCommandGrammar.cancelWord, speak: { app.speak($0) })
                    }
                    .frame(minWidth: 88, minHeight: 64)
                    .accessibilityIdentifier("F19.session.cancelCall")
                    Button(L10n.f19_confirm) {
                        // 走引擎的 repeatingObject 确认语义——UI 触屏确认
                        // 与语音「确认」同一条路径，不绕过状态机（FR19.5）
                        let executed = session.submit(VoiceCommandGrammar.confirmWord, speak: { app.speak($0) })
                        handleExecution(executed, object: session.pendingObject)
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(minWidth: 88, minHeight: 64)
                    .accessibilityIdentifier("F19.session.confirmCall")
                }
            }
        }
    }

    @ViewBuilder
    private var rejectionBlock: some View {
        // 拒绝卡（FR19.5：删除/剂量变更一律拒绝 → 引导触屏）
        if session.rejected {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    VLIcon.ban.resizable().frame(width: 24, height: 24)
                    Text(L10n.f19_rejectedTitle).font(.headline)
                }
                Text(L10n.f19_goTouch).font(.subheadline).foregroundStyle(.secondary)
                Button(L10n.f19_goTouch) { session.clearRejection() }
                    .frame(minHeight: 64)
                    .accessibilityIdentifier("F19.session.rejected.dismiss")
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12)
                .fill(Color("grade-d", bundle: .main).opacity(0.1)))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("F19.session.rejectionCard")
        }
    }

    private var listeningIndicator: some View {
        // 虚假聆听态修复（审查修复）：本视图无任何录音/听写控件，输入只有
        // 键盘 TextField；FR17.4 定标门控（FeatureFlags.voiceStructuringEnabled）
        // 放行前语音路径未接通，session.start() 仅翻转 isListening 布尔——
        // 此前恒渲染绿点「正在聆听」误导用户（声称在听却没有任何采集）。
        // 门控放行前渲染「已停止」且不提供 resume（无处可 resume）。
        let listening = session.isListening && FeatureFlags.voiceStructuringEnabled
        return HStack(spacing: 8) {
            Circle()
                .fill(listening ? Color("semantic-success", bundle: .main) : Color("text-tertiary", bundle: .main))
                .frame(width: 10, height: 10)
            Text(listening ? L10n.f19_listeningHint : L10n.f19_stopped)
                .font(.caption).foregroundStyle(.secondary)
            if !listening && FeatureFlags.voiceStructuringEnabled {
                Button(L10n.f19_paused) { session.resume() }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("F19.session.resume")
            }
        }
        .accessibilityIdentifier("F19.session.listening")
    }

    private func handleChoice(number: Int) {
        let text = VoiceCommandGrammar.ordinalWord(number) ?? "\(number)"
        let executed = session.submit(text, speak: { app.speak($0) })
        handleExecution(executed, object: session.pendingObject)
        // 审查修复：视图侧 options 镜像的清空收敛进 submit()（镜像与引擎
        // 状态同构）——此处若无条件 clearOptions 会把 handleExecution 重新
        // 挂出的列选（翻页/多命中）抹掉；若不清空则芯片滞留、再点零动作。
    }

    /// F19 附表能力矩阵执行：查询类播报真实数据（纯事实句式），操作类
    /// 执行真实写路径（BR-004：确认即如实记录），危险类已在状态机层完成分级确认。
    private func handleExecution(_ command: VoiceCommand?, object: String?) {
        guard let command else { return }
        // 审查修复：非标记服药命令执行即清列选候选表——用户搁置列选改说
        // 其它命令后，残留候选不得劫持下一次按药名的新确认（静默确认
        // 旧候选之一 = 多命中纪律失效）
        if command != .markTaken { markTakenOptions = [] }
        // 第七轮修复：载荷一次性消费——非拨号命令消费后即清镜像，防
        // 异步落库路径（recordMetric 的 Task 未完成前）出现与拨号无关的
        // 复述确认卡；拨号类（callContact/callEmergency120）由 FR19.5
        // 复述确认卡承接，保持镜像直到确认。
        defer {
            if command != .callContact, command != .callEmergency120 {
                session.clearPendingObject()
            }
        }
        switch command {
        case .callContact, .callEmergency120:
            executeCall(object)
        case .openTimeline, .goHome:
            executeNavigation(command)
        case .exitSession:
            executeExitSession()
        case .todayMeds:
            executeTodayMeds(object: object)
        case .nextAppointment:
            executeNextAppointment()
        case .recentGlucose:
            executeRecentGlucose()
        case .stockRemaining:
            executeStockRemaining(object: object)
        case .stockLocation:
            executeStockLocation(object: object)
        case .stockExpiry:
            executeStockExpiry(object: object)
        case .expiringSoon:
            executeExpiringSoon()
        case .askMedicationTaken:
            executeAskMedicationTaken()
        case .markTaken:
            executeMarkTaken(object: object)
        case .recordMetric:
            executeRecordMetric(object: object)
        case .recordQuestion:
            executeRecordQuestion(object: object)
        case .startCamera:
            executeStartCamera()
        case .openSearch:
            executeOpenSearch(object: object)
        case .repeatLast, .louder, .yes, .no, .selectNumber, .selectName, .cancel:
            break   // 会话类命令由状态机在 submit 前处理
        }
    }

    // MARK: - F19 附表命令执行（每命令一函数）

    /// 拨号（FR19.5）：复述对象 + 确认之后才真正拨号。
    private func executeCall(_ object: String?) {
        if let object { performCall(object) }
        session.clearPendingObject()
    }

    /// F19 附表「打开页面」= 执行导航并播报落点——同文件
    /// .startCamera/.openSearch 已证明 dismiss+router 可行，此前只
    /// dismiss 并让用户自己去点（导航类指令未实装）。时间轴 = records
    /// Tab 根（TimelineFullView），首页 = home Tab（统一经 select 出口）
    private func executeNavigation(_ command: VoiceCommand) {
        let targetTab: MainModuleID = command == .openTimeline ? .records : .home
        session.systemFeedback(command == .openTimeline ? L10n.f19GoTimeline : L10n.f19GoHome,
                               speak: { app.speak($0) })
        dismiss()
        router.select(targetTab)
    }

    /// 审查修复（FR19.6 保持界面停留位置）：退出是会话级命令，只收起
    /// 会话、绝不切 Tab——此前并入导航类把用户从任意 Tab 拽回首页。
    /// 状态机对 .exitSession 恒走 exitGracefully（不产 execute 事件），
    /// 本分支为纵深防御；语义与 exitGracefully 一致：仅退出。
    private func executeExitSession() {
        dismiss()
    }

    /// 附表①查询今日用药：清单播报，>3 条自动分页——每页 3 条，
    /// 剩余 >0 时经 FR19.4 列选「下一页」继续（编号/选项名应答均可），
    /// 末页播报结束（审查修复：此前 prefix(3)+「……」截断后第 4 条起
    /// 永久无法听到，与附表「自动分页」契约不符）。
    private func executeTodayMeds(object: String?) {
        let names = reminderStore.todaySlots
            .flatMap { $0.records.map(\.displayLabel) }
        if let object, object == L10n.f19NextPage {
            speakTodayMedsPage(names, page: todayMedsPage + 1)
            return
        }
        todayMedsPage = 0
        speakTodayMedsPage(names, page: 0)
    }

    /// 附表②查询下一个预约（无预约如实播报）。
    private func executeNextAppointment() {
        let apt = reminderStore.upcomingAppointments.first
        let text = apt.map { L10n.f19NextAppointment("\($0.hospital)·\($0.department)", $0.startsAt.formatted(date: .abbreviated, time: .shortened)) }
            ?? L10n.f19NoAppointment
        session.systemFeedback(text, speak: { app.speak($0) })
    }

    /// 附表：最近血糖——recentValues 直接查库、不写任何共享槽位。
    /// 审查修复：trendState.detailSeries 只在趋势页被访问过时才加载——
    /// 直接进语音会话会误报「暂无血糖记录」（F19 事实播报）。
    /// 2026-09-16 审查修复（共用槽位串号）：原实现调用 loadDetail 复用趋势页
    /// 的状态槽——语音一问把正在看的趋势页清成空态，且回读 detailSeries 时
    /// 只判 `?.` 不校身份：连问两次或同时有另一成员/另一指标在途时，
    /// 会把上一请求甚至别人序列的数值当作「最近血糖」播出来（BR-001 同族）。
    private func executeRecentGlucose() {
        let patientId = app.currentPatientId
        let limit = 3
        Task {
            let points = await trendState.recentValues(patientId: patientId, metric: .glucose, limit: limit)
            // 审查修复：裸插值绕过医学数值单一出口（62.0 → "62.0" 与
            // 趋势页 oneDecimal 口径漂移）——统一走 MedicalNumberFormat
            let text = points.map { MedicalNumberFormat.oneDecimal($0.value) }.joined(separator: "、")
            // 审查修复：序列存在但空点时 joined 为 ""（非 nil）——空串必须
            // 落到「暂无血糖记录」分支，不得播报空模板
            session.systemFeedback(text.isEmpty ? L10n.f19NoGlucose : L10n.f19RecentGlucose(text),
                                  speak: { app.speak($0) })
        }
    }

    /// 附表③查询余量：「约剩 N 天·按计划估算」（FR9.8.7 诚实性文案）。
    /// 指定药名（引擎载荷）时只回该药的全部批次；纯列表问句回全部。
    private func executeStockRemaining(object: String?) {
        if let object, matchingLots(object).isEmpty {
            // 指定药名无匹配：如实报未找到，绝不回全库清单
            // （答非所问 + 泄露无关药品余量）
            session.systemFeedback(L10n.f19StockNoMatch(object), speak: { app.speak($0) })
        } else {
            let items = object.map { matchingLots($0) } ?? hub.inventoryItems
            let text = items.map { item -> String in
                if let days = item.approxDaysLeft {
                    return L10n.f19StockRemaining(item.medicationName, days)
                }
                return L10n.f19StockNoPlan(item.medicationName)
            }.joined(separator: "；")
            session.systemFeedback(text.isEmpty ? L10n.f19NoStock : text, speak: { app.speak($0) })
        }
    }

    /// 附表④存放位置文本播报（指定药名时只回该药的全部批次）
    private func executeStockLocation(object: String?) {
        if let object, matchingLots(object).isEmpty {
            session.systemFeedback(L10n.f19StockNoMatch(object), speak: { app.speak($0) })
        } else {
            let items = object.map { matchingLots($0) } ?? hub.inventoryItems
            let text = items
                .map { L10n.f19StockLocation($0.medicationName, $0.storageNote ?? L10n.f19LocationUnknown) }
                .joined(separator: "；")
            session.systemFeedback(text.isEmpty ? L10n.f19NoStock : text, speak: { app.speak($0) })
        }
    }

    /// 附表⑤查询有效期：「X 什么时候过期」必须回该药效期日期——
    /// 此前与临期清单混流：载荷被弃、回全局 ≤30 天清单（答非所问）。
    /// 同名药多批次逐批回效期；泛化问句（载荷 nil）回落三级清单。
    private func executeStockExpiry(object: String?) {
        let matched = object.map { matchingLots($0) } ?? []
        if let object, matched.isEmpty {
            session.systemFeedback(L10n.f19StockNoMatch(object), speak: { app.speak($0) })
        } else if !matched.isEmpty {
            let lines = matched.map { item -> String in
                guard let expireAt = item.expireAt else {
                    return L10n.f19ExpiryUnknown(item.medicationName)
                }
                let date = expireAt.formatted(date: .abbreviated, time: .omitted)
                return expireAt < Date()
                    ? L10n.f19Expired(item.medicationName, date)
                    : L10n.f19Expiring(item.medicationName, date)
            }
            session.systemFeedback(lines.joined(separator: "；"), speak: { app.speak($0) })
        } else {
            // 载荷 nil（「药什么时候过期」等泛化问句）：回落三级清单，
            // 不得谎报「没有库存记录」
            session.systemFeedback(expiringSummary(), speak: { app.speak($0) })
        }
    }

    /// 附表⑥临期/过期清单：三级分组播报（expiringSummary 单一出口）
    private func executeExpiringSoon() {
        session.systemFeedback(expiringSummary(), speak: { app.speak($0) })
    }

    /// 附表时段服药确认：逐药回读已服/未服清单
    private func executeAskMedicationTaken() {
        let lines = reminderStore.todaySlots.flatMap { slot in
            slot.records.map { record -> String in
                let state = record.action == .taken || record.action == .discomfort
                    ? L10n.f19Taken : L10n.f19NotTaken
                return L10n.f19SlotMedState(record.displayLabel, state)
            }
        }
        session.systemFeedback(lines.isEmpty ? L10n.f19NoTodayMeds : lines.joined(separator: "；"),
                               speak: { app.speak($0) })
    }

    /// 附表②标记已服用：唯一在服计划命中 → 单次口头确认后逐时段确认。
    /// 审查修复（BR-004）：多条命中时不再静默确认第一条——回读清单
    /// 让用户点名确认，只确认用户显式指定的那一条。
    private func executeMarkTaken(object: String?) {
        guard let object else { return }
        // 列选应答：按选项标签反查候选直连表，直连剂量行确认——
        // 同 displayLabel 的多时段剂量此前按标签再过滤永远命中 2 条、
        // 再列选再命中（死循环，BR-004 确认路径不可达）
        if let idx = markTakenOptions.firstIndex(where: { $0.label == object }) {
            let record = markTakenOptions[idx].record
            markTakenOptions = []
            session.systemFeedback(
                success: L10n.f19MarkTakenDone(object),
                failure: L10n.f19MarkTakenFailed(object),
                speak: { app.speak($0) },
                perform: {
                    await reminderStore.confirmTaken(patientId: app.currentPatientId,
                                                     dose: record.dose)
                })
            return
        }
        let matched = reminderStore.todaySlots
            .flatMap { $0.records }
            .filter { $0.displayLabel.contains(object) && $0.action == nil }
        if matched.count == 1, let record = matched.first {
            // BR-004 真实性：写库结果决定反馈（systemFeedback 单一出口）
            session.systemFeedback(
                success: L10n.f19MarkTakenDone(object),
                failure: L10n.f19MarkTakenFailed(object),
                speak: { app.speak($0) },
                perform: {
                    await reminderStore.confirmTaken(patientId: app.currentPatientId,
                                                     dose: record.dose)
                })
        } else if matched.isEmpty {
            session.systemFeedback(L10n.f19MarkTakenNoMatch(object),
                                   speak: { app.speak($0) })
        } else {
            // 第七轮修复：多命中进入 FR19.4 列选（编号选择）——
            // 原实现播报清单后是死胡同：用户复述药名的自由输入被
            // 状态机解析为未识别（silentRounds 累积直至会话被关），
            // 确认永远无法完成；列选选定后引擎以 .markTaken 执行。
            // 审查修复（BR-004 唯一标签）：同药多时段的 displayLabel
            // 逐字相同（不含时段），按纯标签反查恒解析到第 0 行 =
            // 「第2个」被静默确认为第 1 条（错剂量确认，比死循环更糟）。
            // 选项标签加时段后缀保证唯一，引擎载荷（= 所选标签）可
            // 精确反查候选行。
            markTakenOptions = matched.map { (label: Self.markTakenOptionLabel($0), record: $0) }
            let labels = markTakenOptions.map(\.label)
            session.presentOptions(labels, for: .markTaken, speak: { app.speak($0) })
        }
    }

    /// 附表⑦记录指标：F17 文法命中 → 落 metric_sample（C 级）。
    /// 审查修复：原实现无视指标类型一律记 bloodPressureSys + "mmHg"——
    /// 「血糖 5.6」「体温 37.5」全部落成血压样本（FR19 附表⑦失效）。
    /// 改用与语音确认卡同一文法抽取（VoiceGrammarDefaults 单一事实源）。
    private func executeRecordMetric(object: String?) {
        guard let object else { return }
        let drafts = VoiceStructuringEngine.extractMetric(
            object, rules: VoiceGrammarDefaults.metricRules)
        let byKey = Dictionary(grouping: drafts, by: { $0.key })
            .compactMapValues { $0.first }
        if let sysDraft = byKey["blood_pressure_sys"], let sysV = Double(sysDraft.value), sysV > 0 {
            let diaV = byKey["blood_pressure_dia"].flatMap { Double($0.value) }
            // 合理性界限（MetricEntryRules 单一出口，与手录同纪律）：
            // 「血压 800」此前以 C 级样本持久化并污染趋势/告警证据链
            guard MetricEntryRules.isPlausible(sysV, for: .bloodPressureSys),
                  diaV.map({ MetricEntryRules.isPlausible($0, for: .bloodPressureDia) }) ?? true else {
                session.systemFeedback(L10n.f19MetricInvalidValue,
                                       speak: { app.speak($0) })
                return
            }
            // 写库结果决定反馈（BR-004 真实性；systemFeedback 单一出口）
            session.systemFeedback(
                success: L10n.f19MetricRecorded(sysV),
                failure: L10n.f19RecordFailed,
                speak: { app.speak($0) },
                perform: {
                    await trendState.addSample(patientId: app.currentPatientId,
                                               metric: .bloodPressureSys,
                                               value: sysV,
                                               secondaryValue: diaV,
                                               unit: sysDraft.unit ?? "mmHg",
                                               measuredAt: Date())
                })
        } else if let draft = drafts.first(where: { $0.key != "title" }),
                  let v = Double(draft.value), v > 0 {
            let metric = Self.metricType(for: draft.key)
            guard let metric else {
                // 文法命中了 MetricType 未覆盖的指标（如体温）——不臆造落库
                session.systemFeedback(L10n.f19MetricNotSupported(draft.key),
                                       speak: { app.speak($0) })
                return
            }
            // 合理性界限（与血压分支同纪律）：界外值响亮拒绝
            guard MetricEntryRules.isPlausible(v, for: metric) else {
                session.systemFeedback(L10n.f19MetricInvalidValue,
                                       speak: { app.speak($0) })
                return
            }
            // 第八轮全仓审查修复：单位必取非空——空单位样本会绕过
            // AlertEngine 的跨单位守卫（ru.isEmpty 跳过拒判定级），
            // 静默混入趋势与告警证据链
            guard let unit = draft.unit, !unit.isEmpty else {
                session.systemFeedback(L10n.f19MetricNotSupported(draft.key),
                                       speak: { app.speak($0) })
                return
            }
            session.systemFeedback(
                success: L10n.f19MetricRecorded(v),
                failure: L10n.f19RecordFailed,
                speak: { app.speak($0) },
                perform: {
                    await trendState.addSample(patientId: app.currentPatientId,
                                               metric: metric,
                                               value: v,
                                               secondaryValue: nil,
                                               unit: unit,
                                               measuredAt: Date())
                })
        } else if drafts.contains(where: { $0.key != "title" && Double($0.value) != nil }) {
            // 第八轮全仓审查修复（响亮拒绝）：文法命中了数值但 ≤0
            // （如「血糖零」经 NumberNormalizer 归一为 "0"）——不落库
            // （0 值无生理意义，污染趋势并误导 L1–L3 告警），但必须
            // 反馈，绝不静默丢弃（原实现双分支落空即无声无息）。
            session.systemFeedback(L10n.f19MetricInvalidValue,
                                   speak: { app.speak($0) })
        }
    }

    /// 附表⑧问诊速记：追加至 FR10.5。写库结果决定反馈——此前
    /// 无条件播报「已记录」而写入可能失败（BR-004 真实性）
    private func executeRecordQuestion(object: String?) {
        guard let object, !object.isEmpty else { return }
        // 写库结果决定反馈（BR-004 真实性；systemFeedback 单一出口）
        session.systemFeedback(
            success: L10n.f19QuestionRecorded(object),
            failure: L10n.f19RecordFailed,
            speak: { app.speak($0) },
            perform: {
                await questionsState.add(patientId: app.currentPatientId, body: object)
            })
    }

    /// 附表⑩开始拍摄：进入相机流（后续动作手动完成）
    private func executeStartCamera() {
        dismiss()
        router.navigate(to: .observationCreate)
    }

    /// 附表：确认的搜索词注入共享状态（此前被丢弃），全局搜索页打开即带词检索
    private func executeOpenSearch(object: String?) {
        if let object, !object.isEmpty { searchState.injectQuery(object) }
        dismiss()
        router.navigate(to: .globalSearch)
    }

    /// 语音文法指标键 → MetricType（文法键 snake_case 为单一事实源；
    /// 温度等 MetricType 未覆盖的指标返回 nil——不臆造落库）
    private static func metricType(for grammarKey: String) -> MetricType? {
        MetricType(grammarKey: grammarKey)   // Domain 单一映射（VoiceGrammarDefaults 同源键）
    }

    /// 标记服药列选选项的唯一标签：displayLabel + 时段时刻——同药多时段的
    /// displayLabel 逐字相同（不含时段），纯标签反查会静默错确认第 0 行
    /// （BR-004）。时段后缀保证选项唯一、编号/选项名应答都可精确反查。
    private static func markTakenOptionLabel(_ record: DoseRecord) -> String {
        "\(record.displayLabel) · \(record.dose.dueAt.formatted(date: .omitted, time: .shortened))"
    }

    /// F19 附表①清单分页播报：每页 3 条；剩余 >0 时列选「下一页」继续
    /// （FR19.4 编号/选项名应答均可——「下一页」即选项名，A2 修复后
    /// 口语应答也成立）。todayMedsPage 由调用方维护。
    private func speakTodayMedsPage(_ names: [String], page: Int) {
        let pageSize = 3
        let start = page * pageSize
        let slice = Array(names.dropFirst(start).prefix(pageSize))
        if slice.isEmpty {
            session.systemFeedback(L10n.f19NoTodayMeds, speak: { app.speak($0) })
            return
        }
        var text = slice.joined(separator: "、")
        let remaining = names.count - start - slice.count
        if remaining > 0 {
            // %d = 剩余条数（三语同语义：审查修复——此前传总数，en 按
            // "more"（剩余）语义渲染而 zh 按「共 N 条」（总数）渲染，
            // en 播报虚增剩余量）
            text += L10n.f19MedListMore(remaining)
            session.presentOptions([L10n.f19NextPage], for: .todayMeds, speak: { app.speak($0) })
        }
        session.systemFeedback(text, speak: { app.speak($0) })
    }

    /// BR-012 紧急关键词前置（V3.40 语音指令入口，复用 F12 词表单一事实源）：
    /// 命中即急救卡、终止本会话——先于 F19 文法（「我胸闷」不再落入速记/
    /// 指标草稿）。返回是否已拦截。
    private func routeEmergencyIfNeeded(_ text: String) -> Bool {
        guard EmergencyKeywordRules.match(text) else { return false }
        session.end()
        dismiss()
        router.navigate(to: .emergencyCardConfig)
        return true
    }

    private func performCall(_ object: String) {
        // FR19.5：联系人名→号码解析（急救卡已确认联系人）；
        // 急救号码免复述（响铃倒计时 5 秒可取消由系统拨号确认承担）。
        // 审查修复：号码按语言区域取 L10n（120/119/911），不再硬编码大陆 120
        let emergency = L10n.emergencyNumber
        if object == emergency {
            SystemLinks.dial(emergency)
            return
        }
        // 审查修复（FR19.5 确认对象语义）：子串匹配按列表顺序取首个——
        // 联系人「妈妈的姐姐」先于「妈妈」时，「打给妈妈」会拨给姨妈
        // （BR-012 急救路径拨错人）。精确名优先；仅当子串命中唯一才放行，
        // 多义一律拒绝拨号（播报未命中，绝不猜）。
        // 审查修复（唯一子串命中仍是猜测）：FR19.5 复述确认环节复述的是
        // 语音原话而非解析出的联系人名——唯一子串命中（「妈妈的姐姐」
        // 含「妈妈」）仍会拨错人。急救路径拨错人代价不对称：非精确名
        // 一律不拨号，播报相近联系人的完整姓名引导用户复述精确名。
        let contacts = hub.emergencySelected.contacts
        guard let contact = contacts.first(where: { $0.title == object }) else {
            let candidates = contacts.filter { $0.title.contains(object) }
            if let sole = candidates.count == 1 ? candidates[0] : nil {
                app.speak(L10n.f19_contactAmbiguous(object, sole.title))
            } else {
                app.speak(L10n.f19_contactNotFound(object))
            }
            return
        }
        // detail 为「关系 · 电话」复合展示串——拨号取纯号码（BR-012 语义）
        // 全仓审查 2026-09-18（F-A2-05）：号码经 SystemLinks 归一拨出；不可拨即播报未命中，不静默
        // 审查修正（L1 编译失败）：contactPhone 是可选字段，缺号码按「未命中」播报而非裸传 String?
        guard let phone = contact.contactPhone else {
            app.speak(L10n.f19_contactNotFound(object))
            return
        }
        if !SystemLinks.dial(phone) {
            app.speak(L10n.f19_contactNotFound(object))
        }
    }

    /// 指定药名的全部匹配批次（双轨库存/StockLot：同名药品可多批次）——
    /// 此前 first 只回首批，多批次药余量/效期/位置被少报。
    /// 精确名优先（Domain InventoryRules.preferredExactMatches 单一事实源，
    /// 审查修复：匹配语义此前内联本视图，规则调整须改视图且不可单测）。
    private func matchingLots(_ obj: String) -> [MedicationStore.InventorySummaryItem] {
        InventoryRules.preferredExactMatches(hub.inventoryItems,
                                             name: { $0.medicationName },
                                             query: obj)
    }

    /// 附表⑥临期/过期三级分组播报（FR9.11；BatchExpiryRules 单一事实源）——
    /// 已过期如实报「已过期」，不再混入「到期」模板。.expiringSoon 与
    /// .stockExpiry 泛化问句回落共用此单一出口。
    private func expiringSummary() -> String {
        let now = Date()
        let lots = hub.inventoryItems.compactMap { item -> (String, Date)? in
            item.expireAt.map { (item.medicationName, $0) }
        }
        let dateText: (Date) -> String = { $0.formatted(date: .abbreviated, time: .omitted) }
        // FR9.11 三级分类经 Domain BatchExpiryRules.status 单一出口——
        // 此前视图内手写三档过滤 + ?? 7/?? 30 兜底字面量，阈值与 Domain
        // 漂移即答非所问（BR 规则只应存在于 Domain 纯函数）
        var expired: [(String, Date)] = []
        var soon7: [(String, Date)] = []
        var soon30: [(String, Date)] = []
        for lot in lots {
            switch BatchExpiryRules.status(expireAt: lot.1, now: now) {
            case .expired: expired.append(lot)
            case .within7: soon7.append(lot)
            case .within30: soon30.append(lot)
            case .later: break
            }
        }
        var parts: [String] = []
        let groups: [([(String, Date)], (String, String) -> String)] = [
            (expired, L10n.f19Expired),
            (soon7, L10n.f19Expiring),
            (soon30, L10n.f19Expiring),
        ]
        for (group, fmt) in groups where !group.isEmpty {
            parts.append(group.map { fmt($0.0, dateText($0.1)) }.joined(separator: "；"))
        }
        return parts.isEmpty ? L10n.f19NoExpiring : parts.joined(separator: "；")
    }

    private func endSession() {
        session.end()
        dismiss()
    }
}
