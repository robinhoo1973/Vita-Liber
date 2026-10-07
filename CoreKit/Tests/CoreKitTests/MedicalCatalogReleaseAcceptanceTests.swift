#if os(iOS) || os(macOS)
import CryptoKit
import Foundation
import GRDB
import Testing
import ZIPFoundation
@testable import Infrastructure

/// medical-data Release 信任链与安装边界验收（CryptoKit/GRDB/ZIPFoundation，仅 macOS CI）。
/// 每条拒绝用例同时断言：目录 destination 与同目录患者库字节不变、journal 未进入。
/// 测试桩有界轮询超时错误（D4：挂起改清晰红）
struct StubDeadlineTimeout: Error {}

@Suite("Medical catalog release acceptance", .timeLimit(.minutes(2)))  // 2026-09-27 委员会 D4：无界轮询挂起会吞 120 分钟 job 预算——2 分钟内清晰红
struct MedicalCatalogReleaseAcceptanceTests {

    // MARK: trust verifier

    @Test("pinned verifier accepts the Swift fixture and the Go-exported pointer")
    func verifierAcceptsSwiftAndGoFixtures() throws {
        let fixture = try MedicalCatalogFixture.make()
        defer { fixture.cleanUp() }
        try fixture.verifier().verify(catalogJSON: fixture.signedPointerJSON, expected: fixture.signedExpectation)

        let expected = try GoMedicalFixture.expected()
        let goPointer = try GoMedicalFixture.data(expected.installableManifest)
        let goVerifier = CryptoKitMedicalCatalogTrustVerifier(pinnedRootJSON: try GoMedicalFixture.data("pinned-root.json"),
                                                              now: { expected.nowDate })
        try goVerifier.verify(catalogJSON: goPointer,
                              expected: try GoMedicalFixture.expectation(goPointer, servedAs: expected.manifestAssetName))
    }

    @Test("self-signed replacement roots never substitute for the pin")
    func replacementRootRejected() throws {
        let fixture = try MedicalCatalogFixture.make()
        let attacker = try MedicalCatalogFixture.make()
        defer { fixture.cleanUp(); attacker.cleanUp() }
        let verifier = fixture.verifier()
        #expect(throws: MedicalCatalogTrustError.self) {
            try verifier.verify(catalogJSON: attacker.signedPointerJSON, expected: attacker.signedExpectation)
        }
        #expect(throws: MedicalCatalogTrustError.self) {
            try verifier.verify(catalogJSON: attacker.pinnedRootJSON, expected: fixture.signedExpectation)
        }

        let expected = try GoMedicalFixture.expected()
        let goPointer = try GoMedicalFixture.data(expected.installableManifest)
        let wrongPin = CryptoKitMedicalCatalogTrustVerifier(pinnedRootJSON: try GoMedicalFixture.data("replacement-root.json"),
                                                            now: { expected.nowDate })
        #expect(throws: MedicalCatalogTrustError.signatureThreshold) {
            try wrongPin.verify(catalogJSON: goPointer,
                                expected: try GoMedicalFixture.expectation(goPointer, servedAs: expected.manifestAssetName))
        }
    }

    @Test("single catalog signature and single-signed pins are rejected")
    func thresholdsEnforced() throws {
        let single = try MedicalCatalogFixture.make(catalogSignerCount: 1)
        let weakPin = try MedicalCatalogFixture.make(rootSignerCount: 1)
        defer { single.cleanUp(); weakPin.cleanUp() }
        #expect(throws: MedicalCatalogTrustError.signatureThreshold) {
            try single.verifier().verify(catalogJSON: single.signedPointerJSON, expected: single.signedExpectation)
        }
        #expect(throws: MedicalCatalogTrustError.signatureThreshold) {
            try weakPin.verifier().verify(catalogJSON: weakPin.signedPointerJSON, expected: weakPin.signedExpectation)
        }

        let expected = try GoMedicalFixture.expected()
        let goSingle = try GoMedicalFixture.data("pointer-single-signature.json")
        let goVerifier = CryptoKitMedicalCatalogTrustVerifier(pinnedRootJSON: try GoMedicalFixture.data("pinned-root.json"),
                                                              now: { expected.nowDate })
        #expect(throws: MedicalCatalogTrustError.signatureThreshold) {
            try goVerifier.verify(catalogJSON: goSingle,
                                  expected: try GoMedicalFixture.expectation(goSingle, servedAs: expected.manifestAssetName))
        }
    }

    @Test("signatures bind the exact payload bytes")
    func tamperedPayloadFailsSignatures() throws {
        let expected = try GoMedicalFixture.expected()
        let goPointer = try GoMedicalFixture.data(expected.installableManifest)
        let goVerifier = CryptoKitMedicalCatalogTrustVerifier(pinnedRootJSON: try GoMedicalFixture.data("pinned-root.json"),
                                                              now: { expected.nowDate })
        let tampered = try GoMedicalFixture.rewrap(goPointer) { $0["packageSize"] = expected.packageSize + 1 }
        #expect(throws: MedicalCatalogTrustError.signatureThreshold) {
            try goVerifier.verify(catalogJSON: tampered,
                                  expected: try GoMedicalFixture.expectation(tampered, servedAs: expected.manifestAssetName))
        }
    }

    @Test("every signed field that differs from the expectation is rejected (re-signed by catalog keys)")
    func signedFieldMismatchRejected() throws {
        let fixture = try MedicalCatalogFixture.make()
        defer { fixture.cleanUp() }
        let other = String(repeating: "c", count: 64)
        let mutations: [(String, (inout [String: Any]) -> Void)] = [
            ("repository", { $0["repository"] = "someone/Vita-Liber" }),
            ("releaseTag", { $0["releaseTag"] = "medical-data-next" }),
            ("catalogVersion", { $0["catalogVersion"] = 31 }),
            // v3 跨字段互核的字段双层同步，隔离到期望绑定门（单改一层在 decode 即拒）：
            ("installable", { fields in
                fields["installable"] = false
                var manifest = fields["manifest"] as? [String: Any] ?? [:]
                manifest["installable"] = false
                fields["manifest"] = manifest
            }),
            ("packageAssetName", { $0["packageAssetName"] = "package-31.bin" }),   // 合法文法、版本不符
            ("packageSize", { $0["packageSize"] = fixture.packageBytes.count + 1 }),
            ("packageSha256", { $0["packageSha256"] = other }),   // v3 包名与哈希解耦：单层即可穿过 decode
            ("sqliteSha256", { fields in
                fields["sqliteSha256"] = other
                var manifest = fields["manifest"] as? [String: Any] ?? [:]
                manifest["sqlite_sha256"] = other
                fields["manifest"] = manifest
            }),
            ("dataVersion", { fields in
                fields["dataVersion"] = other
                var manifest = fields["manifest"] as? [String: Any] ?? [:]
                manifest["data_version"] = other
                fields["manifest"] = manifest
            }),
            // v3 新增互核门专测：planSetSHA256 单改顶层即拒（该字段无其它门覆盖）。
            ("planSetSHA256", { $0["planSetSHA256"] = other }),
            ("sqliteSchemaVersion", { $0["sqliteSchemaVersion"] = 6 }),   // ≠ 默认 7（旧值 7 与默认相同=零变异，CI #655）
            ("rootVersion", { $0["rootVersion"] = 2 }),
        ]
        let verifier = fixture.verifier()
        for (name, mutate) in mutations {
            let resigned = try fixture.signedPointer(mutate)
            #expect(throws: MedicalCatalogTrustError.self, "\(name) mismatch must be rejected") {
                try verifier.verify(catalogJSON: resigned, expected: fixture.signedExpectation)
            }
        }
    }

    @Test("physical v7 candidates are accepted; v5/v6 and mismatched SQLite stamps are rejected")
    func physicalSchemaVersionCompatibility() throws {
        // CNB 单写者契约:仅 v7(旧 GitHub 时代 v5/v6 检查点从未发布,零旧设备悬崖)。
        let v7Fixture = try MedicalCatalogFixture.make(schemaVersion: 7)
        defer { v7Fixture.cleanUp() }
        let candidate = try v7Fixture.candidate()
        #expect(candidate.schemaVersion == 7)
        let sqlite = v7Fixture.directory.appendingPathComponent("source.sqlite")
        try MedicalCatalogStore.validateRelease(path: sqlite, schemaVersion: 7,
                                                dataVersion: v7Fixture.signedExpectation.dataVersion)

        // v5/v6 在 pointer 解码门即被拒——`make` 构造 `signedExpectation` 时已调用
        // `MedicalCatalogSignedPointerDecoder.expectation`（App 解析网络 pointer 的同一函数）。
        for legacy in [5, 6] {
            #expect(throws: MedicalCatalogTrustError.invalidField) {
                _ = try MedicalCatalogFixture.make(schemaVersion: legacy)
            }
        }
        // 不支持的物理版本即使 SQLite 本体有效,`validateRelease` 也在版本门即拒。
        #expect(throws: MedicalCatalogUpdateError.catalogIntegrityFailed) {
            try MedicalCatalogStore.validateRelease(
                path: sqlite, schemaVersion: 6,
                dataVersion: v7Fixture.signedExpectation.dataVersion)
        }

        let badUserVersion = try MedicalCatalogFixture.make(database: .wrongUserVersion, schemaVersion: 7)
        defer { badUserVersion.cleanUp() }
        #expect(throws: MedicalCatalogUpdateError.catalogIntegrityFailed) {
            try MedicalCatalogStore.validateRelease(
                path: badUserVersion.directory.appendingPathComponent("source.sqlite"), schemaVersion: 7,
                dataVersion: badUserVersion.signedExpectation.dataVersion)
        }

        let badMetaVersion = try MedicalCatalogFixture.make(database: .wrongSchemaVersion, schemaVersion: 7)
        defer { badMetaVersion.cleanUp() }
        #expect(throws: MedicalCatalogUpdateError.catalogIntegrityFailed) {
            try MedicalCatalogStore.validateRelease(
                path: badMetaVersion.directory.appendingPathComponent("source.sqlite"), schemaVersion: 7,
                dataVersion: badMetaVersion.signedExpectation.dataVersion)
        }
    }

    @Test("expired pointers are never accepted by the App")
    func expiredPointerRejected() throws {
        let fixture = try MedicalCatalogFixture.make()
        defer { fixture.cleanUp() }
        let late = CryptoKitMedicalCatalogTrustVerifier(pinnedRootJSON: fixture.pinnedRootJSON,
                                                        now: { MedicalCatalogFixture.date("2026-10-27T12:00:00Z") })
        #expect(throws: MedicalCatalogTrustError.expired) {
            try late.verify(catalogJSON: fixture.signedPointerJSON, expected: fixture.signedExpectation)
        }

        let expected = try GoMedicalFixture.expected()
        let goExpired = try GoMedicalFixture.data(expected.expiredManifest)
        let goVerifier = CryptoKitMedicalCatalogTrustVerifier(pinnedRootJSON: try GoMedicalFixture.data("pinned-root.json"),
                                                              now: { expected.nowDate })
        let stale = try GoMedicalFixture.expectation(goExpired, servedAs: expected.manifestAssetName,
                                                     now: MedicalCatalogFixture.date("2026-09-01T00:00:00Z"))
        #expect(throws: MedicalCatalogTrustError.expired) {
            try goVerifier.verify(catalogJSON: goExpired, expected: stale)
        }
    }

    // MARK: installer boundary

    @Test("installable=false is rejected before package download and opener")
    func nonInstallableRejectedBeforeDownload() async throws {
        let fixture = try MedicalCatalogFixture.make(installable: false)
        defer { fixture.cleanUp() }
        let fetcher = StubPackageFetcher(bytes: fixture.packageBytes)
        let opener = CountingZIPOpener()
        let journal = InMemoryActivationJournal()
        let service = fixture.service(fetcher: fetcher, journal: journal)
        try await fixture.expectRejected(.catalogNotInstallable, journal: journal) {
            try await service.update(candidate: try fixture.candidate(), opener: opener)
        }
        #expect(fetcher.fetchCount == 0)
        #expect(opener.openCount == 0)
    }

    /// 进度 → 阶段键（五阶段顺序钉用；2026-09-27 评审补）。
    private static func phaseKey(_ progress: MedicalCatalogUpdateProgress) -> String {
        switch progress {
        case .downloading: return "downloading"
        case .verifyingPackage: return "verifyingPackage"
        case .decrypting: return "decrypting"
        case .verifyingCatalog: return "verifyingCatalog"
        case .activating: return "activating"
        }
    }

    @Test("verified package activates atomically after every gate, journal brackets the swap")
    func validPackageActivates() async throws {
        let fixture = try MedicalCatalogFixture.make()
        defer { fixture.cleanUp() }
        let journal = InMemoryActivationJournal()
        let service = fixture.service(fetcher: StubPackageFetcher(bytes: fixture.packageBytes), journal: journal)
        let candidate = try fixture.candidate()
        let patientBefore = fixture.sha256(fixture.patientDatabaseURL)
        let events = ProgressLog()
        try await service.update(candidate: candidate, opener: CountingZIPOpener(), progress: { events.append($0) })

        #expect(fixture.sha256(fixture.destinationURL) == candidate.sqliteSHA256)
        #expect(fixture.sha256(fixture.patientDatabaseURL) == patientBefore)
        #expect(journal.events == ["begin", "complete"])
        let pending = try #require(journal.pending.first)
        #expect(pending.candidate == candidate)
        #expect(pending.activeURL == fixture.destinationURL)
        #expect(pending.stagingURL.deletingLastPathComponent() == fixture.destinationURL.deletingLastPathComponent())
        #expect(journal.activeSHAAtBegin == MedicalCatalogFixture.oldCatalogSHA256)
        #expect(journal.stagingSHAAtBegin == candidate.sqliteSHA256)
        let backup = try #require(pending.lastGoodBackupURL)
        #expect(fixture.sha256(backup) == MedicalCatalogFixture.oldCatalogSHA256)
        #expect(events.values.first == .downloading(receivedBytes: 0, totalBytes: candidate.packageSize))
        #expect(events.values.last == .activating)
        // 五阶段顺序钉（2026-09-27 评审补）：阶段只前进不回退，防重排回归
        // （downloading 按进度多次上报，相邻去重后比较）。
        var distinct: [String] = []
        for phase in events.values.map(Self.phaseKey) where distinct.last != phase {
            distinct.append(phase)
        }
        #expect(distinct == ["downloading", "verifyingPackage", "decrypting", "verifyingCatalog", "activating"])
        #expect(fixture.leftoverWorkFiles().isEmpty)

        let installed = try MedicalCatalogStore.installedVersion(path: fixture.destinationURL)
        #expect(MedicalCatalogUpdateService.sameDataVersion(local: installed, candidate: candidate))
    }

    @Test("expired candidate is rejected at the update entry (freshness gate)")
    func expiredCandidateRejectedAtUpdateEntry() async throws {
        let fixture = try MedicalCatalogFixture.make()
        defer { fixture.cleanUp() }
        let journal = InMemoryActivationJournal()
        // 时钟错位注入：候选在 fixture 时钟（检查时刻）仍有效，更新入口时钟晚于
        // 到期——「检查时有效、数日后更新时过期」的真实窗口。
        let service = fixture.service(fetcher: StubPackageFetcher(bytes: fixture.packageBytes), journal: journal,
                                      now: { MedicalCatalogFixture.date("2026-09-27T00:00:00Z") })
        let expired = try fixture.candidate { $0["expiresAt"] = "2026-09-26T13:30:00Z" }
        await #expect(throws: MedicalCatalogUpdateError.catalogNotInstallable) {
            try await service.update(candidate: expired, opener: CountingZIPOpener())
        }
        #expect(fixture.sha256(fixture.destinationURL) == MedicalCatalogFixture.oldCatalogSHA256)
        #expect(journal.events.isEmpty)
        #expect(fixture.leftoverWorkFiles().isEmpty)
    }

    @Test("tampered or resized package bytes are rejected before opening")
    func packageChecksumAndSizeGates() async throws {
        let fixture = try MedicalCatalogFixture.make()
        defer { fixture.cleanUp() }
        var flipped = fixture.packageBytes
        flipped[flipped.count - 1] ^= 0xFF
        for bytes in [flipped, fixture.packageBytes + Data([0])] {
            let opener = CountingZIPOpener()
            let journal = InMemoryActivationJournal()
            let service = fixture.service(fetcher: StubPackageFetcher(bytes: bytes), journal: journal)
            try await fixture.expectRejected(.checksumMismatch, journal: journal) {
                try await service.update(candidate: try fixture.candidate(), opener: opener)
            }
            #expect(opener.openCount == 0)
        }
    }

    @Test("decrypted SQLite hash, data_version and FK gates reject before activation")
    func sqliteGatesReject() async throws {
        let base = try MedicalCatalogFixture.make()
        defer { base.cleanUp() }
        let other = String(repeating: "d", count: 64)
        let wrongSQLiteHash = try base.candidate { fields in
            // v3 跨字段互核：双层同步才能穿过 decode，隔离到更新侧 sqlite 哈希门
            fields["sqliteSha256"] = other
            var manifest = fields["manifest"] as? [String: Any] ?? [:]
            manifest["sqlite_sha256"] = other
            fields["manifest"] = manifest
        }
        let journal = InMemoryActivationJournal()
        let service = base.service(fetcher: StubPackageFetcher(bytes: base.packageBytes), journal: journal)
        try await base.expectRejected(.checksumMismatch, journal: journal) {
            try await service.update(candidate: wrongSQLiteHash, opener: CountingZIPOpener())
        }

        for shape in [MedicalCatalogFixture.Database.foreignKeyViolation, .wrongDataVersion, .wrongUserVersion, .missingDrugTable] {
            let fixture = try MedicalCatalogFixture.make(database: shape)
            defer { fixture.cleanUp() }
            let journal = InMemoryActivationJournal()
            let service = fixture.service(fetcher: StubPackageFetcher(bytes: fixture.packageBytes), journal: journal)
            try await fixture.expectRejected(.catalogIntegrityFailed, journal: journal) {
                try await service.update(candidate: try fixture.candidate(), opener: CountingZIPOpener())
            }
        }
    }

    @Test("ZIP expansion beyond the SQLite limit is rejected")
    func zipExpansionLimit() async throws {
        let fixture = try MedicalCatalogFixture.make()
        defer { fixture.cleanUp() }
        let journal = InMemoryActivationJournal()
        let service = fixture.service(fetcher: StubPackageFetcher(bytes: fixture.packageBytes), journal: journal,
                                      limits: MedicalCatalogUpdateLimits(maxPackageBytes: 1 << 20, maxSQLiteBytes: 1024))
        try await fixture.expectRejected(.packageInvalid, journal: journal) {
            try await service.update(candidate: try fixture.candidate(), opener: CountingZIPOpener())
        }
        let tooSmallPackageLimit = fixture.service(
            fetcher: StubPackageFetcher(bytes: fixture.packageBytes), journal: journal,
            limits: MedicalCatalogUpdateLimits(maxPackageBytes: 16, maxSQLiteBytes: 1 << 20))
        try await fixture.expectRejected(.packageTooLarge, journal: journal) {
            try await tooSmallPackageLimit.update(candidate: try fixture.candidate(), opener: CountingZIPOpener())
        }
    }

    @Test("ZIP layout gate: exactly one plain medical-catalog.sqlite entry")
    func zipLayoutGate() throws {
        let fixture = try MedicalCatalogFixture.make()
        defer { fixture.cleanUp() }
        let sqlite = Data("SQLite format 3\u{0}payload".utf8)
        let layouts: [[(String, Entry.EntryType, Data)]] = [
            [("medical-catalog.sqlite", .file, sqlite), ("extra.txt", .file, Data("x".utf8))],
            [("../medical-catalog.sqlite", .file, sqlite)],
            [("nested/medical-catalog.sqlite", .file, sqlite)],
            [("medical-catalog.sqlite", .symlink, Data("/etc/passwd".utf8))],
            [("medical-catalog.sqlite", .file, Data())],
        ]
        for layout in layouts {
            let zip = try fixture.zip(layout)
            let target = fixture.directory.appendingPathComponent("extract-\(UUID().uuidString).sqlite")
            #expect(throws: MedicalCatalogUpdateError.packageInvalid) {
                try MedicalCatalogPackageExtractor.extractSQLite(from: zip, to: target, maxSQLiteBytes: 1 << 20)
            }
            #expect(!FileManager.default.fileExists(atPath: target.path))
        }
    }

    @Test("reopen failure after the swap restores the last-good catalog")
    func reopenFailureRestores() async throws {
        let fixture = try MedicalCatalogFixture.make()
        defer { fixture.cleanUp() }
        let journal = InMemoryActivationJournal()
        let service = fixture.service(fetcher: StubPackageFetcher(bytes: fixture.packageBytes), journal: journal,
                                      activeCheck: { _ in throw MedicalCatalogUpdateError.catalogIntegrityFailed })
        let patientBefore = fixture.sha256(fixture.patientDatabaseURL)
        await #expect(throws: MedicalCatalogUpdateError.activationFailed) {
            try await service.update(candidate: try fixture.candidate(), opener: CountingZIPOpener())
        }
        #expect(fixture.sha256(fixture.destinationURL) == MedicalCatalogFixture.oldCatalogSHA256)
        #expect(fixture.sha256(fixture.patientDatabaseURL) == patientBefore)
        #expect(journal.events == ["begin"])
    }

    @Test("updates are single-flight")
    func singleFlight() async throws {
        let fixture = try MedicalCatalogFixture.make()
        defer { fixture.cleanUp() }
        let fetcher = StubPackageFetcher(bytes: fixture.packageBytes, held: true)
        let service = fixture.service(fetcher: fetcher, journal: InMemoryActivationJournal())
        let candidate = try fixture.candidate()
        let first = Task { try await service.update(candidate: candidate, opener: CountingZIPOpener()) }
        try await fetcher.waitUntilStarted()
        await #expect(throws: MedicalCatalogUpdateError.updateInProgress) {
            try await service.update(candidate: candidate, opener: CountingZIPOpener())
        }
        fetcher.release()
        try await first.value
        #expect(fixture.sha256(fixture.destinationURL) == candidate.sqliteSHA256)
        #expect(fetcher.fetchCount == 1)
    }

    @Test("cancellation during download keeps the active catalog")
    func cancellationKeepsDestination() async throws {
        let fixture = try MedicalCatalogFixture.make()
        defer { fixture.cleanUp() }
        let fetcher = StubPackageFetcher(bytes: fixture.packageBytes, held: true)
        let journal = InMemoryActivationJournal()
        let service = fixture.service(fetcher: fetcher, journal: journal)
        let candidate = try fixture.candidate()
        let patientBefore = fixture.sha256(fixture.patientDatabaseURL)
        let task = Task { try await service.update(candidate: candidate, opener: CountingZIPOpener()) }
        try await fetcher.waitUntilStarted()
        task.cancel()
        await #expect(throws: MedicalCatalogUpdateError.cancelled) { try await task.value }
        #expect(fixture.sha256(fixture.destinationURL) == MedicalCatalogFixture.oldCatalogSHA256)
        #expect(fixture.sha256(fixture.patientDatabaseURL) == patientBefore)
        #expect(journal.events.isEmpty)
        #expect(fixture.leftoverWorkFiles().isEmpty)
    }

    // MARK: transport + Go package

    @Test("transfer guard rejects off-allowlist redirects, redirect chains and byte overflow")
    func transferGuard() throws {
        let base = try #require(URL(string: "https://cnb.cool/robinhoo1973/Resources/-/releases/download/medical-data/x.bin"))
        let asset = try #require(URL(string: "https://asset.cnb.cool/robinhoo1973/Resources/asset"))
        let evil = try #require(URL(string: "https://evil.example.com/asset"))
        let task = URLSession.shared.downloadTask(with: base)
        let redirect = try #require(HTTPURLResponse(url: base, statusCode: 302, httpVersion: nil, headerFields: nil))

        let offList = MedicalCatalogPackageTransfer(expectedBytes: 10, onBytes: { _ in })
        let rejected = RequestBox()
        offList.urlSession(URLSession.shared, task: task, willPerformHTTPRedirection: redirect,
                           newRequest: URLRequest(url: evil)) { rejected.set($0) }
        #expect(rejected.value == nil && rejected.called)
        #expect(offList.failure == .redirectRejected)

        let chain = MedicalCatalogPackageTransfer(expectedBytes: 10, onBytes: { _ in })
        for hop in 0...MedicalCatalogPackageTransfer.maxRedirects {
            let box = RequestBox()
            chain.urlSession(URLSession.shared, task: task, willPerformHTTPRedirection: redirect,
                             newRequest: URLRequest(url: asset)) { box.set($0) }
            #expect((box.value != nil) == (hop < MedicalCatalogPackageTransfer.maxRedirects))
        }
        #expect(chain.failure == .redirectRejected)

        let overflow = MedicalCatalogPackageTransfer(expectedBytes: 10, onBytes: { _ in })
        overflow.urlSession(URLSession.shared, downloadTask: task, didWriteData: 11, totalBytesWritten: 11,
                            totalBytesExpectedToWrite: 11)
        #expect(overflow.failure == .packageTooLarge)
        task.cancel()

        let response = { (url: URL, status: Int, headers: [String: String]) in
            HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)
        }
        let validator = MedicalCatalogPackageTransfer(expectedBytes: 10, onBytes: { _ in })
        try validator.validate(try #require(response(asset, 200, ["Content-Length": "10"])))
        #expect(throws: MedicalCatalogUpdateError.redirectRejected) {
            try validator.validate(try #require(response(evil, 200, ["Content-Length": "10"])))
        }
        #expect(throws: MedicalCatalogUpdateError.downloadFailed) {
            try validator.validate(try #require(response(asset, 404, [:])))
        }
        #expect(throws: MedicalCatalogUpdateError.downloadFailed) {
            try validator.validate(try #require(response(asset, 200, ["Content-Encoding": "gzip"])))
        }
        #expect(throws: MedicalCatalogUpdateError.checksumMismatch) {
            try validator.validate(try #require(response(asset, 200, ["Content-Length": "11"])))
        }
    }

    @Test("fetcher refuses asset names outside the package grammar without touching the network")
    func fetcherRefusesNonPackageNames() async throws {
        let fixture = try MedicalCatalogFixture.make()
        defer { fixture.cleanUp() }
        let fetcher = URLSessionMedicalCatalogPackageFetcher()
        for name in ["../medical-catalog.sqlite", "manifest.json", ""] {
            await #expect(throws: MedicalCatalogUpdateError.downloadFailed) {
                try await fetcher.fetch(assetName: name, expectedSize: 10,
                                        to: fixture.directory.appendingPathComponent("p.bin"), progress: { _ in })
            }
        }
    }

    @Test("Go envelope package opens to the signed SQLite and passes the release gate")
    func goEnvelopePackageOpens() async throws {
        let expected = try GoMedicalFixture.expected()
        let fixture = try MedicalCatalogFixture.make()
        defer { fixture.cleanUp() }
        let sqlite = fixture.directory.appendingPathComponent("go-open.sqlite")
        // 2026-10-06：包加密 age → 与 ASR 同构的分块 AES-256-GCM 信封；identity
        // 是**明文 SQLite 的 SHA-256**，与签名指针里的 sqliteSha256 同值。
        try await EnvelopeMedicalCatalogPackageOpening()
            .open(packageURL: GoMedicalFixture.url(expected.packageAssetName), sqliteURL: sqlite,
                  identity: expected.sqliteSha256, maxSQLiteBytes: 1 << 20)
        #expect(fixture.sha256(sqlite) == expected.sqliteSha256)
        #expect(fixture.sha256(sqlite) == fixture.sha256(GoMedicalFixture.url("catalog.sqlite")))
        try MedicalCatalogStore.validateRelease(path: sqlite, schemaVersion: expected.sqliteSchemaVersion,
                                                dataVersion: expected.dataVersion)
        #expect(throws: MedicalCatalogUpdateError.catalogIntegrityFailed) {
            try MedicalCatalogStore.validateRelease(path: sqlite, schemaVersion: expected.sqliteSchemaVersion,
                                                    dataVersion: String(repeating: "0", count: 64))
        }
        // 错 identity ⇒ GCM 认证失败（而不是解出垃圾）。这条同时钉死
        // 「identity 漂移必须 fail-closed」——ASR 侧同型断言。
        await #expect(throws: (any Error).self) {
            try await EnvelopeMedicalCatalogPackageOpening()
                .open(packageURL: GoMedicalFixture.url(expected.packageAssetName),
                      sqliteURL: fixture.directory.appendingPathComponent("wrong.sqlite"),
                      identity: String(repeating: "a", count: 64), maxSQLiteBytes: 1 << 20)
        }
    }

    @Test("legacy age 格式包对新信封 opener 响亮失败（旧资产安全语义）")
    func goEnvelopeOpenerRejectsLegacyAgePackage() async throws {
        // 迁移期 age 资产以 -cipher- 名留存（三代 orphan fixture）——新 opener
        // 只认 VLASR 信封魔数，age 字节必须**响亮失败**而非静默误判：
        // 魔数预检 = fail-closed（旧包解不开即拒绝，绝不产出垃圾 sqlite）。
        let legacy = "medical-data-package-sqlite-"
            + "2eeeccca7189103e0e2049e441f690fe0b8d71116c880b283a637f58ffc51050"
            + "-cipher-10b60fdbfc8a77e7334a68142ec082aa3510bb6deb120ac7da6648fa6f868a16.bin"
        let fixture = try MedicalCatalogFixture.make()
        defer { fixture.cleanUp() }
        await #expect(throws: (any Error).self) {
            try await EnvelopeMedicalCatalogPackageOpening()
                .open(packageURL: GoMedicalFixture.url(legacy),
                      sqliteURL: fixture.directory.appendingPathComponent("legacy.sqlite"),
                      identity: String(repeating: "2", count: 64), maxSQLiteBytes: 1 << 20)
        }
    }
}

// MARK: - Swift-generated fixture

struct MedicalCatalogFixture {
    enum Database { case valid, foreignKeyViolation, wrongDataVersion, wrongUserVersion, wrongSchemaVersion, missingDrugTable }

    static let clock = date("2026-09-26T13:00:00Z")
    static let oldCatalog = Data("previous verified catalog bytes".utf8)
    static var oldCatalogSHA256: String { CryptoKitContentHasher().sha256Hex(oldCatalog) }

    let directory: URL
    let pinnedRootJSON: Data
    let signedPointerJSON: Data
    let pointerAssetName: String
    let signedExpectation: MedicalCatalogSignedExpectation
    let packageBytes: Data
    let destinationURL: URL
    let patientDatabaseURL: URL
    private let pointerFields: [String: Any]
    private let catalogSigners: [Curve25519.Signing.PrivateKey]

    static func date(_ value: String) -> Date { MedicalCatalogReleaseProtocol.timestamp(value) ?? .distantPast }

    static func make(rootSignerCount: Int = 2, catalogSignerCount: Int = 2, installable: Bool = true,
                     database: Database = .valid, schemaVersion: Int = 7) throws -> MedicalCatalogFixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("medical-acceptance-\(UUID().uuidString)", isDirectory: true)
        let catalogDirectory = directory.appendingPathComponent("MedicalCatalog", isDirectory: true)
        try FileManager.default.createDirectory(at: catalogDirectory, withIntermediateDirectories: true)

        let rootKeys = [Curve25519.Signing.PrivateKey(), Curve25519.Signing.PrivateKey()]
        let catalogKeys = [Curve25519.Signing.PrivateKey(), Curve25519.Signing.PrivateKey()]
        let root: [String: Any] = [
            "schemaVersion": 1, "role": "root", "app": "vitaliber", "assetKind": "medical-data", "version": 1,
            "expiresAt": "2028-09-26T12:00:00Z",
            "keys": (rootKeys + catalogKeys).map { ["id": keyID($0), "publicKey": $0.publicKey.rawRepresentation.base64EncodedString()] },
            "rootKeyIDs": rootKeys.map(keyID), "rootThreshold": 2,
            "catalogKeyIDs": catalogKeys.map(keyID), "catalogThreshold": 2,
            "assetBaseURL": MedicalCatalogReleaseProtocol.releaseBaseURL,
            "allowedHosts": ["asset.cnb.cool"],
        ]
        let pinnedRootJSON = try sign(root, with: Array(rootKeys.prefix(rootSignerCount)))

        let dataVersion = CryptoKitContentHasher().sha256Hex(Data(UUID().uuidString.utf8))
        let sqliteURL = directory.appendingPathComponent("source.sqlite")
        try buildDatabase(at: sqliteURL, dataVersion: dataVersion, schemaVersion: schemaVersion, shape: database)
        let sqliteBytes = try Data(contentsOf: sqliteURL)
        let packageBytes = try Data(contentsOf: zip(at: directory.appendingPathComponent("package.zip"),
                                                    entries: [("medical-catalog.sqlite", .file, sqliteBytes)]))
        let hasher = CryptoKitContentHasher()
        let sqliteSHA = hasher.sha256Hex(sqliteBytes)
        let packageSHA = hasher.sha256Hex(packageBytes)
        let fetchStateSHA = hasher.sha256Hex(Data("fetch".utf8))
        let planSetSHA = hasher.sha256Hex(Data("plan-set".utf8))
        // v3 内嵌清单：与顶层逐项一致（decode 跨字段互核强制；单改一层即在 decode 拒）。
        let manifestFields: [String: Any] = [
            "schema_version": 2, "run_id": "swift-fixture",
            "run_status": installable ? "complete" : "partial", "installable": installable,
            "started_at": "2026-09-26T12:00:00Z", "ended_at": "2026-09-26T12:30:00Z",
            "content_sha256": dataVersion, "sqlite_sha256": sqliteSHA,
            "sqlite_schema_version": schemaVersion, "plan_set_sha256": planSetSHA,
            "config_sha256": hasher.sha256Hex(Data("config".utf8)),
            "source_policy_sha256": hasher.sha256Hex(Data("source-policy".utf8)),
            "processor_contracts_sha256": hasher.sha256Hex(Data("processor-contracts".utf8)),
            "fetch_state_sha256": fetchStateSHA, "data_version": dataVersion,
            "sources": [["name": "swift-fixture"]],
        ]
        let fields: [String: Any] = [
            // v3 冻结（2026-10-07）：wire schemaVersion=3（破坏性升级，消费面未发版前
            // 切换零成本）。根文档的 schemaVersion 仍为 1（两侧一致，勿改）。
            "schemaVersion": 3, "role": "catalog", "app": "vitaliber", "assetKind": "medical-data",
            "rootVersion": 1, "catalogVersion": 30,
            "issuedAt": "2026-09-26T12:00:00Z", "expiresAt": "2026-10-27T12:00:00Z",
            "sqliteSha256": sqliteSHA, "packageSha256": packageSHA, "packageSize": packageBytes.count,
            "packageAssetName": MedicalCatalogReleaseProtocol.packageAssetName(catalogVersion: 30),
            "fetchStateSha256": fetchStateSHA,
            "installable": installable,
            "contentSha256": dataVersion, "manifest": manifestFields,
            "dataVersion": dataVersion, "sqliteSchemaVersion": schemaVersion,
            "releaseTag": "medical-data", "repository": "robinhoo1973/Resources",
            "planSetSHA256": planSetSHA,   // 与 Go json 标签逐字节一致（迁移夹具漏大小写——CI #654）
        ]
        let signers = Array(catalogKeys.prefix(catalogSignerCount))
        let pointerJSON = try sign(fields, with: signers)
        let assetName = MedicalCatalogReleaseProtocol.manifestAssetName
        let expectation = try MedicalCatalogSignedPointerDecoder.expectation(
            catalogJSON: pointerJSON, servedAs: assetName, now: clock, hasher: hasher)

        let destination = catalogDirectory.appendingPathComponent("medical-catalog.sqlite")
        try oldCatalog.write(to: destination)
        let patient = catalogDirectory.appendingPathComponent("vitaliber.sqlite")
        try Data("patient main database — never touched".utf8).write(to: patient)
        return MedicalCatalogFixture(directory: directory, pinnedRootJSON: pinnedRootJSON, signedPointerJSON: pointerJSON,
                                     pointerAssetName: assetName, signedExpectation: expectation, packageBytes: packageBytes,
                                     destinationURL: destination, patientDatabaseURL: patient,
                                     pointerFields: fields, catalogSigners: catalogKeys)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: directory) // try?-ok: 隔离测试目录清理
    }

    func verifier() -> CryptoKitMedicalCatalogTrustVerifier {
        CryptoKitMedicalCatalogTrustVerifier(pinnedRootJSON: pinnedRootJSON, now: { Self.clock })
    }

    /// 以夹具 catalog 私钥重签改动后的 pointer：每条断言只隔离一个信任门。
    func signedPointer(_ mutate: (inout [String: Any]) -> Void) throws -> Data {
        var fields = pointerFields
        mutate(&fields)
        return try Self.sign(fields, with: catalogSigners)
    }

    /// 仅经 pinned verifier 放行的候选（模块内 initializer 只在验签后调用）。
    func candidate(_ mutate: ((inout [String: Any]) -> Void)? = nil) throws -> VerifiedMedicalCatalogCandidate {
        var fields = pointerFields
        mutate?(&fields)
        let json = mutate == nil ? signedPointerJSON : try Self.sign(fields, with: catalogSigners)
        // v3：单头固定名，签名信封只落 `manifest.json`（唯一提交点）。
        let expectation = try MedicalCatalogSignedPointerDecoder.expectation(
            catalogJSON: json, servedAs: MedicalCatalogReleaseProtocol.manifestAssetName,
            now: Self.clock, hasher: CryptoKitContentHasher())
        try verifier().verify(catalogJSON: json, expected: expectation)
        return VerifiedMedicalCatalogCandidate(verified: expectation)
    }

    func service(fetcher: any MedicalCatalogPackageFetching, journal: InMemoryActivationJournal,
                 limits: MedicalCatalogUpdateLimits = MedicalCatalogUpdateLimits(maxPackageBytes: 1 << 20, maxSQLiteBytes: 1 << 22),
                 activeCheck: (@Sendable (URL) throws -> Void)? = nil,
                 now: @escaping @Sendable () -> Date = { Date() }) -> MedicalCatalogUpdateService {
        MedicalCatalogUpdateService(destination: destinationURL, fetcher: fetcher, journal: journal, limits: limits,
                                    activeCheck: activeCheck ?? { try MedicalCatalogStore.smokeCheck(path: $0) },
                                    now: now)
    }

    func expectRejected(_ error: MedicalCatalogUpdateError, journal: InMemoryActivationJournal,
                        _ body: @escaping () async throws -> Void) async throws {
        let patientBefore = sha256(patientDatabaseURL)
        await #expect(throws: error) { try await body() }
        #expect(sha256(destinationURL) == Self.oldCatalogSHA256)
        #expect(sha256(patientDatabaseURL) == patientBefore)
        #expect(journal.events.isEmpty)
        #expect(leftoverWorkFiles().isEmpty)
    }

    func sha256(_ url: URL) -> String? {
        guard let data = FileManager.default.contents(atPath: url.path) else { return nil }
        return CryptoKitContentHasher().sha256Hex(data)
    }

    /// destination 目录内除 active/患者库/last-good 外不得残留 staging/work 文件。
    func leftoverWorkFiles() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: destinationURL.deletingLastPathComponent().path)) ?? [] // try?-ok: 测试断言读目录，失败即视为无残留由其他断言兜底
        let allowed: Set<String> = [destinationURL.lastPathComponent, patientDatabaseURL.lastPathComponent,
                                    destinationURL.lastPathComponent + MedicalCatalogUpdateService.lastGoodSuffix]
        return names.filter { !allowed.contains($0) }
    }

    func zip(_ entries: [(String, Entry.EntryType, Data)]) throws -> URL {
        try Self.zip(at: directory.appendingPathComponent("layout-\(UUID().uuidString).zip"), entries: entries)
    }

    static func zip(at url: URL, entries: [(String, Entry.EntryType, Data)]) throws -> URL {
        let archive = try Archive(url: url, accessMode: .create)
        for (path, type, data) in entries {
            try archive.addEntry(with: path, type: type, uncompressedSize: Int64(data.count),
                                 compressionMethod: type == .file ? .deflate : .none,
                                 provider: { position, size in data.subdata(in: Int(position)..<Int(position) + size) })
        }
        return url
    }

    private static func keyID(_ key: Curve25519.Signing.PrivateKey) -> String {
        CryptoKitContentHasher().sha256Hex(key.publicKey.rawRepresentation)
    }

    private static func sign(_ fields: [String: Any], with keys: [Curve25519.Signing.PrivateKey]) throws -> Data {
        let payload = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        var signatures: [[String: String]] = []
        for key in keys {
            signatures.append(["keyId": keyID(key), "signature": try key.signature(for: payload).base64EncodedString()])
        }
        return try JSONSerialization.data(withJSONObject: ["payload": payload.base64EncodedString(), "signatures": signatures],
                                          options: [.sortedKeys])
    }

    private static func buildDatabase(at url: URL, dataVersion: String, schemaVersion: Int, shape: Database) throws {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = false
        let queue = try DatabaseQueue(path: url.path, configuration: configuration)
        try queue.write { db in
            let userVersion = shape == .wrongUserVersion ? (schemaVersion == 5 ? 4 : schemaVersion + 1) : schemaVersion
            try db.execute(sql: "PRAGMA user_version = \(userVersion)")
            try db.execute(sql: "CREATE TABLE catalog_meta (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL)")
            let metaVersion = shape == .wrongDataVersion ? String(repeating: "f", count: 64) : dataVersion
            let metaSchemaVersion = shape == .wrongSchemaVersion ? (schemaVersion == 5 ? 6 : 5) : schemaVersion
            try db.execute(sql: "INSERT INTO catalog_meta(key, value) VALUES ('schema_version', ?), ('data_version', ?)",
                           arguments: [String(metaSchemaVersion), metaVersion])
            guard shape != .missingDrugTable else { return }
            try db.execute(sql: """
                CREATE TABLE drug (id INTEGER PRIMARY KEY, region TEXT NOT NULL, source_id TEXT NOT NULL UNIQUE, license_no TEXT, name_zh TEXT, name_en TEXT, brand_name TEXT, dosage_form TEXT, spec TEXT, drug_category TEXT, license_holder TEXT, manufacturer TEXT, insurance_code TEXT, drug_code TEXT, active_ingredients TEXT, usage_ref_json TEXT NOT NULL, region_specific_json TEXT NOT NULL, aliases_json TEXT NOT NULL);
                CREATE TABLE drug_alias (drug_id INTEGER NOT NULL REFERENCES drug(id), alias TEXT NOT NULL);
                INSERT INTO drug (id, region, source_id, name_zh, usage_ref_json, region_specific_json, aliases_json)
                    VALUES (1, 'CN', 'CN:H0001', '阿莫西林胶囊', '{}', '{}', '[]');
                INSERT INTO drug_alias (drug_id, alias) VALUES (1, '阿莫西林');
                """)
            if shape == .foreignKeyViolation {
                try db.execute(sql: "INSERT INTO drug_alias (drug_id, alias) VALUES (999, 'orphan')")
            }
        }
    }
}

// MARK: - Test doubles

final class StubPackageFetcher: MedicalCatalogPackageFetching, @unchecked Sendable {
    private let lock = NSLock()
    private let bytes: Data
    private var held: Bool
    private var started = false
    private var count = 0

    init(bytes: Data, held: Bool = false) {
        self.bytes = bytes
        self.held = held
    }

    var fetchCount: Int { lock.lock(); defer { lock.unlock() }; return count }
    private var isHeld: Bool { lock.lock(); defer { lock.unlock() }; return held }
    private var hasStarted: Bool { lock.lock(); defer { lock.unlock() }; return started }

    func release() { lock.lock(); held = false; lock.unlock() }

    func waitUntilStarted() async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(2)
        while !hasStarted {
            if clock.now >= deadline { Issue.record("fetch 2s 内未启动——服务回归请勿挂起"); throw StubDeadlineTimeout() }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    func fetch(assetName: String, expectedSize: Int64, to destination: URL,
               progress: @escaping @Sendable (Int64) -> Void) async throws {
        lock.lock(); count += 1; started = true; lock.unlock()
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(2)
        while isHeld {
            if clock.now >= deadline { Issue.record("release 2s 内未达——取消传播回归请勿挂起"); throw StubDeadlineTimeout() }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        try bytes.write(to: destination)
        progress(Int64(bytes.count))
    }
}

/// Swift 夹具的包是明文 ZIP（测试宿主不链 CryptoKit 信封）；解包走生产同一 extractor。
final class CountingZIPOpener: MedicalCatalogPackageOpening, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var openCount: Int { lock.lock(); defer { lock.unlock() }; return count }

    func open(packageURL: URL, sqliteURL: URL, identity: String, maxSQLiteBytes: Int64) async throws {
        lock.lock(); count += 1; lock.unlock()
        try MedicalCatalogPackageExtractor.extractSQLite(from: packageURL, to: sqliteURL, maxSQLiteBytes: maxSQLiteBytes)
    }
}

final class InMemoryActivationJournal: MedicalCatalogActivationJournaling, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    private var entries: [PendingActivation] = []
    private(set) var activeSHAAtBegin: String?
    private(set) var stagingSHAAtBegin: String?

    var events: [String] { lock.lock(); defer { lock.unlock() }; return log }
    var pending: [PendingActivation] { lock.lock(); defer { lock.unlock() }; return entries }

    func begin(_ pending: PendingActivation) throws {
        let hasher = CryptoKitContentHasher()
        let active = FileManager.default.contents(atPath: pending.activeURL.path).map(hasher.sha256Hex)
        let staging = FileManager.default.contents(atPath: pending.stagingURL.path).map(hasher.sha256Hex)
        lock.lock(); defer { lock.unlock() }
        log.append("begin")
        entries.append(pending)
        activeSHAAtBegin = active
        stagingSHAAtBegin = staging
    }

    func complete(_ pending: PendingActivation) throws {
        lock.lock(); defer { lock.unlock() }
        log.append("complete")
    }
}

final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [MedicalCatalogUpdateProgress] = []
    var values: [MedicalCatalogUpdateProgress] { lock.lock(); defer { lock.unlock() }; return stored }
    func append(_ value: MedicalCatalogUpdateProgress) { lock.lock(); stored.append(value); lock.unlock() }
}

final class RequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: URLRequest?
    private var wasCalled = false
    var value: URLRequest? { lock.lock(); defer { lock.unlock() }; return stored }
    var called: Bool { lock.lock(); defer { lock.unlock() }; return wasCalled }
    func set(_ request: URLRequest?) { lock.lock(); stored = request; wasCalled = true; lock.unlock() }
}
#endif
