import XCTest
import Foundation
import GRDB
import Domain
import Infrastructure
import Protocols
import UIKit
@testable import VitaLiber

/// TC-M1a-03/05 的 App 层半场（test-plan §4.2）：
/// 生物识别门禁（FR1.1 V3.22）、L1 三卡 ConsentRecord 落库、BR-003。
/// 评审修正：经 GRDBM1aPersistor 走真实 §4.3 表——「本人关联 patient_profile」
/// 从 ID 断言升级为落库断言，闭合假绿。
/// V3.39 对齐：BR-003 闸门用例从旧 AppState 引擎（captureSample/commitToTimeline，
/// 已随向导简化删除）迁移到活管线 DocumentsState.commitDraft / DocumentStore——
/// 红线验收覆盖生产路径而非死代码。
@MainActor
// binds: SU-M1a-SEC / SU-M1a-BIO / SU-M1a-GOLDEN — TC-M1a-03/04/05（BR-003 一票否决）
final class M1aAcceptanceTests: XCTestCase {

    /// 第八轮全仓审查修复（临时目录残留清理）：makeDocs 此前把 BR-002
    /// 不可变原件直接写进系统共享临时目录（originals/<patientId>/），
    /// 无 teardown 清理——原件按设计永不删除，每次运行永久累积。改为
    /// 每用例独立子目录并在 tearDown 统一清除。
    private var testOriginalsDirs: [URL] = []

    override func tearDownWithError() throws {
        for dir in testOriginalsDirs {
            try? FileManager.default.removeItem(at: dir)   // try?-ok: 清理尽力而为——失败只留残留测试目录，不阻断后续用例
        }
        testOriginalsDirs = []
        try super.tearDownWithError()
    }

    private func freshDefaults() -> UserDefaults {
        let suite = "M1aAcceptanceTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    private func makeApp(defaults: UserDefaults, gateResult: Bool = true) throws -> AppState {
        let container = try AppContainer.preview()
        return AppState(persistor: container.persistor,
                        gateUnlocker: FakeGateUnlocker(result: gateResult),
                        defaults: defaults, launchArgs: [])
    }

    /// 活管线状态仓（V3.39 BR-003 用例载体）：真实 DocumentStore + 桩识别器
    private func makeDocs(container: AppContainer, lines: [String] = []) -> DocumentsState {
        // 第八轮修复：每用例独立原件目录（tearDown 清除，见 testOriginalsDirs）
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vitaliber-originals-\(UUID().uuidString)", isDirectory: true)
        testOriginalsDirs.append(dir)
        return DocumentsState(
            store: container.documents,
            pipeline: OCRPipeline(recognizer: StubImageTextRecognizer(scripted: .init(lines: lines, confidence: lines.isEmpty ? 0 : 0.9)),
                                  grayscaleDecoder: GrayscaleImageDecoder()),
            originalsDir: dir,
            understandingEngine: NLTextUnderstanding())
    }

    private var tinyPNG: Data {
        UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).pngData { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        }
    }

    /// FR5.5/FR6.2（V3.61 相机单入口）：无入口类型提示 + 零命中 → 类型未决，
    /// 确认卡必须引导选择、不得以占位值落库。
    func test_typeFreeCaptureLeavesDocTypeUnresolvedWhenNothingIsJudged() async throws {
        let defaults = freshDefaults()
        let container = try AppContainer.preview()
        let app = AppState(persistor: container.persistor, defaults: defaults, launchArgs: [])
        await app.bootstrap()
        let patientId = try await ensureOwner(app: app, container: container)
        let docs = makeDocs(container: container, lines: ["随手写的一行", "没有任何医疗关键词"])
        let draft = await docs.prepareImageDraft(patientId: patientId, originalData: tinyPNG, processedData: tinyPNG,
                                                 mimeType: "image/png", docType: nil, title: nil,
                                                 isSensitive: true, origin: "camera")
        XCTAssertEqual(draft?.docTypeResolved, false, "零命中且无入口提示 → 未决，引导选择")
        XCTAssertEqual(draft?.docType, DocumentsState.unresolvedDocTypePlaceholder)
    }

    /// 无入口提示时理解层判定即预选（D 级可改）；入口提示存在时 <0.75 不覆盖用户选择。
    func test_judgedTypeResolvesWithoutEntryHint() async throws {
        let defaults = freshDefaults()
        let container = try AppContainer.preview()
        let app = AppState(persistor: container.persistor, defaults: defaults, launchArgs: [])
        await app.bootstrap()
        let patientId = try await ensureOwner(app: app, container: container)
        let docs = makeDocs(container: container, lines: ["处方", "用法：每日三次", "口服"])
        let judged = await docs.prepareImageDraft(patientId: patientId, originalData: tinyPNG, processedData: tinyPNG,
                                                  mimeType: "image/png", docType: nil, title: nil,
                                                  isSensitive: true, origin: "camera")
        XCTAssertEqual(judged?.docTypeResolved, true)
        XCTAssertEqual(judged?.docType, L10n.docTypePrescription)
        XCTAssertEqual(judged?.isPrescription, true)
        XCTAssertEqual(judged?.documentTypeKey, "prescription")

        let hinted = makeDocs(container: container, lines: ["检验"])   // 单行命中 0.6 < 0.75
        let image = tinyPNG
        let kept = await hinted.prepareImageDraft(patientId: patientId, originalData: image, processedData: image,
                                                  mimeType: "image/png", docType: L10n.docTypeRecord, title: nil,
                                                  isSensitive: true, origin: "camera")
        XCTAssertEqual(kept?.docType, L10n.docTypeRecord, "低置信判定不得推翻用户显式入口类型")
        XCTAssertEqual(kept?.docTypeResolved, true)
    }

    /// 建所有者并等 patient_profile 落库（document_file 外键依赖）
    private func ensureOwner(app: AppState, container: AppContainer) async throws -> UUID {
        app.createOwner(name: "王女士")
        for _ in 0..<20 {
            let count = try await container.store.writer.read {
                try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM patient_profile") ?? 0
            }
            if count == 1 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        return app.currentPatientId
    }

    /// FR1.1 · V3.22：门禁 = 系统设备所有者认证。冷启动（本会话未认证）即锁；
    /// 认证成功（FakeGateUnlocker 注入成功）→ 放行。完成首启前不锁。
    func test_SU_M1a_BIO_冷启动未认证即锁_认证成功放行() async throws {
        let defaults = freshDefaults()
        let app = try makeApp(defaults: defaults)
        await app.bootstrap()

        // 未完成首启：门禁未生效（向导内不锁）
        XCTAssertFalse(app.isGateEnabled)
        XCTAssertFalse(app.needsLockScreen)

        // 完成首启（模拟 onboardingFinished）→ 冷启动锁
        app.finishOnboarding()
        XCTAssertTrue(app.isGateEnabled)
        XCTAssertTrue(app.needsLockScreen, "冷启动未认证必须见锁屏")

        // 系统认证成功 → 放行
        let ok = await app.requestUnlock(reason: "test")
        XCTAssertTrue(ok)
        XCTAssertFalse(app.needsLockScreen)
        XCTAssertNotNil(app.lastUnlockedAt)
    }

    /// 认证失败/取消不放行（FakeGateUnlocker(result: false)）
    func test_SU_M1a_BIO_认证失败不放行() async throws {
        let defaults = freshDefaults()
        let app = try makeApp(defaults: defaults, gateResult: false)
        await app.bootstrap()
        app.finishOnboarding()
        XCTAssertTrue(app.needsLockScreen)

        let ok = await app.requestUnlock(reason: "test")
        XCTAssertFalse(ok)
        XCTAssertTrue(app.needsLockScreen, "认证失败必须停留在锁屏（可重试）")
        XCTAssertNil(app.lastUnlockedAt)
    }

    /// V3.22：首启三卡后直达建档（无 PIN 步骤）
    func test_SU_M1a_BIO_首启三卡后直达建档无PIN步骤() async throws {
        let defaults = freshDefaults()
        let app = try makeApp(defaults: defaults)
        await app.bootstrap()
        app.advanceDisclosure()
        app.advanceDisclosure()
        app.advanceDisclosure()
        if case .ownerName = app.stage {
            // 符合预期
        } else {
            XCTFail("三卡后应直达建档（ownerName），实际 \(app.stage)")
        }
        // 旧 PIN 残留键被清除（V3.22 卫生清理）
        XCTAssertNil(defaults.object(forKey: "pinHashV2"))
    }

    /// TC-M1a-05：L1 三卡逐卡确认 → 每条卡生成对应 ConsentRecord 并落 consent_record 表
    func test_三卡确认写入ConsentRecord且落库() async throws {
        let defaults = freshDefaults()
        let container = try AppContainer.preview()
        let app = AppState(persistor: container.persistor,
                           defaults: defaults, launchArgs: [])
        await app.bootstrap()
        XCTAssertEqual(app.disclosureCards.count, 3)
        app.advanceDisclosure()
        app.advanceDisclosure()
        app.advanceDisclosure()
        XCTAssertEqual(app.consentRecords.count, 3)
        XCTAssertEqual(Set(app.consentRecords.map(\.key)).count, 3)   // 三卡三键不重复

        // 落库断言（评审修正：不再是 UserDefaults 写入）；异步持久化任务轮询等落库
        var stored: [ConsentRecord] = []
        for _ in 0..<20 {
            stored = try await container.persistor.loadConsents()
            if stored.count == 3 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(stored.count, 3, "ConsentRecord 必须真实写入 consent_record 表")

        // 重启不重复落库（评审修正：杀进程重走三卡去重）
        let app2 = AppState(persistor: container.persistor,
                            defaults: defaults, launchArgs: [])
        await app2.bootstrap()
        XCTAssertEqual(app2.consentRecords.count, 3)
        app2.advanceDisclosure()
        XCTAssertEqual(app2.consentRecords.count, 3, "已确认的卡不得重复落 ConsentRecord")
    }

    /// LocalOwner 建立 → patient_profile 出现「本人」关联（评审修正：落库断言闭合假绿）
    func test_建档后本人关联落库() async throws {
        let defaults = freshDefaults()
        let container = try AppContainer.preview()
        let app = AppState(persistor: container.persistor,
                           defaults: defaults, launchArgs: [])
        await app.bootstrap()
        app.createOwner(name: "王女士")
        // 等待异步持久化落库
        for _ in 0..<20 {
            let count = try await container.store.writer.read {
                try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM patient_profile") ?? 0
            }
            if count == 1 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let profileCount = try await container.store.writer.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM patient_profile") ?? 0
        }
        let ownerCount = try await container.store.writer.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM local_owner") ?? 0
        }
        XCTAssertEqual(profileCount, 1, "patient_profile 必须出现「本人」档案行")
        XCTAssertEqual(ownerCount, 1, "local_owner 必须出现所有者行")
    }

    /// BR-003 活管线：确认集未全部确认时，只有已确认字段进入正式区——
    /// commitDraft 的 ocrText/留痕仅含已确认字段（V3.39 后生产闸门 =
    /// DocumentsState.commitDraft，旧 AppState 引擎已删除，红线验收不得覆盖死代码）。
    func test_BR003_活管线_未确认字段不入正式区且留痕仅已确认() async throws {
        let defaults = freshDefaults()
        let container = try AppContainer.preview()
        let app = AppState(persistor: container.persistor, defaults: defaults, launchArgs: [])
        await app.bootstrap()
        let patientId = try await ensureOwner(app: app, container: container)

        let docs = makeDocs(container: container)
        var fields = [FieldDraft(key: "drug_name", value: "阿莫西林", confidence: 0.93),
                      FieldDraft(key: "dosage", value: "每日三次", confidence: 0.88)]
        _ = fields[0].confirm()
        let image = tinyPNG
        let draft = DocumentsState.ImportDraft(
            patientId: patientId, docType: "病历", title: "样张", isSensitive: true,
            origin: "import", sha256: "sha:test",
            originalData: image, processedData: image, mimeType: "image/png",
            qualityTags: [], pages: [.init(index: 0, lines: ["阿莫西林", "每日三次"],
                                           fields: fields)])
        let saved = await docs.commitDraft(draft)
        XCTAssertTrue(saved)

        let rows = try await container.documents.list(patientId: patientId)
        XCTAssertEqual(rows.count, 1, "确认保存后 document_file 必须有一条记录")
        XCTAssertEqual(rows[0].grade, "D", "Saving metadata must not promote unreviewed machine fields")

        // ocrText 只含已确认字段（未确认的「每日三次」不得进入正式区）
        let ocrText = try await container.store.writer.read {
            try String.fetchOne($0, sql: "SELECT ocr_text FROM document_file LIMIT 1")
        }
        XCTAssertTrue(ocrText?.contains("阿莫西林") == true, "已确认字段必须进入正式区")
        XCTAssertFalse(ocrText?.contains("每日三次") == true, "BR-003：未确认字段不得进入正式区")

        // FR6.1 留痕：ocr_result 只落已确认字段（一行），未确认字段不留痕
        let traceCount = try await container.store.writer.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM ocr_result") ?? 0
        }
        XCTAssertEqual(traceCount, 1, "识别留痕必须仅含已确认字段")
    }

    /// A legacy document without retained media must not be blindly promoted.
    func test_legacyReviewWithoutOriginalLeavesDocumentUnconfirmed() async throws {
        let defaults = freshDefaults()
        let container = try AppContainer.preview()
        let app = AppState(persistor: container.persistor, defaults: defaults, launchArgs: [])
        await app.bootstrap()
        let patientId = try await ensureOwner(app: app, container: container)

        let docId = try await container.documents.save(
            patientId: patientId, docType: "病历", sha256: "pdf:test",
            mimeType: "application/pdf", origin: "import", isSensitive: false,
            metaJSON: nil, title: "PDF 导入", ocrText: "识别文本", grade: "D")
        var row = try await container.documents.fetch(id: docId)
        XCTAssertEqual(row?.grade, "D", "机器识别未确认的文档必须以 D 级入库")

        let docs = makeDocs(container: container)
        let draft = await docs.prepareStoredDocument(id: docId, patientId: patientId)
        XCTAssertNil(draft)
        XCTAssertNotNil(docs.lastImportError)

        row = try await container.documents.fetch(id: docId)
        XCTAssertEqual(row?.grade, "D")
    }
}
