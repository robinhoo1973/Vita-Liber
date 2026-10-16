import Foundation

/// 媒体 blob 加密封装端口（discussions/2026-10-16-local-storage-layout-council.md §8 切片 9）：
/// 载具内 blob 先加密后入包（G7 断链的注入点）；密钥由媒体密钥派生
/// （HKDF-SHA256(masterKey, salt: "vlbm-media-v1")，见 CryptoKitMediaBlobSealing），
/// 同步/分享通道复用同一密文包。明文哈希语义不变：清单 sha256 = 明文原件哈希。
public protocol MediaBlobSealing: Sendable {

    /// 加密明文 blob → 自描述密文（分块 AES-256-GCM，BackupCrypto 帧复用）。
    /// 任何篡改/错钥在 open 侧抛错，绝不返回部分明文。
    func seal(_ plaintext: Data) throws -> Data

    /// 解密 + 认证。篡改/错钥/结构违规抛错。
    func open(_ sealed: Data) throws -> Data
}

/// 媒体密钥派生错误（端口层语义）。
public enum MediaBlobSealingError: Error, Sendable, Equatable {
    case invalidKeySize(Int)   // 主密钥非 32 字节——HKDF 派生前拒绝
}
