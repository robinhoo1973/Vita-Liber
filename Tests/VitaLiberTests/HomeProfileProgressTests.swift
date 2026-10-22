import XCTest
import Foundation
import Perception
import Domain
import Protocols
@testable import VitaLiber

/// FR2.1b 档案完善进度：2 个字段（血型/生日）；证件号/医保号已停止收集。
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

    func test_unloadedProfileDoesNotInventProgress() async {
        let (app, _) = makeApp(profiles: [PatientProfile(displayName: "本人")])
        XCTAssertNil(app.profileCompletion)
    }

    func test_whitespaceFieldsDoNotCountAsCompletedInformation() async throws {
        let profile = PatientProfile(displayName: "本人", birthDate: " \n",
                                     bloodType: " ")
        let (app, _) = makeApp(profiles: [profile])
        await app.bootstrap()
        let progress = try XCTUnwrap(app.profileCompletion)
        XCTAssertEqual(progress.done, 0)
        XCTAssertEqual(progress.total, 2)
    }

    func test_memberSwitchInvalidatesObservedProgressWithoutReloadingMembers() async {
        let a = PatientProfile(displayName: "本人", birthDate: "1980-01-01")
        let b = PatientProfile(displayName: "家人", relation: "子女")
        let (app, _) = makeApp(profiles: [a, b])
        await app.bootstrap()
        let changed = expectation(description: "成员切换必须发布新进度")
        withPerceptionTracking {
            _ = app.profileCompletion
        } onChange: {
            changed.fulfill()
        }
        app.setCurrentPatient(b.id)
        await fulfillment(of: [changed], timeout: 5)
    }

    func test_bloodTypeAndBirthDateCompleteTheProfileWithoutOvercounting() async {
        let profile = PatientProfile(displayName: "本人", birthDate: "1980-01-01",
                                     bloodType: "A")
        let (app, _) = makeApp(profiles: [profile])
        await app.bootstrap()
        XCTAssertEqual(app.profileCompletion?.done, 2)
        XCTAssertEqual(app.profileCompletion?.total, 2)
    }
}

/// 持久化端口替身：仅隔离 DB/Apple SDK，观察与计数执行生产 AppState。
private actor HomeProfilePersistor: PatientPersisting {
    private var profiles: [PatientProfile]
    private var owner: LocalOwner?
    private var consents: [ConsentRecord] = []

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
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else {
            throw CocoaError(.fileWriteUnknown)
        }
        profiles[index] = profile
    }
    func databaseHealth() async throws -> (sizeBytes: Int64, integrityOK: Bool) { (0, true) }
    func reset() async throws { profiles = []; owner = nil; consents = [] }
}
