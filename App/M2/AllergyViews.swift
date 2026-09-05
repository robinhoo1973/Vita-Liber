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
                                Text(L10n.allergySelfReportBadge)
                                    .font(.caption2)
                                    .foregroundStyle(Color("grade-c", bundle: .main))
                            }
                            Text("\(L10n.allergySeverity(allergy.severity)) · \(allergy.occurredAt.formatted(date: .abbreviated, time: .omitted))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .swipeActions {
                            Button(L10n.allergyDelete, role: .destructive) {
                                Task { await state.deleteAllergy(id: allergy.id) }
                            }
                        }
                        .accessibilityIdentifier("SP-50.allergy.row.\(allergy.id.uuidString)")
                    }
                }
            }
        }
        .navigationTitle(L10n.allergyTitle)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showCreate = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityIdentifier("SP-50.allergy.add")
            }
        }
        .sheet(isPresented: $showCreate) {
            AllergyCreateView()
        }
        .task(id: app.currentPatientId) { await state.load(patientId: app.currentPatientId) }
    }

    private func severityColor(_ s: String) -> Color {
        // 严重度原值来自 Domain 常量（视图不内联中文）
        if s == SevereReactionRules.severityValues[2] || s == "severe" { return .red }
        if s == SevereReactionRules.severityValues[1] || s == "moderate" { return .orange }
        return .gray
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

    // FR23.1 选项来自 Domain 常量（数据词汇单一来源，视图不内联中文）
    private var kinds: [String] { SevereReactionRules.allergenKinds }
    private var reactionTags: [String] { SevereReactionRules.reactionTagOptions }

    var body: some View {
        NavigationStack {
            Form {
                if step == 1 {
                    Section(L10n.allergyStep1) {
                        Picker(L10n.allergyKind, selection: $allergenKind) {
                            ForEach(kinds, id: \.self) { Text($0) }
                        }
                    }
                } else if step == 2 {
                    Section(L10n.allergyStep2) {
                        TextField(L10n.allergySubstancePlaceholder, text: $substance)
                        // 反应标签 chips 多选 + 自由输入
                        ForEach(reactionTags, id: \.self) { tag in
                            Button {
                                toggleTag(tag)
                            } label: {
                                HStack {
                                    Text(tag)
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
            await state.createAllergy(patientId: app.currentPatientId, substance: substance,
                                      severity: severity, tags: tags, note: note.isEmpty ? nil : note)
            if severe {
                showEmergencyCard = true
            } else {
                dismiss()
            }
        }
    }
}
