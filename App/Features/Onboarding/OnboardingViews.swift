import SwiftUI
import Domain
import Perception

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
        WithPerceptionTracking {
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
        WithPerceptionTracking {
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
}

/// 首启建档表单（业主 2026-09-17 定）：注册必要字段 = 特征性数据（性别/出生日期/血型）+
/// 紧急联系人。进入时尝试从 Apple 健康**预填默认值**（最小授权请求、只读特征型）——
/// 授权被拒/健康里没有 → 静默回落手动填写，**绝不阻断注册**；预填值全部可编辑。
/// 「稍后」跳过语义保留（FR21.9 可跳过：占位「本人」+ 稍后完善）。
struct OwnerSetupView: View {
    @Environment(AppState.self) private var app
    @Environment(F16DeviceState.self) private var deviceState
    @State private var name = ""
    @State private var gender = ""                       // male/female/other；空 = 未选
    @State private var birthYear = ""
    @State private var birthMonth = ""
    @State private var birthDay = ""
    @State private var bloodChoice = ""                  // 标准八档 / "special"；空 = 未选
    @State private var specialBloodNote = ""
    @State private var contactName = ""
    @State private var contactRelation = MemberRelation.partner.rawValue
    @State private var contactPhone = ""
    /// 预填是否已应用（提示行只在有实际默认值时出现）
    @State private var prefilled = false
    @State private var prefillAttempted = false
    /// 全仓审查 2026-09-18（F-A1-01）：建档落库失败响亮呈现（四态纪律），不推进向导
    @State private var saveFailed = false
    /// 提交在途（防双击重复建档；落库成功后视图随 stage 卸载）
    @State private var submitting = false
    /// 键盘焦点（numberPad/phonePad 无回车键——键盘工具栏「确认」是唯一收起通道）
    @FocusState private var focusedField: Field?
    private enum Field { case name, birthYear, birthMonth, birthDay, bloodNote, contactName, contactPhone }

    var body: some View {
        WithPerceptionTracking {
            VStack(spacing: 0) {
                Form {
                    profileSection
                    contactSection
                    if prefilled {
                        Label(L10n.onboardPrefillHint, systemImage: "heart.text.clipboard")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("SP-06.owner.prefillHint")
                    }
                    actionsSection
                }
                .frame(maxWidth: 560)
                // 键盘工具栏：数字键盘族无 return——「确认」收起键盘（触达与录入框一致）
                .toolbar {
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button(L10n.commonConfirm) { focusedField = nil }
                            .accessibilityIdentifier("SP-06.owner.dismissKeyboard")
                    }
                }
            }
            .navigationTitle(L10n.onboard_buildProfile)
            .saveFailedAlert(title: L10n.onboardSaveFailed, hint: L10n.onboardSaveFailedHint,
                             isPresented: $saveFailed)
            .task {
                guard !prefillAttempted else { return }
                prefillAttempted = true
                await prefillFromHealth()
            }
        }
    }

    // MARK: - 本人资料（特征性数据）

    private var profileSection: some View {
        Section {
            TextField(L10n.onboard_yourName, text: $name)
                    .focused($focusedField, equals: .name)
                    .accessibilityIdentifier("SP-06.owner.name")
            Picker(L10n.onboardGender, selection: $gender) {
                Text(L10n.onboardNotSelected).tag("")
                Text(L10n.onboardGenderMale).tag("male")
                Text(L10n.onboardGenderFemale).tag("female")
                Text(L10n.onboardGenderOther).tag("other")
            }
            .accessibilityIdentifier("SP-06.owner.gender")
            // FR3.1 精度纪律：年份必填、月日可空；月日只接受成对填写（不虚构不补齐）
            HStack {
                TextField(L10n.onboardBirthYear, text: $birthYear)
                    .focused($focusedField, equals: .birthYear)
                    .keyboardType(.numberPad)
                    .accessibilityIdentifier("SP-06.owner.birthYear")
                TextField(L10n.onboardBirthMonth, text: $birthMonth)
                    .focused($focusedField, equals: .birthMonth)
                    .keyboardType(.numberPad)
                    .frame(maxWidth: 64)
                    .accessibilityIdentifier("SP-06.owner.birthMonth")
                TextField(L10n.onboardBirthDay, text: $birthDay)
                    .focused($focusedField, equals: .birthDay)
                    .keyboardType(.numberPad)
                    .frame(maxWidth: 64)
                    .accessibilityIdentifier("SP-06.owner.birthDay")
            }
            Picker(L10n.memberBloodType, selection: $bloodChoice) {
                Text(L10n.onboardNotSelected).tag("")
                ForEach(RegistrationPrefill.standardBloodTypes, id: \.self) { type in
                    Text(type).tag(type)
                }
                Text(L10n.onboardBloodSpecial).tag("special")
            }
            .accessibilityIdentifier("SP-06.owner.bloodType")
            if bloodChoice == "special" {
                TextField(L10n.onboardBloodNotePlaceholder, text: $specialBloodNote)
                    .focused($focusedField, equals: .bloodNote)
                    .accessibilityIdentifier("SP-06.owner.bloodNote")
            }
        } header: { Text(L10n.onboardProfileHeader) } footer: { Text(L10n.onboardProfileFooter) }
    }

    // MARK: - 紧急联系人（注册必填）

    private var contactSection: some View {
        Section {
            TextField(L10n.onboardContactName, text: $contactName)
                    .focused($focusedField, equals: .contactName)
                    .accessibilityIdentifier("SP-06.owner.contact.name")
            Picker(L10n.onboardContactRelation, selection: $contactRelation) {
                // 关系展示走 memberRelationDisplayName 单一映射出口（FR6.9 展示层纪律）。
                // 审查修复（选项英文问题）：选项集此前硬编码英文 rawValue 数组——
                // 存储词表与成员 sheet 的 Domain MemberRelation（中文 rawValue 单一
                // 事实源）漂移，且展示层 default 分支原样吐回小写英文。改走
                // MemberRelation.creatable（Domain 单一出口），三语经既有
                // member.relation.* 键本地化（en 首字母大写）。
                ForEach(MemberRelation.creatable, id: \.self) { rel in
                    Text(L10n.memberRelationDisplayName(rel.rawValue)).tag(rel.rawValue)
                }
            }
            .accessibilityIdentifier("SP-06.owner.contact.relation")
            TextField(L10n.onboardContactPhone, text: $contactPhone)
                    .focused($focusedField, equals: .contactPhone)
                    .keyboardType(.phonePad)
                .accessibilityIdentifier("SP-06.owner.contact.phone")
        } header: { Text(L10n.onboardContactHeader) } footer: { Text(L10n.onboardContactFooter) }
    }

    private var actionsSection: some View {
        Section {
            Button {
                create()
            } label: {
                Text(L10n.onboard_createContinue).frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!formValid || submitting)
            .accessibilityIdentifier("SP-06.owner.create")
            // FR21.9：任意步可跳过（建档可稍后完成，由系统默认「本人」占位）
            // 全仓审查 2026-09-18（F-A1-01）：占位建档同样先落库、失败不推进
            Button {
                guard !submitting else { return }
                submitting = true
                Task {
                    let ok = await app.skipOwner()
                    submitting = false
                    if !ok { saveFailed = true }
                }
            } label: {
                Text(L10n.onboard_later).frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderless)
            .disabled(submitting)
            .accessibilityIdentifier("SP-06.owner.skip")
        }
    }

    // MARK: - 健康预填

    /// 预填 = 便利默认值：最小授权请求 + 只读特征型；任何一步失败/无数据 → 静默回落。
    /// 只填空字段——用户已输入的内容绝不被覆盖。
    private func prefillFromHealth() async {
        // 授权被拒/流程未完成/健康里无数据 → 静默回落手动填写，绝不阻断注册
        let characteristics: HealthCharacteristics
        do {
            characteristics = try await deviceState.requestRegistrationPrefill()
        } catch { return }
        guard !Task.isCancelled else { return }
        let defaults = RegistrationPrefill.defaults(from: characteristics)
        if gender.isEmpty { gender = defaults.gender ?? "" }
        if birthYear.isEmpty {
            birthYear = defaults.birthYear ?? ""
            birthMonth = defaults.birthMonth ?? ""
            birthDay = defaults.birthDay ?? ""
        }
        if bloodChoice.isEmpty { bloodChoice = defaults.bloodType ?? "" }
        if !defaults.isEmpty { prefilled = true }
    }

    // MARK: - 校验与提交

    /// 出生日期串：月日**成对**合法（01-12 / 01-31）才携带，否则仅年份（FR3.1 不虚构不补齐）。
    private var birthDate: String? {
        guard birthYear.count == 4, birthYear.allSatisfy(\.isNumber) else { return nil }
        let monthOK = birthMonth.count == 2 && birthMonth.allSatisfy(\.isNumber)
            && (1...12).contains(Int(birthMonth) ?? 0)
        let dayOK = birthDay.count == 2 && birthDay.allSatisfy(\.isNumber)
            && (1...31).contains(Int(birthDay) ?? 0)
        if birthMonth.isEmpty && birthDay.isEmpty { return birthYear }
        guard monthOK && dayOK else { return nil }   // 只填其一/非法 → 表单无效，响亮拒绝
        return "\(birthYear)-\(birthMonth)-\(birthDay)"
    }

    private var bloodValue: String? {
        if bloodChoice.isEmpty { return nil }
        if bloodChoice == "special" {
            let note = specialBloodNote.trimmingCharacters(in: .whitespacesAndNewlines)
            return note.isEmpty ? nil : note
        }
        return bloodChoice
    }

    private var contactDraft: EmergencyContactDraft? {
        let draft = EmergencyContactDraft(name: contactName, relation: contactRelation,
                                          phone: contactPhone)
        return draft.isValid ? draft : nil
    }

    private var formValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !gender.isEmpty && birthDate != nil && bloodValue != nil && contactDraft != nil
    }

    /// 全仓审查 2026-09-18（F-A1-01）：await 落库结果——成功由 AppState 推进 stage
    /// 卸载本视图；失败弹统一保存失败警报、表单保留用户输入可重试。
    private func create() {
        guard formValid, !submitting, let birthDate, let bloodValue, let contact = contactDraft else { return }
        submitting = true
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        Task {
            let ok = await app.createOwner(name: trimmedName, gender: gender, birthDate: birthDate,
                                           bloodType: bloodValue, contact: contact)
            submitting = false
            if !ok { saveFailed = true }
        }
    }
}
