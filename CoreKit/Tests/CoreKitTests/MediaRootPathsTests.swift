import Foundation
import Testing
@testable import Infrastructure

/// 媒体根与双形态路径金样（2026-10-27 存储边界委员会 P0）。
@Suite("SU-M5-STORE · 媒体根路径")
struct MediaRootPathsTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("media-root-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("mediaBase 固定为 AppSupport/VitaLiber/Media")
    func mediaBaseShape() {
        let base = URL(fileURLWithPath: "/A")
        #expect(MediaRootPaths.mediaBase(applicationSupportBase: base).path
                == "/A/VitaLiber/Media")
        #expect(MediaRootPaths.canonicalMedicalNotesRoot(mediaBase: URL(fileURLWithPath: "/A/VitaLiber/Media")).path
                == "/A/VitaLiber/Media/MedicalNotes")
        #expect(MediaRootPaths.legacyMedicalNotesRoot(documentsBase: URL(fileURLWithPath: "/D")).path
                == "/D/MedicalNotes")
    }

    @Test("双形态解析：绝对原样、相对拼 mediaBase、空白 nil")
    func resolveDualForm() {
        let media = URL(fileURLWithPath: "/A/VitaLiber/Media")
        #expect(MediaRootPaths.resolve(path: "/legacy/abs/x.jpg", mediaBase: media)?.path
                == "/legacy/abs/x.jpg")
        #expect(MediaRootPaths.resolve(path: "MedicalNotes/originals/p/x.bin", mediaBase: media)?.path
                == "/A/VitaLiber/Media/MedicalNotes/originals/p/x.bin")
        #expect(MediaRootPaths.resolve(path: "  ", mediaBase: media) == nil)
    }

    @Test("迁移矩阵：仅旧根→搬移；仅新根→already；双根→bothPresent 不动；皆无→noSource")
    func migrationMatrix() throws {
        let fm = FileManager.default
        let root = try temporaryDirectory()
        defer { try? fm.removeItem(at: root) } // try?-ok: 测试清理

        let legacyOnly = root.appendingPathComponent("case1/legacy", isDirectory: true)
        let canonical1 = root.appendingPathComponent("case1/canonical", isDirectory: true)
        try fm.createDirectory(at: legacyOnly, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: legacyOnly.appendingPathComponent("a.bin"))
        #expect(MediaRootPaths.migrateLegacyRoot(legacy: legacyOnly, canonical: canonical1) == .moved)
        #expect(fm.fileExists(atPath: canonical1.appendingPathComponent("a.bin").path))
        #expect(!fm.fileExists(atPath: legacyOnly.path))
        // 幂等：再跑一次 = alreadyCanonical
        #expect(MediaRootPaths.migrateLegacyRoot(legacy: legacyOnly, canonical: canonical1) == .alreadyCanonical)

        let legacy2 = root.appendingPathComponent("case2/legacy", isDirectory: true)
        let canonical2 = root.appendingPathComponent("case2/canonical", isDirectory: true)
        try fm.createDirectory(at: legacy2, withIntermediateDirectories: true)
        try fm.createDirectory(at: canonical2, withIntermediateDirectories: true)
        #expect(MediaRootPaths.migrateLegacyRoot(legacy: legacy2, canonical: canonical2) == .bothPresent)
        #expect(fm.fileExists(atPath: legacy2.path))
        #expect(fm.fileExists(atPath: canonical2.path))

        let legacy3 = root.appendingPathComponent("case3/legacy", isDirectory: true)
        let canonical3 = root.appendingPathComponent("case3/canonical", isDirectory: true)
        #expect(MediaRootPaths.migrateLegacyRoot(legacy: legacy3, canonical: canonical3) == .noSource)
    }

    @Test("搬移失败回报 moveFailed 且旧根保留")
    func migrationFailure() throws {
        let fm = FileManager.default
        let root = try temporaryDirectory()
        defer { try? fm.removeItem(at: root) } // try?-ok: 测试清理
        let legacy = root.appendingPathComponent("legacy", isDirectory: true)
        try fm.createDirectory(at: legacy, withIntermediateDirectories: true)
        // 用普通文件占住 canonical 的父目录路径，createDirectory 必败
        let blocker = root.appendingPathComponent("blocked", isDirectory: true)
        try Data("x".utf8).write(to: blocker)
        let canonical = blocker.appendingPathComponent("canonical", isDirectory: true)
        guard case .moveFailed = MediaRootPaths.migrateLegacyRoot(legacy: legacy, canonical: canonical) else {
            Issue.record("应为 moveFailed")
            return
        }
        #expect(fm.fileExists(atPath: legacy.path))
    }
}
