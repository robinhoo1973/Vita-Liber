import Foundation

/// Qwen2.5-0.5B GGUF 模型管理：路径查找、下载状态、文件校验。
/// 结构轮（2026-09-15）：自 LlamaCppExtractionEngine.swift 迁出——引擎与
/// 模型文件管理是两个职责（P2）。
public enum LlamaModelManager {
    /// 模型文件名（与 asr-release-spec.json 一致）。
    public static let modelFileName = "qwen2.5-0.5b-instruct-q4_k_m.gguf"
    /// 模型包大小上限（字节），用于 WiFi-only 下载判断。
    public static let maxModelSize: Int64 = 400_000_000

    /// 模型文件路径（App 沙盒 Documents 目录下）。
    public static func modelURL(for fileName: String = modelFileName) -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("llm-models/\(fileName)")
    }

    /// 模型是否已就绪（文件存在且可读）。
    public static func isModelReady(fileName: String = modelFileName) -> Bool {
        let url = modelURL(for: fileName)
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && !isDir.boolValue
    }

    /// 模型文件大小（字节）。
    public static func modelSize(fileName: String = modelFileName) -> Int64 {
        let url = modelURL(for: fileName)
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            return (attrs[.size] as? Int64) ?? 0
        } catch {
            return 0
        }
    }
}
