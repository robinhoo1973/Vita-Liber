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
    let events: [GuidelineStore.AlertEvent]
    /// 装配层注入的信源条目（metricKey → entry），用于「打开原文」；
    /// 缺条目时降级为只读书目行（不臆造 URL）
    var sourceEntries: [String: GuidelineEntry] = [:]

    private var l1Plus: [GuidelineStore.AlertEvent] {
        events.filter { $0.severity != .L0 }.sorted { $0.createdAt > $1.createdAt }
    }

    var body: some View {
        if events.isEmpty {
            ContentUnavailableView("暂无预警记录", systemImage: "waveform.path.ecg",
                                   description: Text("读数越过参考范围时会在这里出现提示"))
                .accessibilityIdentifier("F16.alerts.empty")
        } else {
            List(l1Plus, id: \.id) { event in
                EvidenceCardRow(event: event, sourceEntry: sourceEntry(for: event))
            }
            .accessibilityIdentifier("F16.alerts.list")
        }
    }

    /// 证据卡不带 metricKey（只存事实文案），按规则 id 取不到条目时
    /// 由装配层在注入前就按 metric 归类——这里以 event.card.sourceRef 的
    /// 书目行为退化键，命中则给链接。
    private func sourceEntry(for event: GuidelineStore.AlertEvent) -> GuidelineEntry? {
        guard let ref = event.card.sourceRef else { return nil }
        return sourceEntries.values.first { ref.contains($0.title) }
    }
}

private struct EvidenceCardRow: View {
    let event: GuidelineStore.AlertEvent
    var sourceEntry: GuidelineEntry?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SeverityTag(severity: event.severity)
                Spacer()
                Text(event.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Text(event.card.facts)
                .font(.subheadline)
                .accessibilityIdentifier("F16.evidence.facts")
            if let ref = event.card.sourceRef {
                // 信源链接：可打开原文（F16 验收「信源链接可打开原文」）。
                // 有 URL 用系统 Link；无 URL 只读书目行（不臆造链接）。
                if let citation = sourceEntry?.citationUrl,
                   let url = URL(string: citation),
                   !url.absoluteString.isEmpty {
                    Link(destination: url) {
                        HStack(spacing: 4) {
                            VLIcon.externalLink.resizable().frame(width: 14, height: 14)
                            Text(ref).font(.caption).multilineTextAlignment(.leading)
                        }
                        .frame(minHeight: 44, alignment: .leading)
                    }
                    .accessibilityLabel("打开信源原文：\(ref)")
                    .accessibilityIdentifier("F16.evidence.source")
                } else {
                    Text(ref).font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("F16.evidence.sourceRef")
                }
            }
            Text(event.card.suggestedPath)
                .font(.caption).foregroundStyle(.secondary)
            Text(event.card.disclaimer)
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("F16.evidence.card")
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
            .accessibilityLabel("预警级别 \(severity.rawValue)")
    }

    private var color: Color {
        switch severity {
        case .L0: return Color("text-tertiary", bundle: .main)
        case .L1: return Color("brand-primary", bundle: .main)
        case .L2: return Color("grade-d", bundle: .main)
        case .L3: return .red
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
            VStack(alignment: .leading, spacing: 6) {
                Text(entry.title).font(.subheadline).bold()
                Text("\(entry.org) · \(entry.version) · \(entry.clauseRef)")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    if let lo = entry.l1Low { thresholdText("L1 ≥ \(String(format: "%g", lo))") }
                    if let hi = entry.l1High { thresholdText("L1 ≤ \(String(format: "%g", hi))") }
                    if let lo = entry.l2Low { thresholdText("L2 ≥ \(String(format: "%g", lo))") }
                    if let hi = entry.l2High { thresholdText("L2 ≤ \(String(format: "%g", hi))") }
                    if let lo = entry.l3Low { thresholdText("L3 ≥ \(String(format: "%g", lo))") }
                    if let hi = entry.l3High { thresholdText("L3 ≤ \(String(format: "%g", hi))") }
                }
                if let url = URL(string: entry.citationUrl), !entry.citationUrl.isEmpty {
                    Link("打开原文", destination: url)
                        .font(.caption)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("F16.guideline.sourceLink")
                }
                Text("链接检查日期 \(entry.checkedAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("F16.guideline.row")
        }
        .navigationTitle("参考范围来源")
    }

    private func thresholdText(_ s: String) -> some View {
        Text(s).font(.caption2).monospacedDigit()
            .foregroundStyle(.secondary)
    }
}
