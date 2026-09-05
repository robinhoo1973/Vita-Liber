import SwiftUI
import PhotosUI
import os
import Domain
import Protocols

/// F12 AI 助手（SP 系列 M1c 切片）：本地检索式问答——七段结构/拒识卡/急救卡。
/// 引用完整性由类型保证（无引用的回答不存在）；E 级徽章标识 AI 解释。
/// FR12.11 图片输入：拍照/相册 → Vision 识别 → **D 级待确认** → 确认后作为
/// 问题提交；纯影像无文字 → 「未识别到文字」+ 手输替代（BR-003）。
struct AssistantView: View {
    @Environment(AppState.self) private var app
    @Environment(AssistantStore.self) private var assistant
    @State private var draft = ""
    @State private var pickerItem: PhotosPickerItem?
    @State private var imageConfirmSet: OcrConfirmationSet?
    @State private var imageNotice: String?

    var body: some View {
        VStack(spacing: 0) {
            // FR20.3 L3 常驻微文案：AI 输入栏上方横幅
            L3DisclosureBanner(disclosure: DisclosureRegistry.l3Disclosures[0])
            ScrollView {
                LazyVStack(spacing: 12) {
                    if let imageNotice {
                        Label(imageNotice, systemImage: "info.circle")
                            .font(.caption).foregroundStyle(.secondary)
                            .accessibilityIdentifier("FR12.11.noText")
                    }
                    ForEach(assistant.messages) { message in
                        MessageBubble(message: message)
                    }
                    if assistant.busy {
                        ProgressView("正在检索你的资料…")
                            .padding()
                    }
                }
                .padding(16)
            }
            HStack(spacing: 8) {
                // FR12.11：拍照/相册发起「帮我看看这张报告」
                PhotosPicker(selection: $pickerItem, matching: .images) {
                    VLIcon.photo.resizable().frame(width: 22, height: 22)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("添加图片或报告照片")
                .accessibilityIdentifier("FR12.11.pickImage")
                TextField("问一个与你资料相关的问题", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...3)
                    .accessibilityIdentifier("SP-21.ai.input")
                Button {
                    let q = draft
                    draft = ""
                    Task {
                        // 注意：基础问答永久免费（comercial §2.1/§2.4——免费档每月 20 次），
                        // 本入口不得接入权益仓/付费墙（L0 [4/9] 红线模块断言）。
                        // 「高级 AI 用量」是 D3 若采纳的增量能力，其弹墙时机接线
                        // 归属 D3 决策后的 Pro 增强入口，不在基础问答上触发。
                        await assistant.ask(q, scopePatientIds: [currentPatientId])
                    }
                } label: {
                    VLIcon.send.resizable().frame(width: 20, height: 20)
                        .frame(width: 44, height: 44)
                }
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || assistant.busy)
                .accessibilityLabel("发送问题")
                .accessibilityIdentifier("SP-21.ai.send")
            }
            .padding(12)
        }
        .navigationTitle(L10n.navAI)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // FR12.10 会话历史入口（SP-51）
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(value: AppRoute.assistantHistory) {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .accessibilityIdentifier("SP-51.history.entry")
            }
        }
        .sceneDisclosure(scene: "ai_assistant")
        .onChange(of: pickerItem) { _, newItem in
            guard let newItem else { return }
            Task { await handlePickedImage(newItem) }
        }
        .sheet(item: $imageConfirmSet) { set in
            ImageConfirmSheet(
                set: set,
                onConfirm: { confirmed in
                    let text = confirmed.confirmedFields.first?.value ?? ""
                    imageConfirmSet = nil
                    draft = text
                },
                onCancel: { imageConfirmSet = nil })
            .presentationDetents([.medium])
        }
    }

    private func handlePickedImage(_ item: PhotosPickerItem) async {
        imageNotice = nil
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                imageNotice = "无法读取这张图片"
                return
            }
            let recognition = try await app.imageRecognizer.recognize(data)
            if recognition.isEmpty {
                imageNotice = ImageInputRules.noTextMessage
                return
            }
            // BR-003：识别文本一律 D 级待确认——确认前不得提交为问题
            let fields = ImageInputRules.draftFields(from: recognition)
            imageConfirmSet = VoiceInputTemplate.confirmationSet(drafts: [
                FieldDraft(key: "image_text", value: recognition.text,
                           confidence: recognition.confidence)
            ])
            _ = fields   // VoiceInputTemplate 重建（待确认态恒成立）；fields 仅作语义对照
        } catch {
            Logger(subsystem: "com.vitaliber", category: "assistant")
                .error("图片识别失败: \(error)")
            imageNotice = ImageInputRules.noTextMessage
        }
    }

    private var currentPatientId: UUID { app.currentPatientId }
}

/// FR12.11 图片识别确认卡：未确认不得提交（BR-003）。
struct ImageConfirmSheet: View {
    let set: OcrConfirmationSet
    var onConfirm: (OcrConfirmationSet) -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.ai_confirmImageText).font(.headline)
            ForEach(set.fields) { field in
                ScrollView {
                    Text(field.value)
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 200)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color("bg-grouped", bundle: .main)))
                .overlay(RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color("grade-d", bundle: .main),
                                  style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                .accessibilityIdentifier("FR12.11.confirm.text")
            }
            Label("图片识别结果未经你确认，不会作为事实提交", systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(Color("grade-d", bundle: .main))
                .accessibilityIdentifier("FR12.11.unconfirmed")
            HStack(spacing: 12) {
                Button("取消", action: onCancel).frame(minHeight: 44)
                Spacer()
                Button("确认并填入问题") {
                    var confirmed = set
                    for i in confirmed.fields.indices { _ = confirmed.fields[i].confirm() }
                    onConfirm(confirmed)
                }
                .buttonStyle(.borderedProminent)
                .frame(minHeight: 44)
                .accessibilityIdentifier("FR12.11.confirm")
            }
        }
        .padding(20)
    }
}

/// 消息气泡：结构化渲染七段/拒识/急救卡（含 E 级徽章与引用列表）
struct MessageBubble: View {
    let message: AssistantStore.Message

    var body: some View {
        HStack {
            if message.role == "user" { Spacer(minLength: 48) }
            VStack(alignment: message.role == "user" ? .trailing : .leading, spacing: 8) {
                if let answer = message.answer {
                    AnswerBodyView(answer: answer)
                } else {
                    Text(message.text)
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 16)
                            .fill(message.role == "user" ? Color("brand-primary", bundle: .main).opacity(0.15) : Color("bg-grouped", bundle: .main)))
                }
            }
            if message.role == "assistant" { Spacer(minLength: 48) }
        }
        .accessibilityElement(children: .combine)
    }
}

struct AnswerBodyView: View {
    let answer: AIAnswer

    var body: some View {
        switch answer.body {
        case .emergencyCard:
            VStack(alignment: .leading, spacing: 12) {
                Label(L10n.ai_emergencyTitle, systemImage: "exclamationmark.octagon.fill")
                    .font(.headline)
                    .foregroundStyle(Color("semantic-danger", bundle: .main))
                Text(L10n.ai_emergencyAction)
                Button {
                    // 审查修复：急救号码按语言区域（120/119/911），不硬编码 120
                    if let url = URL(string: "tel://\(L10n.emergencyNumber)") { UIApplication.shared.open(url) }
                } label: {
                    Label(L10n.ai_emergencyCall, systemImage: "phone.fill")
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color("semantic-danger", bundle: .main))
                .accessibilityIdentifier("SP-21.ai.call120")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color("semantic-danger", bundle: .main).opacity(0.1)))
            .accessibilityIdentifier("SP-21.ai.emergency")
        case .refused(let r):
            VStack(alignment: .leading, spacing: 8) {
                Label(r.reason == .highRiskTopic ? "无法回答这个问题" : "资料不足",
                      systemImage: "info.circle")
                    .font(.headline)
                Text(AssistantStore.refusalDetail(r.reason)).font(.body)
                HStack(spacing: 8) {
                    ForEach(r.actions, id: \.rawValue) { action in
                        // 审查修复：原空动作死按钮——接真实路由
                        // （补充资料→成员管理；咨询医生或药师→帮助与诊断）
                        NavigationLink(value: action == .addRecords
                                       ? AppRoute.memberList : AppRoute.helpCenter) {
                            Text(action == .addRecords
                                 ? L10n.assistant_addRecords : L10n.assistant_consultDoctor)
                                .frame(minHeight: 44)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color("bg-grouped", bundle: .main)))
            .accessibilityIdentifier("SP-21.ai.refused")
        case .composed(let p):
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("E").font(.caption.bold())
                        .padding(4)
                        .background(Circle().fill(Color("grade-e", bundle: .main).opacity(0.2)))
                        .foregroundStyle(Color("grade-e", bundle: .main))
                    Text(L10n.ai_aiBadge).font(.caption).foregroundStyle(.secondary)
                }
                Text(p.conclusion).font(.body)
                if !p.excerpts.isEmpty {
                    Text(L10n.ai_citations).font(.caption.bold())
                    ForEach(p.excerpts, id: \.self) { e in
                        Text(e).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if !p.terminology.isEmpty {
                    ForEach(p.terminology, id: \.self) { t in
                        Text(t).font(.footnote)
                    }
                }
                if !p.sources.isEmpty {
                    Text(L10n.ai_source).font(.caption.bold())
                    ForEach(p.sources, id: \.self) { s in
                        Text(s).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if !p.uncertainties.isEmpty {
                    ForEach(p.uncertainties, id: \.self) { u in
                        Text(L10n.aiUncertain(u)).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if !p.questionsForDoctor.isEmpty {
                    ForEach(p.questionsForDoctor, id: \.self) { q in
                        Text(L10n.aiAskDoctor(q)).font(.caption2)
                            .foregroundStyle(Color("brand-primary", bundle: .main))
                    }
                }
                Text(p.scopeNote).font(.caption2).foregroundStyle(.secondary)
                Text(p.disclaimer).font(.caption2).foregroundStyle(.secondary)
                ForEach(p.citations, id: \.refID) { c in
                    HStack(spacing: 4) {
                        Image(systemName: "doc.text")
                        Text(c.snippet).font(.caption2).lineLimit(1)
                    }
                    .foregroundStyle(Color("brand-primary", bundle: .main))
                    .accessibilityIdentifier("SP-21.ai.citation")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color("bg-grouped", bundle: .main)))
            .accessibilityIdentifier("SP-21.ai.answer")
        }
        // FR12.8 反馈四键：有用/无用（16pt 图标）+ 长按菜单（引用错误/疑似危险）
        AIFeedbackRow()
    }
}

/// FR12.8 反馈四键（本地留存，P1 上报）：有用/无用 + 长按菜单（引用错误/疑似危险）
private struct AIFeedbackRow: View {
    @Environment(AssistantStore.self) private var assistant

    var body: some View {
        HStack(spacing: 16) {
            Spacer()
            Button {
                assistant.recordFeedback(kind: "useful")
            } label: {
                Image(systemName: "hand.thumbsup")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel(L10n.aiFeedbackUseful)
            .accessibilityIdentifier("SP-21.ai.feedback.useful")
            Button {
                assistant.recordFeedback(kind: "useless")
            } label: {
                Image(systemName: "hand.thumbsdown")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel(L10n.aiFeedbackUseless)
            .accessibilityIdentifier("SP-21.ai.feedback.useless")
            Menu {
                Button(L10n.aiFeedbackCitationError) {
                    assistant.recordFeedback(kind: "citation_error")
                }
                Button(L10n.aiFeedbackDanger) {
                    assistant.recordFeedback(kind: "suspected_danger")
                }
            } label: {
                Image(systemName: "exclamationmark.bubble")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel(L10n.aiFeedbackMore)
            .accessibilityIdentifier("SP-21.ai.feedback.more")
        }
        .padding(.top, 4)
    }
}
