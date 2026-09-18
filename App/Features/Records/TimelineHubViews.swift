import SwiftUI
import Domain
import Perception

// MARK: - SP-19 主卡 / 子卡行（子项目 J · round1 §E.3 / §E.4）

/// 主卡行（DisclosureGroup 的 label）：图标 + 类型胶囊 + 医院/机构 + 日期 + 子卡计数徽章 + 独立「详情」触点。
/// 展开/收起由 DisclosureGroup 原生承担（VoiceOver 自带展开态）；文本块合并为一个无障碍元素并携带子记录数。
/// 图标/色令牌只经 `CardKindIcon`（单一出口）；色按卡类不按内容（BR-004/012）。
struct TimelineHubRowView: View {
    let item: TimelineHubEntry
    let hub: RecordHub
    let onOpen: () -> Void

    private var spec: CardKindIcon.Spec {
        CardKindIcon.spec(hub: hub, hospitalized: item.entry.kind == .hospitalization)
    }

    /// 主文案：就诊/住院 = 医院或科室（store 的 summary），缺失回落就诊类型名；体检 = 机构/套餐（title）。
    private var headline: String {
        switch hub {
        case .encounter, .hospitalization:
            if let place = item.entry.summary, !place.isEmpty { return place }
            return DocumentsDisplay.fieldValueDisplay(forKey: "kind", value: item.entry.title)
        case .healthExam:
            return item.entry.title.isEmpty ? L10n.timelineKindName(.healthExam) : item.entry.title
        }
    }

    /// 次文案：就诊 = 就诊类型名（有医院时才需要）；体检 = 总检结论原文（不摘要、不解读）。
    private var subline: String? {
        switch hub {
        case .encounter, .hospitalization:
            guard let place = item.entry.summary, !place.isEmpty else { return nil }
            return DocumentsDisplay.fieldValueDisplay(forKey: "kind", value: item.entry.title)
        case .healthExam:
            return item.entry.summary
        }
    }

    /// VoiceOver：类型 · 主文案 · 日期 · N 项子记录 · 处方 1 · 检验 2（计数按子卡类型序）。
    private var accessibilityText: String {
        var parts = [L10n.timelineKindName(item.entry.kind), headline, item.entry.date.formatted(date: .abbreviated, time: .omitted)]
        parts.append(item.children.isEmpty ? L10n.timelineHubNoChildren : L10n.timelineHubChildren(item.children.count))
        parts += HubCountBadges.ordered(item.counts).map { L10n.timelineHubCount($0.kind, $0.count) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        WithPerceptionTracking {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: spec.symbol)
                    .foregroundStyle(spec.tint)
                    .frame(width: 24, alignment: .center)
                    .padding(.top, 4)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(L10n.timelineKindName(item.entry.kind))
                            .font(.caption)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Capsule().fill(Color("brand-primary", bundle: .main).opacity(0.12)))
                            .foregroundStyle(Color("brand-primary", bundle: .main))
                        Text(headline).font(.subheadline).lineLimit(1)
                    }
                    if let subline, !subline.isEmpty {
                        Text(subline).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Text(item.entry.date.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption2).foregroundStyle(.tertiary)
                    if !item.counts.isEmpty {
                        HubCountBadges(counts: item.counts)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(accessibilityText)
                .accessibilityIdentifier("SP-19.hub.toggle")
                Spacer(minLength: 4)
                Button(action: onOpen) {
                    Text(L10n.timelineHubOpen)
                        .font(.caption)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(L10n.timelineHubOpen)
                .accessibilityIdentifier("SP-19.hub.open")
            }
            .padding(.vertical, 2)
        }
    }
}

/// 子卡计数徽章：「处方 1 · 检验 2」——图标 + 数量，序 = `TimelineHierarchyRules.childKindOrder`；VoiceOver 读类型名 + 数量。
struct HubCountBadges: View {
    let counts: [TimelineEntryKind: Int]

    /// 计数序 = `TimelineHierarchyRules.childKindOrder`（未登记类型按 rawValue 收尾）。
    static func ordered(_ counts: [TimelineEntryKind: Int]) -> [(kind: TimelineEntryKind, count: Int)] {
        counts.sorted { a, b in
            let ra = TimelineHierarchyRules.childKindOrder.firstIndex(of: a.key) ?? Int.max
            let rb = TimelineHierarchyRules.childKindOrder.firstIndex(of: b.key) ?? Int.max
            if ra != rb { return ra < rb }
            return a.key.rawValue < b.key.rawValue
        }.map { (kind: $0.key, count: $0.value) }
    }

    var body: some View {
        WithPerceptionTracking {
            HStack(spacing: 8) {
                ForEach(Self.ordered(counts), id: \.kind) { badge in
                    let spec = CardKindIcon.spec(timelineKind: badge.kind)
                    HStack(spacing: 3) {
                        Image(systemName: spec.symbol).font(.caption2).foregroundStyle(spec.tint)
                        Text("\(badge.count)").font(.caption2).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(L10n.timelineHubCount(badge.kind, badge.count))
                    .accessibilityIdentifier("SP-19.hub.count.\(badge.kind.rawValue)")
                }
            }
        }
    }
}

/// 子卡行（DisclosureGroup 展开内容）：图标 + 类型名 + 标题/摘要 + 日期 + 来源徽章（原件）。
/// 处方摘要 = 行数「N 项」；结论聚合 = 「N 条结论」+ 首条原文；原件摘要 = 文档类型稳定键 → 三语标签。
struct TimelineChildRowView: View {
    let entry: TimelineEntry

    private var spec: CardKindIcon.Spec { CardKindIcon.spec(timelineKind: entry.kind) }

    /// 行标题：经 `DocumentsDisplay.timelineEntryTitle` 单一出口（结论=条数 / 治疗=类型展示名 /
    /// 就诊·住院=`kind` canonical raw → 展示名 / 其余原文、空则回落类型名）。
    ///
    /// 2026-09-17 业主实测复发「就诊类型显示 `outpatient`」：本行此前**直出** `entry.title`，
    /// 而就诊行的 title 是 `kind` raw（`TimelineQueryStore` 的 `e.kind AS title`）——
    /// 主卡行接了展示出口、子卡行漏了。现与主卡行同源。
    private var title: String { DocumentsDisplay.timelineEntryTitle(entry) }

    private var summary: String? {
        guard let raw = entry.summary?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        switch entry.kind {
        case .prescription:
            if let count = Int(raw) { return L10n.timelineHubItems(count) }
            return raw
        case .document:
            return L10n.docTypeName(raw)
        case .treatmentRecord, .claim, .diagnosis, .labReport, .examReport, .surgery, .appointment, .reminder, .hospitalization,
             .vaccination, .clinicalConclusion, .encounter, .healthExam, .medication, .observation, .lab, .selfMeasured,
             .allergy, .voiceNote, .healthProblem, .healthData:
            return raw
        }
    }

    var body: some View {
        WithPerceptionTracking {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: spec.symbol)
                    .font(.subheadline)
                    .foregroundStyle(spec.tint)
                    .frame(width: 22, alignment: .center)
                    .padding(.top, 2)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(L10n.timelineKindName(entry.kind))
                            .font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color("bg-grouped", bundle: .main)))
                            .foregroundStyle(.secondary)
                        Text(title).font(.subheadline).lineLimit(1)
                        // 来源徽章（2026-09-15 实测修复）：改按**徽章值**放行而非按卡类——
                        // 原 `entry.kind == .document` 让同一份数据在资料库（只显示 D）、
                        // 健康档案子卡（只显示原件类）、明细页（恒显示 C）三处三种口径。
                        // 与叶子行同规则：只保留需要提醒的差异态（D/E 未确认、A/B 医院原文
                        // 与信源库）；C = 默认事实态，不出徽章。
                        if let grade = entry.grade, grade != "C" {
                            GradeBadge(grade: grade)
                        }
                    }
                    if let summary {
                        Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Text(entry.date.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 2)
            .frame(minHeight: 44)
        }
    }
}
