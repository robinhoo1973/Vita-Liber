import Testing
@testable import Domain

@Suite("SU-M0-DBBOOT · 启动数据库决策")
struct DatabaseBootPolicyTests {
    private func probe(exists: Bool = true, size: Int64 = 4096, header: Bool = true,
                       version: Int? = 48, tables: Int = 73,
                       required: Int = DatabaseBootPolicy.requiredTables.count,
                       originals: Bool = false) -> DatabaseProbeSnapshot {
        DatabaseProbeSnapshot(
            exists: exists, sizeBytes: size, headerValid: header,
            observedVersion: version, tableCount: tables,
            requiredTablesPresent: required,
            requiredTablesExpected: DatabaseBootPolicy.requiredTables.count,
            originalsPresent: originals)
    }

    @Test func missingFileWithoutOriginalsIsFresh() {
        #expect(DatabaseBootPolicy.decide(probe(exists: false), supportedVersion: 48) == .fresh)
    }

    @Test func missingFileWithOriginalsBlocksRebuild() {
        #expect(DatabaseBootPolicy.decide(probe(exists: false, originals: true), supportedVersion: 48)
                == .missingWithOriginals)
    }

    @Test func emptyFileIsCorruptNotFresh() {
        #expect(DatabaseBootPolicy.decide(probe(size: 0), supportedVersion: 48)
                == .corrupt(.emptyFile))
    }

    @Test func nonSQLiteHeaderIsCorrupt() {
        #expect(DatabaseBootPolicy.decide(probe(header: false), supportedVersion: 48)
                == .corrupt(.badHeader))
    }

    @Test func unreadableVersionIsCorrupt() {
        #expect(DatabaseBootPolicy.decide(probe(version: nil), supportedVersion: 48)
                == .corrupt(.unreadableVersion))
    }

    @Test func zeroVersionWithTablesIsCorrupt() {
        #expect(DatabaseBootPolicy.decide(probe(version: 0, tables: 3), supportedVersion: 48)
                == .corrupt(.versionZeroWithTables))
    }

    @Test func zeroVersionWithoutTablesIsFresh() {
        #expect(DatabaseBootPolicy.decide(probe(version: 0, tables: 0), supportedVersion: 48) == .fresh)
    }

    @Test func emptyFileWithOriginalsBlocksRebuild() {
        // 空 SQLite 文件 + 原件证据 = 半恢复/外部产物，不得当全新库重建。
        #expect(DatabaseBootPolicy.decide(probe(version: 0, tables: 0, originals: true),
                                          supportedVersion: 48) == .missingWithOriginals)
    }

    @Test func missingCoreTableBlocksEvenAtLatestVersion() {
        #expect(DatabaseBootPolicy.decide(probe(required: 2), supportedVersion: 48)
                == .corrupt(.missingRequiredTables))
    }

    @Test func olderVersionPlansMigrationWithExplicitEndpoints() {
        #expect(DatabaseBootPolicy.decide(probe(version: 47), supportedVersion: 48)
                == .migrate(from: 47, to: 48))
    }

    @Test func latestVersionIsReady() {
        #expect(DatabaseBootPolicy.decide(probe(version: 48), supportedVersion: 48)
                == .ready(version: 48))
    }

    @Test func newerVersionIsRejected() {
        #expect(DatabaseBootPolicy.decide(probe(version: 49), supportedVersion: 48)
                == .tooNew(found: 49, supported: 48))
    }
}
