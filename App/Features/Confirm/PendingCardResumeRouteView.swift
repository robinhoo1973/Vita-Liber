import SwiftUI
import Domain
import Infrastructure   // PendingCard（CoreKit.Infrastructure 待办卡实体）
import Perception

/// 续办待办卡入口视图（业主裁决 4 拆分，2026-09-26 自 EntityCardConfirmView.swift 迁出）：
/// 装载 pending 卡、保留导入会话时显示进度、legacy 缺原件时降级为只读呈现、加载失败可重试。
struct PendingCardResumeRouteView: View {
    let cardId: String
    @Environment(DocumentsState.self) private var docs
    @State private var pending: PendingCard?
    @State private var loaded = false
    @State private var loadFailed = false
    @State private var reimport = false
    @State private var retainedImportID: UUID?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        WithPerceptionTracking {
            Group {
                if let retainedImportID, docs.activeImport?.id == retainedImportID {
                    ProgressView()
                } else if pending != nil, let review = docs.pendingReviews[cardId], let documentId = review.pending.sourceDocId, !loadFailed {
                    EntityCardConfirmView(card: Binding(get: { review.card }, set: { review.card = $0 }),
                        mode: .resume(review), patientId: review.pending.patientId, documentId: documentId,
                        pageCount: review.pageCount, position: nil)
                } else if let pending, loaded {
                    List {
                        Section {
                            OCRReviewOwnerRow(patientId: pending.patientId)
                            GradeBadge(grade: "D")
                            Text(L10n.ocrReviewLegacySourceMissing)
                            Button(L10n.homeCaptureFile) { reimport = true }.frame(minHeight: 44)
                        }
                        Section(L10n.entityCardSharedSection) {
                            // 与首页 PendingCardDetailSheet 同源的单一出口（2026-09-26 审查去重，
                            // 见 Documents/PendingCardPartialDataSection.swift）
                            PendingCardPartialDataSection(payload: pending.partialData)
                        }
                        Section(L10n.pendingCardRawText) { Text(pending.rawText).textSelection(.enabled) }
                    }
                    .scrollContentBackground(.hidden)   // ui-ux §3.0 surface/tint：渐变画布透出
                    .tintedCanvas()   // 渐变直挂本容器（根级背景会被 TabView/导航栈系统底色覆盖，V4.06 修正）
                } else if loadFailed {
                    VLUnavailableView {
                        Label(L10n.docImportFailed, systemImage: "exclamationmark.triangle")
                    } actions: {
                        Button(L10n.retry) { Task { await load() } }
                            .accessibilityIdentifier("SP-53.resume.retry")
                    }
                } else if loaded {
                    VLUnavailableView(L10n.pendingCardNotFound, systemImage: "tray")
                } else {
                    // §6 骨架屏（2026-10-03 评审 R1-8c）：页级加载态禁用菊花。
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(0..<3, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 14)
                                .fill(Color(.systemGray5))
                                .frame(height: 56)
                        }
                    }
                    .padding(.horizontal, 16)
                    .accessibilityIdentifier("SP-53.resume.loading")
                }
            }
            // 2026-10-03 评审 R1-8b：页面容器补标识（容器级标识必须 .contain，L0 §17 掩蔽纪律）
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("SP-53.resume")
            .task(id: cardId) { await load() }
            .ocrImportReviewHost(enabled: retainedImportID != nil && docs.activeImport?.id == retainedImportID,
                                 advanceQueuedImports: false) { _ in dismiss() }
            .onDisappear {
                if docs.pendingReviews[cardId]?.completed == true { docs.pendingReviews.removeValue(forKey: cardId) }
            }
            .sheet(isPresented: $reimport) {
                if let pending { NavigationStack { QuickCaptureView(kind: nil, patientId: pending.patientId) } }
            }
            .toolbar {
                if loaded && docs.pendingReviews[cardId] == nil && retainedImportID == nil {
                    ToolbarItem(placement: .cancellationAction) { Button(L10n.commonCancel) { dismiss() } }
                }
            }
        }
    }

    private func load() async {
        loaded = false; loadFailed = false; pending = nil; retainedImportID = nil
        do {
            let fetched = try await docs.loadPendingCard(id: cardId)
            guard !Task.isCancelled else { return }
            guard let fetched, ["pending", "in_progress"].contains(fetched.status) else { loaded = true; return }
            pending = fetched
            if let retained = docs.retainedImport(for: fetched) {
                retainedImportID = retained.id
                loaded = true
                return
            }
            _ = await docs.resumePendingCard(fetched)
        } catch { loadFailed = true }
        loaded = true
    }
}
