import SwiftUI
import Domain
import Infrastructure
import Perception

// MARK: - v27 体检主卡详情（子项目 J · round1 §E.1 / 融合方案 §五-5.4 · AppRoute.healthExamDetail）

/// 体检读面的可观察门面（`HealthExamStore` 是 actor，环境注入须 @Perceptible）。只读；写入方为 OCRCardStore。
@MainActor
@Perceptible
final class HealthExamViewState {
    private let store: HealthExamStore

    init(store: HealthExamStore) { self.store = store }

    /// 表头 → 子报告（视图）→ 结论 → 一般检查投影点 → 原件；跨成员 / 不存在 → `OCRCardStore.StoreError.invalidCard`（不泄露存在性）。
    func detail(id: UUID, patientId: UUID) async throws -> HealthExamStore.HealthExamDetail {
        try await store.detail(id: id, patientId: patientId)
    }
}

/// 体检详情（单一自适应视图，ADR-021；iPad 由 `.frame(maxWidth: 672)` 承担行宽）：
/// 表头（机构 / 编号 / 套餐 / 体检日 / 总检医生 / 报告日）→ 一般检查**打印原文**（BR-006）→ 总检结论 / 健康指导原文 →
/// 结论逐条（类型胶囊 + 原文 + `severity_text` 原文，**不着色**，BR-004/012）→ 子报告（检验 / 检查 → 已确认卡详情）→ 投影指标 → 原件。
struct HealthExamDetailView: View {
    let patientId: UUID
    let examId: UUID
    @Environment(HealthExamViewState.self) private var exams
    @State private var detail: HealthExamStore.HealthExamDetail?
    @State private var failed = false
    @State private var notFound = false
    @State private var showSource = false
    /// 检测检查项默认折叠（业主 2026-09-17 定，同时间轴主卡口径）
    @State private var reportsExpanded = false

    var body: some View {
        WithPerceptionTracking {
            Group {
                if let detail {
                    content(detail)
                } else if notFound {
                    // §5.48：查无 / 跨成员 → 自弹回根（与 RouteFallbackView 同时序）
                    RouteFallbackView(route: .healthExamDetail(patientId: patientId, id: examId))
                } else if failed {
                    VLUnavailableView {
                        Label(L10n.docImportFailed, systemImage: "exclamationmark.triangle")
                    } actions: { Button(L10n.retry) { Task { await load() } } }
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: 672)
            .navigationTitle(L10n.healthExamTitle)
            .navigationBarTitleDisplayMode(.inline)
            .task(id: examId) { await load() }
            .sheet(isPresented: $showSource) {
                if let documentId = detail?.documentId {
                    DocumentSourcePageView(documentId: documentId, patientId: patientId, pageIndex: 0)
                }
            }
        }
    }

    // MARK: - 分段

    @ViewBuilder
    private func content(_ detail: HealthExamStore.HealthExamDetail) -> some View {
        let exam = detail.exam
        List {
            Section {
                OCRReviewOwnerRow(patientId: patientId)
                HStack(spacing: 8) {
                    let spec = CardKindIcon.spec(hub: .healthExam)
                    Image(systemName: spec.symbol).foregroundStyle(spec.tint)
                    Text(exam.orgName ?? L10n.timelineKindName(.healthExam)).font(.title3.bold())
                    Spacer()
                    GradeBadge(grade: "C")
                }
                ForEach(headerRows(exam), id: \.key) { row in
                    LabeledContent(DocumentsDisplay.fieldLabel(forKey: row.key), value: row.value)
                }
            } header: { Text(L10n.healthExamHeader) }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("SP-19.healthExam.header")

            let general = generalRows(exam)
            if !general.isEmpty {
                // 一般检查：打印原文逐项（身高 / 体重 / BMI / 血压 / 脉搏 / 腰围 / 视力）——不换算、不判定
                Section(L10n.healthExamGeneral) {
                    ForEach(general, id: \.key) { row in
                        LabeledContent(DocumentsDisplay.fieldLabel(forKey: row.key), value: row.value)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("SP-19.healthExam.general")
            }

            if let overall = exam.overallConclusion?.trimmingCharacters(in: .whitespacesAndNewlines), !overall.isEmpty {
                Section(L10n.healthExamOverall) {
                    Text(overall).font(.callout).textSelection(.enabled)
                        .accessibilityIdentifier("SP-19.healthExam.overall")
                }
            }
            if let guidance = exam.healthGuidance?.trimmingCharacters(in: .whitespacesAndNewlines), !guidance.isEmpty {
                Section(L10n.healthExamGuidance) {
                    Text(guidance).font(.callout).textSelection(.enabled)
                        .accessibilityIdentifier("SP-19.healthExam.guidance")
                }
            }

            // 结论逐条：severity_text 只是纯文本（融合方案的 正常/关注/异常/需复查 不编码、不排序、不着色）
            Section {
                if detail.conclusions.isEmpty {
                    Text(L10n.healthExamNoConclusions).font(.caption).foregroundStyle(.secondary)
                }
                ForEach(Array(detail.conclusions.enumerated()), id: \.element.id) { index, conclusion in
                    ClinicalConclusionRow(conclusion: conclusion)
                        .accessibilityIdentifier("SP-19.healthExam.conclusion.\(index)")
                }
            } header: { Text(L10n.healthExamConclusions) } footer: { Text(L10n.healthExamDisclaimer) }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("SP-19.healthExam.conclusions")

            // 子报告（v_clinical_report：检验表头 / 检查报告）→ 同一已确认卡详情
            // 业主 2026-09-17 定：检测检查项默认折叠（同时间轴主卡口径），计数入标签；
            // 逐项符号已在 reportRow（CardKindIcon 按 reportType：检验 = 试管 / 检查 = 影像）
            Section {
                if detail.reports.isEmpty {
                    Text(L10n.healthExamNoReports).font(.caption).foregroundStyle(.secondary)
                } else {
                    DisclosureGroup(isExpanded: $reportsExpanded) {
                        ForEach(Array(detail.reports.enumerated()), id: \.element.id) { index, report in
                            NavigationLink(value: AppRoute.medicalCard(kind: Self.cardKind(for: report.reportType), id: report.reportId, patientId: patientId)) {
                                reportRow(report)
                            }
                            .accessibilityIdentifier("SP-19.healthExam.report.\(index)")
                        }
                    } label: {
                        Label(L10n.healthExamReportsCount(detail.reports.count), systemImage: "stethoscope")
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("SP-19.healthExam.reports")

            // 一般检查投影点（weight / bloodPressureSys / bloodPressureDia / heartRate）：趋势读面的镜像，原文列仍在上方
            if !detail.generalSamples.isEmpty {
                Section(L10n.healthExamSamples) {
                    ForEach(detail.generalSamples) { sample in
                        LabeledContent(sampleLabel(sample), value: MedicalNumberFormat.oneDecimal(sample.value) + " " + sample.unit)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("SP-19.healthExam.samples")
            }

            if detail.documentId != nil {
                Section {
                    Button { showSource = true } label: {
                        Label(L10n.healthExamSource, systemImage: "doc.text.magnifyingglass").frame(minHeight: 44)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("SP-19.healthExam.source")
                }
            }
        }
    }

    @ViewBuilder
    private func reportRow(_ report: ClinicalReportSummary) -> some View {
        let kind = Self.cardKind(for: report.reportType)
        let spec = CardKindIcon.spec(cardKind: kind)
        HStack(spacing: 10) {
            Image(systemName: spec.symbol).foregroundStyle(spec.tint)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(L10n.entityCardKindName(kind))
                        .font(.caption)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Capsule().fill(Color("brand-primary", bundle: .main).opacity(0.12)))
                        .foregroundStyle(Color("brand-primary", bundle: .main))
                    if let date = report.reportDate {
                        Text(date.formatted(date: .abbreviated, time: .omitted)).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                let subtitle = [report.orgName, report.reportNo].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                if !subtitle.isEmpty { Text(subtitle).font(.subheadline).lineLimit(2) }
            }
        }
        .frame(minHeight: 44)
    }

    // MARK: - 投影

    /// 视图 `report_type` → 已确认卡详情卡类（体检自身不在子报告清单内，穷尽保留）。
    static func cardKind(for type: ReportType) -> String {
        switch type {
        case .lab: return "lab_report"
        case .exam: return "exam_report"
        case .healthExam: return "health_exam"
        }
    }

    /// 表头行（非空才列）：机构 / 编号 / 套餐 / 体检日 / 总检医生 / 报告日。
    private func headerRows(_ exam: HealthExam) -> [(key: String, value: String)] {
        let pairs: [(String, String?)] = [
            ("exam_no", exam.examNo), ("package_name", exam.packageName),
            ("exam_date", exam.examDate.map { $0.formatted(date: .long, time: .omitted) }),
            ("total_doctor", exam.totalDoctor),
            ("report_date", exam.reportDate.map { $0.formatted(date: .long, time: .omitted) }),
        ]
        return pairs.compactMap { key, value in
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return (key: key, value: value)
        }
    }

    /// 一般检查原文（`*_text` 列，模板键去后缀），键序 = 报告阅读序。
    private func generalRows(_ exam: HealthExam) -> [(key: String, value: String)] {
        let pairs: [(String, String?)] = [
            ("height", exam.heightText), ("weight", exam.weightText), ("bmi", exam.bmiText),
            ("systolic", exam.systolicText), ("diastolic", exam.diastolicText), ("pulse", exam.pulseText),
            ("waist", exam.waistText), ("vision_left", exam.visionLeftText), ("vision_right", exam.visionRightText),
        ]
        return pairs.compactMap { key, value in
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return (key: key, value: value)
        }
    }

    /// 投影点标签：rawLabel 为模板键（weight / systolic …）时经字段词表，否则原文。
    private func sampleLabel(_ sample: OCRCardStore.LabSampleRow) -> String {
        DocumentsDisplay.fieldLabel(forKey: sample.rawLabel)
    }

    private func load() async {
        detail = nil; failed = false; notFound = false
        do {
            let value = try await exams.detail(id: examId, patientId: patientId)
            guard !Task.isCancelled else { return }
            detail = value
        } catch OCRCardStore.StoreError.invalidCard {
            if !Task.isCancelled { notFound = true }
        } catch {
            if !Task.isCancelled { failed = true }
        }
    }
}
