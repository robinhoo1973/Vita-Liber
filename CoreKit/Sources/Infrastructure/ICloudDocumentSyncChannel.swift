#if os(iOS) || os(macOS)
// linux-blind: （平台守卫：iCloud 文档容器/FileProvider 仅 Apple 平台，Linux 编译空单元，改动须经 macOS CI 验证）
import Foundation
import Domain
import Protocols

/// iCloud 文档容器同步通道（discussions/2026-10-16-backup-sync-share-design.md §5.3）：
/// 落点 = 容器内 `VitaSync/` 子目录；NSFileCoordinator 串行化本设备进程与系统同步守护进程的写；
/// .icloud 占位文件读取前显式 startDownloadingUbiquitousItem（离线未落地 → 跳过该候选，
/// 绝不读半文件）。文件层零仲裁：全版本上抛，语义合并归 SyncMergeRules + ADR-019。
public struct ICloudDocumentSyncChannel: SyncChannel, Sendable {

    public static let syncSubdirectory = "VitaSync"
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    private func containerRoot() throws -> URL {
        guard let root = fileManager.url(forUbiquityContainerIdentifier: nil) else {
            throw SyncChannelError.icloudUnavailable
        }
        return root
    }

    public func fetchEnvelopes() async throws -> [SyncEnvelopeCandidate] {
        let dir = try containerRoot().appendingPathComponent(Self.syncSubdirectory, isDirectory: true)
        var candidates: [SyncEnvelopeCandidate] = []
        let names: [String]
        do {
            names = try fileManager.contentsOfDirectory(atPath: dir.path)
        } catch {
            return []   // 目录不存在 = 无同步历史（首启）
        }
        for name in names {
            guard let identity = SyncFileNaming.decode(name) else { continue }   // 杂散文件不入合并
            let url = dir.appendingPathComponent(name)
            // .icloud 占位 → 显式落地；离线未落地（抛错）→ 跳过该候选，绝不读半文件
            do {
                if fileManager.isUbiquitousItem(at: url) {
                    try FileManager.default.startDownloadingUbiquitousItem(at: url)
                    continue   // 下载异步——本轮跳过，下次 fetch 再取（保守：宁可本轮少一版，不赌半读）
                }
                let data = try Data(contentsOf: url)
                candidates.append(SyncEnvelopeCandidate(realmId: identity.realmId,
                                                        deviceId: identity.deviceId,
                                                        seq: identity.seq, data: data))
            } catch {
                continue
            }
        }
        return candidates
    }

    public func commit(_ data: Data, identity: SyncFileNaming.Identity) async throws {
        let dir = try containerRoot().appendingPathComponent(Self.syncSubdirectory, isDirectory: true)
        do {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            throw SyncChannelError.writeFailed
        }
        let url = dir.appendingPathComponent(SyncFileNaming.encode(identity))
        var coordinatorError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinatorError) { coordinatedURL in
            do {
                try data.write(to: coordinatedURL, options: .atomic)
            } catch {
                writeError = error
            }
        }
        if let coordinatorError { throw SyncChannelError.coordinatorFailed(coordinatorError.code) }
        if let writeError { throw writeError }
    }
}

/// 同步通道错误（端口语义，Linux 可编译——见 Protocols/SyncChannel.swift 同族定义处引用）
public enum SyncChannelError: Error, Sendable, Equatable {
    case icloudUnavailable
    case writeFailed
    case coordinatorFailed(Int32)
}
#endif
