import Foundation

/// GB 级原生模型（sherpa-onnx ASR/TTS、llama.cpp）加载前的内存预算策略（round5 Q3，2026-09-20）。
///
/// 事实：sherpa-onnx `ReadFile` 把整模读入 `std::vector<char>` 再 `Ort::Session(env, data, size)`——加载期峰值≈2× 模型体积；
/// 超出 iOS 前台 jetsam 限即被系统终止（不是 Swift 崩溃、无 crash log，用户看到「闪退」），并殃及整机内存（其它进程页被逐出
/// → 变慢）。sherpa 内部元数据不符走 `SHERPA_ONNX_EXIT(-1)`，Swift 同样不可捕获。因此**只能在加载前**以纯函数策略拒绝。
/// D6（变体档位建议）只按物理 RAM 提示、不拦截——本策略在其下方兜底，保留用户选择权但把「系统杀」变成「应用说明」。
///
/// 常量集中命名、可定标（L2 真机）；判定纯函数、Linux 可测。
public enum ModelMemoryBudget {
    /// 加载峰值系数（文件缓冲 + ORT 初始化拷贝）。
    public static let loadPeakFactor = 2.0
    /// 峰值之外的固定余量（应用自身 + 系统抖动）。
    public static let baseHeadroomBytes: Int64 = 200 * 1_024 * 1_024
    /// 预热（面板打开即加载）额外要求的余量：低于此值只允许「按压时再载」，不在用户尚未按压时抢占内存。
    public static let preloadHeadroomBytes: Int64 = 400 * 1_024 * 1_024

    public enum Verdict: Equatable, Sendable {
        case ok
        /// 可加载但预热余量不足：延迟到按压时加载。
        case tight
        /// 不足：拒绝加载并说明所需/可用（UI 建议换小档或释放内存）。
        case insufficient(requiredBytes: Int64, availableBytes: Int64)

        public var allowsLoad: Bool { if case .insufficient = self { return false } else { return true } }
        public var allowsPreload: Bool { self == .ok }
    }

    /// llama.cpp（GGUF mmap + Metal 共享内存）加载峰值系数——权重按需分页、不整读入堆，比 sherpa 温和。
    public static let llamaPeakFactor = 1.3

    /// 峰值估算 = 体积 × 系数 + 固定余量（系数按运行时形态给：sherpa 2.0 / llama 1.3）。
    public static func peakBytes(modelBytes: Int64, peakFactor: Double = loadPeakFactor) -> Int64 {
        Int64(Double(max(modelBytes, 0)) * peakFactor) + baseHeadroomBytes
    }

    /// 判定。`availableBytes == nil`（探针不可用）→ `.ok`：fail-open 只对「未知」，已知不足一律拒。
    public static func verdict(modelBytes: Int64, availableBytes: Int64?, peakFactor: Double = loadPeakFactor) -> Verdict {
        guard let available = availableBytes else { return .ok }
        let required = peakBytes(modelBytes: modelBytes, peakFactor: peakFactor)
        if available < required { return .insufficient(requiredBytes: required, availableBytes: available) }
        if available - required < preloadHeadroomBytes { return .tight }
        return .ok
    }
}

/// 崩溃环断路标记（round5 Q3）：加载前落盘、加载成功后清除；下次启动若仍在且指向同一模型身份 → 上次加载未完成
/// （被 jetsam / `SHERPA_ONNX_EXIT` 终止），本会话**不自动预热**该模型并提示用户（浏览器「安全模式」同一做法）。
/// 纯值类型 + 编解码；落盘位置由 Infrastructure 决定。
public struct LoadAttemptMarker: Codable, Equatable, Sendable {
    public let identity: String
    public let startedAt: Date
    public init(identity: String, startedAt: Date = Date()) {
        self.identity = identity; self.startedAt = startedAt
    }
    public func indicatesInterruptedLoad(of identity: String) -> Bool { self.identity == identity }
    public func encoded() throws -> Data { try JSONEncoder().encode(self) }
    public static func decode(_ data: Data) -> LoadAttemptMarker? { try? JSONDecoder().decode(LoadAttemptMarker.self, from: data) }   // try?-ok: 标记损坏视为无标记
}
