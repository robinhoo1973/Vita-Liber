import Foundation
import Domain

/// 端侧 Core ML 模型安装（2026-11-07 业主：有下载模型时优先用下载模型，
/// 没有则随包模型主力）。
///
/// 仅接受**显式安装**：调用方把已验证的模型包放到临时目录后调用
/// `install(package:)`；本类型不联网、不自动检查、不后台下载。
/// 目录契约与随包一致：`catalog.json` + `modelFile`（`.mlmodelc`）。
/// 安装后 `installedDirectory()` 优先于随包目录；删除/损坏即回落随包。
public enum CoreMLModelInstallation {
    public enum InstallError: Error, Sendable {
        case invalidPackage
        case copyFailed
    }

    public static func installedDirectory(fileManager: FileManager = .default) -> URL? {
        guard let support = try? fileManager.url(for: .applicationSupportDirectory,   // try?-ok: 无目录=未安装
                                                 in: .userDomainMask,
                                                 appropriateFor: nil, create: false),
              let directory = validated(fileManager: fileManager,
                                        root: support.appendingPathComponent("VitaLiber/CoreMLModels", isDirectory: true))
        else { return nil }
        return directory
    }

    /// 安装一个目录包：内容必须通过 catalog 解码、格式版本与完整性校验。
    /// 采用 staging → 原子替换；失败保留旧版本（回滚=删除 current 或重新安装旧包）。
    public static func install(package: URL, fileManager: FileManager = .default) throws {
        guard packageIsValid(package: package) else { throw InstallError.invalidPackage }
        guard let support = try? fileManager.url(for: .applicationSupportDirectory,   // try?-ok: 无目录=安装失败
                                                 in: .userDomainMask,
                                                 appropriateFor: nil, create: true)
        else { throw InstallError.copyFailed }
        let root = support.appendingPathComponent("VitaLiber/CoreMLModels", isDirectory: true)
        do {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            let staging = root.appendingPathComponent("staging-\(UUID().uuidString)", isDirectory: true)
            try fileManager.copyItem(at: package, to: staging)
            let current = root.appendingPathComponent("current", isDirectory: true)
            if fileManager.fileExists(atPath: current.path) {
                _ = try fileManager.replaceItemAt(current, withItemAt: staging)
            } else {
                try fileManager.moveItem(at: staging, to: current)
            }
        } catch {
            throw InstallError.copyFailed
        }
    }

    public static func removeInstalled(fileManager: FileManager = .default) throws {
        guard let support = try? fileManager.url(for: .applicationSupportDirectory,   // try?-ok: 无目录=无安装
                                                 in: .userDomainMask,
                                                 appropriateFor: nil, create: false) else { return }
        let current = support.appendingPathComponent("VitaLiber/CoreMLModels/current", isDirectory: true)
        if fileManager.fileExists(atPath: current.path) {
            try fileManager.removeItem(at: current)
        }
    }

    private static func validated(fileManager: FileManager, root: URL) -> URL? {
        let current = root.appendingPathComponent("current", isDirectory: true)
        guard fileManager.fileExists(atPath: current.appendingPathComponent("catalog.json").path),
              packageIsValid(package: current) else { return nil }
        return current
    }

    private static func packageIsValid(package: URL) -> Bool {
        guard let data = try? Data(contentsOf: package.appendingPathComponent("catalog.json")),   // try?-ok: 缺件=无效
              let catalog = try? JSONDecoder().decode(CoreMLElementMatcher.Catalog.self, from: data),   // try?-ok: 损坏=无效
              catalog.formatVersion == 1 else { return false }
        let modelURL = package.appendingPathComponent(catalog.modelFile)
        guard FileManager.default.fileExists(atPath: modelURL.path) else { return false }
        return CoreMLElementMatcher.verifiesIntegrity(modelURL: modelURL, catalog: catalog)
    }
}
