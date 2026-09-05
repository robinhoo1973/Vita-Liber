// 平台守卫镜像 Package.swift（ERR#8 纪律）：CryptoKit 仅 Apple 平台链接。
#if os(iOS) || os(macOS)
import Foundation
import CryptoKit
import Protocols

/// ContentHashing 生产实现（ADR-025）：经审计的 CryptoKit.SHA256。
/// 替代原 Domain 自研 SHA-256 引擎——去重哈希/审计脱敏/库存哈希
/// 全部收敛到同一实现，消除「同一实体两条哈希链」的漂移风险。
public struct CryptoKitContentHasher: ContentHashing {
    public init() {}

    public func sha256Hex(_ data: Data) -> String {
        CryptoKit.SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
#endif
