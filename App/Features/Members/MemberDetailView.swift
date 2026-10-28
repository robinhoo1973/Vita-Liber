import SwiftUI
import Domain
import Infrastructure   // MemberDeletionService
import Perception

// MARK: - FR3.1 成员详情/编辑 + FR3.4 删除流 + FR3.5 重新归属

/// 成员详情：FR3.1 字段（血型/生日/备注）+ 删除流（影响清单 →
/// 姓名二次确认 → 计划「删除/停用归档」选择）+ 重新归属说明。
/// 2026-10-22 业主：身份证件号/医保号停止收集与显示。
///
/// 2026-09-26 结构修复（原子性时限轮）：此前 `member` + `current` 双副本 + 四个镜像
/// @State 字符串 + onAppear 整体回灌 + 保存时空串→nil 翻译三处锁步——回灌会静默
/// 丢弃未保存编辑（离开再返回即清空）。改为单一草稿 `current` + 逐字段自定义
/// Binding（空串↔nil 翻译收进 setter），删除 onAppear 回灌与保存翻译。
struct MemberDetailView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var current: PatientProfile
    @State private var showDeleteFlow = false
    @State private var impact: MemberDeletionService.Impact?
    @State private var confirmName = ""
    @State private var deleteChoice: MemberDeletionService.DeleteChoice = .archivePlans
    /// 保存失败可见性（审查修复：updateMember 返回 false 被丢弃——写库
    /// 失败只留日志，用户以为已保存、重启后字段静默回退）
    @State private var saveFailed = false
    /// 审查修复：删除失败此前静默（见 deleteFlow 回调）
    @State private var deleteFailed = false
    /// 生日补录编辑器（2026-09-26 审查修复：非法存量值提示「重新填写」但本页没有
    /// 生日编辑入口——提示不可执行；与 MemberCreateSheet 同构：Toggle + DatePicker +
    /// 显式选择才落库，未经选择不写「今天」）。仅合法存量值作为初始值。
    @State private var hasBirthDate: Bool
    @State private var birthDate: Date
    @State private var birthDatePicked = false
    /// 用户是否主动动过生日控件——未经显式交互的保存绝不改写存量值
    /// （初始 Toggle 关着，只改血型就保存不得顺手清掉存量生日，BR-002）。
    @State private var birthDateEdited = false
    // FR3.1 P1（2026-10-28 补录批）：血型受控控件（ABO+Rh 网格）+ 身高/体重。
    @State private var bloodSelection: String
    @State private var bloodNote: String
    @State private var heightText: String
    @State private var weightText: String

    init(member: PatientProfile) {
        _current = State(initialValue: member)
        let stored = member.birthDate ?? ""
        _hasBirthDate = State(initialValue: MemberProfileCompleteness.isValidBirthDate(stored))
        _birthDate = State(initialValue: MemberProfileCompleteness.parsedBirthDate(stored) ?? Date())
        // 存量血型映射（BR-002 不改写）：ABO±Rh 可解析 → 网格选中；unknown 哨兵 →
        // 不知道；其余非空自由文本（历史输入/特殊说明）→ special + 注记原文保真。
        let bt = member.bloodType ?? ""
        var selection = bt
        var note = ""
        if !bt.isEmpty,
           bt != "special",
           BloodTypePushGrid.aboValue(from: bt) == nil,
           bt != BloodTypePushGrid.unknownValue,
           bt != L10n.bloodTypeUnknown {
            selection = "special"
            note = bt
        }
        _bloodSelection = State(initialValue: selection)
        _bloodNote = State(initialValue: note)
        _heightText = State(initialValue: Self.metricText(member.heightCm))
        _weightText = State(initialValue: Self.metricText(member.weightKg))
    }

    /// 空串↔nil 翻译收进 setter（单一草稿 `current`，无镜像 @State 字符串）。
    private func optionalField(_ keyPath: WritableKeyPath<PatientProfile, String?>) -> Binding<String> {
        Binding(
            get: { current[keyPath: keyPath] ?? "" },
            set: { current[keyPath: keyPath] = $0.isEmpty ? nil : $0 }
        )
    }

    // MARK: - FR3.1 P1 血型/身高/体重解析（2026-10-28 补录批）

    /// 血型最终值：未选→nil；special→注记（空白→nil）；其余=网格选中值。
    private var resolvedBloodType: String? {
        if bloodSelection.isEmpty { return nil }
        if bloodSelection == "special" {
            let note = bloodNote.trimmingCharacters(in: .whitespacesAndNewlines)
            return note.isEmpty ? nil : note
        }
        return bloodSelection
    }

    /// 非空且不可解析为正数 → 输入无效（空=未填写，合法）。
    private var bodyMetricInvalidPreview: Bool {
        (!heightText.isEmpty && Self.parseMetric(heightText) == nil)
            || (!weightText.isEmpty && Self.parseMetric(weightText) == nil)
    }

    private var parsedHeight: Double? { Self.parseMetric(heightText) }
    private var parsedWeight: Double? { Self.parseMetric(weightText) }

    static func metricText(_ value: Double?) -> String {
        guard let value else { return "" }
        return value.rounded() == value ? String(Int(value)) : String(value)
    }

    /// 接受逗号小数（地区键盘习惯）；须正数。
    static func parseMetric(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: ".")
        guard !trimmed.isEmpty, let value = Double(trimmed), value > 0 else { return nil }
        return value
    }

    var body: some View {
        WithPerceptionTracking {
            Form {
                Section(L10n.memberDetailBasic) {
                    LabeledContent(L10n.member_namePlaceholder, value: current.displayName)
                    LabeledContent(L10n.member_relation,
                                   value: L10n.memberRelationDisplayName(current.relation))
                    if let birth = current.birthDate {
                        LabeledContent(L10n.member_birthDatePlaceholder, value: birth)
                        // 业主裁决 3（2026-09-26）：存量非法值显示原样（不做迁移，BR-002），
                        // 但不计完整度，并提示补录。
                        if !MemberProfileCompleteness.isValidBirthDate(birth) {
                            Text(L10n.member_birthDateInvalidHint)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                // FR3.1 字段补全（血型受控控件/身高/体重/备注）+ 生日补录；证件号/医保号已移除。
                Section(L10n.memberDetailMore) {
                    Toggle(L10n.member_birthDateLabel, isOn: $hasBirthDate)
                        .accessibilityIdentifier("FR3.1.member.birthDateToggle")
                        .onChangeCompat(of: hasBirthDate) { _, _ in birthDateEdited = true }   // 零参闭包 onChange 为 iOS 17 专用形态，走 Compat 垫片
                    if hasBirthDate {
                        DatePicker(L10n.member_birthDateLabel, selection: $birthDate,
                                   in: MemberProfileCompleteness.birthDateEarliest...Date(),
                                   displayedComponents: .date)
                            .accessibilityIdentifier("FR3.1.member.birthDate")
                            .onChangeCompat(of: birthDate) { _, _ in birthDatePicked = true }   // 零参闭包 onChange 为 iOS 17 专用形态，走 Compat 垫片
                    }
                    BloodTypePushGrid(selection: $bloodSelection)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("FR3.1.member.bloodType")
                    if bloodSelection == "special" {
                        TextField(L10n.onboardBloodNotePlaceholder, text: $bloodNote)
                            .accessibilityIdentifier("FR3.1.member.bloodNote")
                    }
                    HStack(spacing: 12) {
                        TextField(L10n.memberHeight, text: $heightText)
                            .keyboardType(.decimalPad)
                            .accessibilityIdentifier("FR3.1.member.height")
                        TextField(L10n.memberWeight, text: $weightText)
                            .keyboardType(.decimalPad)
                            .accessibilityIdentifier("FR3.1.member.weight")
                    }
                    if bodyMetricInvalidPreview {
                        // 非数字输入可见提示（空=未填写合法，不提示）。
                        Text(L10n.memberBodyMetricInvalidHint)
                            .font(.caption)
                            .foregroundStyle(Color("semantic-warning", bundle: .main))
                            .accessibilityIdentifier("FR3.1.member.bodyMetricInvalidHint")
                    }
                    TextField(L10n.memberNote, text: optionalField(\.note), axis: .vertical)
                    Button(L10n.reminder_save) {
                        guard !bodyMetricInvalidPreview else { return }   // 按钮已禁用，双保险
                        current.bloodType = resolvedBloodType
                        current.heightCm = parsedHeight
                        current.weightKg = parsedWeight
                        if birthDateEdited || birthDatePicked {
                            if !hasBirthDate {
                                current.birthDate = nil
                            } else if birthDatePicked {
                                current.birthDate = MemberProfileCompleteness.birthDateString(from: birthDate)
                            }
                        }
                        current.updatedAt = Date().timeIntervalSince1970
                        Task {
                            // 审查修复：写库结果必须可见——失败只记日志时用户
                            // 相信已保存、数据下次启动静默回退
                            if !(await app.updateMember(current)) {
                                saveFailed = true
                            }
                        }
                    }
                    .disabled(bodyMetricInvalidPreview)
                    .accessibilityIdentifier("FR3.1.member.update")
                }
                // 删除流（FR3.4：影响清单 → 姓名确认 → 计划处置选择）
                // 审查修复：删除保护闸门改按 ID 判定本人——原以显示串
                // 「本人」比较，zh-Hant/未来多语言下闸门失效
                // 审查修复第二轮：owner 未装载（启动加载失败/降级容器）时
                // `member.id != app.owner?.selfPatientId` 对全部成员成立（含本人）——
                // 本人档案可被删，BR-001 锚点随 `owner?.selfPatientId ?? patientId`
                // 回落到已软删成员。无法确立「谁是本人」时一律隐藏删除入口
                // （纵深防线在 MemberDeletionService 服务端二次拒绝）。
                Section {
                    if let selfId = app.owner?.selfPatientId {
                        if current.id != selfId {
                            Button(L10n.memberDelete, role: .destructive) {
                                Task {
                                    impact = await app.memberDeletionImpact(patientId: current.id)
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
            }
            .navigationTitle(current.displayName)
            .sheet(isPresented: $showDeleteFlow) {
                DeleteMemberFlowSheet(member: current, impact: impact ?? MemberDeletionService.Impact(),
                                      choice: $deleteChoice, confirmName: $confirmName) {
                    Task {
                        let ok = await app.deleteMember(patientId: current.id, choice: deleteChoice)
                        if ok {
                            showDeleteFlow = false
                            dismiss()
                        } else {
                            // 审查修复：删除失败此前静默——sheet 原地保留、无任何反馈，
                            // 按钮点了像没点（用户会重复点击或误以为已删除）。不可逆动作
                            // 的失败必须可见。
                            deleteFailed = true
                        }
                    }
                }
            }
            .alert(L10n.memberDeleteFailed, isPresented: $deleteFailed) {
                Button(L10n.onboard_gotIt, role: .cancel) { }
            }
            .alert(L10n.memberUpdateFailed, isPresented: $saveFailed) {
                Button(L10n.onboard_gotIt, role: .cancel) { }
            } message: {
                Text(L10n.memberUpdateFailedHint)
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
        WithPerceptionTracking {
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
}
