import SwiftUI
import Domain
import Perception

// MARK: - 首页渲染原子（2026-09-26 原子结构轮第二批：由 HomeView 分解）
//
// 业主组合纪律（2026-09-16）：复杂类必须由专注小类组合。HomeView 此前 958 行 /
// 40 成员，渲染原子与状态编排混在一个结构体里。本文件承接**纯渲染子视图**——
// 状态经 let 值 + 闭包传入（无 @Environment/@State），HomeView 保留聚合装配、
// 动作分派与加载编排（有状态编排者 + 无状态叶视图，与 HomeDispositions.swift 同族）。

/// FR2.2 聚合行（类别视觉映射每行只求值一次；点击由父级分派）。
struct HomeAggregationRow: View {
    let item: AggregatedReminderItem
    let onOpen: () -> Void

    var body: some View {
        // 类别视觉映射每行只求值一次（原同表达式三次查表）
        let icon = CardKindIcon.spec(aggregation: item.aggregationKind)
        return Button {
            onOpen()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon.symbol)
                    .font(.title3)
                    .foregroundStyle(icon.tint)
                    .frame(width: 36, height: 36)
                    .background(RoundedRectangle(cornerRadius: 10)
                        .fill(icon.tint.opacity(0.12)))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(L10n.pendingCardAggregationTitle(item.title))
                            .font(.subheadline).foregroundStyle(.primary)
                            .lineLimit(1)
                        if item.id.kind == "alert_event", let status = item.status, status != "L0" {
                            // FR16.2 证据卡入口：级别徽章（仅 alert_event 的 L1+ 才渲染；
                            // dose_slot/pending_card 的 status 是处置状态透传，不是级别）
                            Text(status)
                                .font(.caption2.bold()).foregroundStyle(.white)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(Color("semantic-danger", bundle: .main)))
                        }
                    }
                    HStack(spacing: 6) {
                        Text(item.occurredAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption).foregroundStyle(.secondary)
                        if item.status == "L0" {
                            // FR16.2 软提示注记：L0 是观察记录，不是警报
                            Text(L10n.homeL0Note)
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                        if item.id.kind == "dose_slot", item.status == "taken" {
                            // FR2.1⑦：已服时段仍可见（BR-004 不隐藏用药事实），只作注记、无滑动动作
                            Text(L10n.reminder_taken)
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        if let remaining = item.remainingCount, remaining > 0 {
                            Text(L10n.homeRemainingFmt(remaining))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer()
                if item.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.caption)
                        .foregroundStyle(Color("semantic-danger", bundle: .main))
                }
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleButtonStyle())   // 按压反馈统一（§3.3 V4.05）
        .accessibilityIdentifier("SP-04.home.row.\(item.id.sourceId)")
    }
}

/// FR2.1④ 类别图标筛选 chip（选中态由父级 `filterKind` 给出）。
struct HomeFilterChip: View {
    let kind: AggregationKind?
    let label: String
    let icon: String
    let selected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button {
            onSelect()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.caption)
                Text(label).font(.caption)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(minHeight: 44)   // ui-ux §5.2 触点 ≥44pt（原 ≈27pt）；与 TimelineViews FilterChip 同口径
            .background(Capsule().fill(selected
                                       ? Color("brand-primary", bundle: .main)
                                       : Color("bg-grouped", bundle: .main)))   // 语义令牌（token-only 纪律，不用系统调色板）
            .foregroundStyle(selected ? Color.white : Color.primary)
        }
        .buttonStyle(PressScaleButtonStyle())   // 按压反馈统一（§3.3 V4.05）
        .accessibilityIdentifier("SP-04.home.chip.\(kind?.rawValue ?? "all")")
    }
}

/// FR2.1a 时间窗 Menu（FR14.7 完整档位在设置页期二；首页三档常用预设）。
struct HomeWindowMenu: View {
    let label: String
    let onSelect: (String) -> Void

    var body: some View {
        Menu {
            Button(L10n.homeWindowDefault) { onSelect("7,14") }
            Button(L10n.homeWindowShort) { onSelect("1,7") }
            Button(L10n.homeWindowLong) { onSelect("30,30") }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "calendar")
                Text(label).font(.caption)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(minHeight: 44)   // ui-ux §5.2 触点 ≥44pt（原 ≈27pt）；同族缺陷（筛选 chips 同修）
            .background(Capsule().fill(Color("bg-grouped", bundle: .main)))   // 语义令牌（token-only 纪律，不用系统调色板）
            .foregroundStyle(Color.primary)
        }
        .accessibilityIdentifier("SP-04.home.windowMenu")
    }
}

/// FR2.1b/FR17.11：实时资料状态，不伪装成「刚发生」的通知时间。
struct HomeProfileProgressCard: View {
    let progress: (done: Int, total: Int)
    /// 缺失的急救相关访谈步骤键（Domain 固定语义序；空 = 不渲染缺项行）
    let missingSteps: [String]
    let onContinue: () -> Void

    var body: some View {
        Button {
            onContinue()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "person.text.rectangle")
                    .font(.title3)
                    .foregroundStyle(Color("brand-primary", bundle: .main))
                    .frame(width: 36)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(L10n.homeProfileProgressTitle)
                            .font(.subheadline.bold()).foregroundStyle(.primary)
                        Spacer(minLength: 8)
                        Text(L10n.homeProfileContinue)
                            .font(.caption).foregroundStyle(Color("brand-primary", bundle: .main))
                    }
                    Text(L10n.homeProfileProgressFmt(progress.done, progress.total))
                        .font(.caption).foregroundStyle(.secondary)
                    ProgressView(value: Double(progress.done), total: Double(progress.total))
                        .tint(Color("brand-primary", bundle: .main))
                    // 2026-10-03 评审 R2-1：一行纯事实缺项提示（FR2.1b V4.11 增补）——
                    // 仅列急救相关访谈缺项（≤3，余折叠），无新增交互、无压力话术。
                    if !missingSteps.isEmpty {
                        Text(L10n.homeProfileMissingFmt(missingLineText))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 8)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleButtonStyle())   // 按压反馈统一（§3.3 V4.05）
        .accessibilityLabel(L10n.homeProfileProgressTitle)
        .accessibilityValue(accessibilityValueText)
        .accessibilityHint(L10n.homeProfileContinue)
        .accessibilityIdentifier("SP-04.home.profileProgress")
    }

    /// 缺项行文案（≤3 展示，余折叠「等 N 项」）
    private var missingLineText: String {
        let names = missingSteps.map(missingStepName)
        let shown = names.count > 3 ? Array(names.prefix(3)) + [L10n.homeProfileMissingMore(names.count - 3)] : names
        return shown.joined(separator: " · ")
    }

    /// 访谈步骤键 → SP-58 语音引导同源名称（单一出口）
    private func missingStepName(_ key: String) -> String {
        switch key {
        case "allergy": return L10n.voiceguide_noteAllergy
        case "pastHistory": return L10n.voiceguide_noteHistory
        case "currentMeds": return L10n.voiceguide_noteMeds
        case "emergencyContact": return L10n.voiceguide_noteContact
        default: return key
        }
    }

    /// 朗读值 = X/8 + 缺项句（缺项行并入朗读，VoiceOver 不丢内容）
    private var accessibilityValueText: String {
        var s = L10n.homeProfileProgressFmt(progress.done, progress.total)
        if !missingSteps.isEmpty { s += " " + L10n.homeProfileMissingFmt(missingLineText) }
        return s
    }
}

/// FR2.1c 筛选空态：当前窗口/类别无结果 ≠ 全局无数据（不得误报
/// 「没有提醒」）；筛选激活时给「一键回到全部」。
struct HomeEmptyAggregation: View {
    let showsReset: Bool
    let onReset: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.largeTitle).foregroundStyle(.tertiary)
            Text(L10n.homeEmptyFilter)
                .font(.subheadline).foregroundStyle(.secondary)
            if showsReset {
                Button(L10n.homeEmptyReset) { onReset() }
                    .font(.subheadline)
                    .foregroundStyle(Color("brand-primary", bundle: .main))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .accessibilityIdentifier("SP-04.home.emptyAggregation")
    }
}

/// FR21.x 首日引导四卡（完成态与动作全部由父级给出）。
struct HomeNewUserGuide: View {
    let memberDone: Bool
    let captureDone: Bool
    let medDone: Bool
    let healthDone: Bool
    let onNavigateMembers: () -> Void
    let onQuickCapture: () -> Void
    let onNavigateMedForm: () -> Void
    let onVisitHealth: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GuideTaskCard(icon: "person.crop.circle.badge.plus", title: L10n.homeGuide1, done: memberDone) {
                onNavigateMembers()
            }
            GuideTaskCard(icon: "camera.fill", title: L10n.homeGuide2, done: captureDone) {
                onQuickCapture()
            }
            GuideTaskCard(icon: "bell.badge.fill", title: L10n.homeGuide3, done: medDone) {
                onNavigateMedForm()
            }
            GuideTaskCard(icon: "heart.text.clipboard", title: L10n.homeGuide4, done: healthDone) {
                onVisitHealth()
            }
        }
        // 容器标识必须 .contain：否则 SwiftUI 把容器 id 压到每个 GuideTaskCard 子元素上，
        // XCUITest 按 SP-04.home.guide.* 查找失败（L0 §17 容器标识掩蔽规则，2026-09-26 审查修复）。
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("SP-04.home.emptyGuide")
    }
}

/// FR9.6 通知未授权横幅（去设置 / 当日关闭；关闭标记由父级持久化）。
struct HomeNotifDeniedBanner: View {
    let onDismiss: () -> Void

    var body: some View {
        HStack {
            Image(systemName: "bell.slash.fill").foregroundStyle(Color("semantic-warning", bundle: .main))
            Text(L10n.homeNotifDenied)
                .font(.footnote)
            Spacer()
            Button(L10n.homeNotifOpen) {
                SystemLinks.openSettings()
            }
            .font(.footnote)
            Button {
                onDismiss()
            } label: {
                // 审查修复：触控目标 ≥44pt（原 ~16pt 图标，关怀模式要求 64pt）
                Image(systemName: "xmark").font(.footnote).foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(L10n.commonCancel)
            .accessibilityIdentifier("SP-04.home.notifDenied.dismiss")
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12)
            .fill(Color("semantic-warning", bundle: .main).opacity(0.12)))
        // List 行内多按钮：borderless 让「去设置」与「关闭」各自命中，行空白区不触发任一
        .buttonStyle(.borderless)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("SP-04.home.notifDenied")
    }
}

/// 引导任务卡（完成态打勾；L2 玻璃表面）。
struct GuideTaskCard: View {
    let icon: String
    let title: String
    let done: Bool
    let action: () -> Void

    var body: some View {
        WithPerceptionTracking {
            Button(action: action) {
                HStack(spacing: 12) {
                    Image(systemName: done ? "checkmark.circle.fill" : icon)
                        .font(.title3)
                        .foregroundStyle(done ? Color("semantic-success", bundle: .main) : Color("brand-primary", bundle: .main))
                    Text(title).font(.subheadline).foregroundStyle(.primary)
                    Spacer()
                    if done {
                        Image(systemName: "checkmark")
                            .foregroundStyle(Color("semantic-success", bundle: .main))
                    }
                }
                .padding(14)
                .glassCard(cornerRadius: VLCornerRadius.compact)   // §3.3 表面阶梯 L2 玻璃（V4.05：常态无阴影）
            }
            .buttonStyle(PressScaleButtonStyle())   // 按压反馈统一：scale(0.97) 弹簧 ≤350ms
            .accessibilityIdentifier("SP-04.home.guide.\(title)")
        }
    }
}

extension AggregationKind {
    /// 筛选 chips 文案（聚合类别 → 既有 L10n 键；图标/色已收敛至
    /// `CardKindIcon.spec(aggregation:)` 单一出口，2026-09-16 委员会评审）。
    var homeFilterLabel: String {
        switch self {
        case .medication: return L10n.homeFilterMedication
        case .appointment: return L10n.homeFilterAppointment
        case .document: return L10n.homeFilterDocument
        case .ocr: return L10n.homeFilterOcr
        case .alert: return L10n.homeFilterAlert
        case .pendingCard: return L10n.homeFilterPending
        case .family: return L10n.homeFilterFamily
        case .sos: return L10n.homeFilterSOS
        case .system: return L10n.homeFilterSystem
        }
    }
}

// MARK: - 原子结构轮第三批（2026-09-26）：HomeView 剩余渲染段迁出

/// FR18.5 关怀模式大卡（≥72pt 主高度，FR18.2）
struct BigCareCard: View {
    let icon: String
    let title: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        WithPerceptionTracking {
            Button(action: action) {
                HStack(spacing: 20) {
                    Image(systemName: icon)
                        .font(VLFont.homeActionIcon)
                        .foregroundStyle(tint)
                        .frame(width: 64, height: 64)
                        .background(RoundedRectangle(cornerRadius: 16).fill(tint.opacity(0.12)))
                    Text(title)
                        .font(.title3.bold())
                        .foregroundStyle(.primary)
                    Spacer()
                }
                .padding(20)
                .frame(maxWidth: .infinity, minHeight: 72)
                .glassCard(cornerRadius: VLCornerRadius.card)   // §3.3 表面阶梯 L2（V4.05：常态无阴影）
            }
            .buttonStyle(PressScaleButtonStyle())   // 按压反馈统一（§3.3 V4.05）
        }
    }
}

/// FR18.5 关怀模式瞬态任务卡（2026-10-03 评审 R2-2）：进行中长任务在关怀首页
/// 保持可见可取消——§6「进度可见可取消」× FR18.5「只留四大卡」的调和：仅活动
/// 任务存在时渲染于四大卡之下，零任务零痕迹（与 SP-64 activeSection 同语义）。
/// 进度读取下沉内层观察域（与 HomeModelDownloadCard 同纪律，防首页全量重算）。
struct CareTransientTaskCard: View {
    let install: ASRInstallCenter.Install
    let onOpen: () -> Void
    let onCancel: () -> Void

    var body: some View {
        WithPerceptionTracking {
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        let brief = install.phase
        let showFraction = ASRDownloadProgress.showsDeterminateProgress(progress: install.progress, phase: brief)
        Button(action: onOpen) {
            HStack(spacing: 20) {
                VLDownloadActivityIcon(isActive: !install.waiting, font: VLFont.homeActionIcon)
                    .foregroundStyle(Color("brand-primary", bundle: .main))
                    .frame(width: 64, height: 64)
                    .background(RoundedRectangle(cornerRadius: 16)
                        .fill(Color("brand-primary", bundle: .main).opacity(0.12)))
                VStack(alignment: .leading, spacing: 6) {
                    Text(detailText(install))
                        .font(.title3.bold())
                        .foregroundStyle(.primary)
                    Text(L10n.voiceEngineName(install.choice))
                        .font(.caption).foregroundStyle(.secondary)
                    // 不确定阶段（激活/清理/排队）不再渲染独立 spinner 行（2026-10-04 业主反馈①）：
                    // 进行态反馈由图标动效 + 阶段文案承担——不确定阶段不再被 spinner 行撑高；
                    // 与确定阶段（条）仍存在条宽差，属确定/不确定两态的既有高度形态。
                    if showFraction {
                        ProgressView(value: install.progress?.fraction ?? 0)
                            .tint(Color("brand-primary", bundle: .main))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button(L10n.commonCancel) { onCancel() }
                    .buttonStyle(.bordered)
                    .frame(minHeight: 72)   // 关怀模式关键动作 ≥72pt（§7.1）
                    .accessibilityIdentifier("SP-04.home.careMode.task.cancel.\(install.choice.rawValue)")
            }
            .padding(20)
            .frame(maxWidth: .infinity)
            .glassCard()
        }
        .buttonStyle(PressScaleButtonStyle())   // 按压反馈统一（§3.3 V4.05）
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.homeModelDownloadTitle)
        .accessibilityValue("\(L10n.voiceEngineName(install.choice)) \(detailText(install))")
        .accessibilityIdentifier("SP-04.home.careMode.task.\(install.choice.rawValue)")
    }
}

/// 后台任务（模型下载）卡片（2026-09-16 业主）：形态对齐档案完善进度卡——
/// 下载显示分数进度（条 + 百分比 + 字节数字），校验/解压/安装/清理显示不确定进度 + 阶段文案；
/// 主体点击进设置下载面（SP-25/SP-62），trailing [取消] 直达安装中心。
///
/// **独立观察域**（2026-09-16 业主实测「下载没有实时进度」的根因修复之二）：
/// 卡片读 `install.progress`/`phase`——下载中每 200ms 一次（ProgressCounter 节流
/// 上限 5 Hz）。这些读取若落在外层跟踪域内，每次进度写入都会让**整个首页 body**
/// 重新求值，其中含全量聚合（5 遍扫描 + 逐项日历运算），主 actor 饱和后进度条
/// 自身的渲染反而被挤掉——现象就是「卡住不动」。故**全部**读取下沉到内层
/// `WithPerceptionTracking`：进度只让本卡片重渲染。
/// 配套：`ASRInstallCenter.Install` 为独立可观察对象（进度不经 `active[index]`
/// 变址写入，`active` 只在安装开始/结束时变化）。
struct HomeModelDownloadCard: View {
    let install: ASRInstallCenter.Install
    let onOpen: () -> Void
    let onCancel: () -> Void

    var body: some View {
        WithPerceptionTracking {
            content
        }
    }

    /// 下载卡片主体。对 `install.progress`/`phase` 的读取**只准**在此求值，且只准由
    /// 上面的 `WithPerceptionTracking` 调用——否则读取会落回外层跟踪域，高频进度重新
    /// 牵连首页全量聚合。
    ///
    /// `@ViewBuilder` **不可省**：本函数在视图表达式前有 `let` 语句，没有它则
    /// `some View` 推不出底层类型（CI 35068918836：`function declares an opaque
    /// return type, but has no return statements`）。拆分时从原 `modelDownloadCard`
    /// 掉了这个标注——App/ 在 Linux 零类型检查、symcheck 也只看标识符，故只能由
    /// macOS L1 暴露。
    @ViewBuilder
    private var content: some View {
        // 校验/解压自 2026-09-16 起也报进度（见 ASRModelDownloadService.install）——
        // 这两段在 GB 级包上要数十秒，此前只能转不确定 spinner，读起来就是
        // 「进度条无反应、然后突然完成」。激活/清理两段仍无粒度，保持不确定态。
        let brief = install.phase
        // 进度值缺省时回落不确定态（阶段切换会重置进度基线，见 ASRInstallCenter.Install.submit）：
        // 没拿到分数却画一条 0% 的确定进度条，读起来是「卡在 0%」。
        // 2026-10-03 评审 R1-10c：分支下沉 Domain 纯函数（Linux 已测）。
        let showFraction = ASRDownloadProgress.showsDeterminateProgress(progress: install.progress, phase: brief)
        let fraction = showFraction ? (install.progress?.fraction ?? 0) : 0
        HStack(spacing: 10) {
            Button {
                // 2026-09-16 委员会评审：此前落 `.voiceEngineLab`（SP-62 引擎实验室）
                // ——该页不承载模型下载面。2026-09-28 B2-3：管理面并入统一
                // 「模型与数据资源」页（SP-64），HomeView 的 onOpen 同步改落
                // `.resourceManagement`。
                onOpen()
            } label: {
                HStack(spacing: 10) {
                    VLDownloadActivityIcon(isActive: !install.waiting)
                        .foregroundStyle(Color("brand-primary", bundle: .main))
                        .frame(width: 36)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(L10n.homeModelDownloadTitle)
                                .font(.subheadline.bold()).foregroundStyle(.primary)
                            Spacer(minLength: 8)
                            if showFraction {
                                Text("\(Int(fraction * 100))%")
                                    .font(.caption).monospacedDigit()
                                    .foregroundStyle(Color("brand-primary", bundle: .main))
                            }
                        }
                        Text(L10n.voiceEngineName(install.choice))
                            .font(.caption).foregroundStyle(.secondary)
                        // 不确定阶段（激活/清理/排队）不再渲染独立 spinner 行（2026-10-04 业主反馈①）：
                        // 进行态反馈由图标动效 + 阶段文案（detailText）承担——不确定阶段不再被
                        // spinner 行撑高；与确定阶段（条）仍存在条宽差，属确定/不确定两态的既有高度形态。
                        if showFraction {
                            ProgressView(value: fraction)
                                .tint(Color("brand-primary", bundle: .main))
                        }
                        // 传输形态（2026-09-16 诊断「下载慢」）：分段 N 路 / 单流退化。
                        // 单流意味着服务端没给 `Accept-Ranges` 或吞了 Range——那是
                        // 「慢」的首要嫌疑，此前完全不可见。
                        let modeLabel = downloadModeText(install.progress?.mode)
                        Text(modeLabel.isEmpty
                             ? detailText(install)
                             : "\(detailText(install)) · \(modeLabel)")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressScaleButtonStyle())   // 按压反馈统一（§3.3 V4.05）
            .accessibilityElement(children: .combine)
            .accessibilityLabel(L10n.homeModelDownloadTitle)
            .accessibilityValue("\(L10n.voiceEngineName(install.choice)) \(detailText(install))")
            .accessibilityHint(L10n.homeModelDownloadView)
            .accessibilityIdentifier("SP-04.home.modelDownload.\(install.choice.rawValue)")

            Button(L10n.commonCancel) { onCancel() }
                .font(.caption)
                .frame(minHeight: 44)
                .accessibilityIdentifier("SP-04.home.modelDownload.cancel.\(install.choice.rawValue)")
        }
    }
}

/// 多任务分组下载卡（2026-10-04 业主反馈②；round2 2026-10-04 自绘展开头）：
/// ≥2 任务合并为单行分组卡，默认折叠（@State 视图销毁即重置 = 新会话默认折叠；
/// 任务数在 ≥2 内变化不偷袭用户展开态），展开逐任务行（行内详情，不跳转——round2 ④）。
/// round2 ①：自绘展开头替代系统 DisclosureGroup——系统 label 行高/内容区默认边距
/// 与自绘卡紧凑 padding 叠加出大段空白带（DisclosureGroup 无边距收口 API；round1
/// 技术债⑥ 预登记路径达成）。头为 Button（PressScaleButtonStyle 按压反馈统一），
/// chevron 旋转 ≤350ms 状态迁移；VoiceOver 以 accessibilityValue 报展开/折叠态。
///
/// **观察域纪律（2026-09-16 根因同族，勿破坏）**：头只读 `choice`（let 不变）与
/// `waiting`（每任务仅翻转一次、低频）——**严禁在头读 progress/phase**：5 Hz 进度写入
/// 会让整张组卡（含展开行容器）重渲染。逐任务进度读取全部落在行卡自己的内层
/// WithPerceptionTracking（嵌套域：父 body 只构造子视图值、子 body 才读属性——inner 屏蔽 outer，
/// HomeView:216 外层包首页 body 已含此嵌套形态）。折叠头不展示聚合百分比/聚合条：
/// 跨任务求和/均值在任务移出或阶段清基线时回跳（2026-09-18/19/20 修掉的 bug 族），
/// 单任务才显示 NN%（复用 per-task 逻辑）。
struct HomeModelDownloadGroupCard: View {
    let installs: [ASRInstallCenter.Install]
    let onCancel: (ASRInstallCenter.Install) -> Void
    @State private var isExpanded = false

    var body: some View {
        WithPerceptionTracking {
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        // 图标动效激活 = 任一任务非排队（混合队列态：first 排队而 second 下载中时图标仍应动——
        // 不可用 first.phase 判定）；waiting 低频，落组卡域安全。
        let animating = installs.contains { !$0.waiting }
        VStack(spacing: 0) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 10) {
                    VLDownloadActivityIcon(isActive: animating)
                        .foregroundStyle(Color("brand-primary", bundle: .main))
                        .frame(width: 36)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.homeModelDownloadGroupFmt(installs.count))
                            .font(.subheadline.bold()).foregroundStyle(.primary)
                        Text(installs.map { L10n.voiceEngineName($0.choice) }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.down")
                        .font(.caption).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                        .animation(.easeInOut(duration: 0.35), value: isExpanded)   // ≤350ms 状态迁移（§10）
                }
                .frame(minHeight: 44)   // 折叠头触点 ≥44pt（§7.1）
                .contentShape(Rectangle())
            }
            .buttonStyle(PressScaleButtonStyle())
            .accessibilityValue(isExpanded
                                ? L10n.homeModelDownloadGroupExpandedValue
                                : L10n.homeModelDownloadGroupCollapsedValue)
            if isExpanded {
                VStack(spacing: 0) {
                    ForEach(installs) { install in
                        HomeModelDownloadGroupRow(install: install) {
                            onCancel(install)
                        }
                        // 展开行同处一个 List 行内，行背景覆盖整行但不分格——行间补分隔（打磨项，round1 C-5）
                        if install.id != installs.last?.id {
                            Divider()
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        // 容器标识必须配 .contain（§17 掩蔽纪律；CareTransientTaskCard 同款先例）——
        // l0-container-id-mask.py 跨结构体子树不分析，此 .contain 是唯一防线，不可省。
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("SP-04.home.modelDownload.group")
    }
}

/// 分组卡展开行（round2 2026-10-04 裁定③④）：
/// ③ leading = 44pt 语义红取消图标（替代原下载图标——状态语义由条/百分比/阶段文案
/// 承担；折叠头的动效图标已答「在做吗」，行内不重复），trailing「取消」文字按钮删除。
/// ④ 行内直接展示数据包介绍（用途 = voiceEngineHint 既有键；大小 = progress.totalBytes，
/// HEAD 未回前不渲染大小行），主体不可点、不跳转 SP-64（单任务卡保持跳转——D4 裁定）；
/// 版本字段待目录元数据管线（跟进项：勿在 5 Hz 重渲视图体做文件 I/O）。
///
/// **独立观察域**：与 HomeModelDownloadCard 同纪律——progress/phase 读取只准落在
/// 本行内层 WithPerceptionTracking（父组卡 body 只构造子视图值）。
struct HomeModelDownloadGroupRow: View {
    let install: ASRInstallCenter.Install
    let onCancel: () -> Void

    var body: some View {
        WithPerceptionTracking {
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        let brief = install.phase
        // 进度值缺省时回落不确定态（阶段切换会重置进度基线，见 ASRInstallCenter.Install.submit）：
        // 没拿到分数却画一条 0% 的确定进度条，读起来是「卡在 0%」。
        let showFraction = ASRDownloadProgress.showsDeterminateProgress(progress: install.progress, phase: brief)
        let fraction = showFraction ? (install.progress?.fraction ?? 0) : 0
        HStack(alignment: .top, spacing: 10) {
            Button {
                onCancel()
            } label: {
                Image(systemName: "xmark.circle")
                    .font(.title3)
                    .foregroundStyle(Color("semantic-danger", bundle: .main))
                    .frame(width: 36, height: 44)   // 触点 ≥44pt（§7.1）
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressScaleButtonStyle())
            .accessibilityLabel(L10n.commonCancel)
            .accessibilityIdentifier("SP-04.home.modelDownload.cancel.\(install.choice.rawValue)")
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(L10n.voiceEngineName(install.choice))
                        .font(.subheadline.bold()).foregroundStyle(.primary)
                    Spacer(minLength: 8)
                    if showFraction {
                        Text("\(Int(fraction * 100))%")
                            .font(.caption).monospacedDigit()
                            .foregroundStyle(Color("brand-primary", bundle: .main))
                    }
                }
                if showFraction {
                    ProgressView(value: fraction)
                        .tint(Color("brand-primary", bundle: .main))
                }
                let modeLabel = downloadModeText(install.progress?.mode)
                Text(modeLabel.isEmpty
                     ? detailText(install)
                     : "\(detailText(install)) · \(modeLabel)")
                    .font(.caption2).foregroundStyle(.secondary)
                // 数据包介绍（round2 ④）：用途一句话（既有键）+ 大小（HEAD 未回前不渲染）。
                Text(L10n.voiceEngineHint(install.choice))
                    .font(.caption).foregroundStyle(.secondary)
                if let total = install.progress?.totalBytes {
                    Text(L10n.asrModelIntroSizeFmt(ByteCountFormatter.string(fromByteCount: total, countStyle: .file)))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 6)
    }
}

/// 传输形态文案（2026-09-16）。空串 = 尚未确定（HEAD 探测完成前）。
/// 文件级私有：HomeModelDownloadCard 与 CareTransientTaskCard 共用
/// （2026-10-04 L1 修复：原为 HomeModelDownloadCard 私有成员，
/// 关怀瞬态卡跨类型引用不可见——CI #642 注解实证）。
/// @MainActor：Install 属性为 MainActor 隔离，文件级函数须同隔离
/// （非隔离上下文访问报错——CI #644 注解实证）。
@MainActor
private func downloadModeText(_ mode: ASRDownloadMode?) -> String {
    switch mode {
    case .segmented(let segments): return L10n.asrModelModeSegmented(segments)
    case .singleStream: return L10n.asrModelModeSingle
    case nil: return ""
    }
}

/// 阶段/进度文案（复用 SP-25 阶段键；下载显示字节数——慢链路下条位移缓慢，数字给确定反馈）。
@MainActor
private func detailText(_ install: ASRInstallCenter.Install) -> String {
    // 2026-09-19：并发槽满排队等待态——首页卡片同源如实呈现，不误报下载中/失败
    if install.waiting { return L10n.asrModelQueued }
    switch install.phase {
    case .verifying: return L10n.asrModelPhaseVerifying
    case .unpacking: return L10n.asrModelPhaseUnpacking
    case .activating: return L10n.asrModelPhaseActivating
    case .pruning: return L10n.asrModelPhasePruning
    case .downloading, nil:
        if let progress = install.progress {
            return L10n.asrModelProgress(
                ByteCountFormatter.string(fromByteCount: progress.receivedBytes, countStyle: .file),
                ByteCountFormatter.string(fromByteCount: progress.totalBytes, countStyle: .file))
        }
        return L10n.asrModelDownloading
    }
}

/// 后台任务失败卡（2026-09-16 评审）：与进度卡同形，红字提示 + [重试] + 关闭。
/// 2026-09-27 UX 席：此前注释谎称含 [重试] 实为仅关闭——补真重试按钮。
struct HomeModelDownloadFailedCard: View {
    let choice: VoiceEngineChoice
    let onRetry: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title3)
                .foregroundStyle(Color("semantic-warning", bundle: .main))
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.asrModelDownloadFailed)
                    .font(.subheadline.bold()).foregroundStyle(.primary)
                Text(L10n.voiceEngineName(choice))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(L10n.retry) { onRetry() }
                .font(.caption)
                .frame(minHeight: 44)
                .accessibilityIdentifier("SP-04.home.modelDownload.failure.retry")
            Button(L10n.commonCancel) { onDismiss() }
                .font(.caption)
                .frame(minHeight: 44)
                .accessibilityIdentifier("SP-04.home.modelDownload.failure.dismiss")
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("SP-04.home.modelDownload.failure.\(choice.rawValue)")
    }
}

/// 首页滑动处置底部条（2026-09-26 原子结构轮第三批：自 HomeView 迁出）：
/// 撤销 / 重试双态；`.task(id:)` 以代次计时，取消（换条/消失）即返回不清理，
/// 到点后经 `onExpire` 回父级核对代次——旧计时器不得清掉新条（round2 U3）。
struct HomeActionToastBanner: View {
    let toast: HomeActionToast
    let onUndo: (String) -> Void
    let onRetry: () -> Void
    let onExpire: () -> Void
    /// round2 U-N6：Reduce Motion 开启时行移除/底部条不做动画。
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var rowAnimation: Animation? { reduceMotion ? nil : .snappy(duration: 0.22) }

    var body: some View {
        HStack(spacing: 12) {
            Text(toast.title).font(.subheadline).lineLimit(1)
            Spacer(minLength: 8)
            switch toast.kind {
            case .undo(let key):
                Button(L10n.homeSwipeUndo) { onUndo(key) }
                    .font(.subheadline.bold())
                    .frame(minHeight: 44)   // 设计系统触控目标 ≥44pt
            case .failed:
                Button(L10n.retry) { onRetry() }
                    .font(.subheadline.bold())
                    .frame(minHeight: 44)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.thinMaterial, in: Capsule())
        .padding(.horizontal, 16).padding(.bottom, 12)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .task(id: toast.id) {
            do { try await Task.sleep(for: .seconds(toast.autoDismissSeconds)) } catch { return }
            withAnimation(rowAnimation) { onExpire() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("SP-04.home.undo")
    }
}
