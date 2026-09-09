import SwiftUI
import Domain
import Infrastructure

/// F16 设备观察四级提示（L0-L3，§5.12 / ui-ux §5.15 预警历史与信源详情）。
///
/// 铁律：
/// 1. 证据卡是**引用式提示**（ADR-010）——五段结构由 Domain 组装，本层只渲染；
/// 2. 措辞负清单一票否决（BR-006 延伸）：`WordingBlacklist.violation` 命中的
///    文案不得上屏——拦截显示优于展示错误；
/// 3. 信源链接 `citationUrl` 必须可点开原文（F16 验收），L1+ 卡片即引用它。

// MARK: - 预警历史

struct AlertHistoryView: View {
    /// 装配层注入的信源条目（metricKey → entry），用于「打开原文」；
    /// 缺条目时降级为只读书目行（不臆造 URL）
    var sourceEntries: [String: GuidelineEntry] = [:]
    @Environment(M2HubStore.self) private var hub
    @Environment(AppState.self) private var app
    @Environment(AppDataChangeCenter.self) private var dataChange
    @State private var history: [GuidelineStore.AlertEvent] = []
    @State private var historyLimit = 200
    // FR16.10 预警历史：按指标/级别筛选（L0 默认隐藏可切换）
    @State private var severityFilter = "L1+"
    @State private var showL0 = false
    /// §5.15 指标筛选（V3.72）：空 = 全部
    @State private var metricFilter: String?

    private var events: [GuidelineStore.AlertEvent] {
        history.filter { $0.patientId == app.currentPatientId }
    }

    private var filtered: [GuidelineStore.AlertEvent] {
        events
            .filter { severityFilter == "L1+" || $0.severity.rawValue == severityFilter }
            .filter { metricFilter == nil || $0.card.metricKey == metricFilter }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// 指标筛选项（当前数据中出现的全部指标键）
    private var metricOptions: [String] {
        Array(Set(events.compactMap { $0.card.metricKey })).sorted()
    }

    var body: some View {
        Group {
            if filtered.isEmpty {
                ContentUnavailableView(L10n.alertEmptyTitle, systemImage: "waveform.path.ecg",
                                       description: Text(L10n.alertEmptyHint))
                    .accessibilityIdentifier("F16.alerts.empty")
            } else {
                List {
                    ForEach(filtered, id: \.id) { event in
                        if event.severity == .L0 {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(L10n.healthHistoricalEvaluation).font(.caption).foregroundStyle(.secondary)
                                if let value = event.card.value {
                                    Text("\(MedicalNumberFormat.quantity(value)) \(event.card.unit ?? "")")
                                } else if let facts = event.card.legacyFacts { Text(facts) }
                            }
                        } else {
                            EvidenceCardRow(event: event, sourceEntry: sourceEntry(for: event))
                        }
                    }
                    if history.count == historyLimit {
                        Button(L10n.healthLoadMore) { historyLimit += 200 }
                    }
                }
                .accessibilityIdentifier("F16.alerts.list")
            }
        }
        .safeAreaInset(edge: .top) {
            HStack(spacing: 8) {
                Picker("", selection: $severityFilter) {
                    Text(L10n.alertFilterAll).tag("L1+")
                    Text("L1").tag("L1")
                    Text("L2").tag("L2")
                    Text("L3").tag("L3")
                }
                .pickerStyle(.segmented)
                Toggle(L10n.healthShowLegacy, isOn: $showL0)
                    .font(.caption)
                // §5.15 指标筛选（V3.72）
                if !metricOptions.isEmpty {
                    Menu {
                        Button(L10n.filterAll) { metricFilter = nil }
                        ForEach(metricOptions, id: \.self) { m in
                             Button(L10n.healthMetricName(m)) { metricFilter = m }
                        }
                    } label: {
                        Text(metricFilter.map(L10n.healthMetricName) ?? L10n.filterAll)
                            .font(.caption).padding(.horizontal, 10).frame(minHeight: 44)
                            .background(Capsule().fill(Color(.systemGray5)))
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(.thinMaterial)
        }
        .navigationTitle(L10n.alert_historyEntry)
        .task(id: "\(app.currentPatientId)-\(dataChange.alertsVersion)-\(showL0)-\(historyLimit)") {
            history = []
            do {
                let loaded = try await hub.healthHistory(patientId: app.currentPatientId, includeLegacy: showL0, limit: historyLimit)
                guard !Task.isCancelled else { return }
                history = loaded
            } catch { history = [] }
        }
    }

    /// V3.68：证据卡已结构化——按 sourceTitle 命中信源库条目给原文链接
    /// （旧行 legacySourceRef 为书目字符串时退化为包含匹配）。
    private func sourceEntry(for event: GuidelineStore.AlertEvent) -> GuidelineEntry? {
        let entries = Array(sourceEntries.values) + hub.guidelineEntries
        if let id = event.card.guidelineID { return entries.first { $0.id == id } }
        let matches = entries.filter {
            $0.metricKey == event.card.metricKey && $0.title == event.card.sourceTitle
                && $0.clauseRef == event.card.sourceClause && $0.year == event.card.sourceYear
        }
        return matches.count == 1 ? matches.first : nil
    }
}

private struct EvidenceCardRow: View {
    let event: GuidelineStore.AlertEvent
    var sourceEntry: GuidelineEntry?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !event.qualified { Text(L10n.healthHistoricalEvaluation).font(.caption).foregroundStyle(.secondary) }
            HStack {
                SeverityTag(severity: event.severity)
                Spacer()
                Text(event.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            // V3.68：结构化卡经 L10n 渲染；旧行（legacy*）直出历史文案
            if let legacy = event.card.legacyFacts {
                Text(legacy)
                    .font(.subheadline)
                    .accessibilityIdentifier("F16.evidence.facts")
            } else if let metricKey = event.card.metricKey, let value = event.card.value,
                      let unit = event.card.unit, let origin = event.card.origin,
                      let measuredAt = event.card.measuredAt {
                Text(L10n.alertEvidenceFacts(L10n.healthMetricName(metricKey), MedicalNumberFormat.quantity(value), unit,
                                             L10n.alertOriginName(origin),
                                             measuredAt.formatted(date: .abbreviated, time: .shortened)))
                    .font(.subheadline)
                    .accessibilityIdentifier("F16.evidence.facts")
            }
            if let ref = event.card.sourceTitle ?? event.card.legacySourceRef {
                let display = event.card.sourceTitle.map { L10n.alertEvidenceSource($0, event.card.sourceOrg ?? "", event.card.sourceYear ?? 0, event.card.sourceClause ?? "") } ?? ref
                // 信源链接：可打开原文（F16 验收「信源链接可打开原文」）。
                // 有 URL 用系统 Link；无 URL 只读书目行（不臆造链接）。
                if let citation = event.card.citationURL ?? sourceEntry?.citationUrl,
                    let url = URL(string: citation),
                    url.scheme == "https" {
                    Link(destination: url) {
                        HStack(spacing: 4) {
                            VLIcon.externalLink.resizable().frame(width: 14, height: 14)
                            Text(display).font(.caption).multilineTextAlignment(.leading)
                        }
                        .frame(minHeight: 44, alignment: .leading)
                    }
                    .accessibilityLabel(L10n.alertOpenSource(display))
                    .accessibilityIdentifier("F16.evidence.source")
                } else {
                    Text(display).font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("F16.evidence.sourceRef")
                }
            }
            Text(Self.pathText(event.card))
                .font(.caption).foregroundStyle(.secondary)
            Text(event.card.legacyDisclaimer ?? L10n.alertEvidenceDisclaimer)
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("F16.evidence.card")
    }

    static func pathText(_ card: AlertEvidenceCard) -> String {
        if let legacy = card.legacyPath { return legacy }
        switch card.path {
        case .retestNow: return L10n.alertEvidencePathRetest
        case .scheduleVisit: return L10n.alertEvidencePathVisit
        case .observe: return L10n.alertEvidencePathObserve
        case nil: return L10n.healthHistoricalEvaluation
        }
    }
}

struct SeverityTag: View {
    let severity: AlertSeverity

    var body: some View {
        Text(severity.rawValue)
            .font(.caption).bold()
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.15)))
            .foregroundStyle(color)
            .accessibilityLabel(L10n.alertSeverity(severity.rawValue))
    }

    private var color: Color {
        switch severity {
        case .L0: return Color("text-tertiary", bundle: .main)
        case .L1: return Color("brand-primary", bundle: .main)
        case .L2: return Color("grade-d", bundle: .main)
        case .L3: return Color("semantic-danger", bundle: .main)
        }
    }
}

// MARK: - 信源详情（FR16.4 准入展示）

/// 设置页「参考范围来源」：权威机构/版本/检查日期/阈值一览。
/// 阈值数字照抄原文、禁止改写——本页只读，无任何编辑入口。
struct GuidelineSourceListView: View {
    let entries: [GuidelineEntry]

    var body: some View {
        List(entries, id: \.id) { entry in
            // FR16.3：阈值出处条目原文可点开 → 信源原文详情页
            NavigationLink(value: AppRoute.guidelineSourceDetail(entry.id)) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(entry.title).font(.subheadline).bold()
                    Text("\(entry.org) · \(entry.version) · \(entry.clauseRef)")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        if GuidelineSource.thresholdsAwaitMedicalReview { Text(L10n.healthMedicalReviewPending).font(.caption) }
                        else {
                            if let lo = entry.l1Low { thresholdText("L1 <= \(MedicalNumberFormat.quantity(lo))") }
                            if let hi = entry.l1High { thresholdText("L1 >= \(MedicalNumberFormat.quantity(hi))") }
                            if let lo = entry.l2Low { thresholdText("L2 <= \(MedicalNumberFormat.quantity(lo))") }
                            if let hi = entry.l2High { thresholdText("L2 >= \(MedicalNumberFormat.quantity(hi))") }
                            if let lo = entry.l3Low { thresholdText("L3 <= \(MedicalNumberFormat.quantity(lo))") }
                            if let hi = entry.l3High { thresholdText("L3 >= \(MedicalNumberFormat.quantity(hi))") }
                        }
                    }
                    if let url = URL(string: entry.citationUrl), !entry.citationUrl.isEmpty {
                        Link(L10n.alertOpenOriginal, destination: url)
                            .font(.caption)
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("F16.guideline.sourceLink")
                    }
                    Text(L10n.alertLinkChecked(entry.checkedAt.formatted(date: .abbreviated, time: .omitted)))
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("F16.guideline.row")
            }
        }
        .navigationTitle(L10n.alertSourceTitle)
    }

    private func thresholdText(_ s: String) -> some View {
        Text(s).font(.caption2).monospacedDigit()
            .foregroundStyle(.secondary)
    }
}

/// FR16.3/16.4 信源原文详情页（guidelineSourceDetail）：B 级信源徽章 +
/// 完整阈值表 + 原文链接 + 准入说明（阈值照抄原文、A 级报告范围优先）。
struct GuidelineSourceDetailView: View {
    let entryId: UUID

    @Environment(M2HubStore.self) private var hub
    @Environment(AppState.self) private var app

    private var entry: GuidelineEntry? {
        hub.guidelineEntries.first { $0.id == entryId }
    }

    var body: some View {
        Group {
            if let entry {
                content(entry)
            } else {
                ContentUnavailableView(L10n.gsDetailNotFound, systemImage: "doc.text.magnifyingglass")
            }
        }
        .navigationTitle(entry?.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: entryId) { await hub.load(patientId: app.currentPatientId) }
    }

    private func content(_ entry: GuidelineEntry) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // 头部：标题 + B 级信源徽章 + 机构/版本/年份
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(entry.title).font(.title3.bold())
                        GradeBadge(grade: "B")   // B = 指南信源库（FR16.4 准入）
                        Spacer()
                    }
                    Text("\(entry.org) · v\(entry.version) · \(String(entry.year))")
                        .font(.caption).foregroundStyle(.secondary)
                    if !entry.metricKey.isEmpty {
                        Text(L10n.gsDetailMetric(entry.metricKey))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                // 完整阈值表（L1/L2/L3 上下限 + 单位）
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.gsDetailThresholds).font(.headline)
                    if GuidelineSource.thresholdsAwaitMedicalReview {
                        Text(L10n.healthMedicalReviewPending).font(.caption)
                    } else {
                    thresholdRow("L1", entry.l1Low, entry.l1High, entry.unit)
                    thresholdRow("L2", entry.l2Low, entry.l2High, entry.unit)
                    thresholdRow("L3", entry.l3Low, entry.l3High, entry.unit)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color("bg-grouped", bundle: .main)))
                // 原文链接（FR16.3 可点开）
                if let url = URL(string: entry.citationUrl), !entry.citationUrl.isEmpty {
                    Link(destination: url) {
                        Label(L10n.alertOpenOriginal, systemImage: "arrow.up.right.square")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("F16.guidelineDetail.sourceLink")
                }
                // 准入说明（FR16.4：阈值照抄原文；A 级报告范围优先）
                Text(L10n.gsDetailNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(L10n.alertLinkChecked(entry.checkedAt.formatted(date: .abbreviated, time: .omitted)))
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(16)
            .frame(maxWidth: 560, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
    }

    private func thresholdRow(_ level: String, _ lo: Double?, _ hi: Double?, _ unit: String) -> some View {
        HStack(spacing: 8) {
            Text(level).bold().frame(width: 28, alignment: .leading)
            Text(lo.map { "<= \(MedicalNumberFormat.quantity($0))" } ?? "—")
            Text(hi.map { ">= \(MedicalNumberFormat.quantity($0))" } ?? "—")
            Text(unit).foregroundStyle(.secondary)
            Spacer()
        }
        .font(.footnote).monospacedDigit()
    }
}

/// V3.68：证据卡摘要行（首页预警卡/通知中心共用）——
/// 结构化信源书目 → 旧行书目 → 旧行事实 → 指标键，逐级回落。
extension AlertEvidenceCard {
    var summaryTitle: String? {
        if let title = sourceTitle {
            return L10n.alertEvidenceSource(title, sourceOrg ?? "", sourceYear ?? 0, sourceClause ?? "")
        }
        return legacySourceRef ?? legacyFacts ?? metricKey
    }
}

struct AlertEvidenceRouteView: View {
    let patientId: UUID
    let eventId: UUID
    @Environment(AppState.self) private var app
    @Environment(M2HubStore.self) private var hub
    @State private var event: GuidelineStore.AlertEvent?
    @State private var loading = true

    var body: some View {
        Group {
            if loading { ProgressView() }
            else if let event, event.patientId == patientId, permitted {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(app.members.first { $0.id == patientId }?.displayName ?? "").font(.headline)
                        EvidenceCardRow(event: event)
                        if event.severity == .L3 && event.qualified {
                            NavigationLink(value: AppRoute.sosHelp) { Text(L10n.healthOpenHelp).frame(minHeight: 44) }
                                .buttonStyle(.borderedProminent)
                        }
                    }.padding()
                }
            } else {
                ContentUnavailableView(L10n.alertEmptyTitle, systemImage: "doc.text.magnifyingglass")
            }
        }
        .navigationTitle(L10n.alert_historyEntry)
        .task(id: eventId) {
            event = nil; loading = true
            guard permitted else { loading = false; return }
            do {
                let loaded = try await hub.healthEvent(id: eventId, patientId: patientId)
                // 审查修复：permitted 在加载途中翻转（成员被删/退出）时
                // 旧实现直接 return 且不复位 loading——页面永远转圈无出口
                guard !Task.isCancelled, permitted else { loading = false; return }
                event = loaded
            } catch { event = nil }
            loading = false
        }
    }

    private var permitted: Bool {
        app.owner?.selfPatientId == patientId || app.members.contains { $0.id == patientId }
    }
}
