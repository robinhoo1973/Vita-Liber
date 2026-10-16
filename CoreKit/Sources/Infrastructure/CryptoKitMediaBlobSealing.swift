#if os(iOS) || os(macOS)
// linux-blind: （平台守卫：CryptoKit 仅 Apple 平台链接（ERR#8 纪律），Linux 编译空单元，改动须经 macOS CI 验证）
import Foundation
import CryptoKit
import Protocols

/// 媒体 blob 加密封装生产实现（discussions/2026-10-16-local-storage-layout-council.md §8 切片 9）：
/// 媒体密钥 = HKDF-SHA256(masterKey, salt: "vlbm-media-v1")——与信封主密钥分离
/// （同步/分享通道复用同一密文包，密钥随信封加密段分发，媒体层不持有主密钥）。
/// 帧复用 BackupCrypto（分块 AES-256-GCM，自描述密文，防篡改由 AEAD 承担）。
/// 明文哈希语义不变：清单 sha256 = 明文原件哈希，加密不改清单哈希。
public struct CryptoKitMediaBlobSealing: MediaBlobSealing, Sendable {

    public static let salt = "vlbm-media-v1"
    public static let info = "vlbm-media-key"
    public static let keyByteCount = 32

    private let key: SymmetricKey

    public init(masterKey: Data) throws {
        guard masterKey.count == Self.keyByteCount else {
            throw MediaBlobSealingError.invalidKeySize(masterKey.count)
        }
        self.key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: masterKey),
            salt: Data(Self.salt.utf8),
            info: Data(Self.info.utf8),
            outputByteCount: Self.keyByteCount)
    }

    public func seal(_ plaintext: Data) throws -> Data {
        try BackupCrypto.seal(payload: plaintext, key: key)
    }

    public func open(_ sealed: Data) throws -> Data {
        try BackupCrypto.open(sealed, key: key)
    }
}
#endif
