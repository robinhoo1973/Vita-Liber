#if os(iOS) || os(macOS)
// linux-blind: （平台守卫：CryptoKit 仅 Apple 平台链接（ERR#8 纪律），Linux 编译空单元，改动须经 macOS CI 验证）
import Foundation
import CryptoKit
import Domain

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
            // 评审修复（编译错误 + 语义错双修）：块布局 = nonce(12) + ciphertext + tag(16)。
            // 原实现 dropFirst(12) 后交给 SealedBox(combined:)——该初始化器期望 nonce 打头，
            // 误把密文前 12B 当 nonce；且 AES.GCM.open(_:using:nonce:) 重载不存在
            // （Apple 平台编译失败）。按显式 (nonce, ciphertext, tag) 三段构造。
            guard let nonce = try? AES.GCM.Nonce(data: nonceData) else { throw CryptoError.malformed }   // try?-ok: 帧字节攻击者可控，nonce 非法即按 malformed 拒绝
            do {
                let sealedBox = try AES.GCM.SealedBox(nonce: nonce,
                                                      ciphertext: block.dropFirst(12).dropLast(16),
                                                      tag: block.suffix(16))
                let plain = try AES.GCM.open(sealedBox, using: key)
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
        guard wrapped.count > 12 + 16, let nonce = try? AES.GCM.Nonce(data: wrapped.prefix(12)) else {   // try?-ok: 包裹段字节攻击者可控，nonce 非法即按 malformed 拒绝
            throw CryptoError.malformed
        }
        do {
            // 同 open(块) 修复：包裹布局为 nonce(12) + ciphertext + tag(16)——显式三段构造，
            // combined 期望 nonce 打头（dropFirst(12) 后的字节交给 combined 会误析 nonce）。
            let sealedBox = try AES.GCM.SealedBox(nonce: nonce,
                                                  ciphertext: wrapped.dropFirst(12).dropLast(16),
                                                  tag: wrapped.suffix(16))
            let keyData = try AES.GCM.open(sealedBox, using: wrappingKey)
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
        /// 解封后的主密钥（Data 形态——SymmetricKey 无 Equatable 且不脱帧传播）；
        /// 媒体载具解密依赖（媒体密钥 = HKDF-SHA256(masterKey,"vlbm-media-v1")，
        /// local-storage-layout-council 切片 12）。仅随帧打开时可得。
        public var masterKey: Data
    }

    /// v2 帧头解析产物（不含明文；openFrame/openWithRecoveryCode/peekRealmId 共用）。
    struct V2Frame {
        var realmId: UUID
        var keyRef: UUID
        var wrappedKey: Data
        var recoveryWrapped: Data?
        var aadHash: String
        var ciphertext: Data
    }

    /// v2 帧结构解析（评审修复：openFrame/openWithRecoveryCode 曾各自内联一份近同解析——
    /// 提取单点，结构违规一律 malformed）。ciphertextLen 以 UInt64 显式钳位到 Int——
    /// 原实现裸 `Int(loadUnaligned(UInt64))`（EnvelopeFrame.parseBinary 有同款守卫，
    /// 此处曾缺）：畸形帧高位非零时 Int(_:) 陷阱（不可恢复崩溃，而非拒绝导入）。
    static func parseV2Frame(_ data: Data) throws -> V2Frame {
        let magicLen = EnvelopeFrame.binaryMagic.count
        guard data.count >= magicLen + 2, data[magicLen] == 2, data[magicLen + 1] == algorithmID else {
            throw CryptoError.malformed
        }
        let algEnd = magicLen + 2
        let realmEnd = algEnd + 16
        let keyRefEnd = realmEnd + 16
        let lenEnd = keyRefEnd + 2
        guard data.count > lenEnd else { throw CryptoError.malformed }
        let wrappedLen = Int(data[keyRefEnd..<lenEnd].withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }.bigEndian)
        let wrappedEnd = lenEnd + wrappedLen
        let recLenEnd = wrappedEnd + 2
        guard data.count > recLenEnd else { throw CryptoError.malformed }
        let recLen = Int(data[wrappedEnd..<recLenEnd].withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }.bigEndian)
        let recEnd = recLenEnd + recLen
        let aadEnd = recEnd + 64
        let ctLenEnd = aadEnd + 8
        guard data.count > ctLenEnd else { throw CryptoError.malformed }
        let rawCiphertextLen = data[aadEnd..<ctLenEnd].withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }.bigEndian
        guard rawCiphertextLen <= UInt64(Int.max), rawCiphertextLen == UInt64(data.count - ctLenEnd) else {
            throw CryptoError.malformed
        }
        return V2Frame(
            realmId: UUID(uuid: data[algEnd..<realmEnd].withUnsafeBytes { $0.loadUnaligned(as: uuid_t.self) }),
            keyRef: UUID(uuid: data[realmEnd..<keyRefEnd].withUnsafeBytes { $0.loadUnaligned(as: uuid_t.self) }),
            wrappedKey: Data(data[lenEnd..<wrappedEnd]),
            recoveryWrapped: recLen > 0 ? Data(data[recLenEnd..<recEnd]) : nil,
            aadHash: String(data: data[recEnd..<aadEnd], encoding: .ascii) ?? "",
            ciphertext: Data(data[ctLenEnd...]))
    }

    public static func openFrame(_ data: Data, unwrapWith wrappingKey: SymmetricKey) throws -> OpenedFrame {
        let frame = try parseV2Frame(data)
        let master = try unwrapKey(frame.wrappedKey, using: wrappingKey)
        return try openFrame(frame, master: master)
    }

    /// 主密钥直供解封（跨设备主路径，design §5.2：主密钥为可同步钥匙串项——
    /// 设备子密钥不可达但同域主密钥可取回时，直接解帧，无需恢复码）。
    public static func openFrame(_ data: Data, masterKey: SymmetricKey) throws -> OpenedFrame {
        try openFrame(try parseV2Frame(data), master: masterKey)
    }

    /// 帧头轻读：只取 realmId（零解密）——调用方据此选择「可同步主密钥」重试路径。
    /// 结构不符返回 nil（探测失败=走既有回退链，不抛错）。
    public static func peekRealmId(_ data: Data) -> UUID? {
        (try? parseV2Frame(data))?.realmId   // try?-ok: 探测语义——解析失败=nil，调用方回退恢复码链
    }

    /// 已解析帧 + 主密钥 → 打开（openFrame 两条公开入口的单点实现）
    static func openFrame(_ frame: V2Frame, master: SymmetricKey) throws -> OpenedFrame {
        let payload = try open(frame.ciphertext, key: master)
        guard sha256Hex(payload) == frame.aadHash else { throw CryptoError.tamperOrKeyMismatch }
        return OpenedFrame(payload: payload, realmId: frame.realmId, keyRef: frame.keyRef,
                           aadHash: frame.aadHash, recoveryWrapped: frame.recoveryWrapped,
                           masterKey: master.withUnsafeBytes { Data($0) })
    }

    /// 恢复码 → KEK（HKDF-SHA256；salt = realmId 字节，域隔离——同一恢复码不跨同步域通用）。
    /// 恢复码不落任何存储（零知识）：包裹段 + 恢复码现场派生才可得主密钥。
    /// 评审修复：派生前归一化输入（大小写/分隔符）——签发链路同一函数派生（generate 产物
    /// 归一化=恒等），手抄路径的大小写/空格不再静默产出不同 KEK（码正确却报码错）。
    public static func recoveryKEK(code: String, realmId: UUID) -> SymmetricKey {
        var salt = Data()
        withUnsafeBytes(of: realmId.uuid) { salt.append(contentsOf: $0) }
        let info = Data("vitaliber-recovery-v1".utf8)
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(RecoveryCode.normalize(code).utf8)),
                                      salt: salt, info: info, outputByteCount: 32)
    }

    /// 恢复码解封主密钥（设备子密钥不可达的逃生舱路径；码错 → tamperOrKeyMismatch）。
    public static func openWithRecoveryCode(_ data: Data, code: String) throws -> OpenedFrame {
        let frame = try parseV2Frame(data)
        guard let recoveryWrapped = frame.recoveryWrapped else { throw CryptoError.malformed }
        let kek = recoveryKEK(code: code, realmId: frame.realmId)
        let master = try unwrapKey(recoveryWrapped, using: kek)
        return try openFrame(frame, master: master)
    }

    static func sha256Hex(_ data: Data) -> String {
        // 收敛到 ContentHashing 单实现（与 BackupService.sha256 同款纪律：全仓哈希不再各自内联）
        CryptoKitContentHasher().sha256Hex(data)
    }
}
#endif
