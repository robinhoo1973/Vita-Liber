import SwiftUI
import Domain
import Infrastructure
import Perception

/// 处方行 → 展示字段目录（SP-08 处方卡行摘要 / 行详情共用同一目录，标签经 `DocumentsDisplay.fieldLabel` 走模板键，
/// 与确认卡（SP-12）同一词表）。剂量/数量按「原文 + 单位」拼显示，疗程/频次/途径原文直出——
/// 不解析数值、不换算、不推算给药方案（BR-006/007）；金额/单价为费用可格式化。
enum PrescriptionLinePresentation {
    /// 全部非空行字段（模板键, 展示值），按 DDL 列序。
    static func fields(_ line: PrescriptionLine) -> [(key: String, value: String)] {
        let pairs: [(String, String?)] = [
            ("drug_name", line.printedName),
            ("generic_name", line.genericName),
            ("brand_name", line.brandName),
            ("drug_form", line.drugForm),
            ("spec", line.spec),
            ("dosage", joined(line.doseText, unit: line.doseUnit)),
            ("quantity", joined(line.quantityText, unit: line.quantityUnit)),
            ("frequency", line.frequencyText),
            ("route", line.routeText),
            ("days", line.durationText),
            ("start_date", line.startDate.map { $0.formatted(date: .abbreviated, time: .omitted) }),
            ("end_date", line.endDate.map { $0.formatted(date: .abbreviated, time: .omitted) }),
            ("as_needed", line.asNeededText),
            ("medication_notes", line.medicationNotes),
            ("note", line.note),
            ("insurance_code", line.insuranceCode),
            ("item_code", line.itemCodeText),
            // 金额形态与就诊费用行同口径（CNY 两位小数）——同一处方金额不得两种显示
            ("unit_price", line.unitPrice.map { $0.formatted(.currency(code: "CNY").precision(.fractionLength(2))) }),
            ("line_amount", line.amount.map { $0.formatted(.currency(code: "CNY").precision(.fractionLength(2))) }),
        ]
        return pairs.compactMap { pair -> (key: String, value: String)? in
            guard let value = pair.1, !value.isEmpty else { return nil }
            return (key: pair.0, value: value)
        }
    }

    /// 列表摘要：规格 · 剂量 · 数量 · 频次 · 途径 · 疗程（非空项按原文拼接）。
    static func summary(_ line: PrescriptionLine) -> String {
        [line.spec, joined(line.doseText, unit: line.doseUnit), joined(line.quantityText, unit: line.quantityUnit),
         line.frequencyText, line.routeText, line.durationText]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    /// 用药说明 + 备注（列表第三行）；均空为 nil。
    static func notes(_ line: PrescriptionLine) -> String? {
        let text = [line.medicationNotes, line.note].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        return text.isEmpty ? nil : text
    }

    /// 「原文 + 单位」：原文缺失即 nil（不为孤立单位造值）。
    static func joined(_ text: String?, unit: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        guard let unit, !unit.isEmpty else { return text }
        return text + " " + unit
    }
}

/// SP-08 处方行详情（v25 §C.6 · ADR-021 单一自适应视图）：行事实全列 + 来源页 + 所属处方表头入口。
/// 只读事实呈现；不显示任何换算/给药建议（BR-006/007）。成员隔离由 `OCRCardStore.lineDetail` 出口把关：
/// 跨成员/已删除一律 `invalidCard` → §5.48 查无降级自弹回根；其他读取失败可重试。
struct PrescriptionLineDetailView: View {
    let lineId: UUID
    let patientId: UUID
    @Environment(DocumentsState.self) private var docs
    @State private var detail: OCRCardStore.LineDetail?
    @State private var gone = false
    @State private var failed = false

    var body: some View {
        WithPerceptionTracking {
            Group {
                if let detail {
                    content(detail)
                } else if gone {
                    RouteFallbackView(route: .prescriptionLine(patientId: patientId, lineId: lineId))
                } else if failed {
                    VLUnavailableView {
                        Label(L10n.prescriptionLineUnavailable, systemImage: "doc.text.magnifyingglass")
                    } actions: { Button(L10n.retry) { Task { await load() } } }
                } else {
                    ProgressView()
                }
            }
            .navigationTitle(detail?.line.printedName ?? L10n.prescriptionLineTitle)
            .navigationBarTitleDisplayMode(.inline)
            .task(id: lineId) { await load() }
        }
    }

    @ViewBuilder
    private func content(_ detail: OCRCardStore.LineDetail) -> some View {
        List {
            Section {
                OCRReviewOwnerRow(patientId: patientId)
                // BR-003：事实表行只收用户确认（C）；未确认草稿不会到达此读面，徽章仍按行标志呈现
                GradeBadge(grade: detail.line.confirmed ? "C" : "D")
                ForEach(Array(PrescriptionLinePresentation.fields(detail.line).enumerated()), id: \.offset) { _, field in
                    LabeledContent(DocumentsDisplay.fieldLabel(forKey: field.key), value: field.value)
                        .accessibilityIdentifier("SP-08.prescriptionLine.field.\(field.key)")
                }
            } header: {
                Text(L10n.prescriptionLineTitle)
            }
            // 容器标识须配 .accessibilityElement(children: .contain)，否则下放覆盖各字段行自身标识（L0 §17）
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("SP-08.prescriptionLine.fields")

            if let raw = detail.line.rawText, !raw.isEmpty {
                Section(L10n.pendingCardRawText) {
                    Text(raw).font(.footnote).textSelection(.enabled)
                }
            }

            Section(L10n.prescriptionLineHeader) {
                NavigationLink(value: AppRoute.medicalCard(kind: "prescription", id: detail.header.entityId, patientId: patientId)) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.entityCardKindName("prescription")).font(.body)
                        let summary = headerSummary(detail.header)
                        if !summary.isEmpty {
                            Text(summary).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .accessibilityIdentifier("SP-08.prescriptionLine.header")
            }

            Section(L10n.pendingCardViewSource) {
                if let source = detail.source {
                    NavigationLink(value: AppRoute.documentDetail(source.documentId)) {
                        Label((source.title ?? L10n.docUntitled) + " · " + L10n.entityCardRowIndex(source.pageIndex + 1),
                              systemImage: "doc.text.magnifyingglass")
                    }
                    .accessibilityIdentifier("SP-08.prescriptionLine.source")
                } else {
                    Text(L10n.prescriptionLineNoSource).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// 表头摘要：医院 · 医生 · 开方日期（已确认表头字段，展示层映射）。
    private func headerSummary(_ header: OCRCardStore.CardDetail) -> String {
        var parts: [String] = []
        for key in ["hospital", "doctor", "prescribed_at"] {
            if let field = header.fields.first(where: { $0.key == key }) {
                parts.append(DocumentsDisplay.fieldValueDisplay(forKey: key, value: field.value))
            }
        }
        return parts.joined(separator: " · ")
    }

    private func load() async {
        gone = false; failed = false
        guard let store = docs.cardStore else { failed = true; return }
        do {
            let value = try await store.lineDetail(lineId: lineId, patientId: patientId)
            guard !Task.isCancelled else { return }
            detail = value
        } catch OCRCardStore.StoreError.invalidCard {
            // 查无/跨成员：不区分存在性（不泄露他人数据），走 §5.48 已删除实体降级
            if !Task.isCancelled { detail = nil; gone = true }
        } catch {
            if !Task.isCancelled { failed = true }
        }
    }
}
