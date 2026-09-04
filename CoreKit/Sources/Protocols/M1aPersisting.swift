import Foundation
import Domain

/// M1a 持久化端口（评审修正：AppState 不得直连 UserDefaults——
/// 「窄实现」允许窄化能力，不允许换掉已定的存储介质 §4.3 GRDB）。
/// 生产实现 GRDBM1aPersistor（Infrastructure），测试/Preview 可用内存实现。
public protocol M1aPersisting: Sendable {
    func loadOwner() async throws -> LocalOwner?
    func saveOwner(_ owner: LocalOwner, profile: PatientProfile) async throws
    /// F3 成员管理（FR3.7 添加家人）：saveOwner 的同族成员写入/读取。
    func saveMember(_ profile: PatientProfile) async throws
    func members() async throws -> [PatientProfile]
    /// FR3.1 成员字段补全（血型/证件号/医保号等）
    func updateMember(_ profile: PatientProfile) async throws
    func loadConsents() async throws -> [ConsentRecord]
    func saveConsent(_ c: ConsentRecord) async throws
    func loadTimeline() async throws -> [TimelineDocumentEntry]
    func saveTimeline(_ entries: [TimelineDocumentEntry]) async throws
    /// FR6.1 OCR 结果独立存储（与 notes 解耦）：原文块+置信度+引擎版本留痕
    func saveOCRResult(documentId: UUID, fields: [CandidateField],
                       engineVersion: String) async throws
    /// FR22.4 数据与存储健康：逻辑库大小（page_count × page_size）与完整性。
    /// 完整性 false 不得充当「正常」展示——数据健康页必须给真实值。
    func databaseHealth() async throws -> (sizeBytes: Int64, integrityOK: Bool)
    /// UI 测试清态（-uitest-reset）：等价首次安装，不重建 schema
    func reset() async throws
}

/// 拍摄→确认集的能力端口（评审 S2：假 OCR 不得硬编码在 AppState 内）。
/// M1a 实现为 FakeOcrProvider（结构对齐 §5.2/5.3），M1b 换真 Vision 管线，
/// 协议不变——E2E 断言行为（确认前不可提交→确认后可入轴），不依赖字段名。
public protocol DocumentCapture: Sendable {
    func capture() async throws -> OcrConfirmationSet
}

/// FR12.11 图片文字识别端口。识别结果一律 D 级待确认（BR-003）——
/// 该判定在 Domain `ImageInputRules`，实现只负责产出文本行与置信度。
public protocol ImageTextRecognizing: Sendable {
    /// 从图片数据识别文字（零落盘：入参出参不含文件路径，实现内部流式处理）
    func recognize(_ imageData: Data) async throws -> ImageInputRules.Recognition
}

/// 测试/Preview 替身：脚本化识别结果。
public actor StubImageTextRecognizer: ImageTextRecognizing {
    private let scripted: ImageInputRules.Recognition
    public init(scripted: ImageInputRules.Recognition) { self.scripted = scripted }
    public func recognize(_ imageData: Data) async throws -> ImageInputRules.Recognition {
        scripted
    }
}
