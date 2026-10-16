import Foundation
import Testing
@testable import Domain

/// 媒体载具清单（discussions/2026-10-16-local-storage-layout-council.md §8 切片 9，Linux 可跑）。
/// v2：条目携带完整放置信息（relativePath/isSensitive/memberId/kind）——清单是打包契约，
/// 信封是随包 DTO（Envelope.media 共用同一类型）。
struct MediaManifestTests {

    private func entry(sha: String, kind: MediaKind = .original, sensitive: Bool = false,
                       memberId: UUID? = nil) -> MediaManifestEntry {
        let path = sensitive
            ? MediaDestinationRules.sensitiveOriginalRelativePath(memberId: memberId!, sha256: sha)
            : MediaDestinationRules.originalRelativePath(sha256: sha)
        return MediaManifestEntry(sha256: sha, size: 100, mime: "image/jpeg",
                                  relativePath: path, isSensitive: sensitive,
                                  memberId: memberId, kind: kind)
    }

    @Test func codableRoundTripV2() throws {
        let member = UUID()
        let entries = [
            entry(sha: String(repeating: "a", count: 64)),
            entry(sha: String(repeating: "b", count: 64), sensitive: true, memberId: member),
        ]
        let manifest = MediaManifest(entries: entries)
        let encoded = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(MediaManifest.self, from: encoded)
        #expect(decoded == manifest)
        #expect(decoded.schemaVersion == 2)
        #expect(decoded.schemaVersion == MediaManifest.currentSchemaVersion)
    }

    @Test func canonicalEntriesDecodeAndValidate() throws {
        let member = UUID()
        let sha = String(repeating: "c", count: 64)
        let sensitiveEntry = entry(sha: sha, sensitive: true, memberId: member)
        #expect(MediaDestinationRules.isCanonicalEntry(sensitiveEntry))
        #expect(MediaDestinationRules.isCanonicalEntry(entry(sha: sha)))
        // 敏感条目缺 memberId → 非规范形（落盘前拒绝）
        let noMember = MediaManifestEntry(sha256: sha, size: 1, mime: "x",
                                          relativePath: MediaDestinationRules.sensitiveOriginalRelativePath(
                                              memberId: member, sha256: sha),
                                          isSensitive: true, memberId: nil, kind: .original)
        #expect(!MediaDestinationRules.isCanonicalEntry(noMember))
    }

    @Test func photoKindShapeRoundTrip() throws {
        let member = UUID()
        let asset = UUID()
        let photo = MediaManifestEntry(sha256: String(repeating: "d", count: 64), size: 1,
                                       mime: "image/jpeg",
                                       relativePath: MediaDestinationRules.photoRelativePath(memberId: member, assetId: asset),
                                       isSensitive: true, memberId: member, kind: .photo)
        #expect(MediaDestinationRules.isCanonicalEntry(photo))
        let blur = MediaManifestEntry(sha256: String(repeating: "e", count: 64), size: 1,
                                      mime: "image/jpeg",
                                      relativePath: MediaDestinationRules.blurRelativePath(memberId: member, assetId: asset),
                                      isSensitive: true, memberId: member, kind: .blur)
        #expect(MediaDestinationRules.isCanonicalEntry(blur))
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
