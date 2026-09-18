import Foundation
import Domain

/// M1a 持久化端口（评审修正：AppState 不得直连 UserDefaults——
/// 「窄实现」允许窄化能力，不允许换掉已定的存储介质 §4.3 GRDB）。
/// 生产实现 GRDBPatientPersistor（Infrastructure），测试/Preview 可用内存实现。
public protocol PatientPersisting: Sendable {
    func loadOwner() async throws -> LocalOwner?
    func saveOwner(_ owner: LocalOwner, profile: PatientProfile) async throws
    /// 本机注册原子流（data-flow V2.31，业主 2026-09-17 定）：local_owner + 本人
    /// patient_profile + 首位紧急联系人同一事务落库；contact nil = 只建身份不建联系人。
    func saveOwner(_ owner: LocalOwner, profile: PatientProfile, contact: EmergencyContactDraft?) async throws
    /// F3 成员管理（FR3.7 添加家人）：saveOwner 的同族成员写入/读取。
    func saveMember(_ profile: PatientProfile) async throws
    func members() async throws -> [PatientProfile]
    /// FR3.1 成员字段补全（血型/证件号/医保号等）
    func updateMember(_ profile: PatientProfile) async throws
    func loadConsents() async throws -> [ConsentRecord]
    func saveConsent(_ c: ConsentRecord) async throws
    /// FR22.4 数据与存储健康：逻辑库大小（page_count × page_size）与完整性。
    /// 完整性 false 不得充当「正常」展示——数据健康页必须给真实值。
    func databaseHealth() async throws -> (sizeBytes: Int64, integrityOK: Bool)
    /// UI 测试清态（-uitest-reset）：等价首次安装，不重建 schema
    func reset() async throws
}

// MARK: - saveOwner(contact:) 默认实现（既有实现/测试替身免改）

public extension PatientPersisting {
    /// 默认 = 两参形态：既有实现/测试替身只建身份不建联系人；
    /// 生产 `GRDBPatientPersistor` 以三参事务覆盖。
    func saveOwner(_ owner: LocalOwner, profile: PatientProfile, contact: EmergencyContactDraft?) async throws {
        try await saveOwner(owner, profile: profile)
    }
}
