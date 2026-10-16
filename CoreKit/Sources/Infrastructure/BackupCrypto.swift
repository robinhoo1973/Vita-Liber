#if os(iOS) || os(macOS)
// linux-blind: （平台守卫：CryptoKit 仅 Apple 平台链接（ERR#8 纪律），Linux 编译空单元，改动须经 macOS CI 验证）
import Foundation
import CryptoKit

/// 备份信封 v2 加密段（discussions/2026-10-16-backup-sync-share-design.md §8.5）：
/// payload 分块 AES-256-GCM（AEAD：机密 + 完整 + 防篡改；单算法单版本，禁降级）。
/// 分块格式：`[BE u32 chunkCount]` + 每块 `[BE u32 sealedLen + nonce(12B) + ciphertext+tag]`；
/// 每块 96-bit 随机 nonce（CryptoKit 生成），同密钥下不复用。空 payload = 0 块（合法）。
/// 主密钥经每设备子密钥包裹（wrapKey/unwrapKey），密钥层级见设计文档 §5.2。
public struct BackupCrypto: Sendable {

    public static let chunkSize = 4 << 20          // 4 MiB
    public static let maxChunks = 65536            // 上限 256 GiB，防损坏计数域爆炸
    public static let algorithmID: UInt8 = 0x01    // AES-256-GCM（单算法单版本）

    public enum CryptoError: Error, Sendable, Equatable {
        case malformed          // 帧结构违规——映射 unsupportedFormat/checksumMismatch 由调用方定
        case tamperOrKeyMismatch
        case tooManyChunks
    }

    /// 分块加密。返回自描述密文（块数 + 每块 nonce/密文内嵌，无需外部元数据）。
    public static func seal(payload: Data, key: SymmetricKey) throws -> Data {
        var out = Data()
        let chunks = payload.isEmpty ? 0 : (payload.count + chunkSize - 1) / chunkSize
        guard chunks <= maxChunks else { throw CryptoError.tooManyChunks }
        var count = UInt32(chunks).bigEndian
        withUnsafeBytes(of: &count) { out.append(contentsOf: $0) }
        var offset = 0
        for _ in 0..<chunks {
            let end = min(offset + chunkSize, payload.count)
            let chunk = payload[offset..<end]
            let nonce = try AES.GCM.Nonce()
            let sealed = try AES.GCM.seal(chunk, using: key, nonce: nonce)
            var len = UInt32(nonce.withUnsafeBytes { $0.count } + sealed.ciphertext.count + sealed.tag.count).bigEndian
            withUnsafeBytes(of: &len) { out.append(contentsOf: $0) }
            withUnsafeBytes(of: nonce) { out.append(contentsOf: $0) }          // 12B
            out.append(sealed.ciphertext)
            out.append(sealed.tag)
            offset = end
        }
        return out
    }

    /// 分块解密 + 认证。任何篡改/错钥/结构违规抛错，绝不返回部分明文。
    public static func open(_ data: Data, key: SymmetricKey) throws -> Data {
        guard data.count >= 4 else { throw CryptoError.malformed }
        let chunks = data.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.bigEndian
        guard chunks <= maxChunks else { throw CryptoError.tooManyChunks }
        var out = Data()
        var cursor = 4
        for _ in 0..<chunks {
            guard data.count - cursor >= 4 else { throw CryptoError.malformed }
            let len = data[cursor..<cursor + 4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.bigEndian
            cursor += 4
            guard data.count - cursor >= Int(len), len > 12 + 16 else { throw CryptoError.malformed }
            let block = data[cursor..<cursor + Int(len)]
            let nonceData = block.prefix(12)
            let sealedBytes = block.dropFirst(12)
            let sealedBox = try AES.GCM.SealedBox(combined: sealedBytes)
            guard let nonce = try? AES.GCM.Nonce(data: nonceData) else { throw CryptoError.malformed }
            do {
                let plain = try AES.GCM.open(sealedBox, using: key, nonce: nonce)
                out.append(plain)
            } catch {
                throw CryptoError.tamperOrKeyMismatch
            }
            cursor += Int(len)
        }
        guard cursor == data.count else { throw CryptoError.malformed }
        return out
    }

    /// 主密钥经每设备子密钥包裹（`[nonce 12B + ciphertext+tag]`）——信封自足，钥匙串重置可经恢复码段自愈。
    public static func wrapKey(_ key: SymmetricKey, using wrappingKey: SymmetricKey) throws -> Data {
        let nonce = try AES.GCM.Nonce()
        let sealed = try AES.GCM.seal(key.withUnsafeBytes { Data($0) }, using: wrappingKey, nonce: nonce)
        var out = Data()
        withUnsafeBytes(of: nonce) { out.append(contentsOf: $0) }
        out.append(sealed.ciphertext)
        out.append(sealed.tag)
        return out
    }

    public static func unwrapKey(_ wrapped: Data, using wrappingKey: SymmetricKey) throws -> SymmetricKey {
        guard wrapped.count > 12 + 16, let nonce = try? AES.GCM.Nonce(data: wrapped.prefix(12)) else {
            throw CryptoError.malformed
        }
        let sealedBox = try AES.GCM.SealedBox(combined: wrapped.dropFirst(12))
        do {
            let keyData = try AES.GCM.open(sealedBox, using: wrappingKey, nonce: nonce)
            return SymmetricKey(data: keyData)
        } catch {
            throw CryptoError.tamperOrKeyMismatch
        }
    }
}
#endif
