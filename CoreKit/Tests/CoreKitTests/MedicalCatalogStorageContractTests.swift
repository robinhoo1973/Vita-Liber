#if os(iOS) || os(macOS)
import Domain
import Foundation
import GRDB
import Testing
@testable import Infrastructure

@Suite("Unified catalog storage contract", .timeLimit(.minutes(2)))
struct MedicalCatalogStorageContractTests {
    @Test("physical9 opens both surfaces with stable App IDs and region-scoped references/details")
    func readsAllDomains() async throws {
        let fixture = try UnifiedAppFixture.make()
        defer { fixture.cleanUp() }
        let access = try MedicalCatalogReadAccess(path: fixture.path)
        let cn = try #require(try await access.drug(id: 1))
        let tw = try #require(try await access.drug(id: 2))
        #expect(cn.sourceID == tw.sourceID)
        #expect(try await access.reference(for: cn).map(\.referenceID) == ["ref-cn"])
        #expect(try await access.reference(for: tw).map(\.referenceID) == ["ref-tw"])
        #expect(try await access.detail(for: cn)?.usageText == "CN 原文😀")
        #expect(try await access.detail(for: tw)?.usageText == "TW 原文😀")
        #expect(try await access.hospitalSuggest(query: "合成", region: nil, limit: 10).first?.id == 41)
        #expect(try await access.departmentList(region: "TW").first?.id == 51)
        #expect(try await access.diagnosisSuggest(query: "R05", system: nil, region: nil, limit: 10).first?.id == 61)
        let exam = try #require(try await access.examSuggest(query: "E1", category: nil, region: nil, limit: 10).first)
        #expect(exam.id == 71 && exam.unit == nil && exam.priceRef == nil && exam.loincConceptID == nil)
        #expect(access.installedVersion?.activationID == "activation-A-1")
    }

    @Test("missing or corrupt unified markers, objects, release and current bindings fail closed")
    func rejectsInvalidUnified() throws {
        let mutations = [
            "DELETE FROM catalog_meta WHERE key='storage_contract'",
            "UPDATE catalog_meta SET value='broken' WHERE key='storage_contract'",
            "UPDATE catalog_meta SET value='8' WHERE key='schema_version'; PRAGMA user_version=8",
            "UPDATE catalog_meta SET value='7' WHERE key='schema_version'; PRAGMA user_version=7",
            "UPDATE metadata SET value='development' WHERE key='lifecycle'",
            "DELETE FROM metadata WHERE key='lifecycle'",
            "DROP VIEW active_alias",
            "DROP TABLE producer_state_history",
            "UPDATE metadata SET value='missing' WHERE key='activation_id'",
            "UPDATE graph_release SET content_sha256='\(String(repeating: "c", count: 64))'",
            "UPDATE graph_release SET catalog_count=11",
            "DELETE FROM producer_import",
            "CREATE UNIQUE INDEX invalid_global_hospital_source ON hospital(source_id)",
            "UPDATE catalog_entry SET current_revision_uid='revision-entry-drug-tw' WHERE entry_uid='entry-drug-cn'",
            "DELETE FROM catalog_entry WHERE entry_uid='entry-drug-cn'",
            "UPDATE drug SET aliases_json='broken JSON' WHERE id=1"
        ]
        for sql in mutations {
            let fixture = try UnifiedAppFixture.make()
            defer { fixture.cleanUp() }
            try fixture.mutate(sql)
            #expect(throws: (any Error).self) { try MedicalCatalogStore(path: fixture.path) }
            #expect(throws: (any Error).self) { try MedicalReferenceCatalogStore(path: fixture.path.path) }
            #expect(throws: (any Error).self) {
                try MedicalCatalogStore.validateReleaseAndSmoke(path: fixture.path, schemaVersion: 9,
                                                                dataVersion: UnifiedAppFixture.release)
            }
        }
    }

    @Test("additional expression indexes cannot crash the shared key inspector")
    func acceptsAdditionalExpressionIndex() throws {
        let fixture = try UnifiedAppFixture.make()
        defer { fixture.cleanUp() }
        try fixture.mutate("CREATE UNIQUE INDEX extra_expression ON drug(region,lower(source_id))")
        let access = try MedicalCatalogReadAccess(path: fixture.path)
        #expect(access.isAvailable && access.installedVersion?.dataVersion == UnifiedAppFixture.release)
    }

    @Test("producer lifecycle audit changes file bytes without rebinding content")
    func producerLifecycleAudit() throws {
        let fixture = try UnifiedAppFixture.make()
        defer { fixture.cleanUp() }
        let before = try MedicalCatalogStore.installedVersion(path: fixture.path)
        try fixture.mutate("""
            INSERT INTO producer_state_history
            SELECT 'audit-1',input_sha256,'fetch_snapshot','["snapshot-a"]',
                   '{"status":"running"}','{"status":"complete"}','2026-10-14'
            FROM producer_import;
            """)
        let after = try MedicalCatalogStore.installedVersion(path: fixture.path)
        #expect(after.dataVersion == before.dataVersion)
        #expect(after.contentSHA256 == before.contentSHA256)
        #expect(after.activationID == before.activationID)
        #expect(after.sqliteSHA256 != before.sqliteSHA256)
        try MedicalCatalogStore.validateReleaseAndSmoke(
            path: fixture.path, schemaVersion: 9, dataVersion: UnifiedAppFixture.release)
    }

    @Test("lazy pooled readers stay on the old inode until the whole pair commits")
    func readersRetainSnapshotAcrossActivePathRename() async throws {
        let old = try UnifiedAppFixture.make()
        let fresh = try UnifiedAppFixture.make()
        defer { old.cleanUp(); fresh.cleanUp() }
        let prepared = try MedicalCatalogReadAccess.prepare(path: old.path)
        let pin = try #require(prepared.retainedFile?.url)
        #expect(pin != old.path)
        let access = MedicalCatalogReadAccess()
        access.commit(prepared)
        try fresh.mutate("""
            UPDATE drug SET name_zh='new candidate' WHERE id=1;
            UPDATE hospital SET name_zh='new candidate hospital';
            """)
        #expect(rename(fresh.path.path, old.path.path) == 0)
        do {
            try await withThrowingTaskGroup(of: Bool.self) { group in
                for _ in 0..<24 {
                    group.addTask {
                        let drug = try await access.drug(id: 1)
                        let hospitals = try await access.hospitalSuggest(query: "合成", region: nil, limit: 10)
                        return drug?.nameZh == "药品甲" && hospitals.first?.id == 41
                    }
                }
                for try await retained in group { #expect(retained) }
            }
        } catch let error as DatabaseError {
            // 真实抛错点诊断（委员会定位：换名后旧 pin 池读,非 prepare）——
            // 记录扩展码坐实 SQLITE_IOERR_VNODE(6922) 或其他子型
            Issue.record("旧快照读 IOERR extendedResultCode=\(error.extendedResultCode.rawValue) sql=\(error.sql ?? "nil")")
            throw error
        }
        #expect(access.catalogGeneration == 1)
        #expect(FileManager.default.fileExists(atPath: pin.path))
    }

    @Test("read pin cleanup collects crashed leases but cannot unlink another live pair")
    func readPinLifecycle() throws {
        let fixture = try UnifiedAppFixture.make()
        defer { fixture.cleanUp() }
        var snapshot: MedicalCatalogReadAccess.Snapshot? = try MedicalCatalogReadAccess.prepare(path: fixture.path)
        let live = try #require(snapshot?.retainedFile?.url)
        let root = live.deletingLastPathComponent()
        let orphan = root.appendingPathComponent(UUID().uuidString).appendingPathExtension("sqlite")
        try FileManager.default.linkItem(at: fixture.path, to: orphan)
        let owner = orphan.deletingPathExtension().appendingPathExtension("lock")
        try Data().write(to: owner)
        let second = try MedicalCatalogReadAccess.prepare(path: fixture.path)
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        #expect(FileManager.default.fileExists(atPath: live.path))
        snapshot = nil
        #expect(!FileManager.default.fileExists(atPath: live.path))
        #expect(second.retainedFile != nil)
        withExtendedLifetime(second) {}
    }

    @Test("partial/empty/blocked snapshots cannot install or serve through either Store")
    func rejectsResearchSnapshots() throws {
        for (scope, ready) in [("partial", "true"), ("empty", "false"), ("full", "false")] {
            let fixture = try UnifiedAppFixture.make()
            defer { fixture.cleanUp() }
            try fixture.mutate("""
                UPDATE graph_release SET scope='\(scope)';
                UPDATE catalog_meta SET value='\(scope)' WHERE key='content_scope';
                UPDATE catalog_meta SET value='\(ready)' WHERE key='catalog_ready';
                """)
            #expect(throws: (any Error).self) { try MedicalCatalogReadAccess(path: fixture.path) }
        }
    }

    @Test("current revision may be historical; metadata binds the activation primary key in A→B→A")
    func historicalRevisionAndActivation() throws {
        let fixture = try UnifiedAppFixture.make()
        defer { fixture.cleanUp() }
        try fixture.mutate("""
            INSERT INTO catalog_revision SELECT 'newer-unused',entry_uid,content_sha256,
                '{}','{"newer":true}','2099-01-01' FROM catalog_revision WHERE revision_uid='revision-entry-drug-cn';
            INSERT INTO graph_release SELECT replace(release_id,'a','b'),2,replace(content_sha256,'a','b'),
                scope,status,source_manifest_json,catalog_count,entity_count,assertion_count,created_at FROM graph_release;
            INSERT INTO graph_activation VALUES
                ('activation-B-2',2,'\(String(repeating: "b", count: 64))','2026-10-02'),
                ('activation-A-3',3,'\(UnifiedAppFixture.release)','2026-10-03');
            UPDATE metadata SET value='activation-A-3' WHERE key='activation_id';
            """)
        #expect(try MedicalCatalogStore.installedVersion(path: fixture.path).activationID == "activation-A-3")
    }

    @Test("same R with different signed SQLite SHA is never skipped; final-path failure keeps both old readers")
    func finalFailureKeepsBothReaders() async throws {
        let old = try UnifiedAppFixture.make()
        let fresh = try UnifiedAppFixture.make()
        defer { old.cleanUp(); fresh.cleanUp() }
        try fresh.mutate("INSERT INTO metadata VALUES ('diagnostic','history-only repack')")
        let access = try MedicalCatalogReadAccess(path: old.path)
        let before = try #require(access.installedVersion)
        let generation = access.catalogGeneration
        let bytes = try Data(contentsOf: fresh.path)
        let package = Data("test-package".utf8)
        let candidate = try UnifiedAppFixture.candidate(sqlite: bytes, package: package)
        #expect(!MedicalCatalogUpdateService.sameDataVersion(local: before, candidate: candidate))
        let updater = MedicalCatalogUpdateService(destination: old.path,
            fetcher: StubPackageFetcher(bytes: package),
            journal: MedicalCatalogActivationJournal.production(supportDirectory: old.directory),
            limits: .standard, activeCheck: { _ in throw MedicalCatalogUpdateError.activationFailed },
            readAccess: access)
        do {
            try await updater.update(candidate: candidate, opener: UnifiedFixtureOpener(bytes: bytes))
            Issue.record("final-path failure unexpectedly succeeded")
        } catch {
            #expect(error as? MedicalCatalogUpdateError == .activationFailed)
        }
        #expect(access.catalogGeneration == generation)
        #expect(access.installedVersion == before)
        #expect(try StreamingFileHasher.sha256(of: old.path) == before.sqliteSHA256)
        do {
            let drug = try await access.drug(id: 1)
            let hospitals = try await access.hospitalSuggest(query: "合成", region: nil, limit: 10)
            #expect(drug?.nameZh == "药品甲")
            #expect(hospitals.first?.id == 41)
        } catch let error as DatabaseError {
            // 真实抛错点诊断（委员会定位：失败更新后旧 pin 池读,非 open）——
            // 记录扩展码坐实 SQLITE_IOERR_VNODE(6922) 或其他子型
            Issue.record("旧快照读 IOERR extendedResultCode=\(error.extendedResultCode.rawValue) sql=\(error.sql ?? "nil")")
            throw error
        }
    }

    @Test("successful installation replaces the pair once and the same DI references read the new generation")
    func successfulInstallSwitchesPair() async throws {
        let old = try UnifiedAppFixture.make()
        let fresh = try UnifiedAppFixture.make()
        defer { old.cleanUp(); fresh.cleanUp() }
        try fresh.mutate("INSERT INTO metadata VALUES ('diagnostic','re-sealed history')")
        let access = try MedicalCatalogReadAccess(path: old.path)
        let drugs: any MedicalCatalogReading = access
        let references: any MedicalReferenceCatalogReading = access
        let generation = access.catalogGeneration
        let bytes = try Data(contentsOf: fresh.path)
        let package = Data("test-package".utf8)
        let candidate = try UnifiedAppFixture.candidate(sqlite: bytes, package: package)
        let updater = MedicalCatalogUpdateService(destination: old.path,
            fetcher: StubPackageFetcher(bytes: package),
            journal: MedicalCatalogActivationJournal.production(supportDirectory: old.directory), readAccess: access)
        try await updater.update(candidate: candidate, opener: UnifiedFixtureOpener(bytes: bytes))
        #expect(access.catalogGeneration == generation + 1)
        #expect(drugs.catalogGeneration == references.catalogGeneration)
        #expect(access.installedVersion?.sqliteSHA256 == candidate.sqliteSHA256)
        #expect(try await drugs.drug(id: 2)?.region == "TW")
        #expect(try await references.departmentList(region: nil).first?.id == 51)
    }

    @Test("the initially empty DI facade activates both surfaces on first installation")
    func emptyFacadeFirstInstall() async throws {
        let fixture = try UnifiedAppFixture.make()
        defer { fixture.cleanUp() }
        let bytes = try Data(contentsOf: fixture.path)
        try FileManager.default.removeItem(at: fixture.path)
        let access = MedicalCatalogReadAccess()
        #expect(!access.isAvailable)
        let package = Data("first installation".utf8)
        let updater = MedicalCatalogUpdateService(destination: fixture.path,
            fetcher: StubPackageFetcher(bytes: package),
            journal: MedicalCatalogActivationJournal.production(supportDirectory: fixture.directory), readAccess: access)
        try await updater.update(candidate: UnifiedAppFixture.candidate(sqlite: bytes, package: package),
                                 opener: UnifiedFixtureOpener(bytes: bytes))
        #expect(access.isAvailable && access.catalogGeneration == 1)
        #expect(try await access.drug(id: 1)?.nameZh == "药品甲")
        #expect(try await access.departmentList(region: nil).first?.id == 51)
    }

    @Test("real bridge KG-only review requires a new R while App columns remain unchanged")
    func kgOnlyGoldenInstallation() async throws {
        let expected = try UnifiedGoldenExpected.load()
        let fixture = try UnifiedAppFixture.make(golden: "bridge-full-v9")
        defer { fixture.cleanUp() }
        let access = try MedicalCatalogReadAccess(path: fixture.path)
        // 夹具现实（bridge-full-v9 为合成单行夹具：drug id=1 "Drug A"/hospital "Hospital"/detail 511 行）：
        // 内容断言必须与 checked-in 夹具逐字节一致（expected.json 钉哈希），不得虚构 id=92 之类。
        let beforeDrug = try await access.drug(id: 1)
        let beforeHospitals = try await access.hospitalSuggest(query: "Hospital", region: nil, limit: 10)
        let beforeDetail = try await access.detail(for: #require(beforeDrug))
        #expect(access.installedVersion?.dataVersion == expected.base.releaseID)
        #expect(access.installedVersion?.sqliteSHA256 == expected.base.sqliteSHA256)
        let reviewed = try UnifiedAppFixture.resource("bridge-reviewed-v9", fileExtension: "sqlite")
        let bytes = try Data(contentsOf: reviewed)
        let package = Data("KG-only test package".utf8)
        let candidate = try UnifiedAppFixture.candidate(sqlite: bytes, package: package,
                                                       dataVersion: expected.reviewed.releaseID)
        #expect(candidate.contentSHA256 == expected.reviewed.releaseID)
        #expect(candidate.sqliteSHA256 == expected.reviewed.sqliteSHA256)
        let updater = MedicalCatalogUpdateService(destination: fixture.path,
            fetcher: StubPackageFetcher(bytes: package),
            journal: MedicalCatalogActivationJournal.production(supportDirectory: fixture.directory), readAccess: access)
        try await updater.update(candidate: candidate, opener: UnifiedFixtureOpener(bytes: bytes))
        #expect(access.installedVersion?.dataVersion == expected.reviewed.releaseID)
        #expect(access.installedVersion?.activationID == expected.reviewed.activationID)
        #expect(access.catalogGeneration == 2)
        #expect(try await access.drug(id: 1) == beforeDrug)
        #expect(try await access.hospitalSuggest(query: "Hospital", region: nil, limit: 10) == beforeHospitals)
        #expect(try await access.detail(for: #require(beforeDrug)) == beforeDetail)
        // 「App 列不变」断言一律取更新前后相等——不钉魔数：indications.count 的语义
        // 由解析规则决定（macOS 实测 8160,非夹具 511 行）,魔数随解析规则漂移即假红。
    }

    @Test("physical9 recovery uses persisted signed content/SHA and restores last-good on a development lifecycle")
    func unifiedJournalRecovery() throws {
        let expected = try UnifiedGoldenExpected.load()
        for development in [false, true] {
            let old = try UnifiedAppFixture.make(golden: "bridge-full-v9")
            let fresh = try UnifiedAppFixture.make(golden: "bridge-reviewed-v9")
            defer { old.cleanUp(); fresh.cleanUp() }
            if development { try fresh.mutate("UPDATE metadata SET value='development' WHERE key='lifecycle'") }
            let package = Data("recovery test package".utf8)
            let bytes = try Data(contentsOf: fresh.path)
            let candidate = try UnifiedAppFixture.candidate(sqlite: bytes, package: package,
                                                           dataVersion: expected.reviewed.releaseID)
            let staging = old.directory.appendingPathComponent("staging.sqlite")
            let backup = old.path.appendingPathExtension("last-good")
            try bytes.write(to: staging)
            try FileManager.default.copyItem(at: old.path, to: backup)
            let pending = PendingActivation(candidate: candidate, stagingURL: staging,
                                             activeURL: old.path, lastGoodBackupURL: backup)
            let journal = MedicalCatalogActivationJournal.production(supportDirectory: old.directory)
            try journal.begin(pending)
            let recordURL = old.directory.appendingPathComponent(MedicalCatalogActivationJournal.journalFileName)
            let record = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: recordURL)) as? [String: Any])
            #expect(record["candidateContentSHA256"] as? String == expected.reviewed.releaseID)
            #expect(record["candidateSQLiteSHA256"] as? String == candidate.sqliteSHA256)
            #expect(rename(staging.path, old.path.path) == 0)
            let result = try journal.recoverBeforeOpen(catalogURL: old.path)
            #expect(result == (development ? .restoredLastGood : .completedActivation))
            let installed = try MedicalCatalogReadAccess(path: old.path)
            #expect(installed.installedVersion?.dataVersion == (development ? expected.base.releaseID : expected.reviewed.releaseID))
            #expect(installed.installedVersion?.sqliteSHA256 == (development ? expected.base.sqliteSHA256 : candidate.sqliteSHA256))
        }
    }

    @Test("schema1 journals may omit legacy content but never unified signed content")
    func missingUnifiedJournalContentRejected() throws {
        let fixture = try UnifiedAppFixture.make()
        defer { fixture.cleanUp() }
        let bytes = try Data(contentsOf: fixture.path)
        let candidate = try UnifiedAppFixture.candidate(sqlite: bytes, package: Data("package".utf8))
        let staging = fixture.directory.appendingPathComponent("staging.sqlite")
        try bytes.write(to: staging)
        let journal = MedicalCatalogActivationJournal.production(supportDirectory: fixture.directory)
        try journal.begin(PendingActivation(candidate: candidate, stagingURL: staging,
                                             activeURL: fixture.path, lastGoodBackupURL: nil))
        let path = fixture.directory.appendingPathComponent(MedicalCatalogActivationJournal.journalFileName)
        var record = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        record.removeValue(forKey: "candidateContentSHA256")
        try JSONSerialization.data(withJSONObject: record).write(to: path)
        #expect(throws: MedicalCatalogActivationJournal.Failure.invalidState) {
            try journal.recoverBeforeOpen(catalogURL: fixture.path)
        }
        #expect(try StreamingFileHasher.sha256(of: fixture.path) == candidate.sqliteSHA256)
    }
}

private struct UnifiedGoldenExpected: Decodable {
    struct Entry: Decodable {
        let releaseID: String
        let sqliteSHA256: String
        let activationID: String
    }
    let base: Entry
    let reviewed: Entry
    static func load() throws -> Self {
        try JSONDecoder().decode(Self.self, from: Data(contentsOf: UnifiedAppFixture.resource("expected", fileExtension: "json")))
    }
}

struct UnifiedAppFixture {
    static let release = String(repeating: "a", count: 64)
    let directory: URL
    var path: URL { directory.appendingPathComponent("catalog.sqlite") }

    static func resource(_ name: String, fileExtension suffix: String) throws -> URL {
        try #require(Bundle.module.url(forResource: name, withExtension: suffix, subdirectory: "Fixtures/unified"))
    }

    static func make(golden: String? = nil) throws -> Self {
        var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: root.appendingPathComponent("Package.swift").path) {
            guard root != root.deletingLastPathComponent() else { throw CocoaError(.fileNoSuchFile) }
            root.deleteLastPathComponent()
        }
        let directory = root.appendingPathComponent(".test-work").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fixture = Self(directory: directory)
        if let golden {
            try FileManager.default.copyItem(at: resource(golden, fileExtension: "sqlite"), to: fixture.path)
            return fixture
        }
        let queue = try DatabaseQueue(path: fixture.path.path)
        try queue.write { db in
            for name in ["schema", "catalog", "app-consumer"] {
                let url = try resource(name, fileExtension: "sql")
                try db.execute(sql: String(contentsOf: url, encoding: .utf8))
            }
        }
        return fixture
    }

    func mutate(_ sql: String) throws {
        var config = Configuration()
        config.foreignKeysEnabled = false
        try DatabaseQueue(path: path.path, configuration: config).write { try $0.execute(sql: sql) }
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: directory) // try?-ok: isolated test workspace cleanup
    }

    static func candidate(sqlite: Data, package: Data,
                          dataVersion: String = UnifiedAppFixture.release) throws -> VerifiedMedicalCatalogCandidate {
        try .testing(catalogVersion: 42, dataVersion: dataVersion, schemaVersion: 9,
            packageAssetName: "package-41.bin", packageSize: Int64(package.count),
            packageSHA256: ReferenceSHA256().sha256Hex(package),
            sqliteSHA256: ReferenceSHA256().sha256Hex(sqlite), installable: true,
            issuedAt: Date().addingTimeInterval(-60), expiresAt: Date().addingTimeInterval(3600),
            signedPointerDigest: String(repeating: "d", count: 64))
    }
}

private struct UnifiedFixtureOpener: MedicalCatalogPackageOpening {
    let bytes: Data
    func open(packageURL: URL, sqliteURL: URL, identity: String, entryName: String,
              maxSQLiteBytes: Int64) async throws {
        try bytes.write(to: sqliteURL)
    }
}
#endif
