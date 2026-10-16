import Foundation

/// 设备密钥环端口（discussions/2026-10-16-backup-sync-share-design.md §5.2）：
/// 密钥材料一律 Data（32B 对称密钥）——CryptoKit 仅 Apple 平台，端口层零平台依赖（Linux 可编译）。
/// 密钥层级：同步主密钥（synchronizable，跨设备可达，主路径）→ 每设备子密钥（ThisDeviceOnly，
/// 本地静态加密）→ 恢复码（用户持有，逃生舱）。恢复码包裹段随信封自足（钥匙串重置可自愈）。
public protocol DeviceKeyRing: Sendable {

    /// 同步主密钥；无则 nil（新设备/钥匙串未同步——须经恢复码或信封自足段解封，绝不静默换钥）。
    func masterKey(realmId: UUID) async throws -> Data?

    /// 写入同步主密钥（首启注册/恢复码解封后）。
    func storeMasterKey(_ key: Data, realmId: UUID) async throws

    /// 每设备子密钥；不存在则生成并持久化（ThisDeviceOnly——不随 iCloud Keychain 同步）。
    func deviceSubKey() async throws -> Data

    /// 生成 32B 随机主密钥（SecRandomCopyBytes；仅生成，不落 Keychain）。
    func generateMasterKey() throws -> Data
}

/// 密钥环错误（Keychain 状态码透传供诊断；语义由调用方映射）。
/// 状态码用 Int32 而非 OSStatus——端口层 Linux 可编译（OSStatus 为 Apple CoreFoundation 类型）。
public enum KeyRingError: Error, Sendable, Equatable {
    case keychain(Int32)
    case invalidKeySize(Int)
}
