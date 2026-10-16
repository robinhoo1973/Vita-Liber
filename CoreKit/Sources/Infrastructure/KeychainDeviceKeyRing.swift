#if os(iOS) || os(macOS)
// linux-blind: （平台守卫：Security/Keychain 仅 Apple 平台，Linux 编译空单元，改动须经 macOS CI 验证）
import Foundation
import Security
import Domain
import Protocols

/// Keychain 设备密钥环实现（discussions/2026-10-16-backup-sync-share-design.md §5.2）：
/// 主密钥 kSecAttrSynchronizable=true（跨设备主路径；E2EE 可信设备圈——Apple 平台安全指南口径）、
/// 子密钥 ThisDeviceOnly（默认不同步）、恢复码包裹段 synchronizable（信封自足语义：
/// 任一设备封装的帧都须带可恢复段，否则跨设备帧恢复码失效——评审修复见 storeRecoveryWrapped）；
/// 服务名单一常量、账号含 realmId（多同步域隔离）。
public struct KeychainDeviceKeyRing: DeviceKeyRing, Sendable {

    private static let service = "com.vitaliber.backup.keys"
    private static let keySize = 32

    public init() {}

    private func baseQuery(_ account: String, synchronizable: Bool, accessible: CFString?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
        ]
        // 显式保护类（安全席 T2b：默认 WhenUnlocked 依赖隐式行为，显式声明防止静默漂移）：
        // 同步主钥仅兼容 WhenUnlocked；本机密钥收窄为 WhenUnlockedThisDeviceOnly。
        // nil = 旧形态回落查询（评审修复）：kSecAttrAccessible 参与查询匹配，带属性会漏掉
        // 无该属性的历史写入（dc87cfb8 期默认 WhenUnlocked）——只有省略才一次覆盖全部旧形态。
        if let accessible {
            query[kSecAttrAccessible as String] = accessible
        }
        if synchronizable {
            query[kSecAttrSynchronizable as String] = kCFBooleanTrue!
        }
        return query
    }

    private static let masterAccessible = kSecAttrAccessibleWhenUnlocked
    private static let deviceAccessible = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

    public func masterKey(realmId: UUID) async throws -> Data? {
        var query = baseQuery("master.\(realmId.uuidString)", synchronizable: true, accessible: Self.masterAccessible)
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
        var query = baseQuery("master.\(realmId.uuidString)", synchronizable: true, accessible: Self.masterAccessible)
        query[kSecValueData as String] = key
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        if addStatus == errSecDuplicateItem {
            // 已存在 → 覆盖（幂等注册；同一 realm 换钥经显式调用，审计由上层承担）
            let update: [String: Any] = [kSecValueData as String: key]
            let updateStatus = SecItemUpdate(baseQuery("master.\(realmId.uuidString)", synchronizable: true, accessible: Self.masterAccessible) as CFDictionary,
                                             update as CFDictionary)
            guard updateStatus == errSecSuccess else { throw KeyRingError.keychain(updateStatus) }
        } else if addStatus != errSecSuccess {
            throw KeyRingError.keychain(addStatus)
        }
    }

    public func deviceSubKey() async throws -> Data {
        let account = "device-sub"
        var readQuery = baseQuery(account, synchronizable: false, accessible: Self.deviceAccessible)
        readQuery[kSecReturnData as String] = true
        readQuery[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let readStatus = SecItemCopyMatching(readQuery as CFDictionary, &result)
        if readStatus == errSecSuccess, let data = result as? Data, data.count == Self.keySize {
            return data
        }
        // 旧形态回落（评审修复，举一反三）：dc87cfb8 期写入无保护类属性（默认
        // WhenUnlocked），带 ThisDeviceOnly 的查询对其恒 notFound——不回落则按
        // 「无钥」生成新钥，Add 撞 duplicate、dupQuery 同样不可见 → 恒抛
        // KeyRingError（备份/同步不可自愈）。只读回落不搬迁：旧项继续可读，
        // 无后续写路径需要覆盖它（与 recoveryWrapped 回落同纪律）。
        var legacyQuery = baseQuery(account, synchronizable: false, accessible: nil)
        legacyQuery[kSecReturnData as String] = true
        legacyQuery[kSecMatchLimit as String] = kSecMatchLimitOne
        var legacyResult: CFTypeRef?
        let legacyStatus = SecItemCopyMatching(legacyQuery as CFDictionary, &legacyResult)
        if legacyStatus == errSecSuccess, let data = legacyResult as? Data, data.count == Self.keySize {
            return data
        }
        // 无/尺寸不符 → 生成并持久化（ThisDeviceOnly：不同步、不随备份迁移）
        let fresh = try generateMasterKey()
        var addQuery = baseQuery(account, synchronizable: false, accessible: Self.deviceAccessible)
        addQuery[kSecValueData as String] = fresh
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecDuplicateItem {
            // 重读同样省略保护类过滤：撞重项可能是旧形态（并发首调窗口内新落项
            // 均为 ThisDeviceOnly，两形态都要能命中）。
            var dupQuery = baseQuery(account, synchronizable: false, accessible: nil)
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

    public func storeRecoveryWrapped(_ wrapped: Data, realmId: UUID) async throws {
        // 评审修复（信封自足闭环）：此前本项 ThisDeviceOnly——同 iCloud 账户的第二台设备
        // 主密钥经同步在位、包裹段缺失，其封装出的帧 recoveryWrapped=0 段，钥匙串重置后
        // 用户持正确恢复码也打不开本设备产出的备份（BackupCrypto.openWithRecoveryCode
        // 拒收无段帧）。包裹段随 iCloud Keychain 同步：包裹体非 PHI，解包须用户码原文
        // （150bit 熵），且主密钥本身已 synchronizable——同信任边界，零边际暴露。
        let account = "recovery.\(realmId.uuidString)"
        var query = baseQuery(account, synchronizable: true, accessible: Self.masterAccessible)
        query[kSecValueData as String] = wrapped
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        if addStatus == errSecDuplicateItem {
            let update: [String: Any] = [kSecValueData as String: wrapped]
            let updateStatus = SecItemUpdate(baseQuery(account, synchronizable: true, accessible: Self.masterAccessible) as CFDictionary,
                                             update as CFDictionary)
            if updateStatus == errSecItemNotFound {
                // 评审修复（升级迁移）：同名旧项以非同步形态存在（a6b4b7c4 切换同步形态前
                // 的写入：dc87cfb8..1d82bed0 无保护类属性=默认 WhenUnlocked、
                // 1d82bed0..a6b4b7c4 显式 ThisDeviceOnly）——非 Any 的同步查询对其不可见，
                // Add 撞 duplicate、Update 报 notFound，此前直接抛出=「创建备份」恒失败。
                // 删除查询省略 kSecAttrAccessible（评审修复）：带 ThisDeviceOnly 查不到
                // 默认保护类的 dc87cfb8 期旧项——删除 notFound 后重试 Add 再撞 duplicate，
                // 迁移对最老形态仍恒失败。
                // 先删旧形态再落同步项；delete→add 之间失败由上层补发自愈
                //（主密钥在、包裹段缺 → createBackup 补发新码）。
                let legacyDelete = SecItemDelete(baseQuery(account, synchronizable: false,
                                                           accessible: nil) as CFDictionary)
                guard legacyDelete == errSecSuccess || legacyDelete == errSecItemNotFound else {
                    throw KeyRingError.keychain(legacyDelete)
                }
                let retryStatus = SecItemAdd(query as CFDictionary, nil)
                guard retryStatus == errSecSuccess else { throw KeyRingError.keychain(retryStatus) }
            } else if updateStatus != errSecSuccess {
                throw KeyRingError.keychain(updateStatus)
            }
        } else if addStatus != errSecSuccess {
            throw KeyRingError.keychain(addStatus)
        }
    }

    public func recoveryWrapped(realmId: UUID) async throws -> Data? {
        var query = baseQuery("recovery.\(realmId.uuidString)", synchronizable: true, accessible: Self.masterAccessible)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            // 评审修复（迁移可见性）：旧版本以非同步形态写下的包裹段对新同步
            // 查询恒 notFound——只读回落旧属性查询（不搬迁：搬迁归 storeRecoveryWrapped
            // 的写路径，读路径保持无副作用）。旧码因此继续对新帧有效。
            // 省略 kSecAttrAccessible（评审修复）：该属性参与匹配，带 ThisDeviceOnly 会
            // 漏掉 dc87cfb8 期无属性旧项（默认 WhenUnlocked）——回落查询恒 notFound、
            // 旧码静默死亡；省略后同一次查询覆盖两种旧形态。
            let legacy = baseQuery("recovery.\(realmId.uuidString)", synchronizable: false,
                                   accessible: nil)
            var legacyQuery = legacy
            legacyQuery[kSecReturnData as String] = true
            legacyQuery[kSecMatchLimit as String] = kSecMatchLimitOne
            var legacyResult: CFTypeRef?
            let legacyStatus = SecItemCopyMatching(legacyQuery as CFDictionary, &legacyResult)
            if legacyStatus == errSecItemNotFound { return nil }
            guard legacyStatus == errSecSuccess, let data = legacyResult as? Data else {
                throw KeyRingError.keychain(legacyStatus)
            }
            return data
        }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeyRingError.keychain(status)
        }
        return data
    }
}
#endif
