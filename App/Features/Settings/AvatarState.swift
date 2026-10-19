import SwiftUI
import UIKit
import Domain
import Perception

/// 本地头像状态（2026-10-19 业主指令）：聊天用户侧头像。
///
/// 存储纪律：
/// - 选择持久化在 `AppSettingKey.avatarChoice`（`symbol:<SF Symbol>` / `photo:<文件名>`）；
/// - 自选照片只落本机 Application Support/Avatar（`.completeFileProtection`），
///   不上传、不进备份、不进日志；默认头像 = SF Symbol（无版权素材）。
@MainActor
@Perceptible
final class AvatarState {
    /// 无版权风险的预设头像（SF Symbols 4 / iOS 16 可用集合）。
    static let presets: [String] = [
        "person.crop.circle.fill", "figure.wave", "heart.fill", "leaf.fill",
        "pawprint.fill", "moon.stars.fill", "sun.max.fill", "sparkles",
    ]
    static let defaultSymbol = "person.crop.circle.fill"

    static let assistantPresets: [String] = [
        "sparkles", "leaf", "moon.stars", "sun.max", "waveform",
        "star", "cloud", "location.north.circle",
    ]
    static let defaultAssistantSymbol = "sparkles"

    private(set) var choice: String
    private(set) var assistantChoice: String
    private(set) var image: UIImage?
    private let settings: AppSettingsStore

    init(settings: AppSettingsStore) {
        self.settings = settings
        self.choice = SettingsRules.resolved(settings.values[.avatarChoice], key: .avatarChoice)
        self.assistantChoice = SettingsRules.resolved(settings.values[.assistantAvatarChoice],
                                                      key: .assistantAvatarChoice)
    }

    var symbol: String { Self.symbolName(in: choice) ?? Self.defaultSymbol }

    var assistantSymbol: String {
        Self.assistantPresets.contains(assistantChoice) ? assistantChoice : Self.defaultAssistantSymbol
    }

    func load() async {
        choice = SettingsRules.resolved(settings.values[.avatarChoice], key: .avatarChoice)
        assistantChoice = SettingsRules.resolved(settings.values[.assistantAvatarChoice],
                                                 key: .assistantAvatarChoice)
        image = Self.loadImage(for: choice)
    }

    func setAssistantSymbol(_ symbol: String) async {
        guard Self.assistantPresets.contains(symbol) else { return }
        assistantChoice = symbol
        await settings.set(symbol, for: .assistantAvatarChoice)
    }

    func setSymbol(_ symbol: String) async {
        guard Self.presets.contains(symbol) || symbol == Self.defaultSymbol else { return }
        Self.removePhotoFile(for: choice)
        choice = "symbol:\(symbol)"
        image = nil
        await settings.set(choice, for: .avatarChoice)
    }

    /// 自选照片：缩放至 ≤512pt、JPEG 0.85 后写入本机；失败抛错由 UI 行内提示。
    func setPhoto(_ data: Data) async throws {
        guard let jpeg = Self.normalizedJPEG(data) else { throw AvatarError.unreadable }
        let directory = try Self.directory()
        let filename = "avatar-\(UUID().uuidString).jpg"
        let url = directory.appendingPathComponent(filename, isDirectory: false)
        try jpeg.write(to: url, options: [.atomic, .completeFileProtection])
        Self.removePhotoFile(for: choice)
        choice = "photo:\(filename)"
        image = UIImage(data: jpeg)
        await settings.set(choice, for: .avatarChoice)
    }

    func reset() async {
        Self.removePhotoFile(for: choice)
        choice = "symbol:\(Self.defaultSymbol)"
        image = nil
        await settings.set(choice, for: .avatarChoice)
    }

    enum AvatarError: Error { case unreadable }

    // MARK: - 存储

    private static func symbolName(in choice: String) -> String? {
        guard choice.hasPrefix("symbol:") else { return nil }
        return String(choice.dropFirst("symbol:".count))
    }

    private static func photoFilename(in choice: String) -> String? {
        guard choice.hasPrefix("photo:") else { return nil }
        return String(choice.dropFirst("photo:".count))
    }

    private static func directory() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory,
                                               in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        let dir = base.appendingPathComponent("Avatar", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.protectionKey: FileProtectionType.complete])
        return dir
    }

    private static func loadImage(for choice: String) -> UIImage? {
        guard let filename = photoFilename(in: choice),
              let directory = try? directory() else { return nil }   // try?-ok: 目录不可用 → 回落默认头像
        return UIImage(contentsOfFile: directory.appendingPathComponent(filename).path)
    }

    private static func removePhotoFile(for choice: String) {
        guard let filename = photoFilename(in: choice),
              let directory = try? directory() else { return }   // try?-ok: 清理尽力而为，不影响新选择
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(filename))   // try?-ok: 清理尽力而为，不影响新选择
    }

    private static func normalizedJPEG(_ data: Data) -> Data? {
        guard let source = UIImage(data: data) else { return nil }
        let longest = max(source.size.width, source.size.height)
        let scale = longest > 512 ? 512 / longest : 1
        let size = CGSize(width: source.size.width * scale, height: source.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: size)
        let resized = renderer.image { _ in source.draw(in: CGRect(origin: .zero, size: size)) }
        return resized.jpegData(compressionQuality: 0.85)
    }
}
