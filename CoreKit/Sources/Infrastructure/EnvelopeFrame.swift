import Foundation

/// 备份信封二进制外层帧（magic+版本+sha256+BE 长度+payload）的纯解析——
/// 自 `BackupService.verifiedEnvelope` 抽取（discussions/2026-10-16-backup-sync-share-design.md V1.7：
/// 让外层格式矩阵在 Linux CoreKitTests 可跑；G1「外层遗留 JSON 分支零测试=死代码」同源清偿）。
/// 任何结构违规返回 nil（错误语义由调用方单一映射为 `BackupError.unsupportedFormat`）；
/// 长度先限界再比较（UInt64→Int ≥2^63 trap 与加法溢出 trap 的既有纪律原样保留）。
public struct EnvelopeFrame: Sendable {

    public static let binaryMagic = Data("VLBU1".utf8)

    public struct Parsed: Sendable, Equatable {
        public let formatVersion: UInt8
        public let claimedSHA: String
        public let payload: Data
    }

    public static func isBinary(_ data: Data) -> Bool {
        data.starts(with: binaryMagic)
    }

    /// 二进制帧格式版本窥探（v1=明文 sha256 帧；v2=加密段帧，结构归 BackupCrypto 所有）。
    /// 结构不足/版本未知 → nil（调用方映射 unsupportedFormat）。
    public static func binaryFormatVersion(_ data: Data) -> UInt8? {
        guard isBinary(data), data.count > binaryMagic.count else { return nil }
        return data[binaryMagic.count]
    }

    /// 二进制帧解析；结构性违规一律 nil（不抛——帧层不持有错误语义）。
    public static func parseBinary(_ data: Data) -> Parsed? {
        guard isBinary(data) else { return nil }
        let magicLen = binaryMagic.count
        guard data.count > magicLen + 1 + 64 + 8 else { return nil }
        let versionStart = magicLen
        guard data[versionStart] == 1 else { return nil }   // 更高格式版本由调用方按需扩展（v2 加密段预留）
        let shaStart = versionStart + 1
        let shaEnd = shaStart + 64
        let lenStart = shaEnd
        let lenEnd = lenStart + 8
        let length = data[lenStart..<lenEnd].withUnsafeBytes {
            $0.loadUnaligned(as: UInt64.self)
        }.bigEndian
        // 审查纪律（V3.61 同族）：length 来自用户挑选的文件——先限界再减法比较，
        // 损坏文件一律走 nil（调用方映射 unsupportedFormat），绝不 trap。
        guard length <= UInt64(Int.max),
              data.count >= lenEnd,
              data.count - lenEnd == Int(length) else { return nil }
        let claimedSHA = String(data: data[shaStart..<shaEnd], encoding: .ascii) ?? ""
        return Parsed(formatVersion: 1, claimedSHA: claimedSHA, payload: data[lenEnd...])
    }
}
