import Domain
import Foundation
import Testing
@testable import Infrastructure

@Suite("Catalog pair generation fencing", .timeLimit(.minutes(2)))
struct MedicalCatalogReadAccessTests {
    @Test("late drug and reference results from a retired generation are rejected")
    func fencesBothSurfaces() async throws {
        for referenceQuery in [false, true] {
            let gate = CatalogReadGate()
            let readers = MedicalCatalogReadAccess()
            let old = DelayedCatalog(gate: gate)
            readers.commit(.init(drugs: old, references: old,
                version: .init(schemaVersion: 9, dataVersion: "A")))
            let task = Task {
                if referenceQuery {
                    _ = try await readers.hospitalSuggest(query: "old", region: nil, limit: 1)
                } else {
                    _ = try await readers.drug(id: 1)
                }
            }
            defer {
                task.cancel()
                Task { await gate.resume() }
            }
            try await gate.waitUntilEntered()
            let fresh = DelayedCatalog(gate: nil)
            readers.commit(.init(drugs: fresh, references: fresh,
                version: .init(schemaVersion: 9, dataVersion: "B")))
            await gate.resume()
            do {
                try await task.value
                Issue.record("old-generation result escaped the facade")
            } catch MedicalCatalogReadAccess.Failure.snapshotChanged {
                #expect(readers.installedVersion?.dataVersion == "B")
                #expect(readers.catalogGeneration == 2)
            }
        }
    }
}

private actor CatalogReadGate {
    enum Failure: Error { case timedOut }
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func waitUntilEntered() async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while continuation == nil {
            try Task.checkCancellation()
            guard clock.now < deadline else { throw Failure.timedOut }
            await Task.yield()
        }
    }
    func resume() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private struct DelayedCatalog: MedicalCatalogReading, MedicalReferenceCatalogReading {
    let gate: CatalogReadGate?
    func drug(id: Int) async throws -> MedicalCatalogDrug? { await gate?.wait(); return nil }
    func match(line: PrescriptionLine) async throws -> MedicalCatalogMatch {
        .init(status: .unmatched, exact: nil, candidates: [])
    }
    func reference(for drug: MedicalCatalogDrug) async throws -> [MedicalCatalogReference] { [] }
    func detail(for drug: MedicalCatalogDrug) async throws -> MedicalCatalogDrugDetail? { nil }
    func hospitalSuggest(query: String, region: String?, limit: Int) async throws -> [MedicalCatalogHospital] {
        await gate?.wait(); return []
    }
    func departmentList(region: String?) async throws -> [MedicalCatalogDepartment] { [] }
    func diagnosisSuggest(query: String, system: String?, region: String?, limit: Int) async throws -> [MedicalCatalogDiagnosis] { [] }
    func examSuggest(query: String, category: String?, region: String?, limit: Int) async throws -> [MedicalCatalogExamItem] { [] }
    var catalogSchemaVersion: Int { get async throws { 9 } }
}
