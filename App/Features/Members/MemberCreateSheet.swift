import SwiftUI
import Domain
import Perception

struct MemberCreateSheet: View {
    var voiceMode: Bool = false
    let onCreate: (String, String, String?) -> Void

    init(voiceMode: Bool = false, onCreate: @escaping (String, String, String?) -> Void) {
        self.voiceMode = voiceMode
        self.onCreate = onCreate
    }
    @State private var name = ""
    @State private var relation: MemberRelation = .child
    // 业主裁决 3（2026-09-26）：生日从自由文本改为结构控件（DatePicker + 可选开关），
    // 从交互上消灭非法值（业界标准做法，Apple HIG/主流医疗 app 同款）；落库仍走
    // Domain 规范格式 yyyy-MM-dd（MemberProfileCompleteness.birthDateString）。
    @State private var hasBirthDate = false
    @State private var birthDate = Date()
    /// 审查修复（2026-09-26）：Toggle 打开即显示「今天」且未触碰 DatePicker 直接
    /// 保存会把「今天」当生日落库（用户只是想稍后再填）——未经显式选择的日期
    /// 一律按未填写处理，绝不落库未经用户确认的日期（BR-002 原始数据原则）。
    @State private var birthDatePicked = false
    /// 一句话语音草稿的可见反馈（关系/生日没听清时必须明说，不静默吞掉）。
    @State private var voiceHint: String?

    /// 关系显示名本地化映射（存储值仍为中文原始值，仅显示时本地化；
    /// 单一出口 = L10n.memberRelationDisplayName）
    private func localizedRelation(_ raw: String) -> String {
        L10n.memberRelationDisplayName(raw)
    }

    /// 一句话语音 → 姓名/关系/生日三个表单状态。只应用解析成功的字段；
    /// 全空才提示重说，部分命中时让用户看到已填项并补齐其余项。
    private func applyVoiceDraft(_ transcript: String) {
        let draft = VoiceProfileRules.memberDraft(from: transcript)
        if let parsed = draft.name { name = parsed }
        if let parsed = draft.relation { relation = parsed }
        if let raw = draft.birthDate,
           let parsed = MemberProfileCompleteness.parsedBirthDate(raw) {
            birthDate = parsed
            hasBirthDate = true
            birthDatePicked = true
        }
        voiceHint = draft.name == nil && draft.relation == nil && draft.birthDate == nil
            ? L10n.member_voiceUnrecognized : nil
    }

    var body: some View {
        WithPerceptionTracking {
            NavigationStack {
                Form {
                    TextField(L10n.member_namePlaceholder, text: $name)
                        .accessibilityIdentifier("FR3.7.create.name")
                    if voiceMode {
                        // 一句话草稿：关系、姓名、生日由 Domain 纯函数确定性拆分；
                        // 表单控件仍可逐项修改，语音不直接落库。
                        Text(L10n.member_voiceHint)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        VoiceDictationButton { transcript, _ in
                            applyVoiceDraft(transcript)
                        }
                        .accessibilityIdentifier("FR3.7.create.nameVoice")
                        if let voiceHint {
                            Text(voiceHint)
                                .font(.caption)
                                .foregroundStyle(Color("semantic-warning", bundle: .main))
                                .accessibilityIdentifier("FR3.7.create.voiceHint")
                        }
                    }
                    Picker(L10n.member_relation, selection: $relation) {
                        // 可选集单点 = Domain MemberRelation.creatable（结构轮 2026-09-15）。
                        ForEach(MemberRelation.creatable, id: \.self) { rel in
                            Text(localizedRelation(rel.rawValue)).tag(rel)
                        }
                    }
                    Toggle(L10n.member_birthDateLabel, isOn: $hasBirthDate)
                        .accessibilityIdentifier("FR3.7.create.birthDateToggle")
                    if hasBirthDate {
                        DatePicker(L10n.member_birthDateLabel, selection: $birthDate,
                                   in: MemberProfileCompleteness.birthDateEarliest...Date(),
                                   displayedComponents: .date)
                            .accessibilityIdentifier("FR3.7.create.birthDate")
                            .onChangeCompat(of: birthDate) { _, _ in birthDatePicked = true }   // 零参闭包 onChange 为 iOS 17 专用形态，走 Compat 垫片
                    }
                }
                .navigationTitle(L10n.member_add)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L10n.member_save) {
                            onCreate(name, relation.rawValue,
                                     hasBirthDate && birthDatePicked ? MemberProfileCompleteness.birthDateString(from: birthDate) : nil)
                        }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityIdentifier("FR3.7.create.save")
                    }
                }
            }
        }
    }
}
