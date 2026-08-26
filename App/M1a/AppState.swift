import Foundation
import SwiftUI
import Domain
import Infrastructure
import Protocols

/// M1a 纵向切片的应用状态仓（@Observable，注入进环境）。
/// 评审修正批（架构 A1-A3 / Swift S1-S2 / PM）：
/// - 持久化面向 M1aPersisting 协议，生产实现 = GRDBM1aPersistor（§4.3 对应表），
///   UserDefaults 仅承载 PIN 锁定快照与 UI 瞬态——「窄实现」窄化能力，不换存储介质；
/// - 锁定阶梯唯一实现 = Domain 的 PinLockStateMachine（actor），App 层只镜像快照；
/// - PIN 落盘 = PinHasher（盐+SHA256+恒时比较）；Keychain+PBKDF2 归 M1c §6 清偿；
/// - 假 OCR 收敛到 FakeOcrProvider（DocumentCapture 协议），生产代码无 -uitest 分支。
@MainActor
@Observable
final class AppState {
    enum OnboardingStage: Equatable {
        case disclosure(index: Int)
        case pinSetup, ownerName
        case scanCapture, ocrConfirm, timeline
        case done
    }

    var stage: OnboardingStage = .disclosure(index: 0)
    var onboardingFinished: Bool

    // 门禁（锁定状态 = Domain 状态机的镜像快照；唯一事实源在 actor 内）
    private(set) var pinHash: String?          // "saltHex:digestHex"（PinHasher）
    private(set) var failedAttempts = 0
    private(set) var lockedUntil: Date?
    private var pinMachine: PinLockStateMachine?

    // 所有者与档案
    private(set) var owner: LocalOwner?

    // 时间轴
    private(set) var timeline: [TimelineDocumentEntry] = []

    // L1 首启三卡确认（ConsentRecord 语义，FR20.5）
    private(set) var consentRecords: [ConsentRecord] = []

    private let persistor: any M1aPersisting
    private let captureProvider: any DocumentCapture
    private let defaults: UserDefaults
    private let launchArgs: [String]
    private let logger = Logger(subsystem: "com.vitaliber", category: "appstate")

    init(persistor: any M1aPersisting,
         capture: any DocumentCapture,
         defaults: UserDefaults = .standard,
         launchArgs: [String] = ProcessInfo.processInfo.arguments) {
        self.persistor = persistor
        self.captureProvider = capture
        self.defaults = defaults
        self.launchArgs = launchArgs
        self.onboardingFinished = defaults.bool(forKey: "onboardingFinished")
        if launchArgs.contains("-uitest-reset") {
            defaults.removePersistentDomain(forName: Bundle.main.bundleIdentifier ?? "com.vitaliber.VitaLiber")
            self.onboardingFinished = false
        }
        self.pinHash = defaults.string(forKey: "pinHashV2")
        if let legacy = defaults.string(forKey: "pinHash"), !legacy.isEmpty {
            // 评审 S1：旧实现是恒等函数，pinHash 键里存的是 PIN 明文——直接删除，
            // 绝不做「明文→哈希」迁移（无法区分真哈希与明文）
            defaults.removeObject(forKey: "pinHash")
            defaults.removeObject(forKey: "failedAttempts")
            defaults.removeObject(forKey: "lockedUntil")
            defaults.removeObject(forKey: "lockStage")
        }
        if onboardingFinished {
            stage = .done
        } else {
            // 三卡断点续填：重启后从上次进度的下一张卡继续
            let progress = defaults.integer(forKey: "disclosureProgress")
            if progress > 0 {
                stage = .disclosure(index: min(progress, disclosureCards.count - 1))
            }
        }
    }

    /// 启动装配（VitaLiberApp .task 调用）：清态（UI 测试）→ 装配锁定状态机 →
    /// 从 GRDB 加载所有者/同意/时间轴。
    func bootstrap() async {
        if launchArgs.contains("-uitest-reset") {
            do { try await persistor.reset() }
            catch { logger.error("测试清态失败: \(error)") }
        }
        await bootstrapPinLock()
        do {
            owner = try await persistor.loadOwner()
            consentRecords = try await persistor.loadConsents()
            timeline = try await persistor.loadTimeline()
        } catch {
            logger.error("持久化加载失败: \(error)")
        }
    }

    private func bootstrapPinLock() async {
        guard pinMachine == nil else { return }
        let store = UserDefaultsPinLockStore(defaults: defaults)
        do {
            let machine = try await PinLockStateMachine(storage: store)
            pinMachine = machine
            refreshLockSnapshot(await machine.snapshot())
        } catch {
            logger.error("PinLockStateMachine 装配失败: \(error)")
        }
    }

    @MainActor
    private func refreshLockSnapshot(_ s: PinLockSnapshot) {
        failedAttempts = s.consecutiveFailures
        lockedUntil = s.lockedUntil
    }

    // MARK: - 披露三卡

    var disclosureCards: [DisclosureCard] { DisclosureRegistry.l1Cards }

    func advanceDisclosure() {
        guard case .disclosure(let i) = stage else { return }
        // 每张卡确认即落 ConsentRecord（FR20.5 / TC-M1a-05）；按 key 去重，
        // 杀进程重走三卡不得重复落库（评审修正）
        let card = disclosureCards[i]
        if !consentRecords.contains(where: { $0.key == card.key }) {
            let record = ConsentRecord(key: card.key, version: card.version,
                                       acceptedAt: Date().timeIntervalSince1970)
            consentRecords.append(record)
            persist { [persistor] in try await persistor.saveConsent(record) }
        }
        // 断点续填（FR21.9）：进度落盘，重启后从当前卡继续
        defaults.set(i + 1, forKey: "disclosureProgress")
        if i + 1 < disclosureCards.count {
            stage = .disclosure(index: i + 1)
        } else {
            stage = .pinSetup
        }
    }

    // MARK: - PIN（阶梯唯一实现在 Domain actor）

    func setupPin(_ pin: String) {
        guard pin.count == 6, pin.allSatisfy(\.isNumber) else { return }
        let h = PinHasher.makeHash(pin: pin)
        pinHash = h.stored
        defaults.set(h.stored, forKey: "pinHashV2")
        stage = .ownerName
    }

    var isLocked: Bool {
        guard let until = lockedUntil else { return false }
        return until > Date()
    }

    /// 锁屏倒计时（ui-ux §5.1）
    var remainingLockSeconds: Int {
        guard let until = lockedUntil else { return 0 }
        return max(0, Int(until.timeIntervalSince(Date())) + 1)
    }

    func verifyPin(_ pin: String) async -> Bool {
        guard let machine = pinMachine else { return false }
        if await machine.isLocked {
            refreshLockSnapshot(await machine.snapshot())
            return false
        }
        guard let stored = pinHash, PinHasher.verify(pin: pin, stored: stored) else {
            do { _ = try await machine.recordFailure() }
            catch { logger.error("recordFailure 持久化失败: \(error)") }
            refreshLockSnapshot(await machine.snapshot())
            return false
        }
        do { try await machine.recordSuccess() }
        catch { logger.error("recordSuccess 持久化失败: \(error)") }
        refreshLockSnapshot(await machine.snapshot())
        lastVerifiedAt = Date()
        return true
    }

    // MARK: - 所有者

    func createOwner(name: String) {
        var o = LocalOwner(displayName: name, createdAt: Date().timeIntervalSince1970)
        let profile = PatientProfile(displayName: name, relation: "本人",
                                     createdAt: o.createdAt, updatedAt: o.createdAt)
        o.selfPatientId = profile.id
        owner = o
        defaults.set(profile.id.uuidString, forKey: "selfPatientId")
        persist { [persistor] in try await persistor.saveOwner(o, profile: profile) }
        stage = .scanCapture
    }

    /// FR21.9：建档可跳过——以「本人」占位，稍后在设置中修改
    func skipOwner() {
        owner = LocalOwner(displayName: "本人", createdAt: Date().timeIntervalSince1970)
        stage = .scanCapture
    }

    // MARK: - 拍摄与 OCR 确认（DocumentCapture 协议注入）

    private(set) var activeSet: OcrConfirmationSet?

    func captureSample() {
        Task {
            do {
                activeSet = try await captureProvider.capture()
                stage = .ocrConfirm
            } catch {
                logger.error("拍摄管线失败: \(error)")
            }
        }
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
        persist { [persistor, timeline] in try await persistor.saveTimeline(timeline) }
        activeSet = nil
        stage = .timeline
    }

    func finishOnboarding() {
        onboardingFinished = true
        defaults.set(true, forKey: "onboardingFinished")
        stage = .done
    }

    /// PIN 已建立即受门禁保护（评审修正：向导期间退后台同样锁屏——FR1.4 自 PIN 建立起成立）
    var isPinProtected: Bool { pinHash != nil }

    /// 验证成功信号：LockOverlayView 观察它解除 backgroundLocked
    private(set) var lastVerifiedAt: Date?

    /// 统一异步持久化出口（§7：错误必须经 Logger 上报，不静默吞掉）
    private func persist(_ op: @escaping @Sendable () async throws -> Void) {
        Task {
            do { try await op() }
            catch { logger.error("持久化失败: \(error)") }
        }
    }
}
