import SwiftUI
import Domain
import Infrastructure

// MARK: - F23 过敏与不良反应记录（SP-50 · FR23.1-23.6）

/// 过敏列表：按成员/时间排序，严重度色条（轻灰/中琥珀/重红），行尾 C 级自述徽章；
/// 顶部 [记录过敏] 大按钮；空态引导。
struct AllergyListView: View {
    @Environment(AppState.self) private var app
    @Environment(ObservationStoreState.self) private var state
    @State private var showCreate = false
    /// FR23.6：删除前明示影响（急救卡/医生摘要）——此前滑扫即删、不可撤销
    @State private var pendingDelete: AllergyStore.AllergyRow?

    var body: some View {
        Group {
            if state.allergies.isEmpty {
                ContentUnavailableView(L10n.allergyEmpty, systemImage: "allergens",
                                       description: Text(L10n.allergyEmptyHint))
                    .accessibilityIdentifier("SP-50.allergy.empty")
            } else {
                List {
                    ForEach(state.allergies) { allergy in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                // FR23.2 严重度色条：轻=灰 / 中=琥珀 / 重=红
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(severityColor(allergy.severity))
                                    .frame(width: 4)
                                    .padding(.vertical, 2)
                                Text(allergy.substance).font(.subheadline)
                                Spacer()
                                // 评审修正 U2：手写徽章变体 → GradeBadge 唯一出口
                                GradeBadge(grade: "C")
                            }
                            Text("\(L10n.allergySeverity(allergy.severity)) · \(allergy.occurredAt.formatted(date: .abbreviated, time: .omitted))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .swipeActions {
                            Button(L10n.allergyDelete, role: .destructive) {
                                pendingDelete = allergy
                            }
                        }
                        .accessibilityIdentifier("SP-50.allergy.row.\(allergy.id.uuidString)")
                    }
                }
            }
        }
        .navigationTitle(L10n.allergyTitle)
        // presenting: 形式直接注入目标行——按钮动作不再依赖与对话框关闭
        // setter 的共享可变状态竞态（动作/置 nil 顺序无关）
        .confirmationDialog(L10n.allergyDeleteConfirmTitle, isPresented:
            Binding(get: { pendingDelete != nil },
                    set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible, presenting: pendingDelete) { target in
            Button(L10n.allergyDelete, role: .destructive) {
                Task { await state.deleteAllergy(id: target.id) }
            }
            Button(L10n.commonCancel, role: .cancel) { }
        } message: { _ in
            Text(L10n.allergyDeleteConfirmHint)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showCreate = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(L10n.allergyAdd)
                .accessibilityIdentifier("SP-50.allergy.add")
            }
        }
        .sheet(isPresented: $showCreate) {
            AllergyCreateView()
        }
        .task(id: app.currentPatientId) { await state.load(patientId: app.currentPatientId) }
    }

    private func severityColor(_ s: String) -> Color {
        // 第八轮全仓审查修复：严重度→颜色经 Domain 等级函数判定（单一
        // 事实源，展示词/规范值均可），语义色令牌替代魔法字符串 + 硬编码
        // .red/.orange/.gray（§3.1 深色模式语义色纪律）
        switch SevereReactionRules.severityLevel(of: s) {
        case 2: return Color("semantic-danger", bundle: .main)
        case 1: return Color("semantic-warning", bundle: .main)
        default: return Color.secondary
        }
    }
}

/// FR23.2 轻量三步记录：选过敏原类型 → 过敏原+反应标签 → 严重度与发生时间；
/// 其余字段折叠可选。保存前 MemberConfirmBar（FR3.3）。
/// FR23.3 重度/关键词命中 → 保存后立即急救引导卡（BR-012），不阻塞保存、可关闭。
struct AllergyCreateView: View {
    @Environment(AppState.self) private var app
    @Environment(ObservationStoreState.self) private var state
    @Environment(\.dismiss) private var dismiss

    @State private var step = 1
    @State private var allergenKind = SevereReactionRules.allergenKinds[0]
    @State private var substance = ""
    @State private var selectedTags: Set<String> = []
    @State private var customTag = ""
    @State private var severity = SevereReactionRules.severityValues[0]
    @State private var occurredAt = Date()
    @State private var note = ""
    @State private var showEmergencyCard = false
    @State private var saveFailed = false

    // FR23.1 选项来自 Domain 常量（数据词汇单一来源，视图不内联中文）
    private var kinds: [String] { SevereReactionRules.allergenKinds }
    private var reactionTags: [String] { SevereReactionRules.reactionTagOptions }

    var body: some View {
        NavigationStack {
            Form {
                if step == 1 {
                    Section(L10n.allergyStep1) {
                        Picker(L10n.allergyKind, selection: $allergenKind) {
                            // 第七轮修复：显示名经 L10n 词表（存储值仍是 Domain 词表原文）
                            ForEach(kinds, id: \.self) { Text(L10n.allergyKindName($0)) }
                        }
                    }
                } else if step == 2 {
                    Section(L10n.allergyStep2) {
                        TextField(L10n.allergySubstancePlaceholder, text: $substance)
                        // 反应标签 chips 多选 + 自由输入（显示名经 L10n 词表）
                        ForEach(reactionTags, id: \.self) { tag in
                            Button {
                                toggleTag(tag)
                            } label: {
                                HStack {
                                    Text(L10n.allergyTagName(tag))
                                    Spacer()
                                    if selectedTags.contains(tag) {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                        TextField(L10n.allergyCustomTag, text: $customTag)
                    }
                } else {
                    Section(L10n.allergyStep3) {
                        Picker(L10n.allergySeverityLabel, selection: $severity) {
                            ForEach(SevereReactionRules.severityValues, id: \.self) { s in
                                Text(L10n.allergySeverity(s)).tag(s)
                            }
                        }
                        .pickerStyle(.segmented)
                        DatePicker(L10n.allergyOccurredAt, selection: $occurredAt, in: ...Date())
                        TextField(L10n.allergyNote, text: $note, axis: .vertical)
                    }
                }
                // FR3.3 归属确认（保存前；FR23 边界：不得静默归入当前成员）
                Section {
                    MemberConfirmBar(
                        patientName: app.members.first(where: { $0.id == app.currentPatientId })?.displayName
                            ?? app.owner?.displayName ?? L10n.help_appName,
                        relation: L10n.member_relationSelf) { }
                }
            }
            .navigationTitle(L10n.allergyCreateTitle)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.commonCancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if step < 3 {
                        Button(L10n.allergyNext) { step += 1 }
                            .disabled(step == 2 && substance.trimmingCharacters(in: .whitespaces).isEmpty)
                    } else {
                        Button(L10n.reminder_save) { save() }
                            .disabled(substance.trimmingCharacters(in: .whitespaces).isEmpty)
                            .accessibilityIdentifier("SP-50.allergy.save")
                    }
                }
            }
            // 保存失败错误态（四态纪律：失败绝不静默呈现为已保存；
            // SaveFailedAlert 统一出口）
            .saveFailedAlert(title: L10n.allergySaveFailed,
                             hint: L10n.allergySaveFailedHint,
                             isPresented: $saveFailed)
            // FR23.3 重度/关键词命中：急救引导卡（BR-012），不阻塞保存、可关闭
            .alert(L10n.allergyEmergencyTitle, isPresented: $showEmergencyCard) {
                Button(L10n.ai_emergencyCall) {
                    // 审查修复：急救号码按语言区域（120/119/911），不硬编码 120
                    if let url = URL(string: "tel://\(L10n.emergencyNumber)") { UIApplication.shared.open(url) }
                }
                Button(L10n.allergyEmergencyGoHospital, role: .cancel) {
                    dismiss()
                }
            } message: {
                Text(L10n.allergyEmergencyBody)
            }
        }
    }

    private func toggleTag(_ tag: String) {
        if selectedTags.contains(tag) { selectedTags.remove(tag) } else { selectedTags.insert(tag) }
    }

    private func save() {
        var tags = Array(selectedTags)
        if !customTag.isEmpty { tags.append(customTag) }
        let severe = SevereReactionRules.triggersEmergencyCard(severity: severity,
                                                               reactionTags: tags, note: note)
        Task {
            // 写库失败保留表单并提示——此前 createAllergy 吞错后无条件
            // dismiss，失败呈现为「已保存」而记录丢失
            let saved = await state.createAllergy(patientId: app.currentPatientId, substance: substance,
                                                  severity: severity, tags: tags, note: note.isEmpty ? nil : note)
            guard saved else {
                saveFailed = true
                return
            }
            if severe {
                showEmergencyCard = true
            } else {
                dismiss()
            }
        }
    }
}
