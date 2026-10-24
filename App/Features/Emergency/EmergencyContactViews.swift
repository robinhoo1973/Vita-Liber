import SwiftUI
import Domain
import Perception

/// F3 P1 紧急联系人管理（2026-10-23 业主：医疗档案里已有的联系人信息
/// 必须能进入急救卡，且注册后仍可补录/修改）。
///
/// 数据源 = `contact.is_emergency = 1`（与急救卡候选同一条查询），
/// 写入经 `M2HubStore` → `EmergencyCardStore`，成功后刷新候选与已选。
/// 边界：只维护用户填写的联系人事实，不推断关系、不预置号码。
struct EmergencyContactListView: View {
    @Environment(AppState.self) private var app
    @Environment(M2HubStore.self) private var hub
    @Environment(AppEntitlementStore.self) private var entitlements

    @State private var editor: ContactEditorTarget?
    @State private var deleteTarget: EmergencyCardItem?
    /// 独立于 `deleteTarget` 的弹窗开关：系统关闭 alert 只会把本开关置 false，
    /// 目标条目保留到按钮动作读取完，避免「先清目标、后跑动作」的空操作。
    @State private var confirmDelete = false
    @State private var actionFailed = false
    /// 自动加入常用成员失败/配额不足的可见提示（联系人与成员是两次写入）。
    @State private var autoAddHint: String?

    private var patientId: UUID { app.currentPatientId }

    private var contacts: [EmergencyCardItem] {
        hub.isLoaded(for: patientId) ? hub.emergencyCandidates.contacts : []
    }

    var body: some View {
        WithPerceptionTracking {
            List {
                if !hub.isLoaded(for: patientId) {
                    Section {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text(L10n.emergencyLoading)
                                .font(.subheadline)
                                .foregroundStyle(Color("text-secondary", bundle: .main))
                        }
                        .accessibilityIdentifier("F15.contacts.loading")
                    }
                } else if hub.emergencyLoadFailed {
                    // 读取失败不等于「尚未添加联系人」：给可重试出口。
                    Section {
                        Text(L10n.emergencyLoadFailed)
                            .font(.subheadline)
                            .foregroundStyle(Color("text-secondary", bundle: .main))
                        Button(L10n.retry) {
                            Task { await hub.load(patientId: patientId, force: true) }
                        }
                        .accessibilityIdentifier("F15.contacts.retry")
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("F15.contacts.loadFailed")
                } else if contacts.isEmpty {
                    Section {
                        Text(L10n.emergencyContactsEmpty)
                            .font(.subheadline)
                            .foregroundStyle(Color("text-secondary", bundle: .main))
                            .accessibilityIdentifier("F15.contacts.empty")
                    }
                } else {
                    Section {
                        ForEach(contacts) { contact in
                            row(contact)
                        }
                    }
                }
                Section {
                    Text(L10n.emergencyContactsHint)
                        .font(.caption)
                        .foregroundStyle(Color("text-secondary", bundle: .main))
                }
            }
            .scrollContentBackground(.hidden)
            .tintedCanvas()
            .navigationTitle(L10n.emergencySectionContacts)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        editor = ContactEditorTarget(id: "new", contact: nil)
                    } label: {
                        Label(L10n.emergencyContactsAdd, systemImage: "plus.circle")
                            .frame(minHeight: 44)
                    }
                    .accessibilityIdentifier("F15.contacts.add")
                }
            }
            .task(id: patientId) { await hub.load(patientId: patientId) }
            .sheet(item: $editor) { target in
                EmergencyContactEditSheet(contact: target.contact) { draft in
                    let saved = await hub.saveEmergencyContact(patientId: patientId,
                                                               id: target.contact?.id,
                                                               draft: draft)
                    if saved {
                        await autoAddMemberIfNeeded(draft)
                    }
                    return saved
                }
            }
            .alert(L10n.emergencyContactsDeleteTitle, isPresented: $confirmDelete) {
                Button(L10n.commonCancel, role: .cancel) { deleteTarget = nil }
                Button(L10n.commonDelete, role: .destructive) { deleteConfirmed() }
            } message: {
                Text(L10n.emergencyContactsDeleteHint)
            }
            .alert(L10n.emergencyContactsActionFailed, isPresented: $actionFailed) {
                Button(L10n.onboard_gotIt, role: .cancel) { }
            }
            .alert(L10n.emergencyContactsAutoMemberTitle,
                   isPresented: Binding(get: { autoAddHint != nil },
                                        set: { if !$0 { autoAddHint = nil } })) {
                Button(L10n.onboard_gotIt, role: .cancel) { autoAddHint = nil }
            } message: {
                Text(autoAddHint ?? "")
            }
        }
    }

    private func row(_ contact: EmergencyCardItem) -> some View {
        Button {
            editor = ContactEditorTarget(id: contact.id.uuidString, contact: contact)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "person.crop.circle.badge.exclamationmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color("brand-primary", bundle: .main))
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(contact.title)
                        .font(.subheadline.weight(.semibold))
                    Text(detail(contact))
                        .font(.caption)
                        .foregroundStyle(Color("text-secondary", bundle: .main))
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color("text-tertiary", bundle: .main))
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("F15.contacts.row")
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                deleteTarget = contact
                confirmDelete = true
            } label: {
                Label(L10n.commonDelete, systemImage: "trash")
            }
            .accessibilityIdentifier("F15.contacts.delete")
        }
    }

    private func detail(_ contact: EmergencyCardItem) -> String {
        let relation = contact.relation.map(L10n.memberRelationDisplayName) ?? ""
        let phone = contact.phone ?? ""
        if relation.isEmpty { return phone }
        return phone.isEmpty ? relation : "\(relation) · \(phone)"
    }

    /// 2026-10-24 业主：紧急联系人是家庭成员时，自动加入常用成员。
    /// 只对配偶/子女/父母/祖父母（含遗留细粒度关系）生效；同名成员已存在则跳过。
    /// 成员配额是独立闸门：名额已满时不静默创建，给可见提示。
    private func autoAddMemberIfNeeded(_ draft: EmergencyContactDraft) async {
        guard EmergencyContactMemberRules.shouldAutoAddMember(
            name: draft.name,
            relation: draft.relation,
            existingMemberNames: app.members.filter { $0.deletedAt == nil }.map(\.displayName)
        ) else { return }
        let relation = MemberRelation(tolerant: draft.relation)
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if PaywallRules.memberAdditionBlocked(currentCount: app.members.count,
                                              ownedProducts: entitlements.owned) {
            autoAddHint = L10n.emergencyContactsAutoMemberQuota
            return
        }
        if !(await app.addMember(name: name, relation: relation.coarse.rawValue,
                                 birthDate: nil)) {
            autoAddHint = L10n.emergencyContactsAutoMemberFailed
        }
    }

    private func deleteConfirmed() {
        guard let target = deleteTarget else { return }
        deleteTarget = nil
        Task {
            if !(await hub.deleteEmergencyContact(patientId: patientId, id: target.id)) {
                actionFailed = true
            }
        }
    }
}

/// `.sheet(item:)` 的呈现载荷：新增（contact == nil）与编辑共用同一表单。
private struct ContactEditorTarget: Identifiable {
    let id: String
    let contact: EmergencyCardItem?
}

/// 紧急联系人新增/编辑表单。校验复用 Domain `EmergencyContactDraft.isValid`
/// ——与注册流只有一套号码规则；保存失败保持本页并提示，不静默回退。
private struct EmergencyContactEditSheet: View {
    let contact: EmergencyCardItem?
    let onSave: @MainActor (EmergencyContactDraft) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var relation: String
    @State private var phone: String
    @State private var isSaving = false
    @State private var saveFailed = false

    init(contact: EmergencyCardItem?,
         onSave: @escaping @MainActor (EmergencyContactDraft) async -> Bool) {
        self.contact = contact
        self.onSave = onSave
        _name = State(initialValue: contact?.title ?? "")
        _relation = State(initialValue: contact?.relation ?? MemberRelation.partner.rawValue)
        _phone = State(initialValue: contact?.phone ?? "")
    }

    private var draft: EmergencyContactDraft {
        EmergencyContactDraft(name: name, relation: relation, phone: phone)
    }

    private var canSave: Bool { draft.isValid && !isSaving }

    /// 新建只给粗粒度关系；编辑存量细粒度值（父亲/母亲/儿子/女儿，来自
    /// 历史/备份导入）时补进选项，否则 Picker 无匹配标签、关系行显示空白。
    private var relationOptions: [String] {
        var options = MemberRelation.creatable.map(\.rawValue)
        if !relation.isEmpty, !options.contains(relation) { options.append(relation) }
        return options
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(L10n.onboardContactName, text: $name)
                        .accessibilityIdentifier("F15.contacts.edit.name")
                    Picker(L10n.onboardContactRelation, selection: $relation) {
                        ForEach(relationOptions, id: \.self) { raw in
                            Text(L10n.memberRelationDisplayName(raw)).tag(raw)
                        }
                    }
                    .accessibilityIdentifier("F15.contacts.edit.relation")
                    TextField(L10n.onboardContactPhone, text: $phone)
                        .keyboardType(.phonePad)
                        .accessibilityIdentifier("F15.contacts.edit.phone")
                } footer: {
                    Text(L10n.emergencyContactsPhoneHint)
                }
            }
            .navigationTitle(contact == nil ? L10n.emergencyContactsAdd : L10n.emergencyContactsEdit)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.commonCancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.commonSave) { save() }
                        .disabled(!canSave)
                        .accessibilityIdentifier("F15.contacts.edit.save")
                }
            }
            .alert(L10n.emergencyContactsActionFailed, isPresented: $saveFailed) {
                Button(L10n.onboard_gotIt, role: .cancel) { }
            }
        }
    }

    private func save() {
        guard canSave else { return }
        isSaving = true
        let payload = draft
        Task {
            let ok = await onSave(payload)
            isSaving = false
            if ok { dismiss() } else { saveFailed = true }
        }
    }
}
