import SwiftUI
import Domain
import Infrastructure   // MemberDeletionService

/// F3 成员管理（SP-06 切片）：列表/切换/添加家人（FR3.7）。
///
/// 配额判定在 Domain（`PaywallRules.addingMemberWouldExceed`）——视图只在
/// 「会超配额」时走五时机弹墙（comercial §3 memberQuotaReached），
/// Pro 已解锁则不弹；业务规则零散落视图（tech-spec §1.1 规则 4）。
struct MemberManagementView: View {
    @Environment(AppState.self) private var app
    @Environment(AppEntitlementStore.self) private var entitlements
    @State private var showAdd = false
    @State private var quotaHint: String?

    var body: some View {
        List {
            Section {
                ForEach(app.members) { member in
                    HStack {
                        memberIcon(member.relation).resizable().frame(width: 24, height: 24)
                        NavigationLink {
                            MemberDetailView(member: member)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(member.displayName).font(.subheadline)
                                Text(member.relation).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if member.id == app.currentPatientId {
                            Text(L10n.member_current).font(.caption).bold()
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(Capsule().fill(Color("brand-primary", bundle: .main).opacity(0.15)))
                                .foregroundStyle(Color("brand-primary", bundle: .main))
                        } else {
                            Button(L10n.member_switch) {
                                app.setCurrentPatient(member.id)
                            }
                            .font(.caption)
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("FR3.7.member.switch")
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("FR3.7.member.row")
                }
            } footer: {
                Text(L10n.member_quotaHint)
            }
            Section {
                Button {
                    showAdd = true
                } label: {
                    Label(L10n.member_add, systemImage: "person.badge.plus").frame(minHeight: 44)
                }
                .accessibilityIdentifier("FR3.7.member.add")
            }
        }
        .navigationTitle(L10n.member_title)
        .task { await app.loadMembers() }
        .sheet(isPresented: $showAdd) {
            MemberCreateSheet { name, relation, birthDate in
                Task { @MainActor in
                    // 五时机 memberQuotaReached（Domain 判定 + 弹墙调度 + 24h 频控）
                    if PaywallRules.addingMemberWouldExceed(currentCount: app.members.count) {
                        if entitlements.evaluateTrigger(.memberQuotaReached) {
                            showAdd = false
                            return
                        }
                    }
                    let ok = await app.addMember(name: name, relation: relation, birthDate: birthDate)
                    quotaHint = ok ? L10n.member_addedHint : nil
                    showAdd = false
                }
            }
        }
        .alert(L10n.member_addedHint, isPresented: Binding(
            get: { quotaHint != nil },
            set: { if !$0 { quotaHint = nil } })) {
            Button(L10n.onboard_gotIt, role: .cancel) {}
        }
    }
}

// MARK: - FR3.1 成员详情/编辑 + FR3.4 删除流 + FR3.5 重新归属

/// 成员详情：FR3.1 字段（血型/证件号/医保号/备注）+ 删除流（影响清单 →
/// 姓名二次确认 → 计划「删除/停用归档」选择）+ 重新归属说明。
struct MemberDetailView: View {
    let member: PatientProfile
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var current: PatientProfile
    @State private var bloodType = ""
    @State private var idNo = ""
    @State private var insuranceNo = ""
    @State private var note = ""
    @State private var showDeleteFlow = false
    @State private var impact: MemberDeletionService.Impact?
    @State private var confirmName = ""
    @State private var deleteChoice: MemberDeletionService.DeleteChoice = .archivePlans

    init(member: PatientProfile) {
        self.member = member
        _current = State(initialValue: member)
    }

    var body: some View {
        Form {
            Section(L10n.memberDetailBasic) {
                LabeledContent(L10n.member_namePlaceholder, value: current.displayName)
                LabeledContent(L10n.member_relation, value: current.relation)
                if let birth = current.birthDate {
                    LabeledContent(L10n.member_birthDatePlaceholder, value: birth)
                }
            }
            // FR3.1 字段补全（P0：血型/证件号/医保号）
            Section(L10n.memberDetailMore) {
                TextField(L10n.memberBloodType, text: $bloodType)
                TextField(L10n.memberIdNo, text: $idNo)
                TextField(L10n.memberInsuranceNo, text: $insuranceNo)
                TextField(L10n.memberNote, text: $note, axis: .vertical)
                Button(L10n.reminder_save) {
                    var updated = current
                    updated.bloodType = bloodType.isEmpty ? nil : bloodType
                    updated.idNo = idNo.isEmpty ? nil : idNo
                    updated.insuranceNo = insuranceNo.isEmpty ? nil : insuranceNo
                    updated.note = note.isEmpty ? nil : note
                    updated.updatedAt = Date().timeIntervalSince1970
                    Task {
                        _ = await app.updateMember(updated)
                    }
                }
                .accessibilityIdentifier("FR3.1.member.update")
            }
            // 删除流（FR3.4：影响清单 → 姓名确认 → 计划处置选择）
            Section {
                if member.relation != "本人" {
                    Button(L10n.memberDelete, role: .destructive) {
                        Task {
                            impact = await app.memberDeletionImpact(patientId: member.id)
                            showDeleteFlow = true
                        }
                    }
                    .accessibilityIdentifier("FR3.4.member.delete")
                } else {
                    Text(L10n.memberSelfNoDelete)
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(current.displayName)
        .onAppear {
            bloodType = current.bloodType ?? ""
            idNo = current.idNo ?? ""
            insuranceNo = current.insuranceNo ?? ""
            note = current.note ?? ""
        }
        .sheet(isPresented: $showDeleteFlow) {
            DeleteMemberFlowSheet(member: member, impact: impact ?? MemberDeletionService.Impact(),
                                  choice: $deleteChoice, confirmName: $confirmName) {
                Task {
                    let ok = await app.deleteMember(patientId: member.id, choice: deleteChoice)
                    if ok {
                        showDeleteFlow = false
                        dismiss()
                    }
                }
            }
        }
    }
}

/// FR3.4 删除流：影响清单 → 姓名二次确认（红色边框输入框）→ 计划处置选择
private struct DeleteMemberFlowSheet: View {
    let member: PatientProfile
    let impact: MemberDeletionService.Impact
    @Binding var choice: MemberDeletionService.DeleteChoice
    @Binding var confirmName: String
    let onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.memberDeleteImpact) {
                    LabeledContent(L10n.memberDeleteImpactDocs, value: "\(impact.documentCount)")
                    LabeledContent(L10n.memberDeleteImpactObs, value: "\(impact.observationCount)")
                    LabeledContent(L10n.memberDeleteImpactPlans, value: "\(impact.planCount)")
                    LabeledContent(L10n.memberDeleteImpactAppts, value: "\(impact.appointmentCount)")
                    Text(L10n.memberDeleteKeepDocs)
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section(L10n.memberDeletePlanChoice) {
                    Picker("", selection: $choice) {
                        Text(L10n.memberDeletePlans).tag(MemberDeletionService.DeleteChoice.deletePlans)
                        Text(L10n.memberArchivePlans).tag(MemberDeletionService.DeleteChoice.archivePlans)
                    }
                    .pickerStyle(.segmented)
                }
                Section(L10n.memberDeleteConfirm) {
                    // FR3.4：需输入成员姓名二次确认
                    TextField(L10n.memberDeleteConfirmPlaceholder(member.displayName), text: $confirmName)
                        .textInputAutocapitalization(.never)
                    Button(L10n.memberDeleteConfirmButton, role: .destructive) {
                        onConfirm()
                    }
                    .disabled(confirmName != member.displayName)
                    .accessibilityIdentifier("FR3.4.member.delete.confirm")
                }
            }
            .navigationTitle(L10n.memberDelete)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.commonCancel) { dismiss() }
                }
            }
        }
    }
}

// MARK: - FR3.3 归属强制确认条（拍摄/导入保存前整屏醒目二次确认）

/// 保存前归属确认条：头像 + 姓名大字 + [更换]——多成员场景下 BR-001
/// 的唯一显式确认点（不得静默用 currentPatientId 保存）。
struct MemberConfirmBar: View {
    let patientName: String
    let relation: String
    let onSwitch: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color("brand-primary", bundle: .main).opacity(0.15))
                .frame(width: 44, height: 44)
                .overlay(Text(String(patientName.prefix(1))).font(.headline)
                    .foregroundStyle(Color("brand-primary", bundle: .main)))
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.memberConfirmBelongsTo)
                    .font(.caption).foregroundStyle(.secondary)
                Text(patientName)
                    .font(.title3.bold())
                Text(relation)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(L10n.memberConfirmSwitch) { onSwitch() }
                .font(.subheadline)
                .frame(minHeight: 44)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14)
            .fill(Color("brand-primary", bundle: .main).opacity(0.06)))
        .accessibilityIdentifier("FR3.3.memberConfirmBar")
    }
}

private struct MemberCreateSheet: View {
    let onCreate: (String, String, String?) -> Void
    @State private var name = ""
    @State private var relation = "子女"
    @State private var birthDate = ""

    private let relations = ["配偶", "子女", "父母", "祖父母", "其他"]

    var body: some View {
        NavigationStack {
            Form {
                TextField(L10n.member_namePlaceholder, text: $name)
                    .accessibilityIdentifier("FR3.7.create.name")
                Picker(L10n.member_relation, selection: $relation) {
                    ForEach(relations, id: \.self) { Text($0) }
                }
                TextField(L10n.member_birthDatePlaceholder, text: $birthDate)
                    .accessibilityIdentifier("FR3.7.create.birthDate")
            }
            .navigationTitle(L10n.member_add)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.member_save) {
                        onCreate(name, relation, birthDate.isEmpty ? nil : birthDate)
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("FR3.7.create.save")
                }
            }
        }
    }
}


extension MemberManagementView {
    /// 按关系选图标（design/Resources Members 系列；未知关系回退家庭图标）
    private func memberIcon(_ relation: String) -> Image {
        switch relation {
        case "配偶": return VLIcon.memberPartner
        case "父亲": return VLIcon.memberFather
        case "母亲": return VLIcon.memberMother
        case "儿子": return VLIcon.memberSon
        case "女儿": return VLIcon.memberDaughter
        case "本人": return VLIcon.memberSelf
        default: return VLIcon.memberFamily
        }
    }
}
