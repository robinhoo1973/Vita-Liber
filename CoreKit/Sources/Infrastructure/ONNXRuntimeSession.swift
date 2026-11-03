#if os(iOS) || os(macOS)
// linux-blind: ORT 静态库/C 桥仅在 Apple 切片链接；Linux 走 OCRBridge 桩，不进入本文件编译单元。
import Foundation
import OCRBridge

/// PP-OCRv6 rec 的 ORT 会话薄包装（2026-11-03 调参批）。
///
/// 只做 session 生命周期与同步推理；所有指针/释放都在 C 桥内完成。
/// 调用方必须串行化（影子 actor 已串行）；不写临时文件、不联网。
public final class ONNXRuntimeSession: @unchecked Sendable {
    public enum SessionError: Error, LocalizedError {
        case unavailable(String)
        case runFailed(String)

        public var errorDescription: String? {
            switch self {
            case .unavailable(let message): return "OCR engine unavailable: \(message)"
            case .runFailed(let message): return "OCR run failed: \(message)"
            }
        }
    }

    public struct Output: Sendable {
        public var probabilities: [Float]
        public var timesteps: Int
        public var classes: Int
    }

    private let handle: UnsafeMutableRawPointer?
    private let modelData: Data

    public init(modelData: Data, intraThreads: Int = 2) throws {
        self.modelData = modelData
        var created: UnsafeMutableRawPointer?
        modelData.withUnsafeBytes { raw in
            created = ocr_session_create(raw.baseAddress, modelData.count, Int32(intraThreads))
        }
        guard let created else {
            throw SessionError.unavailable(String(cString: ocr_last_error()))
        }
        self.handle = created
    }

    deinit {
        if let handle { ocr_session_free(handle) }
    }

    public func run(input: [Float], height: Int, width: Int) throws -> Output {
        guard let handle else { throw SessionError.unavailable("session closed") }
        var output: UnsafeMutablePointer<Float>?
        var count = 0
        var timesteps: Int64 = 0
        var classes: Int64 = 0
        let status = input.withUnsafeBufferPointer { buffer in
            ocr_session_run(handle, buffer.baseAddress, Int64(height), Int64(width),
                            &output, &count, &timesteps, &classes)
        }
        guard status == 0, let output else {
            throw SessionError.runFailed(String(cString: ocr_last_error()))
        }
        defer { ocr_buffer_free(output) }
        let probabilities = Array(UnsafeBufferPointer(start: output, count: count))
        return Output(probabilities: probabilities, timesteps: Int(timesteps), classes: Int(classes))
    }
}
#endif
