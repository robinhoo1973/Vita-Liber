import Foundation

/// 聊天语音消息音频（2026-10-19 业主指令）：本机文件，零上传。
///
/// 目录 = Application Support/ChatAudio（`.completeFileProtection`）。
/// 录音先写 `temp-<uuid>.caf`；用户「使用」后 `adopt` 移入 `voice-<uuid>.caf`，
/// 聊天消息只持有文件名；取消/未使用由调用方删除临时文件。
enum ChatAudioStore {
    static func makeTemporaryURL() -> URL? {
        guard let dir = directory() else { return nil }
        return dir.appendingPathComponent("temp-\(UUID().uuidString).caf")
    }

    /// 采用临时录音：移到最终名并返回文件名；文件不存在返回 nil。
    static func adopt(_ url: URL) -> String? {
        guard FileManager.default.fileExists(atPath: url.path),
              let dir = directory() else { return nil }
        let filename = "voice-\(UUID().uuidString).caf"
        do {
            try FileManager.default.moveItem(at: url, to: dir.appendingPathComponent(filename))
            return filename
        } catch {
            return nil
        }
    }

    static func fileURL(_ filename: String) -> URL? {
        directory()?.appendingPathComponent(filename)
    }

    static func remove(_ filename: String?) {
        guard let filename, let dir = directory() else { return }
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(filename))   // try?-ok: 清理尽力而为
    }

    static func removeTemporary(_ url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)   // try?-ok: 取消清理尽力而为
    }

    /// 「清空全部」等数据擦除路径调用：聊天语音不留存。
    static func wipe() {
        guard let dir = directory() else { return }
        try? FileManager.default.removeItem(at: dir)   // try?-ok: 擦除尽力而为
    }

    private static func directory() -> URL? {
        do {
            let base = try FileManager.default.url(for: .applicationSupportDirectory,
                                                   in: .userDomainMask,
                                                   appropriateFor: nil, create: true)
            let dir = base.appendingPathComponent("ChatAudio", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                    attributes: [.protectionKey: FileProtectionType.complete])
            return dir
        } catch {
            return nil
        }
    }
}
