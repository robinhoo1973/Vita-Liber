#if os(iOS) || os(macOS)
// linux-blind: ORT C 桥仅在 Apple 切片；Linux 无第三 OCR 源。
import Foundation
import OCRBridge

/// 双输入 ONNX 会话（CnOCR：`x` [1,1,32,W] + `input_lengths` [1]）。
///
/// 与 `ONNXRuntimeSession` 分离而非加可选参数：Paddle rec/det 的既有单输入
/// 路径保持零改动，第三源缺件/加载失败时只影响它自己。
public final class ONNXRuntimeTwoInputSession: @unchecked Sendable {
    private let handle: UnsafeMutableRawPointer?
    private let modelData: Data

    public init(modelData: Data, intraThreads: Int = 2,
                inputName: String, lengthsInputName: String, outputName: String) throws {
        self.modelData = modelData
        var created: UnsafeMutableRawPointer?
        inputName.withCString { input in
            lengthsInputName.withCString { lengths in
                outputName.withCString { output in
                    modelData.withUnsafeBytes { raw in
                        created = ocr_session_create2(raw.baseAddress, modelData.count,
                                                      input, lengths, output, Int32(intraThreads))
                    }
                }
            }
        }
        guard let created else {
            throw ONNXRuntimeSession.SessionError.unavailable(String(cString: ocr_last_error()))
        }
        self.handle = created
    }

    deinit {
        if let handle { ocr_session_free(handle) }
    }

    /// 单通道灰度张量 [1,1,height,width]；`length` 回填 CnOCR 的缩放后宽度。
    public func run(input: [Float], height: Int, width: Int, length: Int)
        throws -> ONNXRuntimeSession.Output {
        guard let handle else {
            throw ONNXRuntimeSession.SessionError.unavailable("session closed")
        }
        guard height > 0, width > 0, length > 0 else {
            throw ONNXRuntimeSession.SessionError.runFailed("invalid input shape \(height)x\(width)")
        }
        let plane = height.multipliedReportingOverflow(by: width)
        guard !plane.overflow, plane.partialValue == input.count else {
            throw ONNXRuntimeSession.SessionError.runFailed(
                "input count \(input.count) != \(height)*\(width)")
        }
        var output: UnsafeMutablePointer<Float>?
        var count = 0
        var timesteps: Int64 = 0
        var classes: Int64 = 0
        let status = input.withUnsafeBufferPointer { buffer in
            ocr_session_run2(handle, buffer.baseAddress, Int64(height), Int64(width),
                             Int64(length), &output, &count, &timesteps, &classes)
        }
        guard status == 0, let output else {
            throw ONNXRuntimeSession.SessionError.runFailed(String(cString: ocr_last_error()))
        }
        defer { ocr_buffer_free(output) }
        guard timesteps > 0, classes > 0,
              timesteps <= Int64(Int.max), classes <= Int64(Int.max) else {
            throw ONNXRuntimeSession.SessionError.runFailed(
                "invalid output shape \(timesteps)x\(classes)")
        }
        let probabilities = Array(UnsafeBufferPointer(start: output, count: count))
        return ONNXRuntimeSession.Output(probabilities: probabilities,
                                         timesteps: Int(timesteps), classes: Int(classes))
    }
}
#endif
