import SwiftUI
import Domain
import Protocols

/// FR17.9 / ui-ux §4.23 中部大号按住说话按钮（SP-55 全屏语音工作台）：
/// 业主反馈「语音速记页面没有语音录入的图形按钮」——此前录音入口是底部
/// 普通按钮（VoiceDictationButton，44pt 标准条），§4.23 要求的「中部大号
/// 按住说话按钮、声波与聆听状态」缺失。
///
/// 本组件 = 大号圆形麦克风（96pt 视觉、128pt 触控目标 ≥64pt 关怀模式纪律）：
/// 长按 ≥0.2s 即录 / 松手即停（手势判定同 VoiceDictationButton 纪律——
/// 快速点按不触发开录）；点按切换（无障碍触屏等价路径）。
/// 录音中：红色外环 + 波形指示条 + 聆听文案 + 实时部分文本。
/// 识别失败：轻提示手输兜底（FR8.9 不阻断手输）。
///
/// 模型由父视图唯一持有（同一转写引擎单会话——多处独立装配会抢音频会话）。
/// 动画纪律：仅录音态切换一次性过渡 ≤350ms；波形为静态状态指示 +
/// SF Symbols variableColor 状态效果，无自定义循环动画。
struct PressToTalkMicButton: View {
    let model: VoiceDictationModel
    /// 长按手势按下起点（用于判定「真长按」vs 快速点按——同 VoiceDictationButton）
    @State private var pressBeganAt: Date?

    var body: some View {
        VStack(spacing: 10) {
            Button {
                // 点按切换（无障碍等价）：录音中再按即停止
                if model.phase == .recording {
                    model.stop()
                } else {
                    model.start()
                }
            } label: {
                ZStack {
                    // 外环：录音中红色放大（一次性状态过渡）
                    Circle()
                        .stroke(ringColor, lineWidth: model.phase == .recording ? 5 : 2)
                        .frame(width: model.phase == .recording ? 128 : 116,
                               height: model.phase == .recording ? 128 : 116)
                    // 主体圆
                    Circle()
                        .fill(model.phase == .recording
                              ? Color("semantic-danger", bundle: .main).opacity(0.15)
                              : Color("bg-grouped", bundle: .main))
                        .frame(width: 104, height: 104)
                    // 麦克风图标 + 录音中波形指示条
                    VStack(spacing: 5) {
                        Image(systemName: model.phase == .recording ? "waveform" : "mic.fill")
                            .font(.system(size: 40))
                            .foregroundStyle(model.phase == .recording
                                             ? Color("semantic-danger", bundle: .main)
                                             : Color("brand-primary", bundle: .main))
                            .symbolEffect(.variableColor.iterative,
                                          options: .repeating,
                                          isActive: model.phase == .recording)
                        if model.phase == .recording {
                            HStack(alignment: .center, spacing: 3) {
                                ForEach([6.0, 12, 18, 12, 6], id: \.self) { h in
                                    Capsule()
                                        .fill(Color("semantic-danger", bundle: .main))
                                        .frame(width: 3, height: h)
                                }
                            }
                            .transition(.opacity)
                        }
                    }
                }
                .animation(.easeInOut(duration: 0.25), value: model.phase)
            }
            .buttonStyle(.plain)
            .frame(minWidth: 128, minHeight: 128)   // 触控目标 ≥64pt（关怀模式纪律）
            .accessibilityIdentifier("SP-55.panel.pressToTalk")
            .accessibilityLabel(model.phase == .recording ? L10n.voicenoteStop : L10n.voicenoteDictation)
            // 按住说话（FR17.1）：长按 ≥0.2s 开录、松手即停；快速点按完全
            // 走上方点按切换（pressBeganAt 只在松手侧按持有时长判定，点按
            // 路径零干预——同 VoiceDictationButton 状态纪律）
            .onLongPressGesture(minimumDuration: 0.2, pressing: { pressing in
                if pressing {
                    pressBeganAt = Date()
                } else {
                    let heldLong = pressBeganAt.map { Date().timeIntervalSince($0) >= 0.2 } ?? false
                    pressBeganAt = nil
                    if heldLong && model.phase == .recording {
                        model.stop()
                    }
                }
            }, perform: {
                model.start()   // 长按成立才开录
            })

            // 聆听状态 / 部分文本 / 失败兜底 / 待机提示（§4.23 声波与聆听状态）
            switch model.phase {
            case .recording:
                Text(L10n.voicenoteDictating)
                    .font(.subheadline)
                    .foregroundStyle(Color("semantic-danger", bundle: .main))
                if !model.partial.isEmpty {
                    Text(model.partial)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                        .accessibilityIdentifier("SP-55.panel.partial")
                }
            case .failed:
                Text(L10n.voicenoteDictationFailed)
                    .font(.caption)
                    .foregroundStyle(Color("semantic-warning", bundle: .main))
            case .idle:
                Text(L10n.voicenoteDictation)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var ringColor: Color {
        model.phase == .recording
            ? Color("semantic-danger", bundle: .main)
            : Color("text-tertiary", bundle: .main)
    }
}
