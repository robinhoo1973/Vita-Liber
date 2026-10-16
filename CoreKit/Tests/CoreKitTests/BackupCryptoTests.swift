import Foundation
import Testing
#if os(iOS) || os(macOS)
// linux-blind: （平台守卫：CryptoKit 仅 Apple 平台链接，本套件仅 macOS CI 执行）
import CryptoKit
@testable import Infrastructure

/// 加密信封段（discussions/2026-10-16-backup-sync-share-design.md §8.5）：
/// 往返 / 篡改 / 错钥 / 帧损坏 / 分块边界 / nonce 唯一性 / 密钥包裹。
struct BackupCryptoTests {

    private let key = SymmetricKey(size: .bits256)

    @Test func roundTripSmall() throws {
        let payload = Data("{\"hello\":\"world\"}".utf8)
        let sealed = try BackupCrypto.seal(payload: payload, key: key)
        let opened = try BackupCrypto.open(sealed, key: key)
        #expect(opened == payload)
    }

    @Test func roundTripEmpty() throws {
        let sealed = try BackupCrypto.seal(payload: Data(), key: key)
        #expect(try BackupCrypto.open(sealed, key: key) == Data())
    }

    @Test func roundTripMultiChunk() throws {
        // > 4 MiB → 2 块;块边界不丢字节
        let payload = Data((0..<(BackupCrypto.chunkSize + 123)).map { UInt8($0 % 251) })
        let sealed = try BackupCrypto.seal(payload: payload, key: key)
        let opened = try BackupCrypto.open(sealed, key: key)
        #expect(opened == payload)
    }

    @Test func roundTripExactChunkBoundary() throws {
        let payload = Data(repeating: 7, count: BackupCrypto.chunkSize)
        let opened = try BackupCrypto.open(try BackupCrypto.seal(payload: payload, key: key), key: key)
        #expect(opened == payload)
    }

    @Test func tamperDetected() throws {
        let sealed = try BackupCrypto.seal(payload: Data("secret".utf8), key: key)
        var corrupted = sealed
        corrupted[corrupted.count - 1] ^= 0x01
        #expect(throws: BackupCrypto.CryptoError.self) {
            _ = try BackupCrypto.open(corrupted, key: key)
        }
    }

    @Test func wrongKeyRejected() throws {
        let sealed = try BackupCrypto.seal(payload: Data("secret".utf8), key: key)
        let otherKey = SymmetricKey(size: .bits256)
        #expect(throws: BackupCrypto.CryptoError.tamperOrKeyMismatch) {
            _ = try BackupCrypto.open(sealed, key: otherKey)
        }
    }

    @Test func malformedFramesRejected() throws {
        #expect(throws: BackupCrypto.CryptoError.self) { _ = try BackupCrypto.open(Data(), key: key) }
        #expect(throws: BackupCrypto.CryptoError.self) { _ = try BackupCrypto.open(Data([0, 0]), key: key) }
        // 声称 1 块但无块体
        var claimOne = Data([0, 0, 0, 1])
        claimOne.append(contentsOf: [0, 0, 0, 8, 1, 2, 3, 4, 5, 6, 7, 8])
        #expect(throws: BackupCrypto.CryptoError.self) { _ = try BackupCrypto.open(claimOne, key: key) }
        // 尾随垃圾
        let sealed = try BackupCrypto.seal(payload: Data("x".utf8), key: key)
        var trailing = sealed
        trailing.append(contentsOf: [0])
        #expect(throws: BackupCrypto.CryptoError.self) { _ = try BackupCrypto.open(trailing, key: key) }
    }

    @Test func nonceNeverReused() throws {
        let a = try BackupCrypto.seal(payload: Data("same".utf8), key: key)
        let b = try BackupCrypto.seal(payload: Data("same".utf8), key: key)
        #expect(a != b)   // 随机 nonce:相同明文两次密封密文必不同
    }

    @Test func keyWrapRoundTrip() throws {
        let master = SymmetricKey(size: .bits256)
        let device = SymmetricKey(size: .bits256)
        let wrapped = try BackupCrypto.wrapKey(master, using: device)
        let unwrapped = try BackupCrypto.unwrapKey(wrapped, using: device)
        #expect(unwrapped.withUnsafeBytes { Data($0) } == master.withUnsafeBytes { Data($0) })
    }

    @Test func keyWrapWrongKeyRejected() throws {
        let wrapped = try BackupCrypto.wrapKey(SymmetricKey(size: .bits256), using: key)
        #expect(throws: BackupCrypto.CryptoError.tamperOrKeyMismatch) {
            _ = try BackupCrypto.unwrapKey(wrapped, using: SymmetricKey(size: .bits256))
        }
    }

    // MARK: - v2 加密信封帧

    @Test func sealFrameOpenFrameRoundTrip() throws {
        let master = SymmetricKey(size: .bits256)
        let device = SymmetricKey(size: .bits256)
        let ref = UUID()
        let payload = Data("frame payload".utf8)
        let frame = try BackupCrypto.sealFrame(payload: payload, masterKey: master, wrappingKey: device, keyRef: ref)
        let opened = try BackupCrypto.openFrame(frame, unwrapWith: device)
        #expect(opened.payload == payload)
        #expect(opened.keyRef == ref)
        #expect(opened.aadHash == BackupCrypto.sha256Hex(payload))
    }

    @Test func sealFrameWrongDeviceKeyRejected() throws {
        let frame = try BackupCrypto.sealFrame(payload: Data("x".utf8), masterKey: SymmetricKey(size: .bits256),
                                               wrappingKey: SymmetricKey(size: .bits256), keyRef: UUID())
        #expect(throws: BackupCrypto.CryptoError.tamperOrKeyMismatch) {
            _ = try BackupCrypto.openFrame(frame, unwrapWith: SymmetricKey(size: .bits256))
        }
    }

    @Test func sealFrameTamperRejected() throws {
        let frame = try BackupCrypto.sealFrame(payload: Data("secret frame".utf8), masterKey: SymmetricKey(size: .bits256),
                                               wrappingKey: SymmetricKey(size: .bits256), keyRef: UUID())
        var corrupted = frame
        corrupted[corrupted.count - 1] ^= 0x01
        #expect(throws: BackupCrypto.CryptoError.self) {
            _ = try BackupCrypto.openFrame(corrupted, unwrapWith: SymmetricKey(size: .bits256))
        }
    }
}
#endif
