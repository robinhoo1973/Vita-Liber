import SwiftUI
import Domain

/// ui-ux §5.8 就诊展示模式（FR8.6 · V3.72 点亮）：全屏临时解锁的时间线轮播——
/// 时间顺序的照片+描述+自述标记+用药背景，给医生看的「一眼版」。
/// 15 分钟剩余时间环 + [退出展示]；退出或超时自动重锁。
///
/// FR1.9 裁决后的会话令牌专用场景：进入需一次设备所有者认证，
/// 之后经 MediaUnlockSession（300s TTL）会话级解锁展示内容；
/// 敏感媒体逐容器认证（SensitiveMediaContainer）不受此影响。
struct DoctorShowcaseView: View {
    let patientId: UUID
    @Environment(AppState.self) private var app
    @Environment(ObservationStoreState.self) private var state
    @Environment(MediaUnlockSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    @State private var remaining: TimeInterval = 300
    @State private var authenticated = false
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            if authenticated {
                showcaseContent
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(L10n.showcaseTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // 剩余时间环（300s 会话倒计时；≤60s 转警告色）
            ToolbarItem(placement: .topBarLeading) {
                ZStack {
                    Circle()
                        .stroke(Color(.systemGray5), lineWidth: 3)
                    Circle()
                        .trim(from: 0, to: CGFloat(remaining / 300))
                        .stroke(remaining <= 60 ? Color("semantic-danger", bundle: .main)
                                                : Color("brand-primary", bundle: .main),
                                style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Text("\(Int(ceil(remaining / 60)))")
                        .font(.caption2).monospacedDigit()
                }
                .frame(width: 28, height: 28)
                .accessibilityIdentifier("SP-28.showcase.timer")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(L10n.showcaseExit) { exit() }
                    .accessibilityIdentifier("SP-28.showcase.exit")
            }
        }
        .onAppear {
            guard !authenticated else { return }
            Task {
                // 进入展示模式需一次设备所有者认证（门禁联动，§5.8）
                if await app.requestUnlock(reason: L10n.showcaseUnlockReason) {
                    authenticated = true
                    session.unlock()   // 会话级解锁（300s TTL 由会话令牌管理，FR1.9 专场景豁免）
                } else {
                    dismiss()
                }
            }
        }
        .onReceive(timer) { _ in
            guard authenticated else { return }
            if remaining <= 1 {
                exit()
            } else {
                remaining -= 1
            }
        }
        .onDisappear { exit() }
    }

    private var showcaseContent: some View {
        Group {
            if state.groups.isEmpty {
                ContentUnavailableView(L10n.showcaseEmpty, systemImage: "photo.on.rectangle.angled")
                    .accessibilityIdentifier("SP-28.showcase.empty")
            } else {
                TabView {
                    ForEach(state.groups) { group in
                        ShowcasePage(group: group)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .automatic))
            }
        }
    }

    private func exit() {
        session.relock()   // 退出/超时自动重锁（BR-007/008）
        dismiss()
    }
}

/// 单组观察展示页：时间 + 类型 + 描述 + 自述标记 + 敏感媒体条（会话级解锁态渲染）
private struct ShowcasePage: View {
    let group: ObservationGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let latest = group.latest {
                Text(latest.occurredAt.formatted(date: .long, time: .shortened))
                    .font(.headline)
                Text(L10n.observationKindName(group.kind))
                    .font(.subheadline).foregroundStyle(.secondary)
                if let description = latest.description, !description.isEmpty {
                    Text(description).font(.body)
                }
                if let mark = latest.selfMark {
                    Text("\(L10n.observationSelfMark)：\(mark)")
                        .font(.caption)
                        .foregroundStyle(Color("semantic-warning", bundle: .main))
                }
                if !latest.mediaAssetIds.isEmpty {
                    LockedMediaStrip(assetIds: latest.mediaAssetIds, memberId: latest.memberId)
                }
            }
            Spacer()
        }
        .padding(24)
    }
}
