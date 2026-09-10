// 平台守卫镜像 Package.swift 的平台条件（ERR#8 纪律）：AVFoundation 仅 Apple 平台可用。
#if os(iOS)
import AVFoundation

/// 采集会话拆除的**单一出口**（FR17.13 回读路由 / FR19.3 播报路由的正确性依赖此纪律）。
///
/// 5WHY 根因（2026-09-10 审查轮）：ASR/TTS 三个采集点（Sherpa 主轨 / SFSpeech 降级轨 /
/// 音量自检）各自维护 AVAudioSession 的开启与拆除——只有 Sherpa 一侧在审查修复中
/// 补了「还原 .playback 类别」。会话类别是共享单例状态：停留在 `.record` 会让其后的
/// FR17.13 回读、FR17.11 提问朗读、FR19.3 播报全部路由到听筒（音量低到不可用），
/// 且该缺陷只随「降级轨被使用」才暴露——sherpa 主轨临时退出构建后成为生产主路径。
///
/// 拆除契约（业界最佳实践：采集方负责还原共享会话状态，teardown 必须对称于 setup）：
/// 1. 先还原类别到 `.playback`（不还原则下次激活沿用 .record 路由听筒）；
/// 2. 再 `setActive(false, .notifyOthersOnDeactivation)`（先类别后停用，顺序与 Sherpa
///    原实现一致——类别改变在激活态下即时生效，停用把音频让回其他 App）。
///
/// 失败不阻断主流程（try?-ok 白名单口径：降级语义——采集已结束，还原失败
/// 只影响其后播报路由与外部 App 恢复，不得掩盖转写/取消主结果）。
public enum AudioSessionTeardown {
    /// 采集后还原：`.playback` + 停用。调用方先自行停引擎/摘 tap，再调本出口。
    public static func restorePlaybackAfterCapture() {
        do { try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.duckOthers]) }
        catch { /* 类别还原失败不阻断主流程 */ }
        do { try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation]) }
        catch { /* 还原失败不阻断主流程 */ }
    }
}
#endif
