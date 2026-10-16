#if os(iOS) || os(macOS)
// linux-blind: （平台守卫：Security/Keychain 仅 Apple 平台，Linux 编译空单元，改动须经 macOS CI 验证）
import Foundation
import Security
import Domain
import Protocols

/// Keychain 设备密钥环实现（discussions/2026-10-16-backup-sync-share-design.md §5.2）：
/// 主密钥 kSecAttrSynchronizable=true（跨设备主路径；E2EE 可信设备圈——Apple 平台安全指南口径）、
/// 子密钥 ThisDeviceOnly（默认不同步）；服务名单一常量、账号含 realmId（多同步域隔离）。
public struct KeychainDeviceKeyRing: DeviceKeyRing, Sendable {

    private static let service = "com.vitaliber.backup.keys"
    private static let keySize = 32

    public init() {}

    private func baseQuery(_ account: String, synchronizable: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
        ]
        if synchronizable {
            query[kSecAttrSynchronizable as String] = kCFBooleanTrue!
        }
        return query
    }

    public func masterKey(realmId: UUID) async throws -> Data? {
        var query = baseQuery("master.\(realmId.uuidString)", synchronizable: true)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeyRingError.keychain(status)
        }
        return data
    }

    public func storeMasterKey(_ key: Data, realmId: UUID) async throws {
        guard key.count == Self.keySize else { throw KeyRingError.invalidKeySize(key.count) }
        var query = baseQuery("master.\(realmId.uuidString)", synchronizable: true)
        query[kSecValueData as String] = key
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        if addStatus == errSecDuplicateItem {
            // 已存在 → 覆盖（幂等注册；同一 realm 换钥经显式调用，审计由上层承担）
            let update: [String: Any] = [kSecValueData as String: key]
            let updateStatus = SecItemUpdate(baseQuery("master.\(realmId.uuidString)", synchronizable: true) as CFDictionary,
                                             update as CFDictionary)
            guard updateStatus == errSecSuccess else { throw KeyRingError.keychain(updateStatus) }
        } else if addStatus != errSecSuccess {
            throw KeyRingError.keychain(addStatus)
        }
    }

    public func deviceSubKey() async throws -> Data {
        let account = "device-sub"
        var readQuery = baseQuery(account, synchronizable: false)
        readQuery[kSecReturnData as String] = true
        readQuery[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let readStatus = SecItemCopyMatching(readQuery as CFDictionary, &result)
        if readStatus == errSecSuccess, let data = result as? Data, data.count == Self.keySize {
            return data
        }
        // 无/尺寸不符 → 生成并持久化（ThisDeviceOnly：不同步、不随备份迁移）
        let fresh = try generateMasterKey()
        var addQuery = baseQuery(account, synchronizable: false)
        addQuery[kSecValueData as String] = fresh
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecDuplicateItem {
            var dupQuery = baseQuery(account, synchronizable: false)
            dupQuery[kSecReturnData as String] = true
            dupQuery[kSecMatchLimit as String] = kSecMatchLimitOne
            var dupResult: CFTypeRef?
            let dupStatus = SecItemCopyMatching(dupQuery as CFDictionary, &dupResult)
            guard dupStatus == errSecSuccess, let data = dupResult as? Data else {
                throw KeyRingError.keychain(dupStatus)
            }
            return data
        }
        guard addStatus == errSecSuccess else { throw KeyRingError.keychain(addStatus) }
        return fresh
    }

    public func generateMasterKey() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: Self.keySize)
        let status = SecRandomCopyBytes(kSecRandomDefault, Self.keySize, &bytes)
        guard status == errSecSuccess else { throw KeyRingError.keychain(status) }
        return Data(bytes)
    }
}
#endif
