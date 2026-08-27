import SwiftUI
import Domain

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
                        VStack(alignment: .leading, spacing: 2) {
                            Text(member.displayName).font(.subheadline)
                            Text(member.relation).font(.caption).foregroundStyle(.secondary)
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
                    Label(L10n.member_add, image: "ic-person-add").frame(minHeight: 44)
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
