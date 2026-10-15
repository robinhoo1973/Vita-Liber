import Domain
import Foundation

/// Stable DI identity for both read surfaces. Preparing a replacement never
/// mutates the live pair; committing it is a single non-suspending operation.
public final class MedicalCatalogReadAccess: MedicalCatalogReading, MedicalReferenceCatalogReading, @unchecked Sendable {
    public enum Failure: Error { case unavailable, snapshotChanged }

    struct Snapshot: Sendable {
        let drugs: any MedicalCatalogReading
        let references: any MedicalReferenceCatalogReading
        let version: MedicalCatalogInstalledVersion
        let retainedFile: MedicalCatalogSnapshotFile?

        init(drugs: any MedicalCatalogReading, references: any MedicalReferenceCatalogReading,
             version: MedicalCatalogInstalledVersion, retainedFile: MedicalCatalogSnapshotFile? = nil) {
            self.drugs = drugs
            self.references = references
            self.version = version
            self.retainedFile = retainedFile
        }
    }

    private let lock = NSLock()
    private var current: Snapshot?
    private var generation: UInt64 = 0

    public init() {}

    public var catalogGeneration: UInt64 { lock.withLock { generation } }
    public var isAvailable: Bool { lock.withLock { current != nil } }
    public var installedVersion: MedicalCatalogInstalledVersion? { lock.withLock { current?.version } }

    func commit(_ snapshot: Snapshot) {
        lock.withLock {
            current = snapshot
            generation &+= 1
        }
    }

    private func read<T: Sendable>(
        _ operation: @Sendable (Snapshot) async throws -> T
    ) async throws -> T {
        let (snapshot, started) = try lock.withLock { () throws -> (Snapshot, UInt64) in
            guard let current else { throw Failure.unavailable }
            return (current, generation)
        }
        defer { withExtendedLifetime(snapshot) {} }
        let result = try await operation(snapshot)
        guard lock.withLock({ generation == started }) else { throw Failure.snapshotChanged }
        return result
    }

    public func match(line: PrescriptionLine) async throws -> MedicalCatalogMatch {
        try await read { try await $0.drugs.match(line: line) }
    }
    public func reference(for drug: MedicalCatalogDrug) async throws -> [MedicalCatalogReference] {
        try await read { try await $0.drugs.reference(for: drug) }
    }
    public func detail(for drug: MedicalCatalogDrug) async throws -> MedicalCatalogDrugDetail? {
        try await read { try await $0.drugs.detail(for: drug) }
    }
    public func drug(id: Int) async throws -> MedicalCatalogDrug? {
        try await read { try await $0.drugs.drug(id: id) }
    }
    public func hospitalSuggest(query: String, region: String?, limit: Int) async throws -> [MedicalCatalogHospital] {
        try await read { try await $0.references.hospitalSuggest(query: query, region: region, limit: limit) }
    }
    public func departmentList(region: String?) async throws -> [MedicalCatalogDepartment] {
        try await read { try await $0.references.departmentList(region: region) }
    }
    public func diagnosisSuggest(query: String, system: String?, region: String?, limit: Int) async throws -> [MedicalCatalogDiagnosis] {
        try await read { try await $0.references.diagnosisSuggest(query: query, system: system, region: region, limit: limit) }
    }
    public func examSuggest(query: String, category: String?, region: String?, limit: Int) async throws -> [MedicalCatalogExamItem] {
        try await read { try await $0.references.examSuggest(query: query, category: category, region: region, limit: limit) }
    }
    public var catalogSchemaVersion: Int {
        get async throws { try await read { $0.version.schemaVersion } }
    }
}

#if os(iOS) || os(macOS)
extension MedicalCatalogReadAccess {
    public convenience init(path: URL) throws {
        self.init()
        commit(try Self.prepare(path: path))
    }

    static func prepare(path: URL, candidate: VerifiedMedicalCatalogCandidate? = nil,
                        expected: MedicalCatalogInstalledVersion? = nil) throws -> Snapshot {
        let retained = try MedicalCatalogSnapshotFile.pin(path)
        let version = try MedicalCatalogStore.installedVersion(path: retained.url)
        guard expected == nil || (version.schemaVersion == expected?.schemaVersion
                && version.dataVersion == expected?.dataVersion
                && (version.schemaVersion != 9 || version.contentSHA256 == expected?.contentSHA256)),
              candidate == nil || (version.schemaVersion == candidate?.schemaVersion
                && version.dataVersion == candidate?.dataVersion
                && (version.schemaVersion != 9 || version.contentSHA256 == candidate?.contentSHA256)) else {
            throw MedicalCatalogUpdateError.catalogIntegrityFailed
        }
        if let requiredSHA = candidate?.sqliteSHA256 ?? expected?.sqliteSHA256 {
            let actualSHA = try version.sqliteSHA256 ?? StreamingFileHasher.sha256(of: retained.url)
            guard actualSHA == requiredSHA else { throw MedicalCatalogUpdateError.checksumMismatch }
        }
        try MedicalCatalogStore.validateReleaseAndSmoke(path: retained.url,
            schemaVersion: version.schemaVersion, dataVersion: version.dataVersion,
            contentSHA256: candidate?.contentSHA256 ?? expected?.contentSHA256 ?? version.contentSHA256)
        let drugs = try MedicalCatalogStore(path: retained.url)
        let references = try MedicalReferenceCatalogStore(path: retained.url.path)
        guard drugs.version == references.version,
              drugs.version.schemaVersion == version.schemaVersion,
              drugs.version.dataVersion == version.dataVersion,
              drugs.version.activationID == version.activationID else {
            throw MedicalCatalogUpdateError.catalogIntegrityFailed
        }
        return Snapshot(drugs: drugs, references: references, version: version, retainedFile: retained)
    }
}
#endif
