#if os(iOS) || os(macOS)
import CryptoKit
import Foundation
import GRDB
import Testing
import ZIPFoundation
@testable import Infrastructure

/// medical-data Release 信任链与安装边界验收（CryptoKit/GRDB/ZIPFoundation/AgeKit，仅 macOS CI）。
/// 每条拒绝用例同时断言：目录 destination 与同目录患者库字节不变、journal 未进入。
@Suite("Medical catalog release acceptance")
struct MedicalCatalogReleaseAcceptanceTests {

    // MARK: trust verifier

    @Test("pinned verifier accepts the Swift fixture and the Go-exported pointer")
    func verifierAcceptsSwiftAndGoFixtures() throws {
        let fixture = try MedicalCatalogFixture.make()
        defer { fixture.cleanUp() }
        try fixture.verifier().verify(catalogJSON: fixture.signedPointerJSON, expected: fixture.signedExpectation)

        let expected = try GoMedicalFixture.expected()
        let goPointer = try GoMedicalFixture.data(expected.installablePointer)
        let goVerifier = CryptoKitMedicalCatalogTrustVerifier(pinnedRootJSON: try GoMedicalFixture.data("pinned-root.json"),
                                                              now: { expected.nowDate })
        try goVerifier.verify(catalogJSON: goPointer,
                              expected: try GoMedicalFixture.expectation(goPointer, servedAs: expected.installablePointer))
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
        let goPointer = try GoMedicalFixture.data(expected.installablePointer)
        let wrongPin = CryptoKitMedicalCatalogTrustVerifier(pinnedRootJSON: try GoMedicalFixture.data("replacement-root.json"),
                                                            now: { expected.nowDate })
        #expect(throws: MedicalCatalogTrustError.signatureThreshold) {
            try wrongPin.verify(catalogJSON: goPointer,
                                expected: try GoMedicalFixture.expectation(goPointer, servedAs: expected.installablePointer))
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
                                  expected: try GoMedicalFixture.expectation(goSingle, servedAs: expected.installablePointer))
        }
    }

    @Test("signatures bind the exact payload bytes")
    func tamperedPayloadFailsSignatures() throws {
        let expected = try GoMedicalFixture.expected()
        let goPointer = try GoMedicalFixture.data(expected.installablePointer)
        let goVerifier = CryptoKitMedicalCatalogTrustVerifier(pinnedRootJSON: try GoMedicalFixture.data("pinned-root.json"),
                                                              now: { expected.nowDate })
        let tampered = try GoMedicalFixture.rewrap(goPointer) { $0["packageSize"] = expected.packageSize + 1 }
        #expect(throws: MedicalCatalogTrustError.signatureThreshold) {
            try goVerifier.verify(catalogJSON: tampered,
                                  expected: try GoMedicalFixture.expectation(tampered, servedAs: expected.installablePointer))
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
            ("installable", { $0["installable"] = false }),
            ("packageAssetName", { $0["packageAssetName"] = "medical-data-package-sqlite-\(other)-cipher-\(other).bin" }),
            ("packageSize", { $0["packageSize"] = fixture.packageBytes.count + 1 }),
            ("packageSha256", { fields in
                fields["packageSha256"] = other
                fields["packageAssetName"] = MedicalCatalogReleaseProtocol.packageAssetName(
                    sqliteSHA256: fields["sqliteSha256"] as? String ?? "", packageSHA256: other)
            }),
            ("sqliteSha256", { fields in
                fields["sqliteSha256"] = other
                fields["packageAssetName"] = MedicalCatalogReleaseProtocol.packageAssetName(
                    sqliteSHA256: other, packageSHA256: fields["packageSha256"] as? String ?? "")
            }),
            ("dataVersion", { $0["dataVersion"] = other }),
            ("sqliteSchemaVersion", { $0["sqliteSchemaVersion"] = 6 }),
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
        let goExpired = try GoMedicalFixture.data(expected.expiredPointer)
        let goVerifier = CryptoKitMedicalCatalogTrustVerifier(pinnedRootJSON: try GoMedicalFixture.data("pinned-root.json"),
                                                              now: { expected.nowDate })
        let stale = try GoMedicalFixture.expectation(goExpired, servedAs: expected.expiredPointer,
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
        #expect(fixture.leftoverWorkFiles().isEmpty)

        let installed = try MedicalCatalogStore.installedVersion(path: fixture.destinationURL)
        #expect(MedicalCatalogUpdateService.sameDataVersion(local: installed, candidate: candidate))
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
            fields["sqliteSha256"] = other
            fields["packageAssetName"] = MedicalCatalogReleaseProtocol.packageAssetName(
                sqliteSHA256: other, packageSHA256: fields["packageSha256"] as? String ?? "")
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
        let github = try #require(URL(string: "https://github.com/robinhoo1973/Vita-Liber/releases/download/medical-data/x.bin"))
        let objects = try #require(URL(string: "https://objects.githubusercontent.com/asset"))
        let evil = try #require(URL(string: "https://evil.example.com/asset"))
        let task = URLSession.shared.downloadTask(with: github)
        let redirect = try #require(HTTPURLResponse(url: github, statusCode: 302, httpVersion: nil, headerFields: nil))

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
                             newRequest: URLRequest(url: objects)) { box.set($0) }
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
        try validator.validate(try #require(response(objects, 200, ["Content-Length": "10"])))
        #expect(throws: MedicalCatalogUpdateError.redirectRejected) {
            try validator.validate(try #require(response(evil, 200, ["Content-Length": "10"])))
        }
        #expect(throws: MedicalCatalogUpdateError.downloadFailed) {
            try validator.validate(try #require(response(objects, 404, [:])))
        }
        #expect(throws: MedicalCatalogUpdateError.downloadFailed) {
            try validator.validate(try #require(response(objects, 200, ["Content-Encoding": "gzip"])))
        }
        #expect(throws: MedicalCatalogUpdateError.checksumMismatch) {
            try validator.validate(try #require(response(objects, 200, ["Content-Length": "11"])))
        }
    }

    @Test("fetcher refuses asset names outside the package grammar without touching the network")
    func fetcherRefusesNonPackageNames() async throws {
        let fixture = try MedicalCatalogFixture.make()
        defer { fixture.cleanUp() }
        let fetcher = URLSessionMedicalCatalogPackageFetcher()
        for name in ["../medical-catalog.sqlite", "medical-data-catalog-installable-20.json", ""] {
            await #expect(throws: MedicalCatalogUpdateError.downloadFailed) {
                try await fetcher.fetch(assetName: name, expectedSize: 10,
                                        to: fixture.directory.appendingPathComponent("p.bin"), progress: { _ in })
            }
        }
    }

    @Test("Go age package opens to the signed SQLite and passes the release gate")
    func goAgePackageOpens() async throws {
        let expected = try GoMedicalFixture.expected()
        let fixture = try MedicalCatalogFixture.make()
        defer { fixture.cleanUp() }
        let identity = String(decoding: try GoMedicalFixture.data("age-identity.txt"), as: UTF8.self)
        let sqlite = fixture.directory.appendingPathComponent("go-open.sqlite")
        try await AgeKitMedicalCatalogPackageOpening(identityText: identity)
            .open(packageURL: GoMedicalFixture.url(expected.packageAssetName), sqliteURL: sqlite, maxSQLiteBytes: 1 << 20)
        #expect(fixture.sha256(sqlite) == expected.sqliteSha256)
        #expect(fixture.sha256(sqlite) == fixture.sha256(GoMedicalFixture.url("catalog.sqlite")))
        try MedicalCatalogStore.validateRelease(path: sqlite, schemaVersion: expected.sqliteSchemaVersion,
                                                dataVersion: expected.dataVersion)
        #expect(throws: MedicalCatalogUpdateError.catalogIntegrityFailed) {
            try MedicalCatalogStore.validateRelease(path: sqlite, schemaVersion: expected.sqliteSchemaVersion,
                                                    dataVersion: String(repeating: "0", count: 64))
        }
        let wrongKey = "AGE-SECRET-KEY-1" + String(repeating: "Q", count: 58)
        await #expect(throws: (any Error).self) {
            try await AgeKitMedicalCatalogPackageOpening(identityText: wrongKey)
                .open(packageURL: GoMedicalFixture.url(expected.packageAssetName),
                      sqliteURL: fixture.directory.appendingPathComponent("wrong.sqlite"), maxSQLiteBytes: 1 << 20)
        }
    }
}

// MARK: - Swift-generated fixture

struct MedicalCatalogFixture {
    enum Database { case valid, foreignKeyViolation, wrongDataVersion, wrongUserVersion, missingDrugTable }

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
                     database: Database = .valid) throws -> MedicalCatalogFixture {
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
            "allowedHosts": ["github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"],
        ]
        let pinnedRootJSON = try sign(root, with: Array(rootKeys.prefix(rootSignerCount)))

        let dataVersion = CryptoKitContentHasher().sha256Hex(Data(UUID().uuidString.utf8))
        let sqliteURL = directory.appendingPathComponent("source.sqlite")
        try buildDatabase(at: sqliteURL, dataVersion: dataVersion, shape: database)
        let sqliteBytes = try Data(contentsOf: sqliteURL)
        let packageBytes = try Data(contentsOf: zip(at: directory.appendingPathComponent("package.zip"),
                                                    entries: [("medical-catalog.sqlite", .file, sqliteBytes)]))
        let hasher = CryptoKitContentHasher()
        let sqliteSHA = hasher.sha256Hex(sqliteBytes)
        let packageSHA = hasher.sha256Hex(packageBytes)
        let fields: [String: Any] = [
            "schemaVersion": 1, "role": "catalog", "app": "vitaliber", "assetKind": "medical-data",
            "rootVersion": 1, "catalogVersion": 30,
            "issuedAt": "2026-09-26T12:00:00Z", "expiresAt": "2026-10-27T12:00:00Z",
            "sqliteSha256": sqliteSHA, "packageSha256": packageSHA, "packageSize": packageBytes.count,
            "packageAssetName": MedicalCatalogReleaseProtocol.packageAssetName(sqliteSHA256: sqliteSHA, packageSHA256: packageSHA),
            "fetchStateSha256": hasher.sha256Hex(Data("fetch".utf8)),
            "installable": installable,
            "contentSha256": dataVersion, "manifestSha256": hasher.sha256Hex(Data("manifest".utf8)),
            "dataVersion": dataVersion, "sqliteSchemaVersion": 5,
            "releaseTag": "medical-data", "repository": "robinhoo1973/Vita-Liber",
        ]
        let signers = Array(catalogKeys.prefix(catalogSignerCount))
        let pointerJSON = try sign(fields, with: signers)
        let assetName = MedicalCatalogReleaseProtocol.pointerAssetName(installable: installable, catalogVersion: 30)
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
        let name = MedicalCatalogReleaseProtocol.pointerAssetName(
            installable: fields["installable"] as? Bool ?? false,
            catalogVersion: Int64(fields["catalogVersion"] as? Int ?? 0))
        let expectation = try MedicalCatalogSignedPointerDecoder.expectation(
            catalogJSON: json, servedAs: name, now: Self.clock, hasher: CryptoKitContentHasher())
        try verifier().verify(catalogJSON: json, expected: expectation)
        return VerifiedMedicalCatalogCandidate(verified: expectation)
    }

    func service(fetcher: any MedicalCatalogPackageFetching, journal: InMemoryActivationJournal,
                 limits: MedicalCatalogUpdateLimits = MedicalCatalogUpdateLimits(maxPackageBytes: 1 << 20, maxSQLiteBytes: 1 << 22),
                 activeCheck: (@Sendable (URL) throws -> Void)? = nil) -> MedicalCatalogUpdateService {
        MedicalCatalogUpdateService(destination: destinationURL, fetcher: fetcher, journal: journal, limits: limits,
                                    activeCheck: activeCheck ?? { try MedicalCatalogStore.smokeCheck(path: $0) })
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

    private static func buildDatabase(at url: URL, dataVersion: String, shape: Database) throws {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = false
        let queue = try DatabaseQueue(path: url.path, configuration: configuration)
        try queue.write { db in
            try db.execute(sql: "PRAGMA user_version = \(shape == .wrongUserVersion ? 4 : 5)")
            try db.execute(sql: "CREATE TABLE catalog_meta (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL)")
            let metaVersion = shape == .wrongDataVersion ? String(repeating: "f", count: 64) : dataVersion
            try db.execute(sql: "INSERT INTO catalog_meta(key, value) VALUES ('schema_version', '5'), ('data_version', ?)",
                           arguments: [metaVersion])
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
        while !hasStarted { try await Task.sleep(nanoseconds: 1_000_000) }
    }

    func fetch(assetName: String, expectedSize: Int64, to destination: URL,
               progress: @escaping @Sendable (Int64) -> Void) async throws {
        lock.lock(); count += 1; started = true; lock.unlock()
        while isHeld { try await Task.sleep(nanoseconds: 1_000_000) }
        try bytes.write(to: destination)
        progress(Int64(bytes.count))
    }
}

/// Swift 夹具的包是明文 ZIP（测试宿主不链 AgeKit）；解包走生产同一 extractor。
final class CountingZIPOpener: MedicalCatalogPackageOpening, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var openCount: Int { lock.lock(); defer { lock.unlock() }; return count }

    func open(packageURL: URL, sqliteURL: URL, maxSQLiteBytes: Int64) async throws {
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
