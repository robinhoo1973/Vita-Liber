import XCTest
@testable import VitaLiber
import Domain

/// T8 回归（启动时序批 ⓪，2026-10-29）：v4 残留清理=替代集三 kind 全就绪才动，
/// 且执行点已后置到启动成功路径（prepare 失败分支结构上不可达清理调用）。
/// 本套件钉死 cleanIfEligible 本体语义；「失败启动零删除」由调用点位置保证
///（DatabaseBootModel 的 do 块内、各 catch 之前），并以此处「缺一不删」用例支撑。
final class LegacyCatalogResidueTests: XCTestCase {
    private func makeSupportDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("residue-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func seedV4Files(in support: URL) throws {
        for name in LegacyCatalogResidue.fileNames {
            try Data("v4".utf8).write(to: support.appendingPathComponent(name))
        }
        let snapshots = support.appendingPathComponent(
            LegacyCatalogResidue.snapshotDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true)
        try Data("snap".utf8).write(to: snapshots.appendingPathComponent("a.sqlite"))
    }

    private func v4FilesExist(in support: URL) -> Bool {
        let files = LegacyCatalogResidue.fileNames.contains {
            FileManager.default.fileExists(atPath: support.appendingPathComponent($0).path)
        }
        let snapshots = FileManager.default.fileExists(
            atPath: support.appendingPathComponent(LegacyCatalogResidue.snapshotDirectoryName).path)
        return files || snapshots
    }

    func testThreeReadyKindsDeleteAllResidue() throws {
        let support = try makeSupportDirectory()
        defer { try? FileManager.default.removeItem(at: support) } // try?-ok: 测试清理
        try seedV4Files(in: support)
        let cleaned = LegacyCatalogResidue.cleanIfEligible(
            readyKinds: Set(CatalogSliceKind.legacyReplacedKinds), supportDirectory: support)
        XCTAssertTrue(cleaned)
        XCTAssertFalse(v4FilesExist(in: support), "三 kind 全就绪必须清空 v4 残留（含快照目录）")
    }

    func testMissingOneKindNeverDeletes() throws {
        let support = try makeSupportDirectory()
        defer { try? FileManager.default.removeItem(at: support) } // try?-ok: 测试清理
        try seedV4Files(in: support)
        var kinds = Set(CatalogSliceKind.legacyReplacedKinds)
        kinds.remove(kinds.first!)
        let cleaned = LegacyCatalogResidue.cleanIfEligible(readyKinds: kinds, supportDirectory: support)
        XCTAssertFalse(cleaned, "替代集未齐必须返回 false")
        XCTAssertTrue(v4FilesExist(in: support), "替代集未齐前绝不删除任何 v4 文件")
    }

    func testEmptyReadyKindsNeverDeletes() throws {
        let support = try makeSupportDirectory()
        defer { try? FileManager.default.removeItem(at: support) } // try?-ok: 测试清理
        try seedV4Files(in: support)
        XCTAssertFalse(LegacyCatalogResidue.cleanIfEligible(readyKinds: [], supportDirectory: support))
        XCTAssertTrue(v4FilesExist(in: support))
    }

    func testIdempotentSecondRunReportsTrueWithNothingToDo() throws {
        let support = try makeSupportDirectory()
        defer { try? FileManager.default.removeItem(at: support) } // try?-ok: 测试清理
        try seedV4Files(in: support)
        let all = Set(CatalogSliceKind.legacyReplacedKinds)
        XCTAssertTrue(LegacyCatalogResidue.cleanIfEligible(readyKinds: all, supportDirectory: support))
        XCTAssertTrue(LegacyCatalogResidue.cleanIfEligible(readyKinds: all, supportDirectory: support),
                      "幂等：空跑仍返回 true")
        XCTAssertFalse(v4FilesExist(in: support))
    }
}
