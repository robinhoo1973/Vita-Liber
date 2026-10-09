import Foundation
import Domain

/// T2 本机 LLM 模型管理（2026-10-09 换型+下载化批重写）：**单一来源 = 下载安装位**。
///
/// 历史脉络（防复发纪律）：2026-09-17 随包内置 → 2026-09-20 首启下载上线同日回滚
/// （根因：Bundle 分支仍在、`isModelReady()` 本地恒真→下载路径短路，「随包与下载并存」）
/// → 2026-10-06 业主裁「改运行时自 CNB 下载」→ 本批落地。**Bundle 查询分支整体删除**：
/// 本文件与消费侧不再出现 `Bundle.main.url(forResource:`（L0 [20] 机械断言钉死）——
/// 并存矛盾自结构上不可再发生。
///
/// 单一来源结构：
/// - 目录信任锚：`Bundle/LLMCatalog/catalog.json`（签名二进制内容，构建期钉
///   URL+sha256+bytes——网络只做字节运输，无授权输入，符合 ADR-030 精神）；
/// - 就绪权威：安装位 `<AppSupport>/LLMModels/<id>/active.json` 指针 + 精确字节；
/// - 版本并存：`<id>/<version>-<sha12>/<fileName>`（同版本重发即新目录，绝不原地覆写）。
public enum LlamaModelManager {

    /// 目录资源子目录/文件名（`project.yml` 文件夹引用入包）。
    public static let catalogSubdirectory = "LLMCatalog"
    public static let catalogFileName = "catalog"
    /// 安装根目录名。
    public static let installRootDirectoryName = "LLMModels"

    /// 安装指针（active.json）——**唯一就绪权威**。字段与目录条目同钉：
    /// 指针只由下载服务的激活步写入（校验通过之后）。
    public struct InstallPointer: Codable, Equatable, Sendable {
        public var version: String
        public var fileName: String
        public var bytes: Int64
        public var sha256: String

        public init(version: String, fileName: String, bytes: Int64, sha256: String) {
            self.version = version
            self.fileName = fileName
            self.bytes = bytes
            self.sha256 = sha256
        }
    }

    /// 激活模型（解析快照——引擎每次 availability/extract 重新解析，安装/删除即时生效）。
    public struct ActiveModel: Sendable, Equatable {
        public let id: String
        public let url: URL
        public let bytes: Int64
        public let sha256: String
        public let frame: ExtractionPromptBuilder.ChatFrameStyle

        public init(id: String, url: URL, bytes: Int64, sha256: String,
                    frame: ExtractionPromptBuilder.ChatFrameStyle) {
            self.id = id
            self.url = url
            self.bytes = bytes
            self.sha256 = sha256
            self.frame = frame
        }
    }

    /// 测试缝（Linux/macOS 单测把安装根指到临时目录；生产恒 nil）。
    static var installRootOverride: URL?
    /// 测试缝（单测注入目录文档；生产恒 nil → 走随包资源）。
    static var catalogOverride: LLMModelCatalog.Document?

    /// 安装根目录（Application Support 下；不进 iCloud 备份、用户不可见——
    /// 目录级 `isExcludedFromBackup` 由下载服务创建时统一设置）。
    public static var installRootDirectory: URL? {
        if let override = installRootOverride { return override }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent(installRootDirectoryName, isDirectory: true)
    }

    /// 某 id 的安装目录。
    public static func installDirectory(id: String) -> URL? {
        installRootDirectory?.appendingPathComponent(id, isDirectory: true)
    }

    // MARK: - 目录（信任锚）

    /// 随包目录文档（缺失/损坏 → nil：一切条目不就绪——绝不假装可用）。
    public static func catalogDocument() -> LLMModelCatalog.Document? {
        if let override = catalogOverride { return override }
        guard let url = Bundle.main.url(forResource: catalogFileName, withExtension: "json",
                                        subdirectory: catalogSubdirectory),
              let data = try? Data(contentsOf: url) else { return nil }   // try?-ok: 目录缺失按未配置处理（就绪判定随之全假）
        return LLMModelCatalog.parse(data)
    }

    // MARK: - 安装指针

    /// 读取指针（缺失/损坏 → nil）。
    static func readPointer(id: String) -> InstallPointer? {
        guard let url = installDirectory(id: id)?.appendingPathComponent(LLMModelInstallLayout.pointerFileName),
              let data = try? Data(contentsOf: url) else { return nil }   // try?-ok: 指针缺失=未安装
        return try? JSONDecoder().decode(InstallPointer.self, from: data)   // try?-ok: 指针损坏=未安装
    }

    /// 写指针（原子写；调用方保证目录存在）。指针写失败 = 本次激活不完整：
    /// 旧指针（若在）继续有效——激活序的最后一步。
    static func writePointer(_ pointer: InstallPointer, id: String) throws {
        guard let directory = installDirectory(id: id) else { throw CocoaError(.fileNoSuchFile) }
        let url = directory.appendingPathComponent(LLMModelInstallLayout.pointerFileName)
        try JSONEncoder().encode(pointer).write(to: url, options: .atomic)
    }

    // MARK: - 就绪判定

    /// 已安装模型文件 URL（指针在 + 文件在）。
    public static func installedModelURL(id: String) -> URL? {
        guard let pointer = readPointer(id: id),
              let directory = installDirectory(id: id) else { return nil }
        let url = directory
            .appendingPathComponent(LLMModelInstallLayout.versionDirectoryName(version: pointer.version,
                                                                               sha256: pointer.sha256),
                                    isDirectory: true)
            .appendingPathComponent(pointer.fileName)
        guard FileManager.default.isReadableFile(atPath: url.path) else { return nil }
        return url
    }

    /// 就绪判定（三重一致）：目录条目 × 指针 × 磁盘字节。
    /// 指针与条目必须同文件名同字节同日摘要——任一漂移即不就绪（静默错配比拒绝更糟）。
    public static func isModelReady(id: String) -> Bool {
        guard let entry = catalogDocument()?.entry(id: id),
              let pointer = readPointer(id: id),
              pointer.fileName == entry.fileName,
              pointer.bytes == entry.bytes,
              pointer.sha256 == entry.sha256,
              let url = installedModelURL(id: id) else { return false }
        return fileSize(at: url) == entry.bytes
    }

    /// 已安装模型字节数（未安装/不可寻址 → 0）。
    public static func modelSize(id: String) -> Int64 {
        guard let url = installedModelURL(id: id) else { return 0 }
        return fileSize(at: url)
    }

    /// 已安装版本（指针版本号；未安装 → nil）——「手动更新」比对与呈现用。
    public static func installedVersion(id: String) -> String? {
        readPointer(id: id)?.version
    }

    /// 激活模型：按目录 `preference` 序取首个**就绪**条目；无就绪候选 → nil
    /// （调用方按既有语义降级 T3——「缺席不失能、不假装可用」）。
    public static func activeModel() -> ActiveModel? {
        guard let document = catalogDocument() else { return nil }
        for entry in document.preferred where isModelReady(id: entry.id) {
            guard let url = installedModelURL(id: entry.id) else { continue }
            return ActiveModel(id: entry.id, url: url, bytes: entry.bytes,
                               sha256: entry.sha256, frame: entry.frame)
        }
        return nil
    }

    private static func fileSize(at url: URL) -> Int64 {
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            return (attrs[.size] as? Int64) ?? 0
        } catch {
            return 0
        }
    }
}
