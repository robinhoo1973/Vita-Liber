import Foundation
import Domain
import Infrastructure
import Perception

/// 药品目录 App 读面：匹配是建议/证据，不自动写处方行 medication_id。
@MainActor
@Perceptible
final class MedicalCatalogState {
    private let store: MedicalCatalogStore?
    var matchByLineID: [UUID: MedicalCatalogMatch] = [:]

    init(store: MedicalCatalogStore?) {
        self.store = store
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
}
