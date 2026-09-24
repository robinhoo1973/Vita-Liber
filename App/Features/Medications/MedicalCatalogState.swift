import Foundation
import Domain
import Infrastructure
import Perception

/// 药品目录 App 读面：匹配是建议/证据，不自动写处方行 medication_id。
@MainActor
@Perceptible
final class MedicalCatalogState {
    private var store: MedicalCatalogStore?
    private let updater: MedicalCatalogUpdateService?
    private let path: URL?
    var matchByLineID: [UUID: MedicalCatalogMatch] = [:]

    init(store: MedicalCatalogStore?, updater: MedicalCatalogUpdateService? = nil, path: URL? = nil) {
        self.store = store
        self.updater = updater
        self.path = path
    }

    var isAvailable: Bool { store != nil }

    func match(_ line: PrescriptionLine) async -> MedicalCatalogMatch? {
        guard let store else { return nil }
        do {
            let result = try await store.match(line: line)
            matchByLineID[line.id] = result
            return result
        } catch {
            return nil
        }
    }

    func drug(id: Int) async -> MedicalCatalogDrug? {
        guard let store else { return nil }
        return try? await store.drug(id: id) // try?-ok: 目录查询失败=详情空态（ProgressView 降级，不崩）
    }

    func references(for drug: MedicalCatalogDrug) async -> [MedicalCatalogReference] {
        guard let store else { return [] }
        return (try? await store.reference(for: drug)) ?? [] // try?-ok: 目录查询失败=无参考链接（降级不崩）
    }

    func detail(for drug: MedicalCatalogDrug) async -> MedicalCatalogDrugDetail? {
        guard let store else { return nil }
        return try? await store.detail(for: drug) // try?-ok: 目录详情缺失=只展示主记录
    }

    func update(_ release: MedicalCatalogRelease,
                opener: any MedicalCatalogPackageOpening) async -> Bool {
        guard let updater, let path else { return false }
        do {
            try await updater.update(release, opener: opener)
            store = try MedicalCatalogStore(path: path)
            matchByLineID.removeAll()
            return true
        } catch {
            return false
        }
    }
}
