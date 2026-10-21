import SwiftUI
import Foundation   // sin（相位驱动动画）

/// 录音态波形（三处共用：聊天语音条 / 按住说话 / 语音速记按钮）。
///
/// 相位驱动 + 电平调制：
/// - 电平可用（聊天录音走 `AudioLevelMonitor`）时，振幅随 RMS 增大；
/// - 电平恒 0（引导访谈等未写录音文件的听写路径）时仍有确定性起伏，
///   保证「正在录音」可见——旧实现绑定 `audioLevel`，0 电平下波形静止，
///   用户看到的就是「没有录音动画」。
/// Reduce Motion：停止相位推进，只按当前电平静态呈现。
struct RecordingWaveform: View {
    let level: Float
    let isActive: Bool
    var color: Color = Color("semantic-danger", bundle: .main)
    var barCount: Int = 28
    var maxHeight: CGFloat = 28
    var spacing: CGFloat = 2
    var accessibilityID: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 12.0,
                                paused: !isActive || reduceMotion)) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: spacing) {
                ForEach(0..<barCount, id: \.self) { index in
                    Capsule()
                        .fill(color.opacity(0.85))
                        .frame(width: 3, height: barHeight(index: index, phase: phase))
                }
            }
        }
        .frame(height: maxHeight)
        .accessibilityElement(children: .ignore)
        // 有显式测试/朗读 ID 时保留在无障碍树（否则 XCUITest 永远查不到）；
        // 纯装饰波形仍隐藏，不打扰 VoiceOver。
        .accessibilityHidden(accessibilityID == nil)
        .accessibilityLabel(accessibilityID == nil ? "" : L10n.voicenoteDictating)
        .accessibilityIdentifier(accessibilityID ?? "voice.recording.waveform")
    }

    /// 0…maxHeight。静止（非激活/Reduce Motion）时仅显示电平高度，
    /// 无电平则保留一条低基线，避免空白。
    private func barHeight(index: Int, phase: TimeInterval) -> CGFloat {
        let normalized = CGFloat(min(max(level * 4, 0), 1))
        guard isActive, !reduceMotion else {
            return max(4, max(normalized, 0.12) * maxHeight)
        }
        // 相邻柱相位错开，形成从左到右的流动感；周期约 0.9s。
        let wave = (sin(phase * 7 + Double(index) * 0.9) + 1) / 2   // 0…1
        // 基线 0.18 保证零电平时仍可见；说话时振幅随电平增长。
        let amplitude = 0.18 + 0.82 * normalized
        return max(4, CGFloat(wave) * amplitude * maxHeight)
    }
}
