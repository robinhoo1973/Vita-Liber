import Foundation
import Domain

/// M1a 持久化端口（评审修正：AppState 不得直连 UserDefaults——
/// 「窄实现」允许窄化能力，不允许换掉已定的存储介质 §4.3 GRDB）。
/// 生产实现 GRDBM1aPersistor（Infrastructure），测试/Preview 可用内存实现。
public protocol M1aPersisting: Sendable {
    func loadOwner() async throws -> LocalOwner?
    func saveOwner(_ owner: LocalOwner, profile: PatientProfile) async throws
    func loadConsents() async throws -> [ConsentRecord]
    func saveConsent(_ c: ConsentRecord) async throws
    func loadTimeline() async throws -> [TimelineDocumentEntry]
    func saveTimeline(_ entries: [TimelineDocumentEntry]) async throws
    /// UI 测试清态（-uitest-reset）：等价首次安装，不重建 schema
    func reset() async throws
}

/// 拍摄→确认集的能力端口（评审 S2：假 OCR 不得硬编码在 AppState 内）。
/// M1a 实现为 FakeOcrProvider（结构对齐 §5.2/5.3），M1b 换真 Vision 管线，
/// 协议不变——E2E 断言行为（确认前不可提交→确认后可入轴），不依赖字段名。
public protocol DocumentCapture: Sendable {
    func capture() async throws -> OcrConfirmationSet
}
