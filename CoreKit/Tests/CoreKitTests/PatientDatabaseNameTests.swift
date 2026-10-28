import Foundation
import Testing
@testable import Domain
@testable import Infrastructure

// binds: SU-M0-DBBOOT-NAMES（gate-suites.tsv M0 行；B0 名字全集解析）
@Suite("SU-M0-DBBOOT-NAMES · 患者库名字全集解析")
struct PatientDatabaseNameTests {
    @Test func emptyDirectoryResolvesToMissing() {
        #expect(DatabaseNameResolution.decide(presentNames: []) == .missing)
        // 非注册名一律忽略（WAL 伴生/历史库/切片目录都不参与主库解析）。
        #expect(DatabaseNameResolution.decide(
            presentNames: ["app-local-user_data.sqlite-wal",
                           "app-local-schema-history.sqlite",
                           "app-catalog-drug.sqlite"]) == .missing)
    }

    @Test func singleCanonicalWins() {
        #expect(DatabaseNameResolution.decide(
            presentNames: [PatientDatabaseNames.canonical]) == .single(PatientDatabaseNames.canonical))
    }

    @Test func singleLegacyIsRecognised() {
        #expect(DatabaseNameResolution.decide(
            presentNames: [PatientDatabaseNames.legacy]) == .single(PatientDatabaseNames.legacy))
    }

    @Test func caseVariantsMatchRegisteredNames() {
        #expect(PatientDatabaseNames.isRegistered("VITALIBER.SQLITE"))
        #expect(DatabaseNameResolution.decide(
            presentNames: ["VITALIBER.sqlite"]) == .single("VITALIBER.sqlite"))
    }

    @Test func twoCandidatesFailClosedWithStableOrder() {
        let resolution = DatabaseNameResolution.decide(
            presentNames: [PatientDatabaseNames.legacy, PatientDatabaseNames.canonical])
        #expect(resolution == .ambiguous([PatientDatabaseNames.canonical,
                                          PatientDatabaseNames.legacy]))
    }

    @Test func locatorScansRealDirectory() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("patient-names-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) } // try?-ok: 测试清理

        #expect(PatientDatabaseLocator.resolve(in: dir) == .missing)
        try Data("x".utf8).write(to: dir.appendingPathComponent(PatientDatabaseNames.legacy))
        #expect(PatientDatabaseLocator.resolve(in: dir) == .single(PatientDatabaseNames.legacy))
        // 同名目录不是候选（只算常规文件）。
        let nested = dir.appendingPathComponent(PatientDatabaseNames.canonical, isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        #expect(PatientDatabaseLocator.resolve(in: dir) == .single(PatientDatabaseNames.legacy))
        try FileManager.default.removeItem(at: nested)
        try Data("y".utf8).write(to: dir.appendingPathComponent(PatientDatabaseNames.canonical))
        #expect(PatientDatabaseLocator.resolve(in: dir) == .ambiguous(
            [PatientDatabaseNames.canonical, PatientDatabaseNames.legacy]))
    }
}
