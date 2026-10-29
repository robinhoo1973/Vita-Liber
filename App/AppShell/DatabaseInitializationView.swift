import SwiftUI
import UIKit
import Domain
import Infrastructure
import Perception

/// 启动门唯一可见页面：本地数据库未就绪前不挂载主界面。
/// 设计约束：三语 L10n、无硬编码颜色/字号、失败态可重试、VoiceOver 可读。
///
/// U-批 B3（2026-10-28）：启动自检「3+1」四行清单——
/// ①本地档案文件 ②档案结构版本 ③医疗数据目录（本机常驻）+ ④参考目录版本
/// （低权重页脚行，仅入口，点「检查」才联网）。行状态由 Domain 纯函数
/// `StartupSelfCheckRows` 从 `BootChecklistSnapshot` 推导；行④由
/// `CatalogSlicesState.aggregate` 驱动。播报纪律（UI 席 §3.3）：只播
/// 进入·完成·失败三次。
///
/// 医疗目录卡（2026-10-27 方案 B）：单主按钮 + 单次动作，完成/无候选自动进入；
/// 两次显式点击语义不变（检查只取元数据，下载是第二次显式动作）。
struct DatabaseInitializationView: View {
    @ObservedObject var model: DatabaseBootModel
    /// 终态播报只发一次（retry 后复位）。
    @State private var announcedTerminal = false
    /// 下载网络门（2026-10-29）：网络确认 + 线路策略（默认蜂窝/Wi-Fi 均可）。
    /// CI 40867321903 红修复：本环境注入曾漏插（锚点不匹配），descriptor 三处
    /// 引用先于声明落地——补齐。
    @Environment(DownloadNetworkGate.self) private var networkGate
    /// 线路策略拦截提示（仅 Wi-Fi 策略/离线时告知原因）。
    @State private var networkBlockedShown = false

    var body: some View {
        WithPerceptionTracking {
            content
                // U-批 B2：首帧呈现上报（被动交接门从此刻起算；headless 无此路径）。
                .onAppear {
                    model.noteSelfCheckPresented()
                    // 4 项=三行本机自检 + 页脚行④（行编号 1–4 一致）。
                    Self.announce(L10n.startupCheckA11yIntroFmt(4))
                }
                .onChangeCompat(of: terminalKey) { _, key in
                    if key == nil {
                        announcedTerminal = false
                    } else if let key, !announcedTerminal {
                        announcedTerminal = true
                        if key == "failed" {
                            Self.announce(L10n.startupCheckA11yFailedFmt(terminalFailureText))
                        } else {
                            Self.announce(L10n.startupCheckA11yDone)
                        }
                    }
                }
                .onChangeCompat(of: updatesBusy) { _, _ in
                    // 行④进行中 > 被动 hold（五级优先级）：开始/结束后重评估交接。
                    model.rowFourActivityChanged()
                }
        }
    }

    private var content: some View {
        // 大字号下可滚动（ui-ux §5.12.4「大字号可滚动」）；本页在 session 之前，
        // 无法读取关怀模式，触控目标一律从宽 ≥64pt。
        ScrollView {
            VStack(spacing: 20) {
                iconBadge
                VStack(spacing: 8) {
                    Text(titleText)
                        .font(.title2.bold())
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("STARTUP.initialization.title")
                    if model.failure == nil {
                        Text(model.awaitingCatalogChoice ? L10n.startupCatalogBody : L10n.startupCheckSubtitle)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                if model.failure == nil && model.awaitingCatalogChoice {
                    catalogCard
                } else {
                    selfCheckSection
                }
                privacyRow
                if let failure = model.failure {
                    failureCard(failure)
                        .transition(.opacity)
                }
            }
            .padding(24)
            .frame(maxWidth: 520)
            .glassCard()
            .padding(.horizontal, 24)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .tintedCanvas()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("STARTUP.initialization")
    }

    private var titleText: String {
        if model.failure != nil { return L10n.startupInitFailureTitle }
        if model.awaitingCatalogChoice { return L10n.startupInitReadyTitle }
        return L10n.startupCheckTitle
    }

    // MARK: - 启动自检四行清单（U-批 B3）

    /// 行状态事实投影：快照在（advisory/final）+ 进行态（失败后不显示进行中）。
    private var facts: StartupSelfCheckFacts {
        let snapshot = model.bootSnapshot
        return StartupSelfCheckFacts(
            probe: snapshot?.probe ?? Self.emptyProbe,
            decision: snapshot?.decision,
            health: snapshot?.sliceHealth ?? [:],
            committedKinds: snapshot?.committedKinds ?? [],
            didFail: model.failure != nil,
            isWorking: isWorking)
    }

    private var isWorking: Bool {
        guard model.failure == nil else { return false }
        switch model.phase {
        case .idle, .ready, .catalogChoice: return false
        default: return true
        }
    }

    private static let emptyProbe = DatabaseProbeSnapshot(
        exists: false, sizeBytes: 0, headerValid: false, observedVersion: nil,
        tableCount: 0, requiredTablesPresent: 0, requiredTablesExpected: 0,
        originalsPresent: false)

    private var selfCheckSection: some View {
        let rows = StartupSelfCheckRows.rows(facts)
        return Group {
            if showsExpandedRows {
                expandedChecklist(rows)
            } else {
                summaryRow(rows)
            }
        }
        .padding(.vertical, 4)
        // 容器标识必须配 .contain，否则标识会压到子元素上（L0 第 17 节）。
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("STARTUP.selfcheck")
    }

    /// 批 ②（2026-10-29）：稳态=一行摘要；异常/首启/迁移/进行中/卡片态/用户展开
    /// 默认展开四行（UX 席稳态折叠裁决 + 测试席 hold 兼容）。
    private var showsExpandedRows: Bool {
        if model.failure != nil || model.isSelfCheckSummaryExpanded
            || model.debugHoldForcesExpanded { return true }
        if model.awaitingCatalogChoice || isWorking { return true }
        switch model.bootSnapshot?.decision {
        case .fresh, .migrate: return true
        case .ready, .tooNew, .missingWithOriginals, .corrupt, nil: return false
        }
    }

    private func expandedChecklist(_ rows: StartupSelfCheckRowStates) -> some View {
        VStack(spacing: 4) {
            if model.isSelfCheckSummaryExpanded {
                // 用户展开态给收起入口（批 ② 500ms 恢复规则的交互面；
                // 系统强制展开场景——首启/迁移/失败/hold——无收起钮）。
                Button {
                    model.toggleSelfCheckSummary()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.up")
                            .font(.footnote.weight(.semibold))
                        Text(L10n.startupCheckSummaryCollapse)
                            .font(.footnote)
                    }
                    .foregroundStyle(Color("text-secondary", bundle: .main))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("STARTUP.selfcheck.summary.collapse")
            }
            checklistRow(identifier: "dbFile", index: 1, title: L10n.startupCheckRowDbFile,
                         state: rows.file, detail: fileDetail(rows.file),
                         note: nil, icon: "externaldrive.fill")
            rowDivider
            checklistRow(identifier: "schema", index: 2, title: L10n.startupCheckRowSchema,
                         state: rows.schema, detail: schemaDetail(rows.schema),
                         note: schemaNote(rows.schema), icon: "square.stack.3d.up.fill")
            rowDivider
            checklistRow(identifier: "catalog", index: 3, title: L10n.startupCheckRowCatalog,
                         state: rows.catalog, detail: catalogDetail(rows.catalog),
                         note: catalogNote(rows.catalog), icon: "books.vertical.fill")
            if model.failure == nil {
                rowDivider
                updatesFooterRow
                footerNotes(rows)
            }
        }
    }

    /// 稳态摘要：纯信息（800ms floor 内不可点定案 SS-1）；展开按钮仅供页面驻留
    /// 场景（hold/慢启动/迁移）——禁「全部通过/数据正常/已是最新」措辞。
    private func summaryRow(_ rows: StartupSelfCheckRowStates) -> some View {
        let states = [rows.file, rows.schema, rows.catalog]
        let passed = states.filter { $0 == .passed }.count
        let needsAttention = states.contains { $0 == .warning }
        return HStack(spacing: 12) {
            Image(systemName: needsAttention ? "exclamationmark.circle.fill" : "checkmark.seal.fill")
                .font(.title3)
                .foregroundStyle(needsAttention
                                 ? Color("semantic-warning", bundle: .main)
                                 : Color("brand-primary", bundle: .main))
                .accessibilityHidden(true)
            Text(needsAttention
                 ? L10n.startupCheckSummaryWarning(Int64(passed))
                 : L10n.startupCheckSummaryPassed(Int64(passed)))
                .font(.body)
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
            Button {
                model.toggleSelfCheckSummary()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color("text-secondary", bundle: .main))
                    .frame(minWidth: 44, minHeight: 44)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("STARTUP.selfcheck.summary.expand")
            .accessibilityLabel(L10n.startupCheckSummaryExpand)
        }
        .frame(minHeight: 64)
        .accessibilityElement(children: .contain)
    }

    private var rowDivider: some View {
        Divider().opacity(0.4).padding(.leading, 40)
    }

    /// 单行：图标 + 标题 + 说明 + 末态胶囊；AX 大字号自动纵排（ViewThatFits）。
    private func checklistRow(identifier: String, index: Int, title: String,
                              state: StartupSelfCheckRowState, detail: String?,
                              note: String?, icon: String) -> some View {
        let stateText = Self.stateText(state)
        return ViewThatFits(in: .horizontal) {
            rowHStack(title: title, state: state, detail: detail, note: note,
                      icon: icon, stateText: stateText)
            rowVStack(title: title, state: state, detail: detail, note: note,
                      icon: icon, stateText: stateText)
        }
        .frame(minHeight: 64)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.startupCheckA11yRowFmt(Int64(index), title, stateText))
        .accessibilityIdentifier("STARTUP.selfcheck.\(identifier)")
    }

    private func rowHStack(title: String, state: StartupSelfCheckRowState,
                           detail: String?, note: String?, icon: String,
                           stateText: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            rowIcon(icon, state: state)
            rowText(title: title, detail: detail, note: note)
            Spacer(minLength: 8)
            stateChip(state, text: stateText)
        }
        .padding(.vertical, 12)
    }

    private func rowVStack(title: String, state: StartupSelfCheckRowState,
                           detail: String?, note: String?, icon: String,
                           stateText: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                rowIcon(icon, state: state)
                rowText(title: title, detail: detail, note: note)
            }
            stateChip(state, text: stateText).padding(.leading, 40)
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func rowIcon(_ name: String, state: StartupSelfCheckRowState) -> some View {
        Image(systemName: name)
            .font(VLFont.startupCheckRowIcon)
            .foregroundStyle(Self.stateTint(state))
            .frame(width: 28, height: 28)
    }

    private func rowText(title: String, detail: String?, note: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.subheadline.weight(.medium))
            if let detail {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let note {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func stateChip(_ state: StartupSelfCheckRowState, text: String) -> some View {
        if state == .running {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(text).font(.footnote).foregroundStyle(.secondary)
            }
        } else {
            Label(text, systemImage: Self.stateSymbol(state))
                .font(.footnote)
                .foregroundStyle(Self.stateTint(state))
                .labelStyle(.titleAndIcon)
        }
    }

    private static func stateText(_ state: StartupSelfCheckRowState) -> String {
        switch state {
        case .pending: return L10n.startupCheckStatePending
        case .running: return L10n.startupCheckStateRunning
        case .passed: return L10n.startupCheckStatePassed
        case .warning: return L10n.startupCheckStateWarning
        case .failed: return L10n.startupCheckStateFailed
        case .skipped: return L10n.startupCheckStateSkipped
        }
    }

    private static func stateSymbol(_ state: StartupSelfCheckRowState) -> String {
        switch state {
        case .pending: return "circle.dotted"
        case .running: return "circle.dashed"
        case .passed: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .failed: return "xmark.octagon.fill"
        case .skipped: return "minus.circle"
        }
    }

    private static func stateTint(_ state: StartupSelfCheckRowState) -> Color {
        switch state {
        case .passed:
            return Color("semantic-success", bundle: .main)
        case .warning, .failed:
            return Color("semantic-warning", bundle: .main)
        case .pending, .running, .skipped:
            return .secondary
        }
    }

    // MARK: 行① 本地档案文件

    private func fileDetail(_ state: StartupSelfCheckRowState) -> String? {
        guard state == .passed else { return nil }
        let exists = model.bootSnapshot?.probe.exists ?? false
        let observed = model.bootSnapshot?.probe.observedVersion
        if !exists {
            return L10n.startupCheckDbFileCreatedFmt(Int64(SchemaMigrations.latestVersion))
        }
        return L10n.startupCheckDbFileFoundFmt(Int64(observed ?? SchemaMigrations.latestVersion))
    }

    // MARK: 行② 档案结构版本

    private func schemaDetail(_ state: StartupSelfCheckRowState) -> String? {
        switch state {
        case .running:
            if case .migrating(let from, let to) = model.phase {
                return L10n.startupInitStageMigrate(from, to)
            }
            return nil
        case .passed:
            guard let decision = model.bootSnapshot?.decision else { return nil }
            switch decision {
            case .migrate(let from, let to):
                return L10n.startupCheckSchemaUpdatedFmt(Int64(from), Int64(to))
            case .fresh:
                return L10n.startupCheckSchemaOkFmt(Int64(SchemaMigrations.latestVersion))
            case .ready(let version):
                return L10n.startupCheckSchemaOkFmt(Int64(version))
            case .tooNew, .missingWithOriginals, .corrupt:
                return nil
            }
        default:
            return nil
        }
    }

    /// 单向迁移提示（O5）：升级后旧版本 App 打不开此档案，一屏一句。
    private func schemaNote(_ state: StartupSelfCheckRowState) -> String? {
        guard state == .passed,
              case .migrate = model.bootSnapshot?.decision else { return nil }
        return L10n.startupCheckSchemaOneWayNote
    }

    // MARK: 行③ 医疗数据目录

    private var readySliceCount: Int {
        let health = model.bootSnapshot?.sliceHealth ?? [:]
        return CatalogSliceKind.allCases.filter { health[$0] == .ready }.count
    }

    private var missingRequiredSliceCount: Int {
        let health = model.bootSnapshot?.sliceHealth ?? [:]
        return CatalogSliceBootPolicy.startupRequiredKinds.filter { health[$0] != .ready }.count
    }

    private func catalogDetail(_ state: StartupSelfCheckRowState) -> String? {
        switch state {
        case .running:
            return L10n.startupCheckCatalogChecking
        case .passed:
            return L10n.startupCheckCatalogInstalledFmt(
                Int64(readySliceCount), Int64(CatalogSliceBootPolicy.displayedSliceCount))
        case .warning:
            return L10n.startupCheckCatalogPartialFmt(Int64(missingRequiredSliceCount))
        default:
            return nil
        }
    }

    /// profile 第四片「可选 · 未安装」（O4：可选但常显；不阻塞、不告警）。
    private func catalogNote(_ state: StartupSelfCheckRowState) -> String? {
        guard state == .passed,
              let health = model.bootSnapshot?.sliceHealth,
              health[.profile] != .ready else { return nil }
        return L10n.startupCheckStateOptional
    }

    // MARK: 行④ 参考目录版本（低权重页脚；仅入口，点「检查」才联网）

    private var updatesBusy: Bool {
        guard let aggregate = model.catalogSlices?.aggregate else { return false }
        return aggregate == .checking || aggregate == .updating
    }

    private var updatesDetail: String {
        guard let slices = model.catalogSlices else { return L10n.startupCheckUpdatesIdle }
        switch slices.aggregate {
        case .notChecked:
            return L10n.startupCheckUpdatesIdle
        case .checking, .updating:
            return L10n.resourceCatalogSlicesChecking
        case .allCurrent:
            return L10n.startupCheckUpdatesCurrent
        case .sourcePartial:
            // Aggregate.sourcePartial 无载荷（B3 评审修复：计数经 descriptor 取）。
            if case .sourcePartial(let count) =
                CatalogSlicesPromptPresentation.descriptor(for: slices, firstLaunch: !UserDefaults.standard.bool(forKey: "onboardingFinished"), networkAvailable: networkGate.isConnected, policyBlocked: networkGate.blockReason() == .wifiOnlyPolicy).status {
                return L10n.startupCheckUpdatesSourcePartialFmt(Int64(count))
            }
            return L10n.resourceCatalogSlicesAllCurrent
        case .updatesAvailable, .partialFailure:
            // 一败其余最新时 aggregate 亦为 .partialFailure 且候选为空
            // （B3 评审修复：不得显示「0 个可更新」，走失败短语）。
            if slices.candidates.isEmpty {
                let status = CatalogSlicesPromptPresentation.descriptor(for: slices, firstLaunch: !UserDefaults.standard.bool(forKey: "onboardingFinished"), networkAvailable: networkGate.isConnected, policyBlocked: networkGate.blockReason() == .wifiOnlyPolicy).status
                return Self.statusText(status, slices: slices)
            }
            return L10n.startupCheckUpdatesCandidatesFmt(Int64(slices.candidates.count))
        case .appUpdateRequired:
            return L10n.startupCheckUpdatesAppRequired
        case .unavailable:
            // checker 缺失=未发布/未配置，从未发起网络（B3 评审修复）。
            return L10n.resourceCatalogUnavailable
        case .allFailed:
            return L10n.startupCheckUpdatesOffline
        }
    }

    private var updatesState: StartupSelfCheckRowState {
        guard let aggregate = model.catalogSlices?.aggregate else { return .pending }
        switch aggregate {
        case .notChecked:
            return .pending
        case .checking, .updating:
            return .running
        case .allCurrent, .sourcePartial:
            return .passed
        case .updatesAvailable, .partialFailure, .appUpdateRequired:
            return .warning
        case .allFailed, .unavailable:
            return .failed
        }
    }

    private var updatesFooterRow: some View {
        let stateText = Self.stateText(updatesState)
        return HStack(alignment: .top, spacing: 12) {
            rowIcon("arrow.triangle.2.circlepath", state: updatesState)
            rowText(title: L10n.startupCheckRowUpdates, detail: updatesDetail, note: nil)
            Spacer(minLength: 8)
            Button {
                model.checkCatalog()
            } label: {
                Text(L10n.startupCheckUpdatesCheck)
                    .frame(minHeight: 64)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.bordered)
            .disabled(updatesBusy || model.catalogSlices == nil)
            .accessibilityIdentifier("STARTUP.selfcheck.updates.check")
            .accessibilityHint(L10n.startupCheckUpdatesTapNote)
        }
        .padding(.vertical, 12)
        // 含子按钮 → 必须 .contain（L0 第 17 节）。
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.startupCheckA11yRowFmt(4, L10n.startupCheckRowUpdates, stateText))
        .accessibilityIdentifier("STARTUP.selfcheck.updates")
    }

    @ViewBuilder
    private func footerNotes(_ rows: StartupSelfCheckRowStates) -> some View {
        VStack(spacing: 6) {
            Text(L10n.startupCheckUpdatesTapNote)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if rows.file == .passed && rows.schema == .passed && rows.catalog == .passed {
                Text(L10n.startupCheckSummaryPassFmt(3))
                    .font(.footnote)
                    .foregroundStyle(Color("semantic-success", bundle: .main))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }

    // MARK: - 播报（进入·完成·失败三次；UI 席 §3.3）

    private var terminalKey: String? {
        if model.failure != nil { return "failed" }
        // 批 ③：final 快照=发布完成（与旧布尔同语义；committedKinds 可能为空，
        // 但发布本身即终态——不得因零切片而吞掉「完成」播报）。
        if model.bootSnapshot?.decision != nil, model.container != nil { return "done" }
        return nil
    }

    private var terminalFailureText: String {
        guard let failure = model.failure else { return "" }
        return failureBody(failure)
    }

    private static func announce(_ text: String) {
        UIAccessibility.post(notification: .announcement, argument: text)
    }

    // MARK: - 医疗目录卡（方案 B：descriptor 驱动）

    /// 内卡表面（UI 席：目录卡/失败卡改 L1 实心表面，防玻璃卡内嵌套模糊）。
    private var cardSurface: Color {
        Color(.secondarySystemGroupedBackground)
    }

    @ViewBuilder
    private var catalogCard: some View {
        if let slices = model.catalogSlices {
            let descriptor = CatalogSlicesPromptPresentation.descriptor(for: slices, firstLaunch: !UserDefaults.standard.bool(forKey: "onboardingFinished"), networkAvailable: networkGate.isConnected, policyBlocked: networkGate.blockReason() == .wifiOnlyPolicy)
            let size = Self.candidateSizeText(descriptor.status)
            let statusText = Self.statusText(descriptor.status, slices: slices)

            VStack(alignment: .leading, spacing: 12) {
                Label(model.isCatalogMandatory ? L10n.startupCatalogTitleRequired : L10n.startupCatalogTitle,
                      systemImage: "books.vertical")
                    .font(.headline)
                if case .completed = descriptor.status {
                    Label(statusText, systemImage: "checkmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(Color("semantic-success", bundle: .main))
                } else {
                    Text(statusText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if case .candidate = descriptor.status {
                    Text(L10n.startupCatalogSizeHint)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if case .phase(_, let progress) = descriptor.status {
                    catalogProgress(progress)
                }
                if case .phase(_, .activating) = descriptor.status {
                    Text(L10n.startupCatalogActivating)
                        .font(.footnote)
                        .foregroundStyle(Color("semantic-warning", bundle: .main))
                }
                catalogActions(descriptor, sizeText: size)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(cardSurface, in: RoundedRectangle(cornerRadius: VLCornerRadius.compact))
            // 容器标识必须配 .contain，否则标识会压到子按钮上（L0 第 17 节）。
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("STARTUP.catalog")
            // 播报纪律（§5.12.4）：只在状态短语变化时播一次；下载字节变化不播。
            .onChangeCompat(of: Self.cardPhaseKey(descriptor.status)) { _, _ in
                UIAccessibility.post(notification: .announcement, argument: statusText)
            }
            .onChangeCompat(of: descriptor.autoEnter) { _, autoEnter in
                if autoEnter { model.scheduleAutoEnterIfNeeded() }
            }
            .alert(L10n.downloadNetworkBlockedTitle, isPresented: $networkBlockedShown) {
                // 2026-10-29 业主：探测到网络不可用 → 建议跳系统设置（公开 API
                // 只能打开本 App 设置页；文案已含「到系统设置开启」指引）。
                if networkGate.blockReason()?.suggestsSystemSettings == true {
                    Button(L10n.helpPermOpenSettings) { SystemLinks.openSettings() }
                }
                Button(L10n.onboard_gotIt, role: .cancel) { }
            } message: {
                Text(L10n.downloadNetworkBlockedBody)
            }
        }
    }

    /// 每个状态最多一个主按钮 + 一个低强调次动作；busy/none 的主按钮禁用。
    private func catalogActions(_ descriptor: CatalogSlicesPromptDescriptor,
                                sizeText: String?) -> some View {
        VStack(spacing: 12) {
            Button {
                perform(descriptor.primary)
            } label: {
                HStack(spacing: 8) {
                    if descriptor.primary == .busy {
                        ProgressView().controlSize(.small)
                    }
                    Text(Self.primaryTitle(descriptor.primary, status: descriptor.status,
                                           sizeText: sizeText))
                        .frame(maxWidth: .infinity, minHeight: 64)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(descriptor.primary == .busy || descriptor.primary == .none)
            .contentShape(Rectangle())
            .accessibilityIdentifier("STARTUP.catalog.primary")
            .accessibilityHint(primaryHint(descriptor.primary))

            if let secondary = descriptor.secondary {
                Button {
                    perform(secondary)
                } label: {
                    Text(Self.secondaryTitle(secondary))
                        .frame(maxWidth: .infinity, minHeight: 64)
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .accessibilityIdentifier("STARTUP.catalog.continue")
                .accessibilityHint(secondaryHint(secondary))
            }
        }
    }

    private func perform(_ action: MedicalCatalogPromptAction) {
        // 2026-10-29 业主：下载前确认网络与线路策略（默认蜂窝与 Wi-Fi 均可；
        // 「我的 → 模型与数据资源」可改仅 Wi-Fi）。被拦截时给出原因，不静默。
        switch action {
        case .check, .recheck, .install, .retryInstall:
            if networkGate.blockReason() != nil {
                networkBlockedShown = true
                return
            }
        default:
            break
        }
        switch action {
        case .check, .recheck: model.checkCatalog()
        case .install, .retryInstall: model.installCatalog()
        case .enter, .enterKeepingUpdate: model.enterKeepingUpdate()
        case .continueWithout: model.deferAndEnter()
        case .cancelCheckAndContinue, .cancelUpdateAndContinue: model.cancelAndEnter()
        case .busy, .none: break
        }
    }

    private func primaryHint(_ action: MedicalCatalogPromptAction) -> String {
        switch action {
        case .check, .recheck: return L10n.updateCenterCheckAllHint
        case .install, .retryInstall: return L10n.resourceCatalogUpdateHint
        default: return ""
        }
    }

    private func secondaryHint(_ action: MedicalCatalogPromptAction) -> String {
        switch action {
        case .cancelCheckAndContinue: return L10n.resourceCatalogCancelCheckHint
        case .cancelUpdateAndContinue: return L10n.resourceCatalogCancelHint
        default: return ""
        }
    }

    /// 候选下载总量文案（仅 candidate 态）；其余状态 nil。
    private static func candidateSizeText(_ status: CatalogSlicesPromptStatus) -> String? {
        guard case .candidate(_, let totalSize) = status, totalSize > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)
    }

    /// 状态短语（切片聚合；未知进行中片显示其名 + 阶段）。
    private static func statusText(_ status: CatalogSlicesPromptStatus,
                                   slices: CatalogSlicesState) -> String {
        switch status {
        case .idleNoLocal(let installed):
            return installed > 0
                ? L10n.resourceCatalogSlicesNotCheckedFmt(
                    installed, CatalogSliceKind.allCases.count)
                : L10n.startupCatalogStatusIdleNoLocal
        case .checking:
            return L10n.resourceCatalogSlicesChecking
        case .candidate(let count, let totalSize):
            return L10n.resourceCatalogSlicesCandidatesFmt(
                slices.installedCount, CatalogSliceKind.allCases.count, count,
                ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file))
        case .phase(let kind, let progress):
            return kindName(kind) + " · " + MedicalCatalogPromptCopy.phaseText(progress)
        case .completed(let version):
            return version.map { L10n.startupCatalogCompletedFmt($0) }
                ?? L10n.startupCatalogCompleted
        case .upToDate:
            return L10n.resourceCatalogSlicesAllCurrent
        case .sourcePartial(let count):
            return L10n.resourceCatalogSlicesSourcePartialFmt(count)
        case .failure(let failed, let hasLocal):
            return hasLocal
                ? L10n.resourceCatalogSlicesPartialFailureFmt(failed)
                : L10n.resourceCatalogUpdateFailedNoLocal
        case .appUpdateRequired(let count):
            return L10n.resourceCatalogSlicesAppUpdateRequiredFmt(count)
        case .unavailable:
            return L10n.resourceCatalogUnavailable
        }
    }

    /// 阶段/状态稳定键：只反映短语类别与阶段，不随下载字节变化（播报去抖）。
    private static func cardPhaseKey(_ status: CatalogSlicesPromptStatus) -> String {
        switch status {
        case .idleNoLocal(let installed): return "idle-\(installed)"
        case .checking: return "checking"
        case .candidate(let count, _): return "candidate-\(count)"
        case .phase(let kind, let progress):
            switch progress {
            case .downloading: return "downloading-\(kind.rawValue)"
            case .verifyingPackage: return "verifying-\(kind.rawValue)"
            case .decrypting: return "decrypting-\(kind.rawValue)"
            case .verifyingCatalog: return "verifyingCatalog-\(kind.rawValue)"
            case .activating: return "activating-\(kind.rawValue)"
            }
        case .completed: return "completed"
        case .upToDate: return "upToDate"
        case .sourcePartial(let count): return "sourcePartial-\(count)"
        case .failure(let failed, _): return "failed-\(failed)"
        case .appUpdateRequired(let count): return "appRequired-\(count)"
        case .unavailable: return "unavailable"
        }
    }

    private static func primaryTitle(_ action: MedicalCatalogPromptAction,
                                     status: CatalogSlicesPromptStatus,
                                     sizeText: String?) -> String {
        switch action {
        case .check: return L10n.resourceCatalogCheck
        case .recheck: return L10n.resourceCatalogRecheck
        case .install: return L10n.startupCatalogInstallFmt(sizeText ?? "")
        case .retryInstall: return L10n.startupCatalogRetryInstall
        case .enter: return L10n.startupCatalogEnter
        case .enterKeepingUpdate: return L10n.startupCatalogUseWhileUpdating
        case .continueWithout: return L10n.startupCatalogContinue
        case .cancelCheckAndContinue: return L10n.startupCatalogCancelCheckContinue
        case .cancelUpdateAndContinue: return L10n.startupCatalogCancelUpdateContinue
        case .busy:
            if case .phase(_, .activating) = status { return L10n.startupCatalogActivating }
            return L10n.resourceCatalogChecking
        case .none: return L10n.startupCatalogUpgradeUnavailable
        }
    }

    private static func secondaryTitle(_ action: MedicalCatalogPromptAction) -> String {
        switch action {
        case .cancelCheckAndContinue: return L10n.startupCatalogCancelCheckContinue
        case .cancelUpdateAndContinue: return L10n.startupCatalogCancelUpdateContinue
        default: return L10n.startupCatalogContinue
        }
    }

    private static func kindName(_ kind: CatalogSliceKind) -> String {
        switch kind {
        case .drug: return L10n.resourceCatalogSliceDrugName
        case .facility: return L10n.resourceCatalogSliceFacilityName
        case .reference: return L10n.resourceCatalogSliceReferenceName
        case .profile: return L10n.resourceCatalogSliceProfileName
        }
    }

    @ViewBuilder
    private func catalogProgress(_ progress: MedicalCatalogDownloadProgress) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if case .downloading(let received, let total) = progress {
                ProgressView(value: total > 0 ? min(1, Double(received) / Double(total)) : 0)
                    .accessibilityValue(percentText(received, total))
                    .accessibilityAddTraits(.updatesFrequently)
                Text(L10n.resourceProgressBytes(byteText(received), byteText(total)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(percentText(received, total))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(L10n.resourceCatalogDownloadingKeepOpen)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(L10n.startupCatalogBackgroundGrace)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("STARTUP.catalog.progress")
    }

    /// 稳定阶段键：只播报阶段切换，下载字节变化不触发播报。
    private func catalogPhaseKey(_ progress: MedicalCatalogDownloadProgress?) -> String {
        guard let progress else { return "idle" }
        switch progress {
        case .downloading: return "downloading"
        case .verifyingPackage: return "verifyingPackage"
        case .decrypting: return "decrypting"
        case .verifyingCatalog: return "verifyingCatalog"
        case .activating: return "activating"
        }
    }

    private func percentText(_ received: Int64, _ total: Int64) -> String {
        guard total > 0 else { return "" }
        return "\(min(100, received * 100 / total))%"
    }

    private func byteText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    // MARK: - 顶图/隐私行/失败卡

    private var iconBadge: some View {
        Image(systemName: model.failure == nil ? "heart.text.square.fill" : "exclamationmark.triangle.fill")
            .font(VLFont.homeActionIcon)
            .foregroundStyle(model.failure == nil ? Color.accentColor : Color("semantic-warning", bundle: .main))
            .frame(width: 88, height: 88)
            .background(.thinMaterial, in: Circle())
            .accessibilityHidden(true)
    }

    private var privacyRow: some View {
        Label(L10n.startupInitPrivacy, systemImage: "lock.shield")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
    }

    private func failureCard(_ failure: DatabaseBootFailure) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(failureBody(failure))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                Task { await model.retry() }
            } label: {
                Text(L10n.startupInitRetry)
                    .frame(maxWidth: .infinity, minHeight: 64)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("STARTUP.initialization.retry")
            if model.readOnlyContainer != nil {
                // 只读降级入口（B2）：仅 tooNew 且只读打开成功时出现。
                Button {
                    model.enterReadOnly()
                } label: {
                    Text(L10n.startupReadonlyEnter)
                        .frame(maxWidth: .infinity, minHeight: 64)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("STARTUP.readonly.enter")
            }
        }
        .padding(16)
        .background(cardSurface, in: RoundedRectangle(cornerRadius: VLCornerRadius.compact))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("STARTUP.failure")
    }

    private func failureBody(_ failure: DatabaseBootFailure) -> String {
        switch failure {
        case .missingWithOriginals:
            return L10n.startupInitFailureMissingOriginals
        case .databaseAmbiguous:
            return L10n.startupInitFailureAmbiguous
        case .corrupt:
            return L10n.startupInitFailureCorrupt
        case .tooNew:
            return L10n.startupInitFailureTooNew
        case .migrationIncomplete(let found, let expected):
            return L10n.startupInitFailureMigration(found, expected)
        case .openFailed, .unexpected:
            return L10n.startupInitFailureGeneric
        }
    }
}
