import Foundation
#if canImport(os)
import os
#endif

/// 迁移启动收据（B3，2026-10-29 转换登记表批；SRE 席方案）。
///
/// **为什么是独立 JSONL 而不是 sqlite**：收据必须在「患者库不可读/打不开」时
/// 仍可写——用 sqlite 就得先打开某个库，恰在最需要取证的时刻不可用。
/// 纯文件追加（O_APPEND 单行写入 + fsync）天然满足，且不碰患者库、不联网。
///
/// 判读语义：末行 `in-progress` 且没有对应终止行 = 上次进程死在迁移中；
/// 每条事件携带 bootId，配对即取证。历史库（每启动重建）仍是诊断投影，
/// 本报文是跨启动唯一证据（tech §5.54 / V3.216③ 缺口补位）。
///
/// 位置纪律：`Application Support/VitaLiber/boot/migration-receipt.jsonl`，
/// 禁 Documents（L0[21] 存储边界）；置 `isExcludedFromBackup`——恢复旧备份
/// 不得带回陈旧 in-progress 标记（SRE 席：否则假警）。超过 256KB 轮转为
/// 同名 `.1`（只保一轮：取证只需最近两次启动）。
public final class MigrationReceipt: @unchecked Sendable {
    public struct Event: Codable, Equatable, Sendable {
        public enum Outcome: String, Codable, Sendable {
            case inProgress = "in-progress"
            case success
            case failed
            case verifyFailed = "verify-failed"
            case openFailed = "open-failed"
        }

        public var bootId: String
        /// 纪元秒（与库表时间列同口径；无时区歧义）。
        public var at: TimeInterval
        /// 目录里检出的注册名候选（B0 名字全集）；≥2 时本身即证据。
        public var candidates: [String]
        /// 实际使用的库文件名（`nil` = 路径解析失败/多候选 fail-closed）。
        public var chosen: String?
        /// 迁移方式（`fresh`/`ready-vN`/`migrate-vN-to-vM`/`too-new-…` 等，同决策标签）。
        public var mode: String
        public var sourceVersion: Int?
        public var targetVersion: Int?
        public var outcome: Outcome
        public var detail: String?
        /// 批 ⑤（2026-10-29）：阶段耗时遥测——每次 boot 仅附加在**终止事件**上
        /// （单事件设计，避免逐阶段写行扰动时序）；旧行无该键=向后兼容解码。
        public var phases: [Phase]?

        public struct Phase: Codable, Equatable, Sendable {
            /// 桶名（history / patientProbe / open.<decision> / sliceVerify）。
            public var name: String
            public var durationMs: Double
            /// ok / failed。
            public var status: String

            public init(name: String, durationMs: Double, status: String) {
                self.name = name; self.durationMs = durationMs; self.status = status
            }
        }

        public init(bootId: String, at: TimeInterval, candidates: [String], chosen: String?,
                    mode: String, sourceVersion: Int?, targetVersion: Int?,
                    outcome: Outcome, detail: String? = nil,
                    phases: [Phase]? = nil) {
            self.bootId = bootId; self.at = at
            self.candidates = candidates; self.chosen = chosen
            self.mode = mode; self.sourceVersion = sourceVersion
            self.targetVersion = targetVersion; self.outcome = outcome
            self.detail = detail; self.phases = phases
        }
    }

    public static let fileName = "migration-receipt.jsonl"
    /// 轮转阈值：只保最近一段取证窗口，防无限增长。
    public static let rotateThresholdBytes = 256 * 1024

    public let fileURL: URL
    private let fileManager: FileManager
    private let rotateThreshold: Int
    private let lock = NSLock()
    #if canImport(os)
    private static let logger = Logger(subsystem: "com.vitaliber", category: "migration-receipt")
    #endif

    /// 目录不存在会创建；文件级备份排除在首次写入时设置（失败仅告警）。
    public init(directory: URL, fileManager: FileManager = .default,
                rotateThreshold: Int = MigrationReceipt.rotateThresholdBytes) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        self.fileURL = directory.appendingPathComponent(Self.fileName)
        self.fileManager = fileManager
        self.rotateThreshold = rotateThreshold
    }

    /// 生产位置：`<Application Support>/VitaLiber/boot/`（与患者库同容器、不同目录）。
    public static func standard(fileManager: FileManager = .default) throws -> MigrationReceipt {
        let base = fileManager.urls(for: .applicationSupportDirectory,
                                    in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return try MigrationReceipt(
            directory: base.appendingPathComponent("VitaLiber/boot", isDirectory: true),
            fileManager: fileManager)
    }

    /// 追加一条事件：整行一次写入 + fsync；任何失败向上抛，由调用方决定
    /// 「只告警不阻断启动」（收据是证据，不是启动闸）。
    public func append(_ event: Event) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var line = try encoder.encode(event)
        line.append(0x0A)
        lock.lock()
        defer { lock.unlock() }
        rotateIfNeeded(incoming: line.count)
        if !fileManager.fileExists(atPath: fileURL.path) {
            guard fileManager.createFile(atPath: fileURL.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            // setResourceValues 为 mutating——URL 值语义，需本地 var。
            var url = fileURL
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values) // try?-ok: 备份排除失败不阻断取证写入
        }
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() } // try?-ok: close 失败无残留影响
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
        try handle.synchronize()   // fsync：断电后末行可判
    }

    /// 轮转：当前文件 + 新行将超阈值时，把现文件改名为 `.1`（覆盖旧 `.1`）。
    private func rotateIfNeeded(incoming: Int) {
        guard let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path), // try?-ok: 取不到属性=按无需轮转处理
              let size = (attributes[.size] as? NSNumber)?.intValue else { return }
        guard size > 0, size + incoming > rotateThreshold else { return }
        let archived = fileURL.appendingPathExtension("1")
        try? fileManager.removeItem(at: archived) // try?-ok: 无旧归档
        do { try fileManager.moveItem(at: fileURL, to: archived) }
        catch {
            #if canImport(os)
            Self.logger.warning("receipt rotate failed: \(String(describing: error), privacy: .public)")
            #endif
        }
    }

    /// 测试/诊断用：读出全部事件行（损坏行跳过——取证尽力而为）。
    public func readEvents() throws -> [Event] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        return data.split(separator: 0x0A).compactMap { line in
            try? decoder.decode(Event.self, from: Data(line)) // try?-ok: 半行/损坏行跳过，取证不因单行失效
        }
    }
}
