import SwiftUI
import Domain
import Infrastructure

/// FR13.2 导出向导（SP-22 · ui-ux §5.11）：
/// 步骤：范围（维度选择）→ 内容开关（备注/水印）→ 身份验证（FR13.4 门禁复用）
/// → 进行中（进度条，可取消）→ 完成（分享/打开）。
/// 维度：全部档案 / 按日期范围 / 医生摘要（按成员导出=当前成员档案；
/// 按健康问题/就诊维度随挂接数据，向导以「全部+日期」子集交付）。
@MainActor
@Observable
final class ExportWizardState {
    enum Phase: Equatable {
        case idle
        case working(processed: Int, total: Int)
        case finished(PDFExportService.ExportPackage)
        case degraded(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var exportURL: URL?
    private let service: PDFExportService
    private var exportTask: Task<Void, Never>?

    init(service: PDFExportService) { self.service = service }

    func run(_ request: PDFExportService.ExportRequest) {
        exportTask?.cancel()
        phase = .working(processed: 0, total: 1)
        exportTask = Task {
            do {
                let pkg = try await service.exportPDF(request) { processed, total in
                    Task { @MainActor in
                        if case .working = self.phase { self.phase = .working(processed: processed, total: total) }
                    }
                }
                try Task.checkCancellation()
                // 落临时文件供分享/打开（FR13.2 边界：导出中断不产生可被误认为完整的半截文件）
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("vitaliber-export-\(Int(Date().timeIntervalSince1970)).pdf")
                try pkg.data.write(to: url, options: .atomic)
                phase = .finished(pkg)
                exportURL = url
            } catch is CancellationError {
                phase = .degraded(L10n.exportCancelled)
            } catch {
                phase = .degraded(L10n.exportFailed)
            }
        }
    }

    func cancel() {
        exportTask?.cancel()
    }

    func reset() {
        exportURL = nil
        phase = .idle
    }
}

struct ExportWizardView: View {
    @Environment(AppState.self) private var app
    @Environment(ExportWizardState.self) private var state
    @Environment(\.dismiss) private var dismiss

    @State private var step = 1
    @State private var scopeKind: PDFExportService.ExportRequest.ScopeKind = .all
    @State private var dateFrom = DayArithmetic.offset(days: -90)
    @State private var dateTo = Date()
    @State private var includeNotes = true
    @State private var watermark = true
    @State private var showShare = false

    var body: some View {
        NavigationStack {
            VStack {
                switch state.phase {
                case .working(let processed, let total):
                    ProgressView(value: total > 0 ? Double(processed) / Double(total) : 0) {
                        Text(L10n.exportProgress(processed, total))
                    }
                    .padding(24)
                    Button(L10n.exportCancel, role: .destructive) { state.cancel() }
                case .finished(let pkg):
                    VStack(spacing: 16) {
                        Image(systemName: "doc.richtext")
                            .font(.system(size: 56))
                            .foregroundStyle(Color("brand-primary", bundle: .main))
                        Text(L10n.exportFinished(pkg.recordCount, pkg.pageCount))
                        ShareLink(item: state.exportURL ?? URL(fileURLWithPath: "/")) {
                            Label(L10n.exportShare, systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity, minHeight: 50)
                        }
                        .buttonStyle(.borderedProminent)
                        Button(L10n.onboard_finishEnterApp) {
                            state.reset()
                            dismiss()
                        }
                    }
                    .padding(24)
                case .degraded(let message):
                    Label(message, systemImage: "exclamationmark.triangle")
                        .padding(24)
                    Button(L10n.exportRetry) {
                        // 审查修复：重试同时重置步进——原只 reset() 状态机，
                        // step 停留在 3，idle 表单无 step1/step2 分支可渲染
                        // （空白表单，无法改导出设置）
                        state.reset()
                        step = 1
                    }
                case .idle:
                    Form {
                        if step == 1 {
                            // FR13.2 维度选择
                            Section(L10n.exportScope) {
                                Picker(L10n.exportScope, selection: $scopeKind) {
                                    Text(L10n.exportScopeAll).tag(PDFExportService.ExportRequest.ScopeKind.all)
                                    Text(L10n.exportScopeDateRange).tag(PDFExportService.ExportRequest.ScopeKind.dateRange)
                                    Text(L10n.exportScopeDoctorSummary).tag(PDFExportService.ExportRequest.ScopeKind.doctorSummary)
                                }
                                if scopeKind == .dateRange {
                                    DatePicker(L10n.exportDateFrom, selection: $dateFrom, displayedComponents: .date)
                                    DatePicker(L10n.exportDateTo, selection: $dateTo, in: dateFrom..., displayedComponents: .date)
                                }
                            }
                        } else if step == 2 {
                            Section(L10n.exportContent) {
                                Toggle(L10n.exportIncludeNotes, isOn: $includeNotes)
                                Toggle(L10n.exportWatermark, isOn: $watermark)
                            }
                            Section {
                                Text(L10n.exportPrivacyHint)
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(L10n.commonCancel) { dismiss() }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            if step < 2 {
                                Button(L10n.allergyNext) { step = 2 }
                            } else {
                                Button(L10n.exportStart) {
                                    Task {
                                        // FR13.4 导出前身份验证（门禁复用）+ 隐私提醒
                                        guard await app.requestUnlock(reason: L10n.exportUnlockReason) else { return }
                                        let request = PDFExportService.ExportRequest(
                                            patientId: app.currentPatientId,
                                            title: L10n.exportTitle(app.currentPatientId.uuidString.prefix(8).description),
                                            dateFrom: scopeKind == .dateRange ? dateFrom : nil,
                                            dateTo: scopeKind == .dateRange ? dateTo : nil,
                                            includeNotes: includeNotes,
                                            watermark: watermark,
                                            emergencyNumber: L10n.emergencyNumber,
                                            scopeKind: scopeKind)
                                        state.run(request)
                                        step = 3
                                    }
                                }
                                .accessibilityIdentifier("SP-22.export.start")
                            }
                        }
                    }
                    .navigationTitle(L10n.exportWizardTitle)
                    // FR20.3 L4 操作前确认：导出隐私提醒（身份验证后再出）
                    .sceneDisclosure(scene: "export", level: 4)
                }
            }
        }
    }
}
