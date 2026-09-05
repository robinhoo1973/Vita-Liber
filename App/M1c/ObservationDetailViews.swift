import SwiftUI
import Domain
import Infrastructure

/// FR8.11 观察详情页（SP-14 契约 §5.7.1）：四入口直达（首页待办/全局搜索/
/// 时间轴/随访通知深链）。FR8.2 已存字段全量呈现；媒体条走 FR8.4 敏感链
/// （LockedMediaStrip）；「补充信息」行内编辑（FR8.7 事后补字段）；删除走
/// FR8.8 三问明示；底部 [设置随访提醒]（FR8.10）。
struct ObservationDetailView: View {
    let observationId: UUID

    @Environment(AppState.self) private var app
    @Environment(ObservationStoreState.self) private var state
    @Environment(ReminderStore.self) private var reminders
    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss

    // 编辑态（补充信息）：确认前只改本地草稿
    @State private var draftBodyPart = ""
    @State private var draftDuration: Int?
    @State private var draftFrequency = ""
    @State private var draftIsFirst = false
    @State private var draftTrigger = ""
    @State private var draftAccompanying = ""
    @State private var draftPainScore: Double = 0
    @State private var draftMedsDiet = ""
    @State private var draftConsulted = false
    @State private var draftDescription = ""
    @State private var showDeleteConfirm = false
    @State private var showFollowUp = false
    @State private var followUpDays = 3
    @State private var editSavedToast = false
    @State private var deletedToast = false
    @State private var followUpDoneToast = false

    var body: some View {
        Group {
            switch state.detailPhase {
            case .loading:
                ProgressView()
            case .failed:
                ContentUnavailableView(L10n.obsDetailLoadFailed, systemImage: "exclamationmark.triangle",
                                       description: Text(L10n.obsDetailRetry))
            case .loaded:
                if let event = state.detail {
                    content(event)
                } else {
                    // 目标已删除/不存在：可见降级，不渲染假页面
                    ContentUnavailableView(L10n.obsDetailLoadFailed, systemImage: "doc.text.magnifyingglass")
                }
            }
        }
        .navigationTitle(navTitle)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: observationId) { await state.loadDetail(id: observationId) }
        .alert(L10n.obsDetailDeleteTitle, isPresented: $showDeleteConfirm) {
            Button(L10n.obsDetailDelete, role: .destructive) {
                Task {
                    if await state.deleteObservation(id: observationId) {
                        deletedToast = true
                    }
                }
            }
            Button(L10n.commonCancel, role: .cancel) { }
        } message: {
            Text(L10n.obsDetailDeleteBody)
        }
        .alert(L10n.obsDetailEditSaved, isPresented: $editSavedToast) {
            Button(L10n.onboard_gotIt, role: .cancel) { }
        }
        .alert(L10n.obsDetailDeleteDone, isPresented: $deletedToast) {
            Button(L10n.onboard_gotIt, role: .cancel) { dismiss() }
        }
        .alert(L10n.obsDetailFollowUpDone, isPresented: $followUpDoneToast) {
            Button(L10n.onboard_gotIt, role: .cancel) { }
        }
        .sheet(isPresented: $showFollowUp) {
            followUpSheet
                .presentationDetents([.medium])
        }
    }

    private var navTitle: String {
        state.detail.map { L10n.observationKindName($0.kind) } ?? ""
    }

    // MARK: - 主体

    private func content(_ event: ObservationEvent) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header(event)
                if !event.mediaAssetIds.isEmpty {
                    LockedMediaStrip(assetIds: event.mediaAssetIds, memberId: event.memberId)
                }
                fields(event)
                bottomActions(event)
            }
            .padding(16)
            .frame(maxWidth: 560, alignment: .leading)   // 居中表单 ≤560pt（ui-ux §4.4）
        }
        .frame(maxWidth: .infinity)
    }

    private func header(_ event: ObservationEvent) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                event.kind.icon
                    .frame(width: 28, height: 28)
                Text(L10n.observationKindName(event.kind)).font(.title3.bold())
                GradeBadge(grade: "C")   // 观察 = 用户确认的 C 级数据
                Spacer()
            }
            Text(event.occurredAt, format: .dateTime.year().month().day().hour().minute())
                .font(.footnote).foregroundStyle(.secondary)
            if let capturedAt = event.capturedAt {
                Text("\(L10n.obsDetailCapturedAt) \(capturedAt, format: .dateTime.year().month().day().hour().minute())")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            // 自述标记（BR-006：显著标注为自述，不渲染好转/恶化判断词）
            if let mark = event.selfMark {
                Text("\(Self.markName(mark))（\(L10n.observationSelfMark)）")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let groupId = event.groupId {
                Button {
                    router.navigate(to: .documentList)   // 列表胶片带（FR8.5 对比视图随补齐批落地）
                } label: {
                    Label(L10n.obsDetailViewGroup, systemImage: "rectangle.stack")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("FR8.11.viewGroup.\(groupId.uuidString)")
            }
        }
    }

    // MARK: - 字段分组（FR8.2 已存字段全量；空字段整行隐藏）

    @ViewBuilder
    private func fields(_ event: ObservationEvent) -> some View {
        // 描述（主字段）
        if let description = event.description, !description.isEmpty {
            Text(description).font(.body)
        }
        // 补充信息折叠区：已存值展示 + 行内编辑
        DisclosureGroup(L10n.obsDetailEdit) {
            editor(event)
        }
        .accessibilityIdentifier("FR8.11.extended")

        // 已存扩展字段回显（未编辑态）
        if event.bodyPart != nil || event.durationMin != nil || event.frequency != nil
            || event.isFirst != nil || event.trigger != nil || event.accompanying != nil
            || event.painScore != nil || event.medsDiet != nil || event.consultedDoctor {
            VStack(alignment: .leading, spacing: 4) {
                row(L10n.obsDetailBodyPart, event.bodyPart)
                if let d = event.durationMin { row(L10n.obsDetailDuration, String(format: L10n.obsDetailDurationFmt, d)) }
                row(L10n.obsDetailFrequency, event.frequency)
                if let first = event.isFirst { row(L10n.obsDetailIsFirst, first ? L10n.onboard_confirm : L10n.commonCancel) }
                row(L10n.obsDetailTrigger, event.trigger)
                row(L10n.obsDetailAccompanying, event.accompanying)
                if let pain = event.painScore { row(L10n.obsDetailPainScore, "\(pain)/10") }
                row(L10n.obsDetailMedsDiet, event.medsDiet)
                if event.consultedDoctor { row(L10n.obsDetailConsulted, L10n.onboard_confirm) }
            }
            .font(.footnote)
        } else if event.description == nil || event.description?.isEmpty == true {
            Text(L10n.obsDetailEmpty).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func row(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            HStack(alignment: .top, spacing: 6) {
                Text(label).foregroundStyle(.secondary).frame(width: 96, alignment: .leading)
                Text(value)
            }
        }
    }

    // MARK: - 行内编辑（FR8.7）

    @ViewBuilder
    private func editor(_ event: ObservationEvent) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(L10n.obsDetailBodyPart, text: $draftBodyPart).textFieldStyle(.roundedBorder)
            Stepper(value: Binding(get: { draftDuration ?? 30 }, set: { draftDuration = $0 }), in: 1...1440) {
                Text(String(format: L10n.obsDetailDurationFmt, draftDuration ?? 30))
            }
            TextField(L10n.obsDetailFrequency, text: $draftFrequency).textFieldStyle(.roundedBorder)
            Toggle(L10n.obsDetailIsFirst, isOn: $draftIsFirst)
            TextField(L10n.obsDetailTrigger, text: $draftTrigger).textFieldStyle(.roundedBorder)
            TextField(L10n.obsDetailAccompanying, text: $draftAccompanying).textFieldStyle(.roundedBorder)
            VStack(alignment: .leading) {
                Text("\(L10n.obsDetailPainScore)：\(Int(draftPainScore))/10")
                Slider(value: $draftPainScore, in: 1...10, step: 1)
            }
            TextField(L10n.obsDetailMedsDiet, text: $draftMedsDiet).textFieldStyle(.roundedBorder)
            Toggle(L10n.obsDetailConsulted, isOn: $draftConsulted)
            TextField("", text: $draftDescription, axis: .vertical)
                .lineLimit(2...5)
                .textFieldStyle(.roundedBorder)

            Button {
                save(event)
            } label: {
                Text(L10n.obsDetailEditSave).frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("FR8.11.extended.save")
        }
        .padding(.top, 8)
        .onAppear { prefill(event) }
    }

    private func prefill(_ event: ObservationEvent) {
        draftBodyPart = event.bodyPart ?? ""
        draftDuration = event.durationMin
        draftFrequency = event.frequency ?? ""
        draftIsFirst = event.isFirst ?? false
        draftTrigger = event.trigger ?? ""
        draftAccompanying = event.accompanying ?? ""
        draftPainScore = Double(event.painScore ?? 1)
        draftMedsDiet = event.medsDiet ?? ""
        draftConsulted = event.consultedDoctor
        draftDescription = event.description ?? ""
    }

    private func save(_ event: ObservationEvent) {
        Task {
            let ok = await state.saveExtended(
                id: event.id,
                bodyPart: draftBodyPart.isEmpty ? nil : draftBodyPart,
                durationMin: draftDuration,
                frequency: draftFrequency.isEmpty ? nil : draftFrequency,
                isFirst: draftIsFirst,
                trigger: draftTrigger.isEmpty ? nil : draftTrigger,
                accompanying: draftAccompanying.isEmpty ? nil : draftAccompanying,
                painScore: Int(draftPainScore),
                medsDiet: draftMedsDiet.isEmpty ? nil : draftMedsDiet,
                consultedDoctor: draftConsulted,
                description: draftDescription.isEmpty ? nil : draftDescription)
            if ok { editSavedToast = true }
        }
    }

    // MARK: - 底栏动作（≥44pt）

    private func bottomActions(_ event: ObservationEvent) -> some View {
        HStack(spacing: 12) {
            Button {
                showFollowUp = true
            } label: {
                Label(L10n.obsDetailFollowUpTitle, systemImage: "bell.badge")
                    .frame(minHeight: 44)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("FR8.10.detail.followUp")
            Button(role: .destructive) {
                showDeleteConfirm = true
            } label: {
                Label(L10n.obsDetailDelete, systemImage: "trash")
                    .frame(minHeight: 44)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("FR8.11.delete")
        }
    }

    private var followUpSheet: some View {
        VStack(spacing: 16) {
            Text(L10n.obsDetailFollowUpTitle).font(.headline)
            Stepper(value: $followUpDays, in: 1...90) {
                Text(String(format: L10n.obsDetailFollowUpDays, followUpDays))
            }
            Button {
                if let event = state.detail {
                    Task {
                        await reminders.scheduleObservationFollowUp(
                            observationId: event.id, observedAt: event.occurredAt,
                            patientId: app.currentPatientId, days: followUpDays)
                        followUpDoneToast = true
                    }
                }
                showFollowUp = false
            } label: {
                Text(L10n.commonSave).frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(20)
    }

    /// 自述标记三值 → 展示名（BR-006：只译值本身，不附加判断）
    static func markName(_ mark: String) -> String {
        switch mark {
        case "improved": return L10n.observationTrendImproved
        case "worsened": return L10n.observationTrendWorsened
        default: return L10n.observationTrendUnchanged
        }
    }
}
