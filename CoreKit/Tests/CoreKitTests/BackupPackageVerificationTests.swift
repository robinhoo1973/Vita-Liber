import Foundation
import Testing
#if os(iOS) || os(macOS)
@testable import Infrastructure

/// 损坏库恢复路径的无 writer 备份校验（业主 2026-10-30）：
/// 备份包在替换本机库之前必须可完整校验（二进制 v1 / 遗留 JSON 双格式 + sha256）。
@Suite("备份包无 writer 校验")
struct BackupPackageVerificationTests {
    /// 最小合法 envelope JSON（可选键省略 = nil；非可选数组给空）。
    private var minimalPayload: Data {
        Data("""
        {"schemaVersion":2,"exportedAt":123.0,"members":[],"consentRecords":[],
         "timeline":[],"documents":[],"plans":[],"appointments":[],"observations":[],
         "allergies":[],"encounters":[],"metrics":[],"immunizations":[],
         "voiceNotes":[],"healthProblems":[],"sensitiveDocIds":[]}
        """.utf8)
    }

    private func binaryPackage(payload: Data, magicVersion: UInt8 = 1) -> Data {
        var data = Data("VLBU1".utf8)
        data.append(contentsOf: [magicVersion])
        data.append(contentsOf: BackupService.sha256(payload).utf8)
        var length = UInt64(payload.count).bigEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(payload)
        return data
    }

    @Test("二进制包校验通过并给出摘要")
    func verifiesBinaryPackage() throws {
        let verified = try BackupService.verifyPackage(binaryPackage(payload: minimalPayload))
        #expect(verified.exportedAt == 123.0)
        #expect(verified.totalRecords == 0)
    }

    @Test("篡改 payload → checksumMismatch；未知格式版本 → unsupportedFormat")
    func rejectsTamperedPackages() {
        var tampered = binaryPackage(payload: minimalPayload)
        tampered[tampered.count - 1] ^= 0xFF
        #expect(throws: BackupService.BackupError.checksumMismatch) {
            _ = try BackupService.verifyPackage(tampered)
        }
        #expect(throws: BackupService.BackupError.unsupportedFormat) {
            _ = try BackupService.verifyPackage(binaryPackage(payload: minimalPayload, magicVersion: 2))
        }
    }

    @Test("遗留 JSON 信封（v0）继续可校验")
    func verifiesLegacyJSONEnvelope() throws {
        let outer: [String: Any] = [
            "formatVersion": 1,
            "sha256": BackupService.sha256(minimalPayload),
            "exportedAt": 123.0,
            "payload": minimalPayload.base64EncodedString()
        ]
        let data = try JSONSerialization.data(withJSONObject: outer)
        let verified = try BackupService.verifyPackage(data)
        #expect(verified.exportedAt == 123.0)
    }
}
#endif
