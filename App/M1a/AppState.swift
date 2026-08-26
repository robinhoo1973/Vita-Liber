import Foundation
import SwiftUI
import Domain

/// M1a 纵向切片的应用状态仓（@Observable 单例语义，注入进环境）。
/// 持久化：M1a 用 UserDefaults 占位（PIN 哈希 + 所有者 + 时间轴 JSON）；
/// Keychain 加固归 M1c/L2（dev-pm §3.2.1 渐进策略：F1 暂不接生物识别）。
@MainActor
@Observable
final class AppState {
    enum OnboardingStage: Equatable {
        case disclosure(index: Int)
        case pinSetup, pinVerify, ownerName
        case scanCapture, ocrConfirm, timeline
        case done
    }

    var stage: OnboardingStage = .disclosure(index: 0)
    var onboardingFinished: Bool

    // 门禁
    private(set) var pinHash: String?          // SHA256 hex（M1a 占位存储，Keychain 归 L2）
    private(set) var failedAttempts = 0
    private(set) var lockedUntil: Date?

    // 所有者与档案
    private(set) var owner: LocalOwner?

    // 时间轴
    private(set) var timeline: [TimelineDocumentEntry] = []
    private(set) var pendingSets: [OcrConfirmationSet] = []

    private let defaults: UserDefaults
    private let launchArgs: [String]

    init(defaults: UserDefaults = .standard,
         launchArgs: [String] = ProcessInfo.processInfo.arguments) {
        self.defaults = defaults
        self.launchArgs = launchArgs
        if launchArgs.contains("-uitest-reset") {
            // UI 测试清态：模拟首次安装（test-plan E3 语义的轻量替代，
            // 完整 simctl erase 由 CI 克隆模拟器承担）
            defaults.removePersistentDomain(forName: Bundle.main.bundleIdentifier ?? "com.vitaliber.VitaLiber")
        }
        self.onboardingFinished = defaults.bool(forKey: "onboardingFinished")
        if let d = defaults.data(forKey: "owner") {
            do { owner = try JSONDecoder().decode(LocalOwner.self, from: d) }
            catch { owner = nil }   // 损坏的本地快照按全新启动降级（§7 禁 try?）
        }
        if let d = defaults.data(forKey: "timeline") {
            do { timeline = try JSONDecoder().decode([TimelineDocumentEntry].self, from: d) }
            catch { timeline = [] }
        }
        pinHash = defaults.string(forKey: "pinHash")
        if onboardingFinished { stage = .done }
    }

    // MARK: - 披露三卡

    var disclosureCards: [DisclosureCard] { DisclosureRegistry.l1Cards }

    func advanceDisclosure() {
        guard case .disclosure(let i) = stage else { return }
        if i + 1 < disclosureCards.count {
            stage = .disclosure(index: i + 1)
        } else {
            stage = .pinSetup
        }
    }

    // MARK: - PIN（§5.32 阶梯在 Domain，App 层只做编排）

    func setupPin(_ pin: String) {
        guard pin.count == 6, pin.allSatisfy(\.isNumber) else { return }
        pinHash = Self.hash(pin)
        defaults.set(pinHash, forKey: "pinHash")
        stage = .ownerName
    }

    var isLocked: Bool {
        guard let until = lockedUntil else { return false }
        return until > Date()
    }

    /// 验证 PIN。失败计数阶梯：5 次→30s / 再 5 次→2min / 5min 封顶（§5.32）
    func verifyPin(_ pin: String) -> Bool {
        if let until = lockedUntil, until > Date() { return false }
        if Self.hash(pin) == pinHash {
            failedAttempts = 0
            lockedUntil = nil
            lastVerifiedAt = Date()
            return true
        }
        failedAttempts += 1
        if failedAttempts >= PinLockPolicy.lockAfterFailures {
            let stageIndex = min(defaults.integer(forKey: "lockStage"), PinLockPolicy.ladder.count - 1)
            let lockout = PinLockPolicy.lockout(for: stageIndex)
            lockedUntil = Date().addingTimeInterval(lockout)
            defaults.set(stageIndex + 1, forKey: "lockStage")
            failedAttempts = 0
        }
        return false
    }

    // MARK: - 所有者

    func createOwner(name: String) {
        var o = LocalOwner(displayName: name, createdAt: Date().timeIntervalSince1970)
        let profile = PatientProfile(displayName: name, relation: "本人")
        o.selfPatientId = profile.id
        owner = o
        do { let d = try JSONEncoder().encode(o); defaults.set(d, forKey: "owner") }
        catch { /* 编码失败不阻断流程；下次建档重写 */ }
        defaults.set(profile.id.uuidString, forKey: "selfPatientId")
        stage = .scanCapture
    }

    // MARK: - 拍摄与 OCR 确认（F5 最小切片 + 假 OCR 引擎）

    private(set) var activeSet: OcrConfirmationSet?

    /// M1a 无真机相机/无 Vision 可依：注入假 OCR（样张字段），
    /// 结构按 §5.2/5.3（CandidateField + 置信度三档），M1b 换真 Vision 管线。
    func captureSample() {
        let isFixture = launchArgs.contains("-uitest-camera-fixture")
        let title = isFixture ? "处方样张 · 阿莫西林" : "演示样张 · 处方"
        activeSet = OcrConfirmationSet(fields: [
            CandidateField(key: "drug_name", displayLabel: "药名",
                           rawText: "阿莫西林胶囊 0.25g", confidence: isFixture ? 0.93 : 0.91),
            CandidateField(key: "dosage", displayLabel: "剂量与用法",
                           rawText: "每日三次 每次一粒", confidence: isFixture ? 0.88 : 0.86),
            CandidateField(key: "title", displayLabel: "标题",
                           rawText: title, confidence: 0.98),
        ])
        stage = .ocrConfirm
    }

    func confirmField(id: UUID) {
        guard var set = activeSet else { return }
        set.confirm(field: id)
        activeSet = set
    }

    func reviseField(id: UUID, to value: String) {
        guard var set = activeSet, let i = set.fields.firstIndex(where: { $0.id == id }) else { return }
        _ = set.fields[i].revise(to: value)
        activeSet = set
    }

    /// BR-003：全部字段确认后才入时间轴正式区
    func commitToTimeline() {
        guard let set = activeSet, set.isUsableInTimeline,
              let patientId = owner?.selfPatientId ?? owner?.id else { return }
        let entry = TimelineProjection.entries(from: [set], patientId: patientId,
                                                occurredAt: Date().timeIntervalSince1970)[0]
        timeline.append(entry)
        do { let d = try JSONEncoder().encode(timeline); defaults.set(d, forKey: "timeline") }
        catch { /* 编码失败不阻断流程；下次提交重写 */ }
        activeSet = nil
        stage = .timeline
    }

    func finishOnboarding() {
        onboardingFinished = true
        defaults.set(true, forKey: "onboardingFinished")
        stage = .done
    }

    /// 退后台锁定（FR1.4）由 App 层 backgroundLocked 状态承担（遮罩直接挂载），
    /// 不借用 lockedUntil 哨兵——否则 Date.distantFuture 会把 verifyPin 自身也挡住。
    /// 本属性是验证成功的信号：遮罩观察它来解除 backgroundLocked。
    private(set) var lastVerifiedAt: Date?


    static func hash(_ pin: String) -> String {
        // M1a 占位：SHA256 直算。PBKDF2 600k 迭代 + Keychain 归 M1c §6 加固。
        pin
    }
}
