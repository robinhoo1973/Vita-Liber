#if os(iOS) || os(macOS)
import Foundation
import Testing
import ZIPFoundation
@testable import Domain
@testable import Infrastructure

/// ASR 模型包解压攻击矩阵（2026-09-16 委员会评审，测试委员 P0）：
/// `ModelPackageUnpacker.unzip` 是**安全关键面**（zip 内路径不可信），此前零覆盖——
/// 静默回归的后果是路径穿越写盘。夹具用与生产同源的 ZIPFoundation 构造
/// （成熟库优先：不手写 zip 字节，避免假夹具）；每条失败用例同时断言
/// **目标目录零残留**（拒绝必须彻底）。
@Suite("SU-M2-ASRDOWNLOAD · 解压攻击矩阵")
struct ModelPackageUnpackerTests {

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("unpack-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 用 ZIPFoundation 造包（entry path 原样写入——攻击面即在此）。
    private func makeZip(at root: URL, entries: [(path: String, data: Data)]) throws -> URL {
        let zipURL = root.appendingPathComponent("package.zip")
        let archive = try Archive(url: zipURL, accessMode: .create)
        for entry in entries {
            try archive.addEntry(with: entry.path, type: .file,
                                 uncompressedSize: Int64(entry.data.count),
                                 compressionMethod: .deflate,
                                 provider: { position, size in
                                     entry.data.subdata(in: Int(position)..<Int(position) + size)
                                 })
        }
        return zipURL
    }

    private func unpackFails(_ zipURL: URL, into root: URL, maximumBytes: Int64 = 1_000_000) throws -> URL {
        let target = root.appendingPathComponent("out", isDirectory: true)
        do {
            try ModelPackageUnpacker.unzip(zipURL, to: target, maximumBytes: maximumBytes)
            Issue.record("预期 unzipFailed，实际成功")
        } catch ASRModelDownloadService.Failure.unzipFailed {
            // 预期路径：拒绝后目标目录不得残留任何条目
            let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: target.path)) ?? []   // try?-ok: 测试临时目录清理，失败无用户可见后果
            #expect(leftovers.isEmpty, "拒绝后目标目录必须零残留，实际：\(leftovers)")
        }
        return target
    }

    @Test("正向对照：合法包成功解压（证明夹具与判定有效——能绿也能红）")
    /// 原名：合法包成功
    func validPackageSucceeds() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }   // try?-ok: 测试临时目录清理，失败无用户可见后果
        let zip = try makeZip(at: root, entries: [
            ("model.onnx", Data(repeating: 1, count: 128)),
            ("tokens.txt", Data("a b c".utf8)),
            ("manifest.json", Data("{}".utf8)),
        ])
        let target = root.appendingPathComponent("out", isDirectory: true)
        // `maximumBytes` 的契约是**展开总量必须与之恰好相等**（= 清单声明的 expandedBytes，
        // 见 ASRModelDownloadService.swift:260 唯一的产线调用点）：ModelPackageUnpacker
        // 末尾以 `total == maximumBytes` 作完整性判定——若只是上限，该判定会被前面的
        // 上限预检（`entry.uncompressedSize <= maximumBytes - total`）完全覆盖而成死代码。
        // 故正向对照必须传精确展开量：128 + 5 + 2 = 135（原传 1_000_000 是把它当上限，错）。
        let exactExpanded = 128 + 5 + 2
        try ModelPackageUnpacker.unzip(zip, to: target, maximumBytes: Int64(exactExpanded))
        #expect(FileManager.default.fileExists(atPath: target.appendingPathComponent("model.onnx").path))
    }

    @Test("路径穿越 `..` 被拒且零残留")
    /// 原名：路径穿越被拒
    func pathTraversalRejected() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }   // try?-ok: 测试临时目录清理，失败无用户可见后果
        let zip = try makeZip(at: root, entries: [("../evil.onnx", Data(repeating: 1, count: 16))])
        _ = try unpackFails(zip, into: root)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("evil.onnx").path),
                "不得逃逸到父目录")
    }

    @Test("绝对路径被拒")
    /// 原名：绝对路径被拒
    func absolutePathRejected() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }   // try?-ok: 测试临时目录清理，失败无用户可见后果
        let zip = try makeZip(at: root, entries: [("/tmp/evil.onnx", Data(repeating: 1, count: 16))])
        _ = try unpackFails(zip, into: root)
    }

    @Test("扩展名白名单外被拒（.sh）")
    /// 原名：白名单外被拒
    func outsideAllowlistRejected() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }   // try?-ok: 测试临时目录清理，失败无用户可见后果
        let zip = try makeZip(at: root, entries: [("evil.sh", Data("rm -rf /".utf8))])
        _ = try unpackFails(zip, into: root)
    }

    @Test("展开量超限被拒（maximumBytes 收紧）")
    /// 原名：展开量超限被拒
    func expansionOverLimitRejected() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }   // try?-ok: 测试临时目录清理，失败无用户可见后果
        let zip = try makeZip(at: root, entries: [("model.onnx", Data(repeating: 1, count: 4096))])
        _ = try unpackFails(zip, into: root, maximumBytes: 1024)
    }

    @Test("CRC 不符被拒（篡改包字节）")
    /// 原名：crc不符被拒
    func crcMismatchRejected() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }   // try?-ok: 测试临时目录清理，失败无用户可见后果
        let zip = try makeZip(at: root, entries: [("model.onnx", Data(repeating: 7, count: 256))])
        // 翻转压缩数据中的一字节：条目 CRC 与实际内容不符
        var bytes = try Data(contentsOf: zip)
        let mid = bytes.count / 2
        bytes[mid] ^= 0xFF
        try bytes.write(to: zip)
        _ = try unpackFails(zip, into: root)
    }
}
#endif
