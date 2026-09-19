// 平台守卫（L0 六族启发式 + CI 34018308312 同族实证）：AVAudioSession 是
// iOS-only API（macOS 'unavailable in macOS'）——本文件仅 iOS 编译；
// macOS 侧引用方（SFSpeechTranscriber 的音频会话逻辑）以 #if os(iOS) 自行
// 守卫，macOS 测试宿主走无会话路径（AVAudioEngine 直连不涉会话路由）。
#if os(iOS)
// linux-blind: AVFoundation 音频 —— Linux 型检编译空单元，改动须经 macOS CI 验证
import AVFoundation

// 拆除契约说明（2026-09-18 清理轮：原 `public enum AudioSessionTeardown {}` 空壳命名空间
// 全仓零引用已删；契约本身保留，作为下方 AudioSessionCapture.remember/restore 快照对的文档）：
//
// 采集会话拆除的**单一出口**（FR17.13 回读路由 / FR19.3 播报路由的正确性依赖此纪律）。
//
// 5WHY 根因（2026-09-10 审查轮）：ASR/TTS 三个采集点（Sherpa 主轨 / SFSpeech 降级轨 /
// 音量自检）各自维护 AVAudioSession 的开启与拆除——只有 Sherpa 一侧在审查修复中
// 补了「还原 .playback 类别」。会话类别是共享单例状态：停留在 `.record` 会让其后的
// FR17.13 回读、FR17.11 提问朗读、FR19.3 播报全部路由到听筒（音量低到不可用），
// 且该缺陷只随「降级轨被使用」才暴露——sherpa 主轨临时退出构建后成为生产主路径。
//
// 拆除契约（业界最佳实践：采集方负责还原共享会话状态，teardown 必须对称于 setup）：
// 1. 先还原类别到采集前的状态（快照还原——不得硬编码假定采集前是 .playback）；
// 2. 再 `setActive(false, .notifyOthersOnDeactivation)`（先类别后停用，顺序与 Sherpa
//    原实现一致——类别改变在激活态下即时生效，停用把音频让回其他 App）。
//
// 失败不阻断主流程（try?-ok 白名单口径：降级语义——采集已结束，还原失败
// 只影响其后播报路由与外部 App 恢复，不得掩盖转写/取消主结果）。
// 审查修复（死代码清除）：restorePlaybackAfterCapture 全仓零调用——
// 硬编码 .playback 前态的第二套拆除契约与快照对（AudioSessionCapture.
// remember/restore）并存，未来调用方选错即还原错误类别。实际采集点
// 全部走快照对，硬编码形态已无合法调用方，删除。

/// 采集会话激活的**单一出口**（与上文的拆除契约对称）：
/// 三个采集点（Sherpa 主轨 / SFSpeech 降级轨 / 音量自检）曾各自内联
/// `setCategory(.record, mode: .measurement, options: [.duckOthers]) + setActive(true)`——
/// 拆除侧已收敛单一出口而激活侧没有，会话选项变更须三处同步、漏一处即
/// 静默漂移。本出口统一激活语义；配合 `remember/restore` 快照对实现
/// 「teardown 对称于 setup」的完整契约。
public enum AudioSessionCapture {
    /// 采集前的共享会话状态快照（类别/mode/options）——拆除时原样还原。
    public struct State: @unchecked Sendable, Equatable {
        public let category: AVAudioSession.Category
        public let mode: AVAudioSession.Mode
        public let options: AVAudioSession.CategoryOptions
        public init(category: AVAudioSession.Category, mode: AVAudioSession.Mode,
                    options: AVAudioSession.CategoryOptions) {
            self.category = category
            self.mode = mode
            self.options = options
        }
    }

    /// 记录当前共享会话状态（必须在任何 setCategory 之前调用）。
    public static func remember() -> State {
        let session = AVAudioSession.sharedInstance()
        return State(category: session.category, mode: session.mode, options: session.categoryOptions)
    }

    /// 采集激活：`.record` + 测量模式 + duck 其他音频，随后激活。
    /// 抛错时**不保证**类别未被修改（setCategory 成功后 setActive 失败也会抛）——
    /// 调用方必须按「已记录快照」还原，不得以「激活是否成功」判定还原。
    public static func activateRecordSession() throws {
        try AVAudioSession.sharedInstance().setCategory(.record, mode: .measurement, options: [.duckOthers])
        try AVAudioSession.sharedInstance().setActive(true)
    }

    /// 还原到采集前状态：先类别后停用（类别改变在激活态下即时生效）。
    /// 失败不阻断主流程（同拆除契约降级口径）。
    public static func restore(_ prior: State) {
        do { try AVAudioSession.sharedInstance().setCategory(prior.category, mode: prior.mode, options: prior.options) }
        catch { /* 还原失败不阻断主流程 */ }
        do { try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation]) }
        catch { /* 还原失败不阻断主流程 */ }
    }
}
#endif
