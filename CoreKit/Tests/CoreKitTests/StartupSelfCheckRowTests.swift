import Testing
@testable import Domain

/// U-批 B3：启动自检三行状态推导矩阵（纯 Domain；行④在 App 层用 aggregate）。
@Suite("SU-M2-SELFCHECK-ROWS")
struct StartupSelfCheckRowTests {
    private static let probeExists = DatabaseProbeSnapshot(
        exists: true, sizeBytes: 4096, headerValid: true, observedVersion: 49,
        tableCount: 30, requiredTablesPresent: 3, requiredTablesExpected: 3,
        originalsPresent: false)
    private static let probeMissingNoOriginals = DatabaseProbeSnapshot(
        exists: false, sizeBytes: 0, headerValid: false, observedVersion: nil,
        tableCount: 0, requiredTablesPresent: 0, requiredTablesExpected: 3,
        originalsPresent: false)
    private static let probeMissingWithOriginals = DatabaseProbeSnapshot(
        exists: false, sizeBytes: 0, headerValid: false, observedVersion: nil,
        tableCount: 0, requiredTablesPresent: 0, requiredTablesExpected: 3,
        originalsPresent: true)

    private static func allReady() -> [CatalogSliceKind: CatalogSliceBootHealth] {
        var dict: [CatalogSliceKind: CatalogSliceBootHealth] = [:]
        for kind in CatalogSliceKind.allCases { dict[kind] = .ready }
        return dict
    }

    /// 批 ③：facts 契约由布尔升级为逐片真值；本工厂保留旧签名以零改写 15 例——
    /// true=全部片已提交（旧语义），false=未提交任何片。新增分歧场景另立用例。
    private static func facts(
        probe: DatabaseProbeSnapshot = probeExists,
        decision: DatabaseBootDecision?,
        health: [CatalogSliceKind: CatalogSliceBootHealth] = allReady(),
        facadeCommitted: Bool,
        didFail: Bool = false,
        isWorking: Bool = false
    ) -> StartupSelfCheckFacts {
        StartupSelfCheckFacts(probe: probe, decision: decision, health: health,
                              committedKinds: facadeCommitted ? Set(CatalogSliceKind.allCases) : [],
                              didFail: didFail, isWorking: isWorking)
    }

    @Test func pendingBeforeAnyDecision() {
        let rows = StartupSelfCheckRows.rows(Self.facts(decision: nil, facadeCommitted: false))
        #expect(rows.file == .pending)
        #expect(rows.schema == .pending)
        #expect(rows.catalog == .skipped)
    }

    @Test func workingBeforeDecisionIsRunning() {
        let rows = StartupSelfCheckRows.rows(
            Self.facts(decision: nil, facadeCommitted: false, isWorking: true))
        #expect(rows.file == .running)
        #expect(rows.schema == .running)
        #expect(rows.catalog == .running)
    }

    @Test func freshWorkingThenSettled() {
        let working = StartupSelfCheckRows.rows(
            Self.facts(probe: Self.probeMissingNoOriginals, decision: .fresh,
                       facadeCommitted: false, isWorking: true))
        #expect(working.file == .running)
        #expect(working.schema == .running)
        #expect(working.catalog == .running)

        let settled = StartupSelfCheckRows.rows(
            Self.facts(probe: Self.probeMissingNoOriginals, decision: .fresh,
                       facadeCommitted: true))
        #expect(settled.file == .passed)
        #expect(settled.schema == .passed)
        #expect(settled.catalog == .passed)
    }

    @Test func readyPathAllPassed() {
        let rows = StartupSelfCheckRows.rows(
            Self.facts(decision: .ready(version: 49), facadeCommitted: true))
        #expect(rows.file == .passed)
        #expect(rows.schema == .passed)
        #expect(rows.catalog == .passed)
    }

    @Test func migrateWorkingThenUpdated() {
        let working = StartupSelfCheckRows.rows(
            Self.facts(decision: .migrate(from: 48, to: 49),
                       facadeCommitted: false, isWorking: true))
        #expect(working.file == .passed)
        #expect(working.schema == .running)

        let done = StartupSelfCheckRows.rows(
            Self.facts(decision: .migrate(from: 48, to: 49), facadeCommitted: true))
        #expect(done.schema == .passed)
    }

    /// B3 评审修复：失败卡在屏（didFail）时行①②不得显示通过。
    @Test func freshFailureMarksFileFailedNotCreated() {
        let rows = StartupSelfCheckRows.rows(
            Self.facts(probe: Self.probeMissingNoOriginals, decision: .fresh,
                       facadeCommitted: false, didFail: true))
        #expect(rows.file == .failed)
        #expect(rows.schema == .skipped)
        #expect(rows.catalog == .skipped)
    }

    @Test func migrateFailureMarksSchemaFailedNotUpdated() {
        let rows = StartupSelfCheckRows.rows(
            Self.facts(decision: .migrate(from: 48, to: 49),
                       facadeCommitted: false, didFail: true))
        #expect(rows.file == .passed)
        #expect(rows.schema == .failed)
    }

    @Test func readyFailureMarksSchemaFailedNotOk() {
        let rows = StartupSelfCheckRows.rows(
            Self.facts(decision: .ready(version: 49),
                       facadeCommitted: false, didFail: true))
        #expect(rows.file == .passed)
        #expect(rows.schema == .failed)
        #expect(rows.catalog == .skipped)
    }

    @Test func tooNewFailsSchemaNotFile() {
        let rows = StartupSelfCheckRows.rows(
            Self.facts(decision: .tooNew(found: 50, supported: 49), facadeCommitted: false))
        #expect(rows.file == .passed)
        #expect(rows.schema == .failed)
        #expect(rows.catalog == .skipped)
    }

    @Test func corruptMissingTablesFailsSchema() {
        let rows = StartupSelfCheckRows.rows(
            Self.facts(decision: .corrupt(.missingRequiredTables), facadeCommitted: false))
        #expect(rows.file == .passed)
        #expect(rows.schema == .failed)
    }

    @Test(arguments: [
        DatabaseBootDecision.CorruptReason.emptyFile,
        .badHeader, .unreadableVersion, .versionZeroWithTables,
    ])
    func fileLevelCorruptionFailsFileRow(reason: DatabaseBootDecision.CorruptReason) {
        let rows = StartupSelfCheckRows.rows(
            Self.facts(decision: .corrupt(reason), facadeCommitted: false))
        #expect(rows.file == .failed)
        #expect(rows.schema == .skipped)
    }

    @Test func missingWithOriginalsFailsFileRow() {
        let rows = StartupSelfCheckRows.rows(
            Self.facts(probe: Self.probeMissingWithOriginals,
                       decision: .missingWithOriginals, facadeCommitted: false))
        #expect(rows.file == .failed)
        #expect(rows.schema == .skipped)
        #expect(rows.catalog == .skipped)
    }

    @Test func committedWithRequiredSliceMissingIsWarning() {
        var health = Self.allReady()
        health[.drug] = .integrityFailed
        let rows = StartupSelfCheckRows.rows(
            Self.facts(decision: .ready(version: 49), health: health, facadeCommitted: true))
        #expect(rows.catalog == .warning)
    }

    @Test func profileMissingNeverBlocksCatalogRow() {
        var health = Self.allReady()
        health[.profile] = .missing
        let rows = StartupSelfCheckRows.rows(
            Self.facts(decision: .ready(version: 49), health: health, facadeCommitted: true))
        #expect(rows.catalog == .passed)   // profile 可选（O4），不构成 warning
    }

    @Test func facadeCommittedCosmeticNeverClaimsReady() {
        // B2 快照语义：失败/advisory（facadeCommitted=false）行③不得显示 ready。
        let rows = StartupSelfCheckRows.rows(
            Self.facts(decision: .ready(version: 49), facadeCommitted: false))
        #expect(rows.catalog == .skipped)
    }
}
