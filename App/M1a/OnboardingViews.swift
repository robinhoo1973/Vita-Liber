import SwiftUI
import UIKit
import PhotosUI
import Domain

/// M1a 首启流程视图：L1 三卡 → 建档 → 拍摄 → OCR 确认 → 时间轴（V3.22 无 PIN 步骤）。
/// 评审修正批：VLIcon 单出口（修空图标）、a11y、L3 微文案、修订入口。

struct DisclosureCardsView: View {
    @Environment(AppState.self) private var app
    let card: DisclosureCard

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 12) {
                icon
                    .resizable().frame(width: 48, height: 48)
                Text(title).font(.title2.bold())
                Text("\(app.disclosureCards.firstIndex(where: { $0.key == card.key }).map { $0 + 1 } ?? 1)/\(app.disclosureCards.count)")
                    .font(.footnote)
                    .foregroundStyle(Color("text-secondary", bundle: .main))
            }
            .padding(.top, 32)

            Text(card.body)
                .font(.body)
                .multilineTextAlignment(.leading)
                .lineSpacing(6)
                .frame(maxWidth: 560)
                .padding(.horizontal, 24)

            Spacer()

            Button {
                app.advanceDisclosure()
            } label: {
                Text(L10n.onboard_gotIt)
                    .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
            .accessibilityIdentifier("SP-01.disclosure.confirm")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color("bg-grouped", bundle: .main))
    }

    /// 评审 S2 修正：资源在 Assets.xcassets 而非系统符号库——
    /// `Image(systemName:)` 传资源名会得到空图标，必须走 VLIcon 单出口
    private var icon: Image {
        switch card.kind {
        case .boundary: return VLIcon.stopOctagon
        case .storage: return VLIcon.lock
        case .skipInfo: return VLIcon.checkCircle
        }
    }
    private var title: String {
        switch card.kind {
        case .boundary: return "这不是医疗设备"
        case .storage: return "数据只在本机"
        case .skipInfo: return "这些可以稍后再做"
        }
    }
}

/// FR21.9 ④ 添加家人（可跳过）：方式选择（手工新建；语音/通讯录 P1 置灰说明）
/// + 新建后「完善档案」引导。跳过不阻塞主流程。
struct AddFamilyStepView: View {
    @Environment(AppState.self) private var app
    @State private var showCreate = false
    @State private var addedHint = false

    var body: some View {
        VStack(spacing: 20) {
            Text(L10n.onboardAddFamilyTitle).font(.title2.bold())
            Text(L10n.onboardAddFamilyHint)
                .font(.footnote).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            VStack(spacing: 12) {
                Button {
                    showCreate = true
                } label: {
                    Label(L10n.onboardAddFamilyManual, systemImage: "person.badge.plus")
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("FR21.9.step4.manual")
                // P1 方式置灰说明（不假装可用）
                Label(L10n.onboardAddFamilyVoiceP1, systemImage: "mic")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 44)
                Label(L10n.onboardAddFamilyContactsP1, systemImage: "person.crop.rectangle")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .padding(.horizontal, 24)

            Button(L10n.onboardAddFamilySkip) {
                app.finishAddFamilyStep()
            }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity, minHeight: 50)
            .padding(.horizontal, 24)
            .accessibilityIdentifier("FR21.9.step4.skip")
        }
        .sheet(isPresented: $showCreate) {
            MemberCreateSheet { name, relation, birthDate in
                Task { @MainActor in
                    _ = await app.addMember(name: name, relation: relation, birthDate: birthDate)
                    showCreate = false
                    addedHint = true
                }
            }
        }
        // FR3.7 新建后「完善档案」引导（过敏/既往史/紧急联系人）
        .alert(L10n.onboardAddFamilyCompleteHint, isPresented: $addedHint) {
            Button(L10n.onboard_gotIt, role: .cancel) { }
        }
    }
}

/// FR21.9 ⑥ 首日引导（全部可跳过）：三张行动卡 [拍第一份资料][设第一个提醒][了解 AI]。
struct FirstDayActionsView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        VStack(spacing: 20) {
            Text(L10n.onboardFirstDayTitle).font(.title2.bold())
            Text(L10n.onboardFirstDayHint)
                .font(.footnote).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            VStack(spacing: 12) {
                ActionCard(icon: "camera.fill", title: L10n.onboardFirstDayCapture) {
                    app.stage = .scanCapture
                }
                ActionCard(icon: "bell.badge.fill", title: L10n.onboardFirstDayReminder) {
                    app.finishFirstDayActions()
                }
                ActionCard(icon: "sparkles", title: L10n.onboardFirstDayAI) {
                    app.finishFirstDayActions()
                }
            }
            .padding(.horizontal, 24)

            Button(L10n.onboardAddFamilySkip) {
                app.finishFirstDayActions()
            }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity, minHeight: 50)
            .padding(.horizontal, 24)
            .accessibilityIdentifier("FR21.9.step6.skip")
        }
    }
}

private struct ActionCard: View {
    let icon: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(Color("brand-primary", bundle: .main))
                    .frame(width: 44, height: 44)
                Text(title).font(.subheadline).foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemGroupedBackground)))
        }
        .buttonStyle(.plain)
    }
}

struct OwnerSetupView: View {
    @Environment(AppState.self) private var app
    @State private var name = ""

    var body: some View {
        VStack(spacing: 20) {
            Text(L10n.onboard_buildProfile).font(.title2.bold())
            Text(L10n.onboard_ownerNote).font(.footnote).foregroundStyle(Color("text-secondary", bundle: .main))
            TextField(L10n.onboard_yourName, text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 320)
                .accessibilityIdentifier("SP-06.owner.name")
            Button {
                guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                app.createOwner(name: name.trimmingCharacters(in: .whitespaces))
            } label: {
                Text(L10n.onboard_createContinue).frame(maxWidth: 320, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            .accessibilityIdentifier("SP-06.owner.create")
            // FR21.9：任意步可跳过（建档可稍后完成，由系统默认「本人」占位）
            Button {
                app.skipOwner()
            } label: {
                Text(L10n.onboard_later)
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("SP-06.owner.skip")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color("bg-grouped", bundle: .main))
    }
}

struct ScanCaptureView: View {
    @Environment(AppState.self) private var app
    @State private var showCamera = false
    @State private var pickedItem: PhotosPickerItem?
    @State private var captureFailed = false

    /// 无相机设备时隐藏拍照入口（与 QuickCaptureView 同一防崩溃纪律）
    private var cameraAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    var body: some View {
        VStack(spacing: 24) {
            Text(L10n.onboard_capturePrescription).font(.title2.bold())
            Text(L10n.onboard_aimPrescription)
                .font(.footnote).foregroundStyle(Color("text-secondary", bundle: .main))
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6]))
                .foregroundStyle(Color("brand-primary", bundle: .main))
                .overlay(VLIcon.scanDocument.resizable().frame(width: 56, height: 56))
                .frame(maxWidth: 320, minHeight: 240)

            if app.hasTestCapture {
                // XCUITest 假样张路径（生产无桩时不可达）
                Button {
                    app.captureSample()
                } label: {
                    Label(L10n.onboard_scanSample, systemImage: "camera")
                        .frame(maxWidth: 320, minHeight: 50)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("SP-07.scan.capture")
            } else {
                // 生产路径：真实拍摄/相册 → Vision 编排层 → 确认工作台（BR-003）
                if cameraAvailable {
                    Button {
                        showCamera = true
                    } label: {
                        Label(L10n.onboard_scanSample, systemImage: "camera.fill")
                            .frame(maxWidth: 320, minHeight: 50)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("SP-07.scan.capture")
                } else {
                    Label(L10n.homeCaptureNoCamera, systemImage: "camera.fill")
                        .font(.caption).foregroundStyle(.secondary)
                }
                PhotosPicker(selection: $pickedItem, matching: .images) {
                    Label(L10n.homeCaptureLibrary, systemImage: "photo.on.rectangle")
                        .frame(maxWidth: 320, minHeight: 50)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("SP-07.scan.library")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color("bg-grouped", bundle: .main))
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in
                showCamera = false
                guard let data = image.jpegData(compressionQuality: 0.85) else {
                    captureFailed = true
                    return
                }
                Task { await runCapture(data) }
            }
        }
        .onChange(of: pickedItem) { _, item in
            guard let item else { return }
            pickedItem = nil
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {   // try?-ok: 加载失败走可见错误
                    await runCapture(data)
                } else {
                    captureFailed = true
                }
            }
        }
        .alert(L10n.docImportFailed, isPresented: $captureFailed) {
            Button(L10n.onboard_gotIt, role: .cancel) { }
        }
    }

    private func runCapture(_ data: Data) async {
        let ok = await app.captureFrom(imageData: data)
        if !ok { captureFailed = true }
    }
}

/// OCR 字段确认工作台（SP-53 的 M1a 切片；BR-003 闸门 + L3 常驻微文案）
struct OcrConfirmView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        VStack(spacing: 16) {
            Text(L10n.onboard_confirmResult).font(.title2.bold())
            // FR20.3 L3 常驻微文案：机器识别确认免责从 L1 第三卡移入此处
            Text(L10n.onboard_ocrDisclaimer)
                .font(.footnote)
                .foregroundStyle(Color("text-secondary", bundle: .main))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            if let set = app.activeSet {
                ForEach(set.fields) { field in
                    ConfirmFieldRowView(field: field) {
                        app.confirmField(id: field.id)
                    } onRevise: { newValue in
                        app.reviseField(id: field.id, to: newValue)
                    } onReject: {
                        app.rejectField(id: field.id)
                    }
                }
            }

            Spacer()

            if let set = app.activeSet, set.isUsableInTimeline {
                Button {
                    app.commitToTimeline()
                } label: {
                    Text(L10n.onboard_confirmAllTimeline).frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal, 24)
                .accessibilityIdentifier("SP-53.ocr.commit")
            }
        }
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color("bg-grouped", bundle: .main))
    }
}

/// 确认行：草稿=虚线 D 级 / 确认=实线绿（ui-ux §1 原则 3）；
/// 修订入口（评审：退出准则「改一条留修订历史」此前无 UI 不可达）
struct ConfirmFieldRowView: View {
    let field: CandidateField
    let onConfirm: () -> Void
    let onRevise: (String) -> Void
    let onReject: () -> Void
    @State private var editing = false
    @State private var draft = ""

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(field.displayLabel).font(.caption).foregroundStyle(Color("text-secondary", bundle: .main))
                Text(field.value).font(.body)
                // FR6.3 三级置信度颜色语义：高=绿轻标注 / 中=黄提示复核 / 低=红高亮必复核
                Text(L10n.onboardTierUnconfirmed(tierText))
                    .font(.caption2)
                    .foregroundStyle(tierColor)
            }
            // ui-ux §7 单焦点朗读放在信息组（不合并操作按钮）：
            // 行级 combine 会把按钮的 identifier 提升到行元素，XCUITest 查询撞双 ID
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(field.displayLabel)，\(field.value)，\(field.isConfirmed ? L10n.onboard_confirmed : L10n.onboard_unconfirmedBadge)")
            Spacer()
            if field.isConfirmed {
                Button {
                    draft = field.value
                    editing = true
                } label: {
                    Image(systemName: "pencil")
                        .frame(width: 44, height: 44)          // 触控目标 ≥44pt（ui-ux §4.2）
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("修改\(field.displayLabel)")
                .accessibilityIdentifier("SP-53.field.edit.\(field.key)")
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color("grade-c", bundle: .main))
                    .frame(width: 44, height: 44)
            } else if field.grade == .rejected {
                Text(L10n.onboardRejected)
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Button("确认", action: onConfirm)
                    .buttonStyle(.bordered)
                    .frame(minHeight: 44)                       // 触控目标 ≥44pt
                    .accessibilityIdentifier("SP-53.field.confirm.\(field.key)")
                // FR6.4 ✕ 放弃：保留原识别值，不入正式区
                Button {
                    onReject()
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.bordered)
                .tint(.secondary)
                .accessibilityLabel(L10n.onboardRejectLabel(field.displayLabel))
                .accessibilityIdentifier("SP-53.field.reject.\(field.key)")
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(.background))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(field.isConfirmed ? Color("grade-c", bundle: .main) : Color("grade-d", bundle: .main),
                              style: StrokeStyle(lineWidth: field.isConfirmed ? 1 : 1.5, dash: field.isConfirmed ? [] : [5]))
        )
        .padding(.horizontal, 16)
        .sheet(isPresented: $editing) {
            VStack(spacing: 16) {
                Text(L10n.onboardReviseTitle(field.displayLabel)).font(.headline)
                Text(L10n.onboardOcrRaw(field.rawText)).font(.caption).foregroundStyle(.secondary)
                TextField(L10n.onboard_newValue, text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("SP-53.field.editField")
                HStack {
                    Button(L10n.onboard_cancel) { editing = false }
                    Button(L10n.onboard_saveEdit) {
                        onRevise(draft)
                        editing = false
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("SP-53.field.editSave")
                }
            }
            .padding(24)
            .presentationDetents([.height(260)])
        }
    }

    private var tierText: String {
        switch ConfidenceTier.tier(field.confidence) {
        case .high: return "高置信度"
        case .mid: return "中置信度"
        case .low: return "低置信度"
        }
    }

    /// FR6.3：已确认 C 绿；未确认按档位——高绿轻标注 / 中黄 / 低红高亮（必须复核）
    private var tierColor: Color {
        if field.isConfirmed { return Color("grade-c", bundle: .main) }
        // 审查修复：语义令牌替代系统原色——高对比度/深色模式重映射才能生效
        switch ConfidenceTier.tier(field.confidence) {
        case .high: return Color("semantic-success", bundle: .main)
        case .mid: return Color("semantic-warning", bundle: .main)
        case .low: return Color("semantic-danger", bundle: .main)
        }
    }
}

/// 时间轴最小投影（F11 M1a：仅文档一类）
struct TimelineView: View {
    @Environment(AppState.self) private var app
    var showFinishButton = true

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text(L10n.onboard_timelineTitle).font(.title2.bold())
                Spacer()
                NavigationLink {
                    ObservationListView()
                } label: {
                    // 评审修正：入口标签与相邻「指标趋势」「语音速记」统一为 4 字
                    //（「观察」2 字造成三入口版式参差），中文等宽字形下 4 字标签天然等宽对齐。
                    Label(L10n.onboard_observationAdd, systemImage: "plus.circle")
                        .frame(minWidth: 88, alignment: .leading)
                }
                .accessibilityIdentifier("SP-10.timeline.observation")
                NavigationLink {
                    TrendEntryView()
                } label: {
                    Label(L10n.onboard_trendTitle, systemImage: "chart.xyaxis.line")
                        .frame(minWidth: 88, alignment: .leading)
                }
                .accessibilityIdentifier("SP-10.timeline.trend")
                NavigationLink {
                    VoiceNotePanelView()
                } label: {
                    Label(L10n.onboard_voiceNote, systemImage: "waveform")
                        .frame(minWidth: 88, alignment: .leading)
                }
                .accessibilityIdentifier("SP-10.timeline.voicenote")
            }
            .padding(.horizontal, 16)
            if app.timeline.isEmpty {
                ContentUnavailableView(L10n.timelineEmptyTitle, systemImage: "clock.arrow.circlepath",
                                       description: Text(L10n.onboard_timelineHint))
            } else {
                List(app.timeline) { entry in
                    // 评审修正：样张/处方条目可打开（此前行无路由，点击无响应）
                    NavigationLink {
                        TimelineDocumentDetailView(entry: entry)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.title).font(.body)
                            Text(L10n.onboardConfirmedCount(entry.confirmedFieldCount, entry.totalFieldCount))
                                .font(.caption).foregroundStyle(.secondary)
                            if !entry.revisionHistory.isEmpty {
                                Text(L10n.onboardRevisionHistory(entry.revisionHistory.joined(separator: " → ")))
                                    .font(.caption2)
                                    .foregroundStyle(Color("text-secondary", bundle: .main))
                            }
                        }
                    }
                    .accessibilityIdentifier("SP-10.timeline.entry")
                }
            }
            if showFinishButton {
                Button {
                    // FR21.9：时间轴完成后进 ⑥ 首日引导（全部可跳过），
                    // 不再直接 finishOnboarding
                    app.stage = .firstDayActions
                } label: {
                    Text(L10n.onboard_finishEnterApp).frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal, 24)
                .accessibilityIdentifier("SP-01.onboarding.finish")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color("bg-grouped", bundle: .main))
    }
}
