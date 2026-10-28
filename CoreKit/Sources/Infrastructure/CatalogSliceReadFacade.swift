#if os(iOS) || os(macOS)
// linux-blind: 依赖三个 GRDB 只读仓 —— Linux 型检编译空单元，改动须经 macOS CI 验证
import Domain
import Foundation

/// 三切片读面合成（2026-10-28 切片-only；二轮质询裁决 9）。
///
/// - **每片独立 store、各自持 DatabasePool**，facade 只持引用：共享的只有
///   facade，绝不共享 actor——单 actor 三池实测串行（drug_reference 全扫
///   0.583s 会阻塞其他域）；
/// - NSLock 内只取快照引用、锁外 await（沿用 v4 `MedicalCatalogReadAccess` 模式）；
/// - fencing：每片独立 `generation`（在途读遇该片 commit 抛 `snapshotChanged`），
///   另设全局 `epoch` 仅给复合读/观察者（任一片 commit 递增）；
/// - 缺片 = 该域不可用：drug 面抛 `Failure.unavailable`；facility/exam 面
///   返回空集（患者流零提示，联想自然退化为普通输入）——绝不回退到 v4 或他片。
public final class CatalogSliceReadFacade: MedicalCatalogReading, MedicalReferenceCatalogReading,
                                           MedicalProfileCatalogReading, @unchecked Sendable {
    public enum Failure: Error, Equatable {
        case unavailable
        case snapshotChanged
    }

    private struct Slot<Store> {
        let store: Store
        let generation: UInt64
    }

    private let lock = NSLock()
    private var drug: Slot<CatalogSliceDrugStore>?
    private var facility: Slot<CatalogSliceFacilityStore>?
    private var exam: Slot<CatalogSliceExamStore>?
    private var profile: Slot<CatalogSliceProfileStore>?
    private var epoch: UInt64 = 0

    public init() {}

    // MARK: - 状态

    public var catalogGeneration: UInt64 { lock.withLock { epoch } }
    public var isDrugAvailable: Bool { lock.withLock { drug != nil } }
    public var isFacilityAvailable: Bool { lock.withLock { facility != nil } }
    public var isExamAvailable: Bool { lock.withLock { exam != nil } }
    public var isProfileAvailable: Bool { lock.withLock { profile != nil } }

    /// 目录检索面是否可用（drug/facility/exam 三片任一；profile 不提供检索，
    /// 不得据此误判——P6 语义：`medicalReferenceCatalog` 以此谓词判 nil）。
    public var hasReferenceSlices: Bool {
        lock.withLock { drug != nil || facility != nil || exam != nil }
    }

    /// 当前可用切片（UI 分组渲染用；顺序按 allCases）。
    public var availableKinds: [CatalogSliceKind] {
        lock.withLock {
            CatalogSliceKind.allCases.filter { kind in
                switch kind {
                case .drug: return drug != nil
                case .facility: return facility != nil
                case .reference: return exam != nil
                case .profile: return profile != nil
                }
            }
        }
    }

    // MARK: - 提交（App 装配在激活/启动探测后调用；非挂起、单次生效）

    public func commitDrug(_ store: CatalogSliceDrugStore) {
        lock.withLock {
            drug = Slot(store: store, generation: (drug?.generation ?? 0) &+ 1)
            epoch &+= 1
        }
    }

    public func commitFacility(_ store: CatalogSliceFacilityStore) {
        lock.withLock {
            facility = Slot(store: store, generation: (facility?.generation ?? 0) &+ 1)
            epoch &+= 1
        }
    }

    public func commitExam(_ store: CatalogSliceExamStore) {
        lock.withLock {
            exam = Slot(store: store, generation: (exam?.generation ?? 0) &+ 1)
            epoch &+= 1
        }
    }

    public func commitProfile(_ store: CatalogSliceProfileStore) {
        lock.withLock {
            profile = Slot(store: store, generation: (profile?.generation ?? 0) &+ 1)
            epoch &+= 1
        }
    }

    /// 清空（备份恢复/清数据/全部切片移除时）；全局 epoch 递增使所有在途读失效。
    public func removeAll() {
        lock.withLock {
            drug = nil
            facility = nil
            exam = nil
            profile = nil
            epoch &+= 1
        }
    }

    // MARK: - MedicalCatalogReading（drug 切片；缺片抛 unavailable）

    public func match(line: PrescriptionLine) async throws -> MedicalCatalogMatch {
        try await withDrug { try await $0.match(line: line) }
    }

    public func reference(for drug: MedicalCatalogDrug) async throws -> [MedicalCatalogReference] {
        try await withDrug { try await $0.reference(for: drug) }
    }

    public func detail(for drug: MedicalCatalogDrug) async throws -> MedicalCatalogDrugDetail? {
        try await withDrug { try await $0.detail(for: drug) }
    }

    public func drug(id: Int) async throws -> MedicalCatalogDrug? {
        try await withDrug { try await $0.drug(id: id) }
    }

    // MARK: - MedicalReferenceCatalogReading（facility/reference 切片；缺片返回空集）

    public func hospitalSuggest(query: String, region: String?, limit: Int) async throws -> [MedicalCatalogHospital] {
        try await withFacility(whenUnavailable: []) {
            try await $0.hospitalSuggest(query: query, region: region, limit: limit)
        }
    }

    public func departmentList(region: String?) async throws -> [MedicalCatalogDepartment] {
        try await withFacility(whenUnavailable: []) { try await $0.departmentList(region: region) }
    }

    public func diagnosisSuggest(query: String, system: String?, region: String?, limit: Int) async throws -> [MedicalCatalogDiagnosis] {
        try await withExam(whenUnavailable: []) {
            try await $0.diagnosisSuggest(query: query, system: system, region: region, limit: limit)
        }
    }

    public func examSuggest(query: String, category: String?, region: String?, limit: Int) async throws -> [MedicalCatalogExamItem] {
        try await withExam(whenUnavailable: []) {
            try await $0.examSuggest(query: query, category: category, region: region, limit: limit)
        }
    }

    // MARK: - MedicalProfileCatalogReading（profile 切片；缺片抛 unavailable，不返回空集）

    public func profileSnapshot(region: String) async throws -> MedicalProfileCatalogSnapshot {
        try await withProfile { try await $0.profileSnapshot(region: region) }
    }

    /// 切片内容 schema 恒为当前支持版本（每片表集随 kind 在该版本冻结）；
    /// 不读任何库——视图在无目录时也可安全取值。
    public var catalogSchemaVersion: Int {
        get async throws { CatalogSliceProtocol.supportedSliceSchemaVersion }
    }

    // MARK: - 快照读（锁内取引用、锁外 await、代际 fencing）

    private func withDrug<T: Sendable>(
        _ operation: @Sendable (CatalogSliceDrugStore) async throws -> T
    ) async throws -> T {
        let snapshot: (CatalogSliceDrugStore, UInt64) = try lock.withLock {
            guard let slot = drug else { throw Failure.unavailable }
            return (slot.store, slot.generation)
        }
        let result = try await operation(snapshot.0)
        guard lock.withLock({ drug?.generation == snapshot.1 }) else { throw Failure.snapshotChanged }
        return result
    }

    private func withFacility<T: Sendable>(
        whenUnavailable: T,
        _ operation: @Sendable (CatalogSliceFacilityStore) async throws -> T
    ) async throws -> T {
        guard let snapshot: (CatalogSliceFacilityStore, UInt64) = lock.withLock({
            facility.map { ($0.store, $0.generation) }
        }) else {
            return whenUnavailable
        }
        let result = try await operation(snapshot.0)
        guard lock.withLock({ facility?.generation == snapshot.1 }) else { throw Failure.snapshotChanged }
        return result
    }

    private func withExam<T: Sendable>(
        whenUnavailable: T,
        _ operation: @Sendable (CatalogSliceExamStore) async throws -> T
    ) async throws -> T {
        guard let snapshot: (CatalogSliceExamStore, UInt64) = lock.withLock({
            exam.map { ($0.store, $0.generation) }
        }) else {
            return whenUnavailable
        }
        let result = try await operation(snapshot.0)
        guard lock.withLock({ exam?.generation == snapshot.1 }) else { throw Failure.snapshotChanged }
        return result
    }

    /// profile 缺片语义刻意区别于三片：基本需求数据不静默空集，显式 `.unavailable`。
    private func withProfile<T: Sendable>(
        _ operation: @Sendable (CatalogSliceProfileStore) async throws -> T
    ) async throws -> T {
        let snapshot: (CatalogSliceProfileStore, UInt64) = try lock.withLock {
            guard let slot = profile else { throw MedicalProfileCatalogFailure.unavailable }
            return (slot.store, slot.generation)
        }
        let result = try await operation(snapshot.0)
        guard lock.withLock({ profile?.generation == snapshot.1 }) else { throw Failure.snapshotChanged }
        return result
    }
}
#endif
