import Foundation
import Testing
@testable import Domain

/// 媒体载具清单（discussions/2026-10-16-backup-sync-share-design.md §8.5 切片 2，Linux 可跑）。
struct MediaManifestTests {

    @Test func codableRoundTrip() throws {
        let entries = [
            MediaManifestEntry(sha256: String(repeating: "a", count: 64), size: 100, mime: "image/jpeg"),
            MediaManifestEntry(sha256: String(repeating: "b", count: 64), size: 200, mime: "audio/m4a"),
        ]
        let manifest = MediaManifest(entries: entries)
        let encoded = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(MediaManifest.self, from: encoded)
        #expect(decoded == manifest)
        #expect(decoded.schemaVersion == MediaManifest.currentSchemaVersion)
    }

    @Test func emptyManifestRoundTrip() throws {
        let manifest = MediaManifest(entries: [])
        let decoded = try JSONDecoder().decode(MediaManifest.self, from: JSONEncoder().encode(manifest))
        #expect(decoded.entries.isEmpty)
    }

    @Test func importReportDefaults() {
        let report = MediaImportReport()
        #expect(report.imported == 0)
        #expect(report.alreadyPresent == 0)
        #expect(report.missing.isEmpty)
    }
}
