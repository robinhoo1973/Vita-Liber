#if os(iOS) || os(macOS)
// linux-blind: Vision 平台守卫 —— Linux 编译空单元，行为由 macOS CI 金色测试覆盖。
import Foundation
import Vision
import Domain

/// QR 载荷解码（Vision 双路径；委员会 S1 设计，2026-10-07）。
///
/// 路径 1 `payloadData`（原始字节）：可能为纯载荷（直判命中），也可能带 QR 段结构
/// （byte-mode 段头 = 4bit 模式 `0b0100` + 8/16bit 字符计数；按位剥离后复判）。
/// 路径 2 `payloadStringValue` → `.isoLatin1` 还原字节（zbar 同构路径——本地对拍
/// 实证 2,024 字节经 Latin-1→UTF-8 映射可无损逆向）。
/// 兜底：候选字节中**唯一**出现 `update-payload-` 时从该处切片复判（0 或 ≥2 命中即拒）。
/// 全部路径失败 = 抛出（调用方归约为「不可用」，fail-closed，不产负结论）。
public enum UpdatePayloadQRDecoder {
    public enum Failure: Error, Equatable {
        case noCode
        case malformed
    }

    public static func payloadBytes(fromPNGData data: Data) throws -> Data {
        let handler = VNImageRequestHandler(data: data, options: [:])
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        do {
            try handler.perform([request])
        } catch {
            throw Failure.noCode
        }
        guard let observation = (request.results ?? []).first else { throw Failure.noCode }
        var candidates: [Data] = []
        if #available(iOS 17.0, macOS 14.0, *) {
            if let raw = observation.payloadData { candidates.append(raw) }
        }
        if let text = observation.payloadStringValue, let latin = text.data(using: .isoLatin1) {
            candidates.append(latin)
        }
        for candidate in candidates {
            if let payload = normalize(candidate) { return payload }
        }
        throw Failure.malformed
    }

    /// 归一化：直判 / byte-mode 段头剥离 / 全流唯一切片 → 合法载荷；否则 nil。
    static func normalize(_ bytes: Data) -> Data? {
        if isValidPayloadShape(bytes) { return bytes }
        if let stripped = stripByteModeSegment(bytes), isValidPayloadShape(stripped) { return stripped }
        return sliceAtUniqueNeedle(bytes)
    }

    /// 合法性 = 79B identity 前缀（合法文法）+ 其后 VLASR 信封魔数。
    static func isValidPayloadShape(_ bytes: Data) -> Bool {
        guard bytes.count >= UpdateAdvicePayloadContract.identityPrefixLength + 6,
              UpdateAdvicePayloadContract.identity(
                  fromPrefix: bytes.prefix(UpdateAdvicePayloadContract.identityPrefixLength)) != nil
        else { return false }
        return PackageEnvelopeCrypto.isEnvelope(
            Data(bytes.dropFirst(UpdateAdvicePayloadContract.identityPrefixLength)))
    }

    /// byte-mode 段头剥离：4bit 模式须为 `0b0100`；字符计数按 8/16bit 两种宽度各试一次
    /// （宽度由 QR 版本决定、载荷里不可见——确定性穷举，**形状校验通过才返回**；
    /// 首个"结构可读"可能是 16bit 计数的高字节误读，未过形状门即换下一宽度）。
    static func stripByteModeSegment(_ bytes: Data) -> Data? {
        var reader = BitReader(bytes)
        guard let mode = reader.read(4), mode == 0b0100 else { return nil }
        for width in [8, 16] {
            var probe = reader
            guard let count = probe.read(width), count > 0,
                  count <= UpdateAdvicePayloadContract.maxEnvelopeBytes
                      + UpdateAdvicePayloadContract.identityPrefixLength,
                  let payload = probe.readBytes(count),
                  isValidPayloadShape(payload) else { continue }
            return payload
        }
        return nil
    }

    /// 全流唯一 needle 切片：`update-payload-` 出现 0 或 ≥2 次 = 拒（歧义即不可信）。
    static func sliceAtUniqueNeedle(_ bytes: Data) -> Data? {
        let needle = Data("update-payload-".utf8)
        var positions: [Int] = []
        var searchStart = bytes.startIndex
        while let found = bytes.range(of: needle, in: searchStart..<bytes.endIndex) {
            positions.append(found.lowerBound - bytes.startIndex)
            searchStart = bytes.index(after: found.lowerBound)
        }
        guard positions.count == 1, let offset = positions.first else { return nil }
        let sliced = Data(bytes.dropFirst(offset))
        return isValidPayloadShape(sliced) ? sliced : nil
    }

    /// MSB-first 位读取器（QR 段结构为大端位序）。
    struct BitReader {
        private let bytes: [UInt8]
        private var bitIndex = 0

        init(_ data: Data) { bytes = Array(data) }

        var remainingBits: Int { bytes.count * 8 - bitIndex }

        mutating func read(_ count: Int) -> Int? {
            guard count >= 0, remainingBits >= count else { return nil }
            var value = 0
            for _ in 0..<count {
                let byte = bytes[bitIndex / 8]
                let bit = (byte >> UInt8(7 - bitIndex % 8)) & 1
                value = (value << 1) | Int(bit)
                bitIndex += 1
            }
            return value
        }

        mutating func readBytes(_ count: Int) -> Data? {
            guard remainingBits >= count * 8 else { return nil }
            var out = Data(capacity: count)
            for _ in 0..<count {
                guard let byte = read(8) else { return nil }
                out.append(UInt8(byte))
            }
            return out
        }
    }
}
#endif
