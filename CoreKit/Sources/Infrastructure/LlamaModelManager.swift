import Foundation

/// Qwen2.5-0.5B GGUF 模型管理：路径查找、就绪判定、文件校验。
/// 结构轮（2026-09-15）：自 LlamaCppExtractionEngine.swift 迁出——引擎与
/// 模型文件管理是两个职责（P2）。
/// 业主 2026-09-17 定：模型**随包内置**（`Resources/LLMModels/` 文件夹引用入
/// bundle）——本管理器改为 bundle-first；Documents/llm-models 保留为**后置
/// 覆盖位**（将来若提供官方更新包下载，落在沙盒即优先于随包版本）。
public enum LlamaModelManager {
    /// 模型文件名（与 `Resources/LLMModels/catalog.json` 一致）。
    public static let modelFileName = "qwen2.5-0.5b-instruct-q4_k_m.gguf"
    /// 随包资源子目录（project.yml 文件夹引用，buildPhase: resources）。
    public static let bundleSubdirectory = "LLMModels"
    /// 模型体积（q4_k_m 实测字节数，随 catalog.json 钉版）。
    public static let expectedModelBytes: Int64 = 491_400_032

    /// 模型文件路径：沙盒覆盖位优先（存在才用），否则随包资源。
    public static func modelURL(for fileName: String = modelFileName) -> URL? {
        let override = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("llm-models/\(fileName)")
        if FileManager.default.fileExists(atPath: override.path) { return override }
        return Bundle.main.url(forResource: fileName, withExtension: nil, subdirectory: bundleSubdirectory)
    }

    /// 模型是否已就绪（随包在 / 覆盖位在，且可读）。
    public static func isModelReady(fileName: String = modelFileName) -> Bool {
        guard let url = modelURL(for: fileName) else { return false }
        return FileManager.default.isReadableFile(atPath: url.path)
    }

    /// 模型文件大小（字节）；模型不可寻址时返回 0。
    public static func modelSize(fileName: String = modelFileName) -> Int64 {
        guard let url = modelURL(for: fileName) else { return 0 }
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            return (attrs[.size] as? Int64) ?? 0
        } catch {
            return 0
        }
    }
}
