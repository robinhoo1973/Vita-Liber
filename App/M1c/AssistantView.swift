import SwiftUI
import Domain

/// F12 AI 助手（SP 系列 M1c 切片）：本地检索式问答——七段结构/拒识卡/急救卡。
/// 引用完整性由类型保证（无引用的回答不存在）；E 级徽章标识 AI 解释。
struct AssistantView: View {
    @Environment(AppState.self) private var app
    @Environment(AssistantStore.self) private var assistant
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 12) {
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
                TextField("问一个与你资料相关的问题", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...3)
                    .accessibilityIdentifier("SP-21.ai.input")
                Button {
                    let q = draft
                    draft = ""
                    Task {
                        await assistant.ask(q, scopePatientIds: [currentPatientId])
                    }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .frame(width: 44, height: 44)
                }
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || assistant.busy)
                .accessibilityLabel("发送问题")
                .accessibilityIdentifier("SP-21.ai.send")
            }
            .padding(12)
        }
        .navigationTitle("AI 助手")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var currentPatientId: UUID { app.owner?.selfPatientId ?? app.owner?.id ?? UUID() }
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
                Label("疑似紧急情况", systemImage: "exclamationmark.octagon.fill")
                    .font(.headline)
                    .foregroundStyle(Color("semantic-danger", bundle: .main))
                Text("请立即拨打 120 或前往最近的医院急诊。")
                Button {
                    if let url = URL(string: "tel://120") { UIApplication.shared.open(url) }
                } label: {
                    Label("拨打 120", systemImage: "phone.fill")
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
                Text(r.detail).font(.body)
                HStack(spacing: 8) {
                    ForEach(r.actions, id: \.rawValue) { action in
                        Button {
                            // 动作跳转：去补充资料 / 咨询医生药师（占位路由，M1.5 接 AppRoute）
                        } label: {
                            Text(action == .addRecords ? "去补充资料" : "咨询医生或药师")
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
                    Text("AI 解释（基于你的资料）").font(.caption).foregroundStyle(.secondary)
                }
                Text(p.conclusion).font(.body)
                if !p.excerpts.isEmpty {
                    Text("相关原文：").font(.caption.bold())
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
                    Text("来源：").font(.caption.bold())
                    ForEach(p.sources, id: \.self) { s in
                        Text(s).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if !p.uncertainties.isEmpty {
                    ForEach(p.uncertainties, id: \.self) { u in
                        Text("不确定：\(u)").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if !p.questionsForDoctor.isEmpty {
                    ForEach(p.questionsForDoctor, id: \.self) { q in
                        Text("建议问医生：\(q)").font(.caption2)
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
    }
}
