import SwiftUI
import Domain

/// 敏感媒体保护容器（BR-007/BR-008 · FR8.4 · tech-spec §5.10）。
///
/// 一处实现，所有敏感媒体界面复用：默认锁定 → 显式门禁解锁 → 无操作自动重锁 →
/// 退后台立即重锁。策略常量与判定全在 Domain `MediaUnlockPolicy`，本容器只负责
/// SwiftUI 侧的机制（计时任务、活跃手势、scenePhase、PIN sheet）。
///
/// 为什么要有这层：BR-007/008 对每个敏感媒体面（观察记录、文档查看器、帮助卡照片、
/// §5.38 医生展示模式）要求同一套重锁语义。逐屏各写一遍必然漂移——历史上已经
/// 从「解锁后固定 30s」漂到「30s 无操作」，只改了其中一处。
///
/// 说明（留待 §5.10 完整实现）：tech-spec 描述的是 MainActor 单例
/// `MediaUnlockSession`，即一次门禁验证换取**会话级**解锁令牌（连看多个敏感文件
/// 不必逐个验证），并由 §5.38 `DoctorShowcaseSession` 复用。本容器先把「策略 +
/// 机制」收敛为单一出口；令牌语义（跨视图共享解锁状态）待展示模式落地时补齐，
/// 届时把 `revealed` 换成对会话令牌的查询即可，各调用点无需改动。
struct SensitiveMediaContainer<Content: View, Placeholder: View>: View {
    @Environment(AppState.self) private var app
    @Environment(\.scenePhase) private var scenePhase

    /// 解锁后呈现的真实内容
    private let content: (Bool) -> Content
    /// 锁定态占位（绝不含可识别内容）
    private let placeholder: (Bool) -> Placeholder

    @State private var revealed = false
    @State private var showPinSheet = false
    @State private var showSetupSheet = false
    @State private var lastInteraction: Date?

    init(@ViewBuilder placeholder: @escaping (Bool) -> Placeholder,
         @ViewBuilder content: @escaping (Bool) -> Content) {
        self.placeholder = placeholder
        self.content = content
    }

    var body: some View {
        ZStack {
            placeholder(revealed)
            if revealed { content(revealed) }
        }
        .onTapGesture {
            guard !revealed else { return }
            // BR-009：未设置应用 PIN 时敏感媒体仍必须锁定——引导设置 PIN，
            // 禁止退化为单击直看；已有 PIN 则走验证。
            if app.isPinProtected {
                showPinSheet = true
            } else {
                showSetupSheet = true
            }
        }
        .sheet(isPresented: $showPinSheet) {
            PinEntryView(mode: .verify)
                .presentationDetents([.height(420)])
        }
        .sheet(isPresented: $showSetupSheet) {
            VStack(spacing: 12) {
                Text(L10n.sensitiveSetupHint)
                    .font(.footnote).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                PinEntryView(mode: .setup)
            }
            .padding(.top, 8)
            .presentationDetents([.height(420)])
        }
        .onChange(of: app.pinHash) { _, value in
            // BR-009 引导路径：设置完成（pinHash 从 nil 变为非 nil）即视为解锁
            guard showSetupSheet, value != nil else { return }
            showSetupSheet = false
            revealed = true
            lastInteraction = Date()
        }
        .onChange(of: app.lastVerifiedAt) { _, value in
            // showPinSheet 闸门：任意门禁验证（例如冷启动解锁）不得顺带解锁敏感内容，
            // 只认「本容器发起的那次验证」（BR-007）
            guard showPinSheet, value != nil else { return }
            showPinSheet = false
            revealed = true
            lastInteraction = Date()
        }
        // 无操作重锁：.task(id:) 随视图销毁自动取消、随交互刷新自动重启，
        // 解锁期间零轮询、锁定期间零开销
        .task(id: lastInteraction) {
            guard revealed else { return }
            do { try await Task.sleep(nanoseconds: UInt64(MediaUnlockPolicy.idleTTL * 1_000_000_000)) }
            catch { return }   // 取消 = 交互刷新或视图销毁，由新任务接管
            if revealed { revealed = false }
        }
        // 读图/点击/拖动/滚动均视为活跃（DragGesture(minimumDistance: 0) 覆盖按下与拖动）；
        // 活跃信号经 Domain 合并窗口去抖，避免每帧写状态
        .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in
            guard revealed else { return }
            let now = Date()
            guard MediaUnlockPolicy.shouldRecordActivity(lastInteraction: lastInteraction, now: now)
            else { return }
            lastInteraction = now
        })
        .onChange(of: scenePhase) { _, phase in
            guard phase != .active, MediaUnlockPolicy.shouldRelockOnBackground() else { return }
            revealed = false
            showPinSheet = false
        }
    }
}
