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

    // MARK: - v2 加密信封帧（外层格式版本 2，discussions/2026-10-16-backup-sync-share-design.md §8.5）
    // 帧布局：[magic VLBU1][2][alg(1B)][realmId(16B)][keyRef(16B)][wrappedKeyLen(BE u16)][wrappedKey]
    //         [recWrappedLen(BE u16, 0=无)][recoveryWrapped?][aadHashHex(64B)][ciphertextLen(BE u64)][ciphertext]
    // aadHash = sha256(明文 payload) hex——备份报告/清单哈希语义延续（加密不改清单哈希纪律）；
    // AEAD 提供机密+完整+防篡改，aadHash 供报告口径与双保险核对。
    // recoveryWrapped = 主密钥经恢复码派生 KEK 包裹（信封自足——设备子密钥不可达时经恢复码解封，钥匙串重置可自愈）。

    public static func sealFrame(payload: Data, masterKey: SymmetricKey,
                                 wrappingKey: SymmetricKey, keyRef: UUID,
                                 realmId: UUID, recoveryWrapped: Data? = nil) throws -> Data {
        let wrappedKey = try wrapKey(masterKey, using: wrappingKey)
        let aadHash = sha256Hex(payload)
        let ciphertext = try seal(payload: payload, key: masterKey)
        var out = Data(EnvelopeFrame.binaryMagic)
        out.append(contentsOf: [2, algorithmID])
        withUnsafeBytes(of: realmId.uuid) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: keyRef.uuid) { out.append(contentsOf: $0) }
        var wrappedLen = UInt16(wrappedKey.count).bigEndian
        withUnsafeBytes(of: &wrappedLen) { out.append(contentsOf: $0) }
        out.append(wrappedKey)
        var recLen = UInt16(recoveryWrapped?.count ?? 0).bigEndian
        withUnsafeBytes(of: &recLen) { out.append(contentsOf: $0) }
        if let recoveryWrapped { out.append(recoveryWrapped) }
        out.append(contentsOf: aadHash.utf8)
        var ctLen = UInt64(ciphertext.count).bigEndian
        withUnsafeBytes(of: &ctLen) { out.append(contentsOf: $0) }
        out.append(ciphertext)
        return out
    }

    public struct OpenedFrame: Sendable, Equatable {
        public var payload: Data
        public var realmId: UUID
        public var keyRef: UUID
        public var aadHash: String
        public var recoveryWrapped: Data?
    }

    public static func openFrame(_ data: Data, unwrapWith wrappingKey: SymmetricKey) throws -> OpenedFrame {
        let magicLen = EnvelopeFrame.binaryMagic.count
        guard data.count > magicLen + 1, data[magicLen] == 2, data[magicLen + 1] == algorithmID else {
            throw CryptoError.malformed
        }
        let algEnd = magicLen + 2
        let realmEnd = algEnd + 16
        let keyRefEnd = realmEnd + 16
        let lenEnd = keyRefEnd + 2
        guard data.count > lenEnd else { throw CryptoError.malformed }
        let realmBytes = data[algEnd..<realmEnd]
        let keyRefBytes = data[realmEnd..<keyRefEnd]
        let wrappedLen = Int(data[keyRefEnd..<lenEnd].withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }.bigEndian)
        let wrappedEnd = lenEnd + wrappedLen
        let recLenEnd = wrappedEnd + 2
        guard data.count > recLenEnd else { throw CryptoError.malformed }
        let recLen = Int(data[wrappedEnd..<recLenEnd].withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }.bigEndian)
        let recEnd = recLenEnd + recLen
        let aadEnd = recEnd + 64
        let ctLenEnd = aadEnd + 8
        guard data.count > ctLenEnd else { throw CryptoError.malformed }
        let wrappedKey = data[lenEnd..<wrappedEnd]
        let recoveryWrapped: Data? = recLen > 0 ? Data(data[recLenEnd..<recEnd]) : nil
        let aadHash = String(data: data[recEnd..<aadEnd], encoding: .ascii) ?? ""
        let ciphertextLen = Int(data[aadEnd..<ctLenEnd].withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }.bigEndian)
        guard ciphertextLen <= data.count - ctLenEnd, data.count - ctLenEnd == ciphertextLen else {
            throw CryptoError.malformed
        }
        let ciphertext = data[ctLenEnd...]
        let master = try unwrapKey(Data(wrappedKey), using: wrappingKey)
        let payload = try open(Data(ciphertext), key: master)
        guard sha256Hex(payload) == aadHash else { throw CryptoError.tamperOrKeyMismatch }
        return OpenedFrame(payload: payload,
                           realmId: UUID(uuid: realmBytes.withUnsafeBytes { $0.loadUnaligned(as: uuid_t.self) }),
                           keyRef: UUID(uuid: keyRefBytes.withUnsafeBytes { $0.loadUnaligned(as: uuid_t.self) }),
                           aadHash: aadHash, recoveryWrapped: recoveryWrapped)
    }

    /// 恢复码 → KEK（HKDF-SHA256；salt = realmId 字节，域隔离——同一恢复码不跨同步域通用）。
    /// 恢复码不落任何存储（零知识）：包裹段 + 恢复码现场派生才可得主密钥。
    public static func recoveryKEK(code: String, realmId: UUID) -> SymmetricKey {
        var salt = Data()
        withUnsafeBytes(of: realmId.uuid) { salt.append(contentsOf: $0) }
        let info = Data("vitaliber-recovery-v1".utf8)
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(code.utf8)),
                                      salt: salt, info: info, outputByteCount: 32)
    }

    /// 恢复码解封主密钥（设备子密钥不可达的逃生舱路径；码错 → tamperOrKeyMismatch）。
    public static func openWithRecoveryCode(_ data: Data, code: String) throws -> OpenedFrame {
        // 先解析帧拿 realmId 与恢复包裹段（本步无需任何密钥）
        let magicLen = EnvelopeFrame.binaryMagic.count
        guard data.count > magicLen + 1, data[magicLen] == 2, data[magicLen + 1] == algorithmID else {
            throw CryptoError.malformed
        }
        let algEnd = magicLen + 2
        let realmEnd = algEnd + 16
        let keyRefEnd = realmEnd + 16
        let lenEnd = keyRefEnd + 2
        guard data.count > lenEnd else { throw CryptoError.malformed }
        let realmBytes = data[algEnd..<realmEnd]
        let keyRefBytes = data[realmEnd..<keyRefEnd]
        let wrappedLen = Int(data[keyRefEnd..<lenEnd].withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }.bigEndian)
        let wrappedEnd = lenEnd + wrappedLen
        let recLenEnd = wrappedEnd + 2
        guard data.count > recLenEnd else { throw CryptoError.malformed }
        let recLen = Int(data[wrappedEnd..<recLenEnd].withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }.bigEndian)
        guard recLen > 0, data.count > recLenEnd + recLen else { throw CryptoError.malformed }
        let recEnd = recLenEnd + recLen
        let aadEnd = recEnd + 64
        let ctLenEnd = aadEnd + 8
        guard data.count > ctLenEnd else { throw CryptoError.malformed }
        let realmId = UUID(uuid: realmBytes.withUnsafeBytes { $0.loadUnaligned(as: uuid_t.self) })
        let keyRef = UUID(uuid: keyRefBytes.withUnsafeBytes { $0.loadUnaligned(as: uuid_t.self) })
        let aadHash = String(data: data[recEnd..<aadEnd], encoding: .ascii) ?? ""
        let ciphertextLen = Int(data[aadEnd..<ctLenEnd].withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }.bigEndian)
        guard ciphertextLen <= data.count - ctLenEnd, data.count - ctLenEnd == ciphertextLen else {
            throw CryptoError.malformed
        }
        let kek = recoveryKEK(code: code, realmId: realmId)
        let master = try unwrapKey(Data(data[recLenEnd..<recEnd]), using: kek)
        let payload = try open(Data(data[ctLenEnd...]), key: master)
        guard sha256Hex(payload) == aadHash else { throw CryptoError.tamperOrKeyMismatch }
        return OpenedFrame(payload: payload, realmId: realmId, keyRef: keyRef,
                           aadHash: aadHash, recoveryWrapped: Data(data[recLenEnd..<recEnd]))
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
#endif
