import SwiftUI
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
            Button {
                app.captureSample()
            } label: {
                Label(L10n.onboard_scanSample, systemImage: "camera")
                    .frame(maxWidth: 320, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("SP-07.scan.capture")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color("bg-grouped", bundle: .main))
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
    @State private var editing = false
    @State private var draft = ""

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(field.displayLabel).font(.caption).foregroundStyle(Color("text-secondary", bundle: .main))
                Text(field.value).font(.body)
                Text(L10n.onboardTierUnconfirmed(tierText))
                    .font(.caption2)
                    .foregroundStyle(field.isConfirmed ? Color("grade-c", bundle: .main) : Color("grade-d", bundle: .main))
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
            } else {
                Button("确认", action: onConfirm)
                    .buttonStyle(.bordered)
                    .frame(minHeight: 44)                       // 触控目标 ≥44pt
                    .accessibilityIdentifier("SP-53.field.confirm.\(field.key)")
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
                    Label(L10n.onboard_observation, systemImage: "plus.circle")
                }
                .accessibilityIdentifier("SP-10.timeline.observation")
                NavigationLink {
                    TrendEntryView()
                } label: {
                    Label(L10n.onboard_trendTitle, systemImage: "chart.xyaxis.line")
                }
                .accessibilityIdentifier("SP-10.timeline.trend")
                NavigationLink {
                    VoiceNotePanelView()
                } label: {
                    Label(L10n.onboard_voiceNote, systemImage: "waveform")
                }
                .accessibilityIdentifier("SP-10.timeline.voicenote")
            }
            .padding(.horizontal, 16)
            if app.timeline.isEmpty {
                ContentUnavailableView(L10n.timelineEmptyTitle, systemImage: "clock.arrow.circlepath",
                                       description: Text(L10n.onboard_timelineHint))
            } else {
                List(app.timeline) { entry in
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
                    .accessibilityIdentifier("SP-10.timeline.entry")
                }
            }
            if showFinishButton {
                Button {
                    app.finishOnboarding()
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
