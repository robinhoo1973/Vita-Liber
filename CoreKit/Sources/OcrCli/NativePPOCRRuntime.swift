#if os(Linux) && canImport(COnnxRuntime)
import Foundation
import Domain
import Protocols
import COnnxRuntime

/// ADR-026 Linux/dev 轨道：ONNX Runtime C API 的 Swift 封装（C 层见 `ppocr_c.c`）。
/// 当前里程碑：确认 `libonnxruntime.so` 可在 Linux 经 C modulemap 加载并取到版本；
/// 完整 PP-OCR det/rec 推理（预处理 + DB 后处理 + CRNN/CTC 解码 + 词表）为后续里程碑，
/// 需另行托管 PP-OCR 模型三件套与字典（外置、SHA-256 校验，见 tech-spec §5.2.2）。
public actor NativePPOCRRuntime {
    public static let shared = NativePPOCRRuntime()
    public let ortVersion: String

    private init() {
        if let v = ort_runtime_version() {
            ortVersion = String(cString: v)
        } else {
            ortVersion = "unknown"
        }
    }

    /// 完整推理的占位：返回空结果，待 PP-OCR 模型与后处理接入。
    public func recognize(_ imageData: Data) async throws -> (lines: [String], confidences: [Double]) {
        return ([], [])
    }
}
#endif
