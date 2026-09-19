#if os(iOS) || os(macOS)
// linux-blind: （平台守卫：内容未在 Linux 编译，盲区） —— Linux 型检编译空单元，改动须经 macOS CI 验证
import Foundation
import Domain

/// 本机 AI 模型（llama GGUF）首启下载服务（2026-09-20 业主裁决项 4）：
/// 491MB 模型不再随包——首启经本服务下载到 Documents/llm-models（覆盖位），
/// 期间 T2 轨不可用、T1/T3 规则轨照常（离线优先：零网络时核心功能不受影响）。
/// 稳定性纪律（同 ASR 轨）：
///   1. **断点续传**：.part 部分文件按字节偏移续传（ModelPackageDownloader resumeOffset）；
///   2. **哈希 + 字节双钉版**：下载完 SHA-256 与 catalog.json 钉版比对 + 体积校验，
///      不符即弃（绝不安装不可信字节）；
///   3. **原子落位**：.part 校验通过后才 move 到正式路径——半程文件永不可见；
///   4. **失败清理**：异常路径删除 .part，下次从头（或从残余有效字节）重试。
public actor LlamaModelDownloadService {
    /// 安装阶段（消费侧呈现「下载等待 UI」的确定性状态）。
    public enum Phase: Sendable { case downloading, verifying, activating }

    /// 进度快照（received/total 字节 + 阶段）。
    public struct Progress: Sendable, Equatable {
        public let receivedBytes: Int64
        public let totalBytes: Int64
        public let phase: Phase
    }

    public enum Failure: Error, LocalizedError {
        case catalogMissing
        case sizeMismatch
        case checksumMismatch
        case underlying(String)

        public var errorDescription: String? {
            switch self {
            case .catalogMissing: return "模型目录缺失——无法发起下载"
            case .sizeMismatch: return "下载字节数与钉版不符"
            case .checksumMismatch: return "下载校验和与钉版不符"
            case .underlying(let message): return message
            }
        }
    }

    public static let shared = LlamaModelDownloadService()

    private let downloader = ModelPackageDownloader(session: URLSession(configuration: .ephemeral), segmentCount: 4)

    public init() {}

    /// 已安装（就绪）即短路；否则下载 → 校验 → 原子落位。进度/阶段回调可在任意线程。
    @discardableResult
    public func install(progress: (@Sendable (Progress) -> Void)? = nil,
                        onPhase: (@Sendable (Phase) -> Void)? = nil) async throws -> URL {
        if LlamaModelManager.isModelReady() {
            if let url = LlamaModelManager.modelURL() { return url }
        }
        guard let catalog = LlamaModelCatalog.load() else { throw Failure.catalogMissing }
        let directory = LlamaModelManager.installDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(catalog.fileName)
        let partial = directory.appendingPathComponent(catalog.fileName + ".part")
        defer {
            // 异常路径清理 .part（成功路径已在激活时 move 走）；读取失败无碍。
            if FileManager.default.fileExists(atPath: partial.path) {
                try? FileManager.default.removeItem(at: partial)   // try?-ok: 清理尽力而为
            }
        }
        try Task.checkCancellation()

        // 断点续传：.part 存在且字节数有效（>0 且 < 钉版体积）时从该偏移续传；
        // 体积异常（截断/污染）的文件丢弃重下。
        var resumeOffset: Int64 = 0
        if let attrs = try? FileManager.default.attributesOfItem(atPath: partial.path),   // try?-ok: 属性读取失败按无部分文件处理，从头下载
           let size = (attrs[.size] as? NSNumber)?.int64Value,
           size > 0, size < catalog.bytes {
            resumeOffset = size
        } else if FileManager.default.fileExists(atPath: partial.path) {
            try? FileManager.default.removeItem(at: partial)   // try?-ok: 无效部分文件丢弃重下
        }

        onPhase?(.downloading)
        let received = Int64(resumeOffset)
        progress?(Progress(receivedBytes: received, totalBytes: catalog.bytes, phase: .downloading))
        do {
            try await downloader.download(url: catalog.downloadURL, expectedBytes: catalog.bytes, to: partial,
                                          progress: { p in
                                              progress?(Progress(receivedBytes: p.receivedBytes, totalBytes: p.totalBytes, phase: .downloading))
                                          }, resumeOffset: resumeOffset)
        } catch {
            try Task.checkCancellation()
            throw Failure.underlying(String(describing: error))
        }

        onPhase?(.verifying)
        let actualHash: String
        do {
            actualHash = try StreamingFileHasher.sha256(of: partial) { done, total in
                progress?(Progress(receivedBytes: catalog.bytes, totalBytes: catalog.bytes, phase: .verifying))
            }
        } catch {
            throw Failure.underlying("校验读取失败")
        }
        // 大小写不敏感比对（族 A4-F6 教训：上游清单可能出现大写 hex）。
        guard actualHash.lowercased() == catalog.sha256.lowercased() else { throw Failure.checksumMismatch }
        let written = (try? FileManager.default.attributesOfItem(atPath: partial.path)[.size] as? NSNumber)?.int64Value ?? 0   // try?-ok: 属性读取失败按 0 处理，后续体积校验必红
        guard written == catalog.bytes else { throw Failure.sizeMismatch }

        onPhase?(.activating)
        if FileManager.default.fileExists(atPath: destination.path) {
            try? FileManager.default.removeItem(at: destination)   // try?-ok: 同体积旧文件替换
        }
        try FileManager.default.moveItem(at: partial, to: destination)
        progress?(Progress(receivedBytes: catalog.bytes, totalBytes: catalog.bytes, phase: .activating))
        return destination
    }
}

/// 模型目录元数据（`Resources/LLMModels/catalog.json` 随包钉版）：
/// 下载 URL + sha256 + 字节数——信任锚 = 构建期钉版（随签名 App 二进发布，
/// 与 ASR 目录的动态签名链互补：单文件静态资产不需要运行时轮换）。
public struct LlamaModelCatalog: Sendable {
    public let fileName: String
    public let downloadURL: URL
    public let bytes: Int64
    public let sha256: String

    public static func load() -> LlamaModelCatalog? {
        guard let url = Bundle.main.url(forResource: "catalog", withExtension: "json",
                                        subdirectory: LlamaModelManager.bundleSubdirectory),
              let data = try? Data(contentsOf: url),   // try?-ok: 目录缺失按未配置处理
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],   // try?-ok: 目录损坏按未配置处理，调用方显式报错
              let model = (object["models"] as? [[String: Any]])?.first,
              let fileName = model["fileName"] as? String,
              let source = model["downloadURL"] as? String,
              let downloadURL = URL(string: source),
              let bytes = model["bytes"] as? Int64,
              let sha256 = model["sha256"] as? String else { return nil }
        return LlamaModelCatalog(fileName: fileName, downloadURL: downloadURL, bytes: bytes, sha256: sha256)
    }
}
#endif
