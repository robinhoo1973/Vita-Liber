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
    /// 注册 +（可选）自动家庭成员同一事务落库（2026-10-30 业主：建档时填写的
    /// 家庭成员紧急联系必须自动进入常用成员；两次写入会留下「联系人已存、
    /// 成员缺失」的半状态，且磁盘满载/DB busy 时用户看不到任何提示）。
    func saveOwner(_ owner: LocalOwner, profile: PatientProfile,
                   contact: EmergencyContactDraft?, autoMember: PatientProfile?) async throws
    /// F3 成员管理（FR3.7 添加家人）：saveOwner 的同族成员写入/读取。
    func saveMember(_ profile: PatientProfile) async throws
    func members() async throws -> [PatientProfile]
    /// FR3.1 成员字段补全（血型/证件号/医保号等）
    func updateMember(_ profile: PatientProfile) async throws
    /// 助手语音/文本动作的成员字段更新（V12/V13）：默认忽略审计，生产实现同事务落库。
    func updateMember(_ profile: PatientProfile, audit: VoiceExecutionAudit?) async throws
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

    /// 默认 = 三参形态 + 成员写入（测试替身/旧实现零改动）。
    /// 生产 `GRDBPatientPersistor` 覆盖为单事务：自动成员不得与联系人分叉。
    func saveOwner(_ owner: LocalOwner, profile: PatientProfile,
                   contact: EmergencyContactDraft?, autoMember: PatientProfile?) async throws {
        try await saveOwner(owner, profile: profile, contact: contact)
        if let autoMember { try await saveMember(autoMember) }
    }

    /// 默认忽略审计（测试替身/旧实现零改动）；生产 GRDB 实现覆盖。
    func updateMember(_ profile: PatientProfile, audit: VoiceExecutionAudit?) async throws {
        try await updateMember(profile)
    }

}
