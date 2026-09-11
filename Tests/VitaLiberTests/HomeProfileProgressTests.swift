import XCTest
import Foundation
import Observation
import Domain
import Protocols
@testable import VitaLiber

// binds: SU-M1c-REGRESSION — TC-M1c-08（FR2.1b / FR17.11 / BR-001）
@MainActor
final class HomeProfileProgressTests: XCTestCase {
    private func makeApp(profiles: [PatientProfile], defaults: UserDefaults? = nil) -> (AppState, HomeProfilePersistor) {
        let persistor = HomeProfilePersistor(profiles: profiles)
        return (makeApp(persistor: persistor, defaults: defaults ?? freshDefaults()), persistor)
    }

    private func makeApp(persistor: HomeProfilePersistor, defaults: UserDefaults) -> AppState {
        AppState(
            persistor: persistor,
            speech: RecordingSpeechSynthesizer(),
            imageRecognizer: StubImageTextRecognizer(scripted: .init(lines: [], confidence: 0)),
            transcription: UnavailableTranscriptionEngine(),
            textRefiner: UnavailableTextRefiner(),
            gateUnlocker: FakeGateUnlocker(result: false),
            defaults: defaults, launchArgs: [])
    }

    private func freshDefaults() -> UserDefaults {
        let suite = "HomeProfileProgressTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    func test_unloadedProfileDoesNotInventZeroOfEightProgress() async {
        let (app, _) = makeApp(profiles: [PatientProfile(displayName: "本人")])
        // 旧实现未加载即返回 0/8，首页会把未知状态误当未完成资料。
        XCTAssertNil(app.profileCompletion)
    }

    func test_whitespaceFieldsDoNotCountAsCompletedInformation() async throws {
        let profile = PatientProfile(displayName: "本人", birthDate: " \n",
                                     bloodType: " ", idNo: "\t", insuranceNo: "  ")
        let (app, _) = makeApp(profiles: [profile])
        await app.bootstrap()
        let progress = try XCTUnwrap(app.profileCompletion)
        XCTAssertEqual(progress.done, 0)
        XCTAssertEqual(progress.total, 8)
    }

    func test_legacyUnscopedInterviewFlagsDoNotCompleteOtherMembers() async throws {
        let defaults = freshDefaults()
        defaults.set(["allergy", "pastHistory", "currentMeds", "emergencyContact"],
                     forKey: "voiceInterviewSteps")
        let a = PatientProfile(displayName: "本人")
        let b = PatientProfile(displayName: "家人", relation: "子女")
        let (app, _) = makeApp(profiles: [a, b], defaults: defaults)
        await app.bootstrap()
        for id in [a.id, b.id] {
            app.setCurrentPatient(id)
            let progress = try XCTUnwrap(app.profileCompletion)
            XCTAssertEqual(progress.done, 0, "旧标记没有成员身份，不能猜测归属")
        }
    }

    func test_memberSwitchInvalidatesObservedProgressWithoutReloadingMembers() async {
        let a = PatientProfile(displayName: "本人", birthDate: "1980-01-01")
        let b = PatientProfile(displayName: "家人", relation: "子女")
        let (app, _) = makeApp(profiles: [a, b])
        await app.bootstrap()
        let changed = expectation(description: "成员切换必须发布新进度")
        withObservationTracking {
            _ = app.profileCompletion
        } onChange: {
            changed.fulfill()
        }
        app.setCurrentPatient(b.id)
        await fulfillment(of: [changed], timeout: 1)
    }

    func test_savedInterviewProgressIsMemberScopedAndSurvivesRestart() async throws {
        let defaults = freshDefaults()
        var a = PatientProfile(displayName: "本人")
        let b = PatientProfile(displayName: "家人", relation: "子女")
        let (app, persistor) = makeApp(profiles: [a, b], defaults: defaults)
        await app.bootstrap()
        a.note = "用户确认的访谈原文"
        let saved = await app.updateMember(a, completingVoiceInterviewStep: "allergy")
        XCTAssertTrue(saved)
        XCTAssertEqual(app.profileCompletion?.done, 1)

        let savedAgain = await app.updateMember(a, completingVoiceInterviewStep: "allergy")
        XCTAssertTrue(savedAgain)
        XCTAssertEqual(app.profileCompletion?.done, 1, "重复确认同一步不能重复计数")
        app.setCurrentPatient(b.id)
        XCTAssertEqual(app.profileCompletion?.done, 0, "A 的访谈不能完成 B 的档案")

        let restarted = makeApp(persistor: persistor, defaults: defaults)
        await restarted.bootstrap()
        XCTAssertEqual(restarted.profileCompletion?.done, 0)
        restarted.setCurrentPatient(a.id)
        XCTAssertEqual(restarted.profileCompletion?.done, 1, "重启后保持原成员的已保存进度")
    }

    func test_failedSaveDoesNotCompleteInterviewAndRetryCanCompleteIt() async {
        var profile = PatientProfile(displayName: "本人")
        let (app, persistor) = makeApp(profiles: [profile])
        await app.bootstrap()
        await persistor.setRejectsUpdates(true)
        profile.note = "用户确认的访谈原文"
        let failed = await app.updateMember(profile, completingVoiceInterviewStep: "allergy")
        XCTAssertFalse(failed)
        XCTAssertEqual(app.profileCompletion?.done, 0, "保存失败不能提前计入完成")

        await persistor.setRejectsUpdates(false)
        let retried = await app.updateMember(profile, completingVoiceInterviewStep: "allergy")
        XCTAssertTrue(retried)
        XCTAssertEqual(app.profileCompletion?.done, 1)
    }

    func test_saveCreditsUpdatedProfileInsteadOfNewlySelectedMember() async {
        var a = PatientProfile(displayName: "本人")
        let b = PatientProfile(displayName: "家人", relation: "子女")
        let (app, _) = makeApp(profiles: [a, b])
        await app.bootstrap()
        app.setCurrentPatient(b.id)
        a.note = "属于 A 的已确认访谈原文"
        let saved = await app.updateMember(a, completingVoiceInterviewStep: "pastHistory")
        XCTAssertTrue(saved)
        XCTAssertEqual(app.profileCompletion?.done, 0)
        app.setCurrentPatient(a.id)
        XCTAssertEqual(app.profileCompletion?.done, 1)
    }

    func test_allSavedFieldsCompleteTheProfileWithoutOvercounting() async {
        var profile = PatientProfile(displayName: "本人", birthDate: "1980-01-01",
                                     bloodType: "A", idNo: "test-id", insuranceNo: "test-insurance")
        let (app, _) = makeApp(profiles: [profile])
        await app.bootstrap()
        XCTAssertEqual(app.profileCompletion?.done, 4)
        for step in ["allergy", "pastHistory", "currentMeds", "emergencyContact", "allergy"] {
            profile.note = "已确认的 \(step) 原文"
            let saved = await app.updateMember(profile, completingVoiceInterviewStep: step)
            XCTAssertTrue(saved)
        }
        XCTAssertEqual(app.profileCompletion?.done, 8)
        XCTAssertEqual(app.profileCompletion?.total, 8)
    }

    func test_clearingDataAlsoClearsInterviewCompletionMetadata() async throws {
        let defaults = freshDefaults()
        var profile = PatientProfile(displayName: "本人")
        let (app, persistor) = makeApp(profiles: [profile], defaults: defaults)
        await app.bootstrap()
        profile.note = "已确认访谈原文"
        let saved = await app.updateMember(profile, completingVoiceInterviewStep: "allergy")
        XCTAssertTrue(saved)
        XCTAssertEqual(app.profileCompletion?.done, 1)
        try await app.persistorReset()

        // 同一身份后来从资料恢复时，不能继承已清除的本机进度标记。
        profile.note = nil
        try await persistor.saveOwner(LocalOwner(displayName: "本人", selfPatientId: profile.id, createdAt: 0),
                                      profile: profile)
        await app.bootstrap()
        XCTAssertEqual(app.profileCompletion?.done, 0)
        let restarted = makeApp(persistor: persistor, defaults: defaults)
        await restarted.bootstrap()
        XCTAssertEqual(restarted.profileCompletion?.done, 0)
    }

    func test_interviewAnswerAndProgressStayWithCapturedMember() async throws {
        let a = PatientProfile(displayName: "本人")
        let b = PatientProfile(displayName: "家人", relation: "子女")
        let (app, _) = makeApp(profiles: [a, b])
        await app.bootstrap()
        // 对应 A 的访谈已建立，返回首页换成 B 后旧确认异步回调才到达。
        let interviewPatientId = app.currentPatientId
        app.setCurrentPatient(b.id)
        let saved = await app.commitVoiceProfileField("allergy", value: "A 的访谈答案", patientId: interviewPatientId)
        XCTAssertTrue(saved)
        XCTAssertNil(app.members.first { $0.id == b.id }?.note)
        XCTAssertEqual(app.profileCompletion?.done, 0)
        let savedA = try XCTUnwrap(app.members.first { $0.id == a.id })
        XCTAssertTrue(savedA.note?.contains("A 的访谈答案") == true)
        app.setCurrentPatient(a.id)
        XCTAssertEqual(app.profileCompletion?.done, 1)
    }

    func test_missingInterviewMemberIsNotReplacedByCurrentMember() async {
        let profile = PatientProfile(displayName: "本人")
        let (app, _) = makeApp(profiles: [profile])
        await app.bootstrap()
        let saved = await app.commitVoiceProfileField("allergy", value: "失效会话的答案", patientId: UUID())
        XCTAssertFalse(saved)
        XCTAssertNil(app.members.first?.note)
        XCTAssertEqual(app.profileCompletion?.done, 0)
    }
}

/// 持久化端口替身：仅隔离 DB/Apple SDK，计数与观察均执行生产 AppState。
private actor HomeProfilePersistor: M1aPersisting {
    private var profiles: [PatientProfile]
    private var owner: LocalOwner?
    private var consents: [ConsentRecord] = []
    private var rejectsUpdates = false

    init(profiles: [PatientProfile]) {
        self.profiles = profiles
        owner = profiles.first.map { LocalOwner(displayName: $0.displayName, selfPatientId: $0.id, createdAt: 0) }
    }

    func loadOwner() async throws -> LocalOwner? { owner }
    func loadConsents() async throws -> [ConsentRecord] { consents }
    func members() async throws -> [PatientProfile] { profiles }
    func saveOwner(_ owner: LocalOwner, profile: PatientProfile) async throws {
        self.owner = owner
        profiles.append(profile)
    }
    func saveMember(_ profile: PatientProfile) async throws { profiles.append(profile) }
    func saveConsent(_ consent: ConsentRecord) async throws { consents.append(consent) }
    func updateMember(_ profile: PatientProfile) async throws {
        guard !rejectsUpdates, let index = profiles.firstIndex(where: { $0.id == profile.id }) else {
            throw CocoaError(.fileWriteUnknown)
        }
        profiles[index] = profile
    }
    func setRejectsUpdates(_ value: Bool) { rejectsUpdates = value }
    func databaseHealth() async throws -> (sizeBytes: Int64, integrityOK: Bool) { (0, true) }
    func reset() async throws { profiles = []; owner = nil; consents = [] }
}
