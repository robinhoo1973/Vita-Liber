import XCTest
import UIKit
import GRDB
import Foundation
import Domain
import Infrastructure
import Protocols
@testable import VitaLiber

/// 文档媒体布局（local-storage-layout-council §7.1 切片 10，macOS CI）：
/// 内容寻址落盘 / 相对路径入 meta / original_sha256 落列 / 双形态读。
@MainActor
final class DocumentMediaLayoutTests: XCTestCase {

    private struct Fixture {
        let database: GRDBStore
        let patient: UUID
        let documents: DocumentStore
        let pending: PendingCardStore
        let docs: DocumentsState
        let directory: URL
    }

    private func fixture(directory: URL? = nil, store: GRDBStore? = nil, patient: UUID? = nil) async throws -> Fixture {
        let database: GRDBStore
        let patientID: UUID
        if let store, let patient {
            database = store
            patientID = patient
        } else if let store {
            database = store
            patientID = try await store.insertPatient("Owner", relation: "self")
        } else {
            (database, patientID) = try await GRDBStore.inMemoryWithOwner()
        }
        let directory = directory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("media-layout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let documents = DocumentStore(writer: database.writer)
        let pending = PendingCardStore(writer: database.writer)
        let docs = DocumentsState(store: documents,
                                  pipeline: OCRPipeline(recognizer: PageRecognizer(lines: ["检验报告"], confidence: 0.9),
                                                        grayscaleDecoder: GrayscaleImageDecoder()),
                                  decoder: PDFKitDecoder(), originalsDir: directory,
                                  understandingEngine: NLTextUnderstanding(), pendingCards: pending,
                                  scheduler: InMemoryReminderScheduler(), cardStore: OCRCardStore(writer: database.writer))
        return Fixture(database: database, patient: patientID, documents: documents,
                       pending: pending, docs: docs, directory: directory)
    }

    private let image: Data = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).pngData { context in
        UIColor.white.setFill()
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
    }

    private func imageDraft(_ f: Fixture, isSensitive: Bool) async throws -> DocumentsState.ImportDraft {
        let prepared = await f.docs.prepareImageDraft(patientId: f.patient, originalData: image,
                                                      processedData: image, mimeType: "image/png",
                                                      docType: nil, title: nil, isSensitive: isSensitive, origin: "camera")
        return try XCTUnwrap(prepared)
    }

    private func sha256Hex(_ data: Data) -> String {
        CryptoKitContentHasher().sha256Hex(data)
    }

    // MARK: 落盘形态

    func test_nonSensitiveOriginalLandsContentAddressed() async throws {
        let f = try await fixture()
        let draft = try await imageDraft(f, isSensitive: false)
        let committed = await f.docs.commitDraft(draft)
        XCTAssertTrue(committed)
        let documents = try await f.documents.list(patientId: f.patient)
        let listed = try XCTUnwrap(documents.first)
        let sha = sha256Hex(image)
        XCTAssertEqual(listed.originalSha256, sha)   // 列 = 明文原件哈希（小写 hex64 无前缀）
        let fetched = try await f.documents.fetch(id: listed.id)   // list 投影不携带 meta_json（DocumentStore.swift:117 契约）
        let document = try XCTUnwrap(fetched)
        let relative = "originals/\(sha.prefix(2))/\(sha).bin"
        print("METAJSON-DEBUG nonSensitive=\(document.metaJSON ?? "nil")")   // TODO-remove 诊断
        XCTAssertTrue(document.metaJSON?.contains(relative) == true)   // meta 相对路径（无绝对路径）
        XCTAssertFalse(document.metaJSON?.contains("/originals") == true)  // 绝不含容器绝对路径
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.directory.appendingPathComponent(relative).path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: f.directory.appendingPathComponent("sensitive").path))   // 非敏感绝不落敏感目录
    }

    func test_sensitiveOriginalLandsInMemberDir() async throws {
        let f = try await fixture()
        let draft = try await imageDraft(f, isSensitive: true)
        let committed = await f.docs.commitDraft(draft)
        XCTAssertTrue(committed)
        let documents = try await f.documents.list(patientId: f.patient)
        let listed = try XCTUnwrap(documents.first)
        let sha = sha256Hex(image)
        XCTAssertEqual(listed.originalSha256, sha)
        let fetched = try await f.documents.fetch(id: listed.id)   // 同上：meta_json 经 fetch
        let document = try XCTUnwrap(fetched)
        let relative = "sensitive/\(f.patient.uuidString)/\(sha).bin"
        print("METAJSON-DEBUG sensitive=\(document.metaJSON ?? "nil")")   // TODO-remove 诊断
        XCTAssertTrue(document.metaJSON?.contains(relative) == true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.directory.appendingPathComponent(relative).path))
        // 敏感件绝不落非敏感 CAS 路径（跨成员去重边界）
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: f.directory.appendingPathComponent("originals/\(sha.prefix(2))/\(sha).bin").path))
    }

    func test_sameBytesTwoDocumentsShareOneFile() async throws {
        let f = try await fixture()
        let first = try await imageDraft(f, isSensitive: false)
        let committedFirst = await f.docs.commitDraft(first)
        XCTAssertTrue(committedFirst)
        // 生产形态：一笔导入一个 session（commitDraft 后 activeImport 不释放,
        // prepareImageDraft 在 source 非 nil 时返回 nil）——同库同患者第二稿经
        // 新 DocumentsState（新 session）落;共享同一媒体根验证 CAS 零复制
        let f2 = try await fixture(directory: f.directory, store: f.database, patient: f.patient)
        let second = try await imageDraft(f2, isSensitive: false)
        let committedSecond = await f2.docs.commitDraft(second)
        XCTAssertTrue(committedSecond)
        let documents = try await f.documents.list(patientId: f.patient)
        XCTAssertEqual(documents.count, 2)
        let sha = sha256Hex(image)
        XCTAssertEqual(documents.map(\.originalSha256), [sha, sha])   // 两行同一内容身份
        // 单份字节：CAS 目录内恰好一个文件（同字节零复制）
        let casDir = f.directory.appendingPathComponent("originals/\(sha.prefix(2))")
        let files = try FileManager.default.contentsOfDirectory(atPath: casDir.path)
        XCTAssertEqual(files, ["\(sha).bin"])
    }

    // MARK: 双形态读（resolver）

    func test_mediaURLResolvesRelativePathAfterCommit() async throws {
        let f = try await fixture()
        let draft = try await imageDraft(f, isSensitive: false)
        let committed = await f.docs.commitDraft(draft)
        XCTAssertTrue(committed)
        let documents = try await f.documents.list(patientId: f.patient)
        let document = try XCTUnwrap(documents.first)
        let resolved = try XCTUnwrap(f.docs.mediaURL(for: document))
        let sha = sha256Hex(image)
        XCTAssertEqual(resolved.path,
                       f.directory.appendingPathComponent("originals/\(sha.prefix(2))/\(sha).bin").path)
        XCTAssertEqual(try Data(contentsOf: resolved), image)
    }

    func test_mediaURLFallsBackToLegacyAbsolutePath() async throws {
        let f = try await fixture()
        // 旧布局行：original_sha256 为 NULL，meta 里是绝对路径（换机前形态）
        let legacyDir = f.directory.appendingPathComponent("originals/\(f.patient.uuidString)")
        try FileManager.default.createDirectory(at: legacyDir, withIntermediateDirectories: true)
        let legacyURL = legacyDir.appendingPathComponent("legacy.png")
        try image.write(to: legacyURL)
        let meta = try JSONSerialization.data(withJSONObject: ["original_path": legacyURL.path])
        let id = try await f.documents.save(patientId: f.patient, docType: "检验报告",
                                            sha256: "file:" + sha256Hex(image), mimeType: "image/png",
                                            origin: "import", isSensitive: false,
                                            metaJSON: String(decoding: meta, as: UTF8.self), title: nil)
        let fetched = try await f.documents.fetch(id: id)
        let document = try XCTUnwrap(fetched)
        XCTAssertNil(document.originalSha256)
        let resolved = try XCTUnwrap(f.docs.mediaURL(for: document))
        XCTAssertEqual(resolved.path, legacyURL.path)   // legacy 绝对路径兜底可读
        XCTAssertEqual(try Data(contentsOf: resolved), image)
    }

    func test_mediaURLPrefersShaDerivationOverLegacy() async throws {
        let f = try await fixture()
        // 懒回填后的行：original_sha256 在列，文件已在 CAS 位；meta 仍携旧绝对路径（已失效）
        let sha = sha256Hex(image)
        let casURL = f.directory.appendingPathComponent("originals/\(sha.prefix(2))/\(sha).bin")
        try FileManager.default.createDirectory(at: casURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try image.write(to: casURL)
        let deadLegacy = "/var/mobile/Containers/Data/Application/dead-uuid/Documents/MedicalNotes/originals/x/y.png"
        let meta = try JSONSerialization.data(withJSONObject: ["original_path": deadLegacy])
        let id = try await f.documents.save(patientId: f.patient, docType: "检验报告",
                                            sha256: "file:" + sha, mimeType: "image/png",
                                            origin: "import", isSensitive: false,
                                            metaJSON: String(decoding: meta, as: UTF8.self), title: nil,
                                            originalSha256: sha)
        let fetched = try await f.documents.fetch(id: id)
        let document = try XCTUnwrap(fetched)
        let resolved = try XCTUnwrap(f.docs.mediaURL(for: document))
        XCTAssertEqual(resolved.path, casURL.path)   // sha 推导优先，悬空绝对路径不阻断
    }
}

// MARK: - 测试桩（生产实现可复用者一律用生产实现；仅识别器与调度器需脚本化）

/// 脚本化图片识别（与 OcrCardQueueAcceptanceTests 同形的最小子集，文件级私有）。
private actor PageRecognizer: ImageTextRecognizing {
    let lines: [String]
    let confidence: Double
    init(lines: [String], confidence: Double) {
        self.lines = lines
        self.confidence = confidence
    }
    func recognize(_ imageData: Data) async throws -> ImageInputRules.Recognition {
        .init(lines: lines, confidence: confidence)
    }
}
