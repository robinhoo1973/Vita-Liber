import Foundation

/// 跨平台 SHA-256（纯 Swift，零框架，Domain 可用）。
///
/// Apple 侧可用 CryptoKit；Linux 侧用纯 Swift 实现（基于公共领域 SHA-256 算法）。
/// 仅用于 DuplicateDetectionService 的哈希计算，不涉及安全敏感场景（仅去重/感知哈希种子）。
/// 安全敏感 KDF（PBKDF2）在 Infrastructure/PinStorage 由 CommonCrypto/SwiftCrypto 处理。

public struct SHA256Digest: Sendable, Equatable, Hashable {
    public var bytes: [UInt8]
    public init(bytes: [UInt8]) { self.bytes = bytes }
    public var hexString: String { bytes.map { String(format: "%02x", $0) }.joined() }
    public func makeIterator() -> Array<UInt8>.Iterator { bytes.makeIterator() }
    public var count: Int { bytes.count }
    public subscript(index: Int) -> UInt8 { bytes[index] }
}

public enum SHA256 {
    /// 计算 SHA-256 摘要（纯 Swift，跨平台）。
    public static func hash(data: Data) -> SHA256Digest {
        var engine = SHA256Engine()
        engine.update(data)
        return SHA256Digest(bytes: engine.finalize())
    }

    /// 流式哈希器。
    public struct SHA256Hasher: Sendable {
        private var engine = SHA256Engine()
        public init() {}
        public mutating func update(data: Data) { engine.update(data) }
        public mutating func finalize() -> SHA256Digest {
            SHA256Digest(bytes: engine.finalize())
        }
    }
}

// MARK: - 纯 Swift SHA-256 实现（基于 FIPS 180-4，公共领域算法）

private struct SHA256Engine {
    private var h: [UInt32] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
    ]
    private var buffer: [UInt8] = []
    private var totalLen: UInt64 = 0

    private let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
        0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
        0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
        0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
        0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
        0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
        0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
        0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
        0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
    ]

    mutating func update(_ data: Data) {
        var pos = 0
        let bytes = Array(data)
        while pos < bytes.count {
            let remaining = 64 - buffer.count
            let take = min(remaining, bytes.count - pos)
            buffer.append(contentsOf: bytes[pos..<pos+take])
            pos += take
            totalLen += UInt64(take)
            if buffer.count == 64 {
                h = compress(h, buffer)
                buffer.removeAll(keepingCapacity: true)
            }
        }
    }

    func finalize() -> [UInt8] {
        var engine = self
        var msg = engine.buffer
        let lenBits = engine.totalLen * 8
        msg.append(0x80)
        while (msg.count % 64) != 56 { msg.append(0) }
        var len = lenBits
        var lenBytes = [UInt8]()
        lenBytes.reserveCapacity(8)
        for _ in 0..<8 { lenBytes.append(UInt8(len & 0xFF)); len >>= 8 }
        msg.append(contentsOf: lenBytes.reversed())
        var h = engine.h
        for chunk in stride(from: 0, to: msg.count, by: 64) {
            let block = Array(msg[chunk..<chunk+64])
            h = compress(h, block)
        }
        var out = [UInt8]()
        out.reserveCapacity(32)
        for v in h {
            out.append(UInt8((v >> 24) & 0xFF))
            out.append(UInt8((v >> 16) & 0xFF))
            out.append(UInt8((v >> 8) & 0xFF))
            out.append(UInt8(v & 0xFF))
        }
        return out
    }

    private func compress(_ h: [UInt32], _ block: [UInt8]) -> [UInt32] {
        var w = [UInt32](repeating: 0, count: 64)
        for i in 0..<16 {
            w[i] = (UInt32(block[i*4]) << 24) | (UInt32(block[i*4+1]) << 16)
                | (UInt32(block[i*4+2]) << 8) | UInt32(block[i*4+3])
        }
        for i in 16..<64 {
            let s0 = rotr(w[i-15], 7) ^ rotr(w[i-15], 18) ^ (w[i-15] >> 3)
            let s1 = rotr(w[i-2], 17) ^ rotr(w[i-2], 19) ^ (w[i-2] >> 10)
            w[i] = w[i-16] &+ s0 &+ w[i-7] &+ s1
        }
        var a = h[0], b = h[1], c = h[2], d = h[3]
        var e = h[4], f = h[5], g = h[6], h_ = h[7]
        for i in 0..<64 {
            let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
            let ch = (e & f) ^ (~e & g)
            let t1 = h_ &+ s1 &+ ch &+ k[i] &+ w[i]
            let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
            let maj = (a & b) ^ (a & c) ^ (b & c)
            let t2 = s0 &+ maj
            h_ = g; g = f; f = e
            e = d &+ t1
            d = c; c = b; b = a
            a = t1 &+ t2
        }
        return [h[0] &+ a, h[1] &+ b, h[2] &+ c, h[3] &+ d,
                h[4] &+ e, h[5] &+ f, h[6] &+ g, h[7] &+ h_]
    }

    private func rotr(_ x: UInt32, _ n: Int) -> UInt32 {
        (x >> n) | (x << (32 - n))
    }
}

