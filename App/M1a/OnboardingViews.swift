import SwiftUI
import UIKit
import Domain

/// M1a 首启流程视图（V3.39 简化）：L1 三卡 → 建档 → 添加家人（无 PIN 步骤）。
/// 拍摄/OCR/时间轴不再属于向导（FR21.9 V3.39：资料采集走 SP-11/SP-10 生产管线，
/// 首日引导三张行动卡由首页空态引导 SP-04 承载）。原 OcrConfirmView/ConfirmFieldRowView
/// 已随向导简化删除——SP-12 单文档确认由 SP-11 确认卡 DocumentImportConfirmView 承载，
/// SP-53 队列改为 grade 'D' 文档聚合（PendingOcrQueueView，DocumentStore 单源）。
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
        case .boundary: return L10n.onboardBoundaryTitle
        case .storage: return L10n.onboardStorageTitle
        case .skipInfo: return L10n.onboardSkipInfoTitle
        }
    }
}

/// FR21.9 ④ 添加家人（可跳过）：方式选择（手工新建；语音/通讯录 P1 置灰说明）
/// + 新建后「完善档案」引导。跳过不阻塞主流程。
/// V3.39 起为向导最后一步——完成即结束首启。新增成员后主按钮切换为
/// 「完成，进入应用」（跳过按钮保留，语义不再歧义：未新增成员时只有跳过）。
struct AddFamilyStepView: View {
    @Environment(AppState.self) private var app
    @State private var showCreate = false
    @State private var addedHint = false
    @State private var addedCount = 0

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

            // V3.39 语义修正：新增过成员后主按钮为「完成，进入应用」——
            // 此前无论是否新增成员都只能点「跳过」完成向导，动作语义与用户
            // 实际行为矛盾（新增了家人还要「跳过」）
            Button(addedCount > 0 ? L10n.onboardAddFamilyFinish : L10n.onboardAddFamilySkip) {
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
                    if await app.addMember(name: name, relation: relation, birthDate: birthDate) {
                        addedCount += 1
                    }
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
