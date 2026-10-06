#if os(iOS) || os(macOS)
// linux-blind: CryptoKit 仅 Apple 平台链接（ERR#8 纪律镜像）—— Linux 型检编译空单元，改动须经 macOS CI 验证
import CryptoKit
import Foundation

/// 包加密信封「aes256gcm-v1」的**中性共享核心**（2026-10-07 模块化抽取）。
///
/// 背景与消费者：
/// - **ASR 下载包**（既有）：`ASRPackageCrypto` 为 façade——保留 ASR 主密钥
///   常量、身份文法与公开签名不变（含 Python 工具链对其源码 `masterKeyHex`
///   字面量的正则抓取契约）。
/// - **医疗目录包**（迁移中）：AgeKit 弃用后按业主裁定复用本方案；调用方经
///   `namespace` 参数声明加密域（ASR 用 `vitaliber/asr/aes256gcm/v1`；医疗域
///   前缀待生产端字节合同共同裁决后落定，见 discussions）。
///
/// 帧格式（与 `scripts/release/asr_envelope.py` 正本逐字节对齐）：
/// 头 = magic "VLASR\x01"(6) + u8 version + u32 BE chunk_size + u64 BE
/// plaintext_size + u32 BE chunk_count；每块 = u32 BE cipher_len + (ct + tag16)
/// ——nonce 由块序号经 HKDF 派生，**不入帧**。key/nonce 由 HKDF-SHA256 自主
/// 密钥与包身份派生：同内容同信封字节（哈希比对与 reuse 缓存成立）；不同
/// 内容必须不同身份（否则同密钥同 nonce 序列加密不同明文 = nonce 重放灾难
/// ——身份文法必须把「同版本换内容」编码进去，ASR 先例 = artifactRevision）。
///
/// HKDF 为 RFC 5869 手动展开（成熟实现优先的已记录例外）：CryptoKit 的
/// `HKDF.deriveKey` 泛型糖在 macOS CI 两轮实证过载解析失败，本文件平台守卫下
/// Linux 零编译信号无法本地迭代——手写只用 HMAC 原语，与 python 侧
/// `HKDF(salt=None)` 逐字节同构（缺省盐 = HashLen 个 0x00）。金样
/// `ASREnvelopeGoldenTests` 在 macOS CI 钉死与 python 信封的字节一致。
enum PackageEnvelopeCrypto {
    enum Failure: Error {
        case malformedEnvelope
        case authenticationFailed
        case sizeMismatch
    }

    private static let magicBytes: [UInt8] = [0x56, 0x4C, 0x41, 0x53, 0x52, 0x01] // "VLASR\x01"
    private static let headerSize = 6 + 1 + 4 + 8 + 4
    private static let tagSize = 16
    private static let nonceSize = 12
    private static let maxChunkSize: UInt32 = 256 * 1024 * 1024
    private static let maxChunkCount: UInt32 = 512

    static func isEnvelope(_ data: Data) -> Bool {
        data.prefix(magicBytes.count).elementsEqual(magicBytes)
    }

    /// 64-hex 主密钥 → SymmetricKey（长度必须恰为 32 字节）。
    static func decodeHexKey(_ hex: String) throws -> SymmetricKey {
        var bytes = [UInt8]()
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let value = UInt8(hex[index..<next], radix: 16) else { throw Failure.malformedEnvelope }
            bytes.append(value)
            index = next
        }
        guard bytes.count == 32 else { throw Failure.malformedEnvelope }
        return SymmetricKey(data: bytes)
    }

    private static func beUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16
            | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
    }

    private static func beUInt64(_ bytes: [UInt8], at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for i in 0..<8 { value = (value << 8) | UInt64(bytes[offset + i]) }
        return value
    }

    private static func beUInt32Bytes(_ value: UInt32) -> Data {
        Data([UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
              UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)])
    }

    private static func derivedKey(master: SymmetricKey, namespace: String, identity: String) -> SymmetricKey {
        SymmetricKey(data: hkdfSHA256(master: master, salt: [],
                                      info: Data("\(namespace)/key/\(identity)".utf8),
                                      length: 32))
    }

    private static func nonceData(master: SymmetricKey, namespace: String, identity: String,
                                  index: UInt32) throws -> AES.GCM.Nonce {
        let nonceBytes = hkdfSHA256(master: master, salt: [],
                                    info: Data("\(namespace)/nonce/\(identity)/\(index)".utf8),
                                    length: nonceSize)
        return try AES.GCM.Nonce(data: nonceBytes)
    }

    private static func hkdfSHA256(master: SymmetricKey, salt: [UInt8], info: Data, length: Int) -> Data {
        let hashLength = SHA256.Digest.byteCount
        let effectiveSalt = salt.isEmpty ? [UInt8](repeating: 0, count: hashLength) : salt
        var masterBytes = [UInt8]()
        master.withUnsafeBytes { masterBytes.append(contentsOf: $0) }
        let prk = HMAC<SHA256>.authenticationCode(for: Data(masterBytes),
                                                  using: SymmetricKey(data: effectiveSalt))
        let prkData = Data(bytes: prk.withUnsafeBytes { Array($0) })
        var output = Data()
        var previous = Data()
        var counter: UInt8 = 1
        while output.count < length {
            var block = previous
            block.append(info)
            block.append(counter)
            let code = HMAC<SHA256>.authenticationCode(for: block, using: SymmetricKey(data: prkData))
            previous = Data(bytes: code.withUnsafeBytes { Array($0) })
            output.append(previous)
            counter &+= 1
        }
        return output.prefix(length)
    }

    /// 信封解密：块式 AES-GCM（每块 ≤ chunkSize，流式落盘，内存有界）。
    /// 调用方须先完成包字节的签名/sha256 校验；本层只做「信封 → 明文 zip」。
    /// - namespace：加密域（info 前缀，如 `vitaliber/asr/aes256gcm/v1`）——
    ///   左右两侧（生产端与消费端）必须逐字节同一值。
    static func decryptEnvelope(at source: URL, to destination: URL, identity: String,
                                namespace: String, masterKey: SymmetricKey,
                                onProgress: (@Sendable (Int64, Int64) -> Void)? = nil) throws {
        let key = derivedKey(master: masterKey, namespace: namespace, identity: identity)
        let reader = try FileHandle(forReadingFrom: source)
        defer { try? reader.close() }   // try?-ok: 只读句柄关闭失败由系统回收

        var headerBytes = [UInt8]()
        headerBytes.reserveCapacity(headerSize)
        while headerBytes.count < headerSize {
            guard let chunk = try reader.read(upToCount: headerSize - headerBytes.count), !chunk.isEmpty else {
                throw Failure.malformedEnvelope
            }
            headerBytes.append(contentsOf: chunk)
        }
        guard Array(headerBytes.prefix(magicBytes.count)) == magicBytes,
              headerBytes[magicBytes.count] == 1 else { throw Failure.malformedEnvelope }
        let chunkSize = beUInt32(headerBytes, at: 7)
        let plaintextSize = beUInt64(headerBytes, at: 11)
        let chunkCount = beUInt32(headerBytes, at: 19)
        guard chunkSize > 0, chunkSize <= maxChunkSize,
              chunkCount > 0, chunkCount <= maxChunkCount else { throw Failure.malformedEnvelope }
        let header = Data(headerBytes)

        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw Failure.sizeMismatch
        }
        let writer = try FileHandle(forWritingTo: destination)
        defer { try? writer.close() }   // try?-ok: 解压临时文件句柄关闭

        var total: Int64 = 0
        for index in UInt32(0)..<chunkCount {
            try Task.checkCancellation()
            guard let frame = try reader.read(upToCount: 4), frame.count == 4 else {
                throw Failure.malformedEnvelope
            }
            let cipherLength = beUInt32(Array(frame), at: 0)
            // 帧内只有 ct+tag(nonce 不入帧)——上界 = chunkSize + tagSize。
            guard cipherLength >= 1, UInt64(cipherLength) <= UInt64(chunkSize) + UInt64(tagSize),
                  let ciphertext = try reader.read(upToCount: Int(cipherLength)),
                  ciphertext.count == Int(cipherLength) else { throw Failure.malformedEnvelope }
            let nonce = try nonceData(master: masterKey, namespace: namespace, identity: identity, index: index)
            let aad = header + beUInt32Bytes(index)
            let tag = ciphertext.suffix(tagSize)
            let sealed = try AES.GCM.SealedBox(nonce: nonce,
                                               ciphertext: ciphertext.dropLast(tagSize),
                                               tag: tag)
            let plain: Data
            do {
                plain = try AES.GCM.open(sealed, using: key, authenticating: aad)
            } catch {
                throw Failure.authenticationFailed
            }
            try writer.write(contentsOf: plain)
            total += Int64(plain.count)
            onProgress?(total, Int64(plaintextSize))
        }
        if let trailing = try reader.read(upToCount: 1), !trailing.isEmpty {
            throw Failure.malformedEnvelope
        }
        guard total == Int64(plaintextSize) else { throw Failure.sizeMismatch }
    }
}
#endif
