import Foundation
import Testing
@testable import Infrastructure

/// 外层帧格式矩阵（G1 清偿：二进制 v1 全形态 + 损坏/截断/溢出陷阱，Linux 可跑）。
/// 帧布局 = magic("VLBU1") + fmtVer(1B) + sha256 hex(64B) + BE u64 长度 + payload。
struct EnvelopeFrameTests {

    private func makeFrame(payload: Data, sha: String) -> Data {
        var data = Data()
        data.append(EnvelopeFrame.binaryMagic)
        data.append(contentsOf: [1])
        data.append(contentsOf: sha.utf8)
        var length = UInt64(payload.count).bigEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(payload)
        return data
    }

    private let sha = String(repeating: "a", count: 64)

    @Test func binaryRoundTrip() {
        let payload = Data("{\"hello\":1}".utf8)
        let frame = makeFrame(payload: payload, sha: sha)
        #expect(EnvelopeFrame.isBinary(frame))
        let parsed = EnvelopeFrame.parseBinary(frame)
        #expect(parsed != nil)
        #expect(parsed?.formatVersion == 1)
        #expect(parsed?.claimedSHA == sha)
        #expect(parsed?.payload == payload)
    }

    @Test func nonBinaryDataRejected() {
        let json = Data("{\"formatVersion\":1}".utf8)
        #expect(!EnvelopeFrame.isBinary(json))
        #expect(EnvelopeFrame.parseBinary(json) == nil)
    }

    @Test func magicOnlyTruncatedRejected() {
        #expect(EnvelopeFrame.parseBinary(EnvelopeFrame.binaryMagic) == nil)
        var data = EnvelopeFrame.binaryMagic
        data.append(contentsOf: [1])
        #expect(EnvelopeFrame.parseBinary(data) == nil)
        // 恰好缺 1 字节（长度字段不完整）
        var near = EnvelopeFrame.binaryMagic
        near.append(contentsOf: [1])
        near.append(contentsOf: sha.utf8)
        near.append(contentsOf: [0, 0, 0, 0, 0, 0, 0])  // 7/8 字节长度
        #expect(EnvelopeFrame.parseBinary(near) == nil)
    }

    @Test func versionByteRejected() {
        var data = EnvelopeFrame.binaryMagic
        data.append(contentsOf: [2])   // v2 加密段预留——当前解析器只认 v1，调用方按需扩展
        data.append(contentsOf: sha.utf8)
        var length = UInt64(0).bigEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        #expect(EnvelopeFrame.parseBinary(data) == nil)
    }

    @Test func lengthOverflowRejectedWithoutTrap() {
        // length = UInt64(Int.max) + 1 —— 先限界再比较，绝不 trap（V3.61 同族纪律）
        var data = EnvelopeFrame.binaryMagic
        data.append(contentsOf: [1])
        data.append(contentsOf: sha.utf8)
        var length = (UInt64(Int.max) + 1).bigEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        #expect(EnvelopeFrame.parseBinary(data) == nil)
    }

    @Test func lengthMismatchRejected() {
        // 声称 10 字节、实际给 5（截断）
        var short = makeFrame(payload: Data("12345".utf8), sha: sha)
        // 改长度字段为 10
        let lenStart = EnvelopeFrame.binaryMagic.count + 1 + 64
        var length = UInt64(10).bigEndian
        withUnsafeBytes(of: &length) { short.replaceSubrange(lenStart..<lenStart + 8, with: $0) }
        #expect(EnvelopeFrame.parseBinary(short) == nil)
        // 声称 5、实际给 6（尾随垃圾）
        var long = makeFrame(payload: Data("12345".utf8), sha: sha)
        long.append(contentsOf: [0])
        #expect(EnvelopeFrame.parseBinary(long) == nil)
    }

    @Test func asciiShaParsed() {
        let frame = makeFrame(payload: Data("x".utf8), sha: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")
        #expect(EnvelopeFrame.parseBinary(frame)?.claimedSHA == "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")
    }
}
