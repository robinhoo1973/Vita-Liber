import Foundation
import Domain

/// 把系统探针折叠成 `ASRModelAdvisor` 的纯输入。Domain 不认识 ProcessInfo/Speech/FileManager。
///
/// **探针只读、无网络、不触发下载**：已安装集合只来自本地下载目录指针与随包资产。
public struct ASRAdvisorInputs: Sendable, Equatable {
    public var hardware: ASRHardwareFacts
    public var installed: ASRInstalledAssets

    public init(hardware: ASRHardwareFacts, installed: ASRInstalledAssets) {
        self.hardware = hardware
        self.installed = installed
    }
}

public enum ASRAdvisorInputsProbe {
    /// 硬件事实。Linux（无 Apple 探针）得到 `availableMemoryBytes = nil`，
    /// 因此纯选择器按业主裁决 fail-closed；包测试只直接测纯策略，不走本探针选主轨。
    public static func hardwareFacts() -> ASRHardwareFacts {
        ASRHardwareFacts(
            availableMemoryBytes: ProcessMemory.availableBytes(),
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
            storageFreeBytes: freeStorageBytes(),
            thermal: thermalState(),
            lowPowerMode: lowPowerMode())
    }

    public static func installedAssets(index: ASRModelReleaseIndex?) -> ASRInstalledAssets {
        #if os(iOS) || os(macOS)
        var models: [ASRInstalledModel] = []
        for descriptor in ASRModelCatalog.descriptors(from: index) {
            let choice = descriptor.choice
            let assets = ASRModelAssets.resolve(for: choice)
            guard assets.isPresent(choice) else { continue }
            let downloaded = ASRModelDownloadService.activeRoot(for: choice) != nil
            models.append(ASRInstalledModel(
                choice: choice,
                bytes: assets.byteCount(choice),
                version: ASRModelDownloadService.installedVersion(for: choice),
                origin: downloaded ? .downloaded : .bundled))
        }
        return ASRInstalledAssets(models: models)
        #else
        // Linux 包测试无随包/下载资产探针。
        return .empty
        #endif
    }

    public static func capture(index: ASRModelReleaseIndex?) -> ASRAdvisorInputs {
        ASRAdvisorInputs(hardware: hardwareFacts(), installed: installedAssets(index: index))
    }

    private static func freeStorageBytes() -> Int64? {
        #if os(iOS) || os(macOS)
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let values = try? base.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])   // try?-ok: 存储探针失败=未知（不拦截，只少一条告警）
        return values?.volumeAvailableCapacityForImportantUsage
        #else
        return nil
        #endif
    }

    private static func thermalState() -> ASRHardwareFacts.Thermal {
        #if os(iOS) || os(macOS)
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .unknown
        }
        #else
        return .unknown
        #endif
    }

    private static func lowPowerMode() -> Bool? {
        #if os(iOS) || os(macOS)
        return ProcessInfo.processInfo.isLowPowerModeEnabled
        #else
        return nil
        #endif
    }
}
