import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import CryptoKit
import Domain
import Infrastructure
import Protocols

// MARK: - F5 资料库（SP-09/SP-10 · FR5.1-5.8 + FR6.6 PDF OCR）

/// 资料库状态仓：列表/入库（相机/文件/相册/手工）/归档/收藏/重复检测。
/// FR5.6 重复检测：文件哈希重复 → 提示疑似重复并给并排对比，绝不自动删除。
/// FR6.6 PDF 逐页 OCR：失败给出可见错误，绝不静默。
@MainActor
@Observable
final class DocumentsState {
    private(set) var documents: [DocumentStore.DocumentRow] = []
    /// SP-53 队列数据源：跨成员聚合的 D 级文档（成员筛选在视图层做——
    /// 此前队列复用 docs.documents（仅当前成员），选其他成员恒空态）。
    private(set) var pendingDocuments: [DocumentStore.DocumentRow] = []
    private(set) var duplicateHits: [DocumentStore.DocumentRow] = []
    private(set) var pendingDuplicate: PendingDocument?
    private(set) var lastImportError: String?
    /// 处方副表写入失败的可见标记（审查修复：commitDraft 曾以 try? 静默吞
    /// 处方行失败——主记录已入库不阻断，但确认卡按「保存成功」dismiss 后
    /// 用户永远不知道处方未进入用药记录，且注释承诺的「到资料库重试」路径
    /// 并不存在）。置位时确认卡以非阻断告警呈现，主文档保存语义不变。
    private(set) var prescriptionSyncFailed = false
    /// PDF 逐页识别失败页数（FR6.6 非阻断可见；0=全部成功/非 PDF 路径）
    private(set) var pdfPartialFailure = 0
    private let store: DocumentStore
    /// FR6.9 待办卡写门（未注入 = 预览/测试环境，跳过稍后不可用）
    private let pendingCards: PendingCardStore?
    private let pipeline: OCRPipeline
    /// PDF 解码（ADR-027：经 EAL 注入，调用方不直接实例化具体引擎——
    /// 第四轮全仓审查修复：importPDF 曾直接 new PDFKitDecoder() 绕过注册表）。
    private let decoder: any ImageDecoding
    /// F9 处方落库（只有确认后才会被调用，未注入时（预览/测试）静默跳过）。
    private let prescriptionStore: PrescriptionStore?
    /// “处方单”文档类型标签（与 L10n.docTypePrescription 同源）——命中时启用处方语义字段标签。
    private let prescriptionDocTypeLabel: String
    /// FR14.1 authOcr 消费点：授权关闭时不运行识别（资料照常入库，仅无识别文本）。
    /// 撤回即时生效——每次导入实时读值，不缓存授权状态。
    private let ocrAuthorized: @MainActor () -> Bool
    /// 原件专用目录根（BR-002，与 AppContainer.defaultOriginalsDir() 同约定）：
    /// `<base>/originals/{patientId}/{uuid}.{ext}`；预览/测试注入临时目录。
    private let originalsDir: URL
    /// FR17.18 共享文本理解层（ADR-029 期一；经 EAL 注入，默认解析注册表第 8 工厂）
    private let understandingEngine: any TextUnderstanding
    /// F25 码表索引（医疗槽位惰性 codeResolution——FR17.18 首个生产消费点；
    /// 未注入时（预览/测试）跳过标准化，不影响确认主流程）
    private let codeIndex: (any CodeIndex & UnitIndex)?
    /// 健康问题懒创建（FR11.4 V3.49 触发点；未注入时静默跳过）。
    private let problemStore: HealthProblemStore?
    /// 类型化数据变更信号（保存成功后 documentsVersion+1 触发跨页刷新）
    private let dataChange: AppDataChangeCenter?
    private var loadingPatientId: UUID?

    init(store: DocumentStore, pipeline: OCRPipeline,
         decoder: (any ImageDecoding)? = nil,
         ocrAuthorized: @escaping @MainActor () -> Bool = { true },
         originalsDir: URL? = nil, prescriptionStore: PrescriptionStore? = nil,
         prescriptionDocTypeLabel: String = L10n.docTypePrescription,
         understandingEngine: (any TextUnderstanding)? = nil,
         codeIndex: (any CodeIndex & UnitIndex)? = nil,
         problemStore: HealthProblemStore? = nil,
         dataChange: AppDataChangeCenter? = nil,
         pendingCards: PendingCardStore? = nil) {
        self.store = store
        self.pipeline = pipeline
        self.decoder = decoder ?? EngineRegistry.shared.resolve(ImageDecodingFactory.self)
        self.ocrAuthorized = ocrAuthorized
        self.originalsDir = originalsDir ?? FileManager.default.temporaryDirectory
        self.prescriptionStore = prescriptionStore
        self.prescriptionDocTypeLabel = prescriptionDocTypeLabel
        self.understandingEngine = understandingEngine
            ?? EngineRegistry.shared.resolve(TextUnderstandingFactory.self)
        self.codeIndex = codeIndex
        self.problemStore = problemStore
        self.dataChange = dataChange
        self.pendingCards = pendingCards
    }

    struct PendingDocument: Identifiable, Equatable {
        let id = UUID()
        /// 导入时的所属成员（第四轮全仓审查修复：裁决落库必须用它，绝不用
        /// loadingPatientId——导入后、裁决前切换成员时后者已指向他人，
        /// 或从未 load 时为 nil → 并存/替换静默丢弃且误报「已保存」）。
        var patientId: UUID
        var originalData: Data
        var processedData: Data
        var mimeType: String
        var docType: String
        var title: String?
        var sha256: String
        var isSensitive: Bool
        var origin: String = "import"
    }

    /// 确认卡的载体：已查重+跑过 OCR 的待确认草稿——尚未写库，等用户逐条确认
    /// （BR-003：机器识别字段必须确认才生效）。
    struct ImportDraft: Identifiable {
        let id = UUID()
        var patientId: UUID
        var docType: String
        var title: String?
        var isSensitive: Bool
        var origin: String
        var sha256: String
        /// 拍摄/选取的原始帧（未经矫正/遮挡，BR-002）。
        var originalData: Data
        /// 矫正+遮挡后的展示版（OCR 与入库用）。
        var processedData: Data
        var mimeType: String
        var qualityTags: [String]
        var confirmationSet: OcrConfirmationSet
        var isPrescription: Bool
        /// FR6.9 待办卡 raw_text 源（识别原文行拼接；BR-002 不丢内容）。
        /// 跳过稍后暂存时必须随卡落库（pending_card.raw_text NOT NULL）
        var ocrText: String
        /// 「替换」裁决的旧文档（第四轮全仓审查修复：旧版归档延后到新版本
        /// 确认入库**之后**——此前 resolveDuplicate 先归档旧版再弹确认卡，
        /// 用户取消 = 旧版已从活跃列表消失 + 新版未入库，资料凭空少一份）
        var replaceDocumentId: UUID?
    }

    /// 最近一次 load 的归档视图开关（setArchived/setFavorite 重载沿用——
    /// 此前重载恒用默认 false：归档视图内取消归档后列表突跳回活跃视图，
    /// 工具条开关与实际内容脱节）
    private var lastIncludeArchived = false

    func load(patientId: UUID, includeArchived: Bool = false) async {
        loadingPatientId = patientId
        lastIncludeArchived = includeArchived
        do {
            let rows = try await store.list(patientId: patientId, includeArchived: includeArchived)
            guard loadingPatientId == patientId else { return }
            documents = rows
        } catch {
            documents = []
        }
    }

    /// SP-53 待确认队列：跨成员聚合 D 级文档（成员筛选视图层做）。
    /// 读取失败保留旧列表（第八轮 doctrine：置空让未确认剂量/文档从
    /// 队列静默消失 = 假「全部已确认」空态，误漏待确认工作）
    func loadPending(patientIds: [UUID]) async {
        do {
            pendingDocuments = try await store.listPending(patientIds: patientIds)
        } catch {
            // 保留上次成功结果，队列不因瞬时读失败清空
        }
    }

    /// 详情页用：单条取回（列表投影不含 meta_json，详情页需要解析原件路径等扩展字段）。
    func fetch(id: UUID) async -> DocumentStore.DocumentRow? {
        try? await store.fetch(id: id)   // try?-ok: 取回失败按「未找到」降级，不阻断详情页展示错误态
    }

    /// 原件落盘（BR-002：原件不可变，必须留档才能满足「永远能看原图」的产品承诺）。
    /// 与 AppState.saveOriginal 同约定：`<base>/originals/{patientId}/{uuid}.{ext}`，
    /// 只写一次不再修改。失败返回 nil——调用方仍照常入库，只是缺原图可查，
    /// 不能因为原件落盘失败就丢弃整份已识别资料（FR6.6 绝不静默丢失，但也绝不因小失大）。
    private func persistOriginal(patientId: UUID, data: Data, ext: String) -> String? {
        let dir = originalsDir
            .appendingPathComponent("originals", isDirectory: true)
            .appendingPathComponent(patientId.uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("\(UUID().uuidString).\(ext)")
            try data.write(to: url, options: .atomic)
            return url.path
        } catch {
            return nil
        }
    }

    /// 把原件路径合并进已有 meta 载荷（不覆盖既有键）；无原件路径时原样返回 base。
    private func mergeOriginalPath(_ path: String?, into base: [String: Any]) -> String? {
        guard let path else {
            return base.isEmpty ? nil : (try? JSONSerialization.data(withJSONObject: base))   // try?-ok: 序列化本方法内部构造的纯 String 字典，理论不会失败；失败时静默回退 nil（即无 meta），不阻断文档入库主流程
                .flatMap { String(data: $0, encoding: .utf8) }
        }
        var merged = base
        merged["original_path"] = path
        return (try? JSONSerialization.data(withJSONObject: merged))   // try?-ok: 同上，序列化失败时静默回退 nil，不阻断文档入库主流程
            .flatMap { String(data: $0, encoding: .utf8) }
    }

    func setArchived(id: UUID, archived: Bool) async {
        do {
            try await store.setArchived(id: id, archived: archived)
            if let patientId = loadingPatientId {
                await load(patientId: patientId, includeArchived: lastIncludeArchived)
            }
        } catch {
            // 错误经日志；列表刷新即真实状态
        }
    }

    func setFavorite(id: UUID, favorite: Bool) async {
        do {
            try await store.setFavorite(id: id, favorite: favorite)
            if let patientId = loadingPatientId {
                await load(patientId: patientId, includeArchived: lastIncludeArchived)
            }
        } catch {
            // 同上
        }
    }

    /// 图片入库第一阶段：查重 + OCR（在矫正/遮挡后的图像上跑），**不写库**。
    /// 命中重复时写入 pendingDuplicate（由调用方展示并徕裁决），返回 nil；
    /// 否则返回待确认草稿，由调用方展示 `DocumentImportConfirmView` 让用户逐条确认。
    /// origin 必须落在 document_file.origin CHECK 枚举内（camera/photoLibrary/import/
    /// scanner/manual）——曾用 "file" 触发 SQLITE_CONSTRAINT_CHECK，全部导入失败。
    func prepareImageDraft(patientId: UUID, originalData: Data, processedData: Data, mimeType: String,
                           docType: String, title: String?, isSensitive: Bool,
                           origin: String = "import") async -> ImportDraft? {
        lastImportError = nil
        // 去重哈希注定到矫正/遮挡后的展示版——同一张原始照片选不同区域/不同遮挡视为不同文档
        let sha = "sha:" + Self.hash(processedData)
        do {
            let hits = try await store.duplicates(sha256: sha, patientId: patientId)
            guard hits.isEmpty else {
                duplicateHits = hits
                pendingDuplicate = PendingDocument(patientId: patientId, originalData: originalData, processedData: processedData,
                                                   mimeType: mimeType, docType: docType, title: title,
                                                   sha256: sha, isSensitive: isSensitive, origin: origin)
                return nil
            }
        } catch {
            lastImportError = L10n.docImportFailed
            return nil
        }
        return await buildDraft(patientId: patientId, originalData: originalData, processedData: processedData,
                                mimeType: mimeType, docType: docType, title: title,
                                isSensitive: isSensitive, origin: origin, sha256: sha)
    }

    /// OCR 跑完后组装待确认草稿（FR17.18 期一接线，V3.49）：行文本先过共享
    /// 文本理解层（文档类型判定 D 级草稿 + 多类候选），字段目录随判定类型
    /// 收敛——处方走 PrescriptionFieldMapper 语义标签、检验/病历走启发式
    /// 语义字段（科室/日期/项目/主诉/诊断/处理）、未命中行通用 line_N 兜底；
    /// 入口 docType 仅作 documentTypeHint（提示，不替代判定，FR5.5/FR6.2）。
    /// FR6.1/ADR-026：OCR 经统一编排层（质量评估+识别）；
    /// FR14.1 authOcr：授权关闭 → 跳过识别，草稿无候选字段但仍可确认保存。
    private func buildDraft(patientId: UUID, originalData: Data, processedData: Data, mimeType: String,
                            docType: String, title: String?, isSensitive: Bool, origin: String,
                            sha256: String, replaceDocumentId: UUID? = nil) async -> ImportDraft? {
        var fields: [CandidateField] = []
        var tags: [String] = []
        var linesText = ""     // FR6.9：识别原文（跳过稍后 pending_card.raw_text 源）
        var effectiveDocType = docType
        var isPrescription = PrescriptionFieldMapper.isPrescriptionDocType(
            docType, prescriptionLabel: prescriptionDocTypeLabel)
        if ocrAuthorized() {
            do {
                let result = try await pipeline.run(imageData: processedData)
                tags = result.qualityTags
                linesText = result.lines.joined(separator: "\n")
                if result.failed {
                    // FR6.6：识别引擎失败必须可见，绝不静默按「无文字」入库
                    lastImportError = L10n.docImportFailed
                    return nil
                }
                // FR17.18：类型判定（D 级建议，可改；低置信/零命中由确认卡
                // 引导选择，入口 hint 仅作提示输入）。判定应用门槛（§8.6
                // 断言④）：单命中 0.6 中档需复核——不得推翻用户显式选择的
                // 入口类型（处方被 0.6 误判为检验报告 = 处方行静默跳过；
                // 检验报告被误判为处方 = 药名字段解析错位）。≥0.75（≥2 行
                // 证据）才采纳判定覆盖 docType。
                let understanding = await understandingEngine.understand(
                    TextUnderstandingInput(text: result.lines.joined(separator: "\n"),
                                           lines: result.lines,
                                           source: .ocr(documentTypeHint: docType)))
                if let judged = understanding.suggestedTarget,
                   understanding.targetConfidence >= 0.75 {
                    let judgedLabel = Self.docTypeLabel(forStableKey: judged)
                    if let judgedLabel {
                        effectiveDocType = judgedLabel
                    }
                    isPrescription = judged == "prescription"
                        || (isPrescription && judgedLabel == nil)
                }
                if isPrescription {
                    fields = PrescriptionFieldMapper.draftFields(from: result.lines, labels: Self.prescriptionLabels)
                } else {
                    // 理解层字段直接消费（引擎侧已含启发式抽取/零命中 line_N
                    // 草稿与已认领行下标——不再 App 侧重跑同一套 guessFields，
                    // 两处独立演化即字段漂移）；契约桩（测试/非 Apple）产出
                    // 为空时回落本地同源 Domain 纯函数抽取，语义一致
                    var draftFields = understanding.fields
                    var claimed = understanding.claimedLineIndices
                    if draftFields.isEmpty && claimed.isEmpty {
                        for (idx, line) in result.lines.enumerated() {
                            for draft in DocumentTypeClassifierFallback.guessFields(line: line) {
                                claimed.insert(idx)
                                draftFields.append(draft)
                            }
                        }
                    }
                    // F25 惰性接线（医疗槽位过 CodeResolver；FR17.18 首个
                    // 生产消费点，FR25.12⑫ 核销——未注入索引时跳过不阻断）
                    if let codeIndex {
                        draftFields = await UnderstandingCodeResolution.resolve(
                            draftFields, locale: Locale(identifier: "zh_Hans"),
                            index: codeIndex, units: codeIndex)
                    }
                    fields = draftFields.map { draft in
                        CandidateField(key: draft.key,
                                       displayLabel: Self.fieldLabel(forKey: draft.key),
                                       rawText: draft.rawText ?? draft.value,
                                       confidence: draft.confidence, value: draft.value,
                                       codeResolution: draft.codeResolution)
                    }
                    fields.append(contentsOf: result.lines.enumerated().compactMap { idx, line in
                        claimed.contains(idx) ? nil : CandidateField(
                            key: "line_\(idx)",
                            displayLabel: String(format: L10n.ocrFieldLine, idx + 1),
                            rawText: line, confidence: 0.6)
                    })
                }
            } catch {
                lastImportError = L10n.docImportFailed
                return nil
            }
        }
        return ImportDraft(patientId: patientId, docType: effectiveDocType, title: title, isSensitive: isSensitive,
                           origin: origin, sha256: sha256, originalData: originalData, processedData: processedData,
                           mimeType: mimeType, qualityTags: tags,
                           confirmationSet: OcrConfirmationSet(fields: fields),   // confirm-ok: F6/F9 图片入库 OCR 确认集是合法产出方（非语音路径），FR17.13 只约束语音草稿确认
                           isPrescription: isPrescription,
                           ocrText: linesText,
                           replaceDocumentId: replaceDocumentId)
    }

    /// FR11.4 懒创建触发判定（病历类 = 检验报告/门诊病历标签；按**保存时**
    /// docType 判定——确认卡 Picker 改类后判定随之更新，不冻结 buildDraft
    /// 时刻的分类快照：改离病历类不再弹「创建健康问题」，改入则补上）
    func isClinicalDocType(_ label: String) -> Bool {
        label == L10n.docTypeReport || label == L10n.docTypeRecord
    }

    /// 稳定类型键 → 文档类型标签（App 层映射；键族单一事实源在
    /// Domain DocumentTypeClassifierFallback）
    private static func docTypeLabel(forStableKey key: String) -> String? {
        switch key {
        case "prescription": return L10n.docTypePrescription
        case "lab_report": return L10n.docTypeReport
        case "outpatient_record", "diagnosis_certificate": return L10n.docTypeRecord
        default: return nil
        }
    }

    /// 理解层字段键 → 确认卡展示标签（L10n 单出口）
    static func fieldLabel(forKey key: String) -> String {
        switch key {
        case "dept": return L10n.ocFieldDept
        case "report_date": return L10n.ocFieldReportDate
        case "reference_range": return L10n.ocFieldReferenceRange
        case "lab_item": return L10n.ocFieldLabItem
        case "chief_complaint": return L10n.ocFieldChiefComplaint
        case "diagnosis": return L10n.ocFieldDiagnosis
        case "treatment": return L10n.ocFieldTreatment
        case "drug_name": return L10n.prescriptionFieldDrugName
        case "prescribed_at": return L10n.ocFieldReportDate
        case "hospital": return L10n.prescriptionFieldHospital
        case "doctor": return L10n.prescriptionFieldDoctor
        default: return key
        }
    }

    static let prescriptionLabels = PrescriptionFieldMapper.Labels(
        hospital: L10n.prescriptionFieldHospital, doctor: L10n.prescriptionFieldDoctor,
        frequency: L10n.prescriptionFieldFrequency, dosage: L10n.prescriptionFieldDosage,
        drugName: L10n.prescriptionFieldDrugName, other: L10n.prescriptionFieldOther)

    /// 用户在 `DocumentImportConfirmView` 确认全部字段后调用：原件+处理版双落盘，
    /// document_file 直接以 grade='C' 写入（确认已完成，不再经 D），处方文档额外落
    /// 一条 prescription 行（复用现有 hospital/doctor/advice_text 列，不新增迁移）。
    /// FR6.9 跳过稍后：部分完整草稿暂存待办卡（D 级草稿，BR-003 表级排除
    /// ——pending_card 不进搜索索引/FTS/AI 检索/导出/时间轴）。缺失字段与
    /// 已识别字段快照随卡落库；同源文档重复跳过复用既有卡（§21.1）。
    /// 返回 nil = 未注入仓（预览/测试）或写入失败（错误经 lastImportError
    /// 可见，绝不静默假装已存）。
    func skipForLater(draft: ImportDraft, assessment: CompletenessAssessment) async -> Bool {
        guard let pendingCards else { return false }
        guard assessment.level == .partiallyComplete else { return false }
        let cardKind = draft.isPrescription ? "prescription" : "document_file"
        let incomplete = assessment.missingFields.map {
            IncompleteField(key: $0.key, confidence: 0, reason: L10n.pendingCardReasonOcrMissing)
        }
        var partial: [String: String] = [:]
        for field in draft.confirmationSet.fields where !field.value.isEmpty {
            partial[field.key] = field.value
        }
        let draft2 = PendingCardDraft(
            patientId: draft.patientId,
            sourceType: "ocr",
            sourceDocId: nil,   // 文档尚未入库（确认卡阶段无 doc id）
            cardKind: cardKind,
            incompleteFields: incomplete,
            partialData: partial,
            rawText: draft.ocrText)
        do {
            try await pendingCards.upsert(draft2)
            return true
        } catch {
            lastImportError = L10n.docImportFailed
            return false
        }
    }

    func commitDraft(_ draft: ImportDraft) async {
        // 错误态归零：保存失败必须可见、成功必须清除残留（第四轮全仓审查
        // 修复——确认卡以 lastImportError 判成功/失败并决定是否 dismiss）
        lastImportError = nil
        prescriptionSyncFailed = false
        // 原件扩展名按真实 MIME 映射（第四轮全仓审查修复：原仅判 "png" 其余
        // 一律 .jpg——HEIC/GIF/WebP 原件以 .jpg 落盘，扩展名与内容不符，
        // BR-002 原图语义受损）
        let ext = ImageInputRules.fileExtension(for: draft.mimeType)
        let originalPath = persistOriginal(patientId: draft.patientId, data: draft.originalData, ext: ext)
        let processedPath = persistOriginal(patientId: draft.patientId, data: draft.processedData, ext: ext)
        var meta: [String: Any] = [:]
        if let originalPath { meta["original_path"] = originalPath }
        if let processedPath { meta["processed_path"] = processedPath }
        let metaJSON = meta.isEmpty ? nil : (try? JSONSerialization.data(withJSONObject: meta))   // try?-ok: 序列化本方法内部构造的纯 String 字典，理论不会失败；失败时静默回退 nil，不阻断确认保存主流程
            .flatMap { String(data: $0, encoding: .utf8) }
        let ocrText = draft.confirmationSet.confirmedFields.map(\.value).joined(separator: "\n")
        do {
            let docId = try await store.save(patientId: draft.patientId, docType: draft.docType,
                                             sha256: draft.sha256, mimeType: draft.mimeType, origin: draft.origin,
                                             isSensitive: draft.isSensitive, metaJSON: metaJSON, title: draft.title,
                                             ocrText: ocrText.isEmpty ? nil : ocrText, grade: "C")
            // 处方行写入判定按**保存时**的 docType 重算（Domain 纯函数）：
            // 确认卡类型 Picker 改类必须生效——buildDraft 的 isPrescription
            // 只是草稿建议，用户改回处方但旧值仍 false 时处方行被静默跳过；
            // 反之改离处方则不再写处方行。此前 Picker 修正对处方行无效。
            let isPrescription = PrescriptionFieldMapper.isPrescriptionDocType(
                draft.docType, prescriptionLabel: prescriptionDocTypeLabel)
            if isPrescription, let prescriptionStore {
                let (hospital, doctor, adviceText) = PrescriptionFieldMapper.buildAdviceText(confirmed: draft.confirmationSet.confirmedFields,
                                                                                             labels: Self.prescriptionLabels)
                do {
                    try await prescriptionStore.create(patientId: draft.patientId, documentFileId: docId,
                                                       hospital: hospital, doctor: doctor, adviceText: adviceText)
                } catch {
                    // 审查修复：处方行写入失败不回滚 document_file（主记录已入库），
                    // 但绝不静默——置位 prescriptionSyncFailed，确认卡以非阻断
                    // 告警提示「文档已保存、处方未同步」（此前 try? 吞错 +
                    // 注释承诺的重试路径并不存在 = 处方行永久丢失且无感知）
                    prescriptionSyncFailed = true
                }
            }
            // FR6.1 识别留痕：已确认字段逐行落 ocr_result（原文块+置信度+引擎版本，
            // 可追溯可重放）。V3.39 起此处是唯一写入口——旧 AppState 引擎已删除；
            // 留痕副表失败不回滚主记录（与处方副表同策略）。
            if !draft.confirmationSet.confirmedFields.isEmpty {
                try? await store.saveOCRResult(documentId: docId,   // try?-ok: 留痕失败不阻断主入库，主记录已落盘
                                               fields: draft.confirmationSet.confirmedFields,
                                               engineVersion: "ocr-pipeline")
            }
            // 「替换」语义：新版本已确认入库，此时才归档旧版（第四轮全仓审查
            // 修复——此前先归档后确认，取消确认卡 = 旧版已归档+新版未入库，
            // 用户资料凭空少一份）。归档失败不阻断：列表刷新即真实状态。
            if let replaceId = draft.replaceDocumentId {
                try? await store.setArchived(id: replaceId, archived: true)   // try?-ok: 归档旧版失败不阻断主入库流程，下次列表刷新自愈
            }
            await load(patientId: draft.patientId)
            // FR17.18 保存后跨页刷新（V3.49）：类型化变更信号 +1——健康资料/
            // 时间轴/健康问题页据 documentsVersion 失效重载。FR11.4 懒创建
            // 触发判定由确认卡按保存时 docType 判定（isClinicalDocType）
            dataChange?.documentSaved()
        } catch {
            lastImportError = L10n.docImportFailed
        }
    }

    /// FR11.4 懒创建（V3.49）：病历类文档确认保存后由确认卡触发——候选名
    /// 由 Domain 纯函数派生（HealthProblemDerivation），用户确认后才落库。
    /// 返回成败；失败静默降级（健康问题条目为可选增强，不阻断文档主流程）。
    func createHealthProblem(patientId: UUID, name: String) async -> Bool {
        guard let problemStore else { return false }
        do {
            _ = try await problemStore.create(patientId: patientId, name: name)
            return true
        } catch {
            return false
        }
    }

    /// 通用文件入库（快速拍摄「文件」来源）：PDF 走逐页 OCR 管线，图片走
    /// Vision 管线（未经四角选区，直接以原图=处理版组草稿，同样需确认后才入库），
    /// 其余格式（Word 等）归档元数据记录——原文件 body 解析待升级，绝不静默吞文件。
    /// isSensitive：快速拍摄默认 true（BR-007 敏感默认锁定）；资料库导入
    /// 沿用原语义 false（用户可后续标记）。
    func importDocument(patientId: UUID, url: URL, docType: String,
                        isSensitive: Bool = false) async -> ImportDraft? {
        lastImportError = nil
        pdfPartialFailure = 0
        // 文件导入 URL 为安全作用域（fileImporter）——图片/其他分支此前
        // 未启动作用域即 Data(contentsOf:)（importPDF 有），真机上
        // iCloud/第三方提供方拒绝读取 → 全部图片导入报「导入失败」
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        switch url.pathExtension.lowercased() {
        case "pdf":
            await importPDF(patientId: patientId, url: url, docType: docType, isSensitive: isSensitive)
            return nil
        case "png", "jpg", "jpeg", "heic", "heif", "gif", "webp":
            guard let data = try? Data(contentsOf: url) else {   // try?-ok: 读取失败走错误路径可见，不阻塞后续导入
                lastImportError = L10n.docImportFailed
                return nil
            }
            // MIME 按字节嗅探（第四轮全仓审查修复：原把扩展名直接当 MIME 传，
            // 扩展名与内容脱钩后 fileExtension(for:) 映射恒回落 .jpg）
            let mime = ImageInputRules.sniffMimeType(of: data,
                                                     fallback: "image/\(url.pathExtension.lowercased())")
            return await prepareImageDraft(patientId: patientId, originalData: data, processedData: data,
                                           mimeType: mime, docType: docType,
                                           title: url.lastPathComponent, isSensitive: isSensitive, origin: "import")
        default:
            // Word/其他格式：元数据入库（文件名/哈希）+ 原件落盘（BR-002），文本解析待升级
            do {
                let data = try Data(contentsOf: url)
                let ext = url.pathExtension.isEmpty ? "docx" : url.pathExtension
                let path = persistOriginal(patientId: patientId, data: data, ext: ext)
                _ = try await store.save(patientId: patientId, docType: docType,
                                         sha256: "file:" + Self.hash(data),
                                         mimeType: url.pathExtension, origin: "import",
                                         isSensitive: isSensitive,
                                         metaJSON: mergeOriginalPath(path, into: ["pendingParse": ext]),
                                         title: url.lastPathComponent)
                await load(patientId: patientId)
            } catch {
                lastImportError = L10n.docImportFailed
            }
            return nil
        }
    }

    /// FR6.6 PDF 逐页 OCR：PDFKitDecoder 渲染 → 逐页识别 → 文本入库。
    /// 渲染失败上抛 → lastImportError 可见（绝不静默）。
    /// 识别文本写入 ocr_text 检索列（原 base64 塞 meta_json：FTS 无法索引）；
    /// 机器识别未确认 = grade 'D'（BR-003），确认后升 C 才进入检索/AI 事实链。
    func importPDF(patientId: UUID, url: URL, docType: String, isSensitive: Bool = false) async {
        lastImportError = nil
        pdfPartialFailure = 0
        do {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            // Swift 6 收敛：@Sendable 逐页回调内禁改捕获 var——串行累加器收集
            // （decodePDFPages 逐页 await 回调、串行执行，无并发写）
            final class ImportAccumulator: @unchecked Sendable {
                var texts: [String] = []
                var failedPages = 0
            }
            let acc = ImportAccumulator()
            // FR14.1 authOcr：授权关闭 → 不逐页识别（只归档，meta 标 skipped）
            let ocrOn = ocrAuthorized()
            if ocrOn {
                // 逐页流式：单页渲染→识别→释放（页位图不整体驻留内存）。
                // 解码器经 EAL 注入（ADR-027：调用方不直接实例化具体引擎——
                // 第四轮全仓审查修复，测试可替身、注册表解码工厂不再死代码）。
                try await decoder.decodePDFPages(data, scale: 2.0, maxPages: 50) { page in
                    // ADR-026：PDF 逐页识别同样经统一编排层
                    let result = (try? await self.pipeline.run(imageData: page.bitmapData))   // try?-ok: 单页失败继续下一页（FR6.6 汇总时标注）
                    if let result, !result.failed, result.hasText {
                        acc.texts.append(result.lines.joined(separator: "\n"))
                    } else {
                        // 引擎失败与无文字分别标注（FR6.6：失败必须可见，不静默）
                        acc.failedPages += 1
                        acc.texts.append("")
                    }
                }
            }
            let texts = acc.texts
            let failedPages = acc.failedPages
            let joined = texts.filter { !$0.isEmpty }.joined(separator: "\n---\n")
            let metaPayload = ["engine": ocrOn ? "vision" : "skipped-auth",
                               "page_count": texts.count,
                               "failed_pages": failedPages] as [String: Any]
            let originalPath = persistOriginal(patientId: patientId, data: data, ext: "pdf")
            let metaJSON = mergeOriginalPath(originalPath, into: metaPayload)
            // FR5.6 重复检测同样适用 PDF 导入（此前仅图片路径查重，同一 PDF
            // 重复导入静默生成重复行）——命中即挂 pendingDuplicate，由调用方
            // 呈现并排对比裁决（keep/adopt/coexist，绝不自动删除）
            let pdfSHA = "pdf:" + Self.hash(data)
            do {
                let hits = try await store.duplicates(sha256: pdfSHA, patientId: patientId)
                guard hits.isEmpty else {
                    duplicateHits = hits
                    pendingDuplicate = PendingDocument(patientId: patientId, originalData: data,
                                                       processedData: data, mimeType: "application/pdf",
                                                       docType: docType, title: url.lastPathComponent,
                                                       sha256: pdfSHA, isSensitive: isSensitive,
                                                       origin: "import")
                    return
                }
            } catch {
                // 查重失败不阻断导入（宁可重复入库也不丢资料）
            }
            _ = try await store.save(patientId: patientId, docType: docType,
                                     sha256: pdfSHA, mimeType: "application/pdf",
                                     origin: "import", isSensitive: isSensitive,
                                     metaJSON: metaJSON, title: url.lastPathComponent,
                                     ocrText: joined.isEmpty ? nil : joined, grade: "D")
            // FR6.6 逐页失败可见（非阻断）：文档已存档但 N 页识别失败——
            // 此前只写 meta_json（无任何 UI 消费点），全部页失败仍弹「已保存」
            pdfPartialFailure = failedPages
            await load(patientId: patientId)
        } catch {
            // FR6.6：失败必须给出可见错误反馈，绝不静默
            lastImportError = L10n.docPDFImportFailed
        }
    }

    /// 手工新建（FR5.1 第五入口）：标题 + 类型 + 备注文本
    func createManual(patientId: UUID, title: String, docType: String, note: String) async {
        do {
            let payload = ["note": note]
            let metaJSON = String(data: try JSONEncoder().encode(payload), encoding: .utf8)
            _ = try await store.save(patientId: patientId, docType: docType,
                                     sha256: nil, mimeType: nil, origin: "manual",
                                     isSensitive: false, metaJSON: metaJSON, title: title)
            await load(patientId: patientId)
        } catch {
            lastImportError = L10n.docImportFailed
        }
    }

    /// 重复提示后的用户裁决：并存（绝不自动删除）或放弃
    enum DuplicateResolution { case keep, coexist, replace }

    /// FR5.6/§5.52 三态裁决（V3.72）：保留已有（丢弃新）/两者并存/替换（归档旧版+存新版）。
    /// 绝不自动删除（归档=软删语义）。并存/替换同样经确认卡（返回草稿而非直接写库）。
    /// 第五轮全仓审查修复（5WHY）：pendingDuplicate 的清理由调用方在草稿挂载后
    /// 经 clearPendingDuplicate 显式执行——若在返回草稿前释放裁决槽（原 defer），
    /// onChange(queueSlotFree) 会在 pendingDraft 赋值前放行串行队列，下一队列项
    /// 完成后覆盖刚裁决出的草稿（用户选的并存/替换被静默丢弃）；同时 sheet
    /// dismiss 触发的 .keep 任务会与选择任务竞速消费 pendingDuplicate。
    func resolveDuplicate(_ resolution: DuplicateResolution) async -> ImportDraft? {
        guard let pending = pendingDuplicate else { return nil }
        let patientId = pending.patientId
        let hits = duplicateHits
        switch resolution {
        case .keep:
            // 丢弃新文件——原件未被写入，无清理动作；裁决槽同步释放
            pendingDuplicate = nil
            duplicateHits = []
            return nil
        case .coexist, .replace:
            break
        }
        // 「替换」的归档动作延后到确认卡入库之后（见 ImportDraft.replaceDocumentId）
        return await buildDraft(patientId: patientId, originalData: pending.originalData,
                                processedData: pending.processedData, mimeType: pending.mimeType,
                                docType: pending.docType, title: pending.title,
                                isSensitive: pending.isSensitive, origin: pending.origin, sha256: pending.sha256,
                                replaceDocumentId: resolution == .replace ? hits.first?.id : nil)
    }

    /// 重复裁决槽显式释放：调用方必须在 pendingDraft 挂载之后调用，
    /// 保证串行队列的「槽空即续跑」（onChange(queueSlotFree)）不早于草稿挂载触发。
    func clearPendingDuplicate() {
        pendingDuplicate = nil
        duplicateHits = []
    }

    /// BR-003 D→C：用户显式确认机器识别文本后才进入检索与 AI 事实链。
    /// 返回是否写入成功；成功后立即把该行移出待确认投影——后续的
    /// loadPending 对账若失败也不得让已确认行滞留（D 徽章 + 可重复确认）。
    @discardableResult
    func confirmText(id: UUID) async -> Bool {
        do {
            try await store.confirmText(id: id)
            pendingDocuments.removeAll { $0.id == id }
            if let patientId = loadingPatientId { await load(patientId: patientId) }
            return true
        } catch {
            // 写入失败经返回值呈现；列表刷新即真实状态
            return false
        }
    }

    /// ADR-025：去重哈希收敛到 ContentHashing 单实现（Infrastructure
    /// CryptoKitContentHasher）——生产路径零自研 crypto
    static func hash(_ data: Data) -> String {
        CryptoKitContentHasher().sha256Hex(data)
    }
}

/// 资料库列表（SP-09）：文档类型徽章 + 敏感锁标 + 归档/收藏滑动操作 +
/// 导入源（SP-10：相机/文件/相册/手工）+ 重复检测对比提示。
struct DocumentLibraryView: View {

    /// 第六轮全仓审查修复：.importSource 路由（SP-10 导入来源选择）此前
    /// 与 .documentList 渲染同一屏（栈内套娃另一个完整资料库）——现经
    /// autoPresentImport 直达五入口确认弹窗，两路由语义分离
    init(autoPresentImport: Bool = false) {
        _showImportSource = State(initialValue: autoPresentImport)
    }

    /// 列表主体与导入入口动作拆为独立计算属性（CI 34037986523 实证：
    /// 巨型 body 表达式超出 Swift 类型推断预算——「unable to type-check
    /// in reasonable time」。拆分为显式类型边界后各段独立推断）。
    private var importContent: some View {
        Group {
            if state.documents.isEmpty {
                DocumentLibraryEmptyView()
            } else {
                DocumentListView()
            }
        }
    }

    /// FR5.1 五入口确认弹窗内容：相机拍摄 / 文件导入（PDF/图片）/ 相册导入 / 手工新建
    @ViewBuilder private var importSourceActions: some View {
        Button(L10n.docImportCamera) { router.navigate(to: .scanCapture(.record)) }
        Button(L10n.docImportFile) { fileImporterActive = true }
        Button(L10n.docImportPhotos) { photosImporterActive = true }
        Button(L10n.docImportManual) { showManualCreate = true }
        Button(L10n.commonCancel, role: .cancel) { }
    }

    @Environment(AppState.self) private var app
    @Environment(DocumentsState.self) private var state
    @Environment(AppRouter.self) private var router
    @State private var showImportSource = false
    @State private var showArchived = false
    @State private var fileImporterActive = false
    /// 文件多选串行队列（与 photoQueue 同纪律：单槽占用时暂停）
    @State private var fileQueue: [URL] = []
    @State private var photosImporterActive = false
    @State private var showManualCreate = false
    @State private var pickedPhotos: [PhotosPickerItem] = []
    /// 相册多选串行队列（第四轮全仓审查修复：防并发 Task 覆盖单槽状态）
    @State private var photoQueue: [PhotosPickerItem] = []
    /// 两个队列共用的在途互斥（第五轮全仓审查修复）：fileQueue 与 photoQueue
    /// 各自守卫 pendingDraft/pendingDuplicate 后并发启动 Task——两条队列同时
    /// 在途时后完成者覆盖先完成者的 pendingDraft，先完成的草稿（含原件字节）
    /// 静默丢失。单槽互斥保证任一时刻至多一个导入在途。
    @State private var queueProcessing = false
    /// 重复裁决「已作出选择」标记（第五轮全仓审查修复）：sheet 保存按钮
    /// onResolve 与 dismiss() 同一事务先后触发——dismiss 令 duplicateAlertBinding
    /// 的 setter 发出 .keep 任务，与选择任务竞速消费 pendingDuplicate（先到者
    /// 清槽、后到者 guard 落空 → 用户选的并存/替换被静默丢弃）。选择已作出时
    /// setter 不得再发 keep。
    @State private var duplicateChoiceMade = false
    @State private var showImportError = false
    /// FR6.1 确认卡（此前导入即以 D 级静默入库，无用户确认环节）：OCR 后展示，
    /// 用户逐条确认/改正才写入数据库。
    @State private var pendingDraft: DocumentsState.ImportDraft?

    @ToolbarContentBuilder private var libraryToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                showArchived.toggle()
                Task { await state.load(patientId: app.currentPatientId, includeArchived: showArchived) }
            } label: {
                Image(systemName: showArchived ? "archivebox.fill" : "archivebox")
            }
            .accessibilityLabel(L10n.docArchive)
            Button {
                showImportSource = true
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel(L10n.docAdd)
            .accessibilityIdentifier("SP-09.document.add")
        }
    }

    var body: some View {
        importContent
            .navigationTitle(L10n.docLibraryTitle)
            .toolbar {
                libraryToolbar
            }
            .confirmationDialog(L10n.docImportSourceTitle, isPresented: $showImportSource,
                                titleVisibility: .visible) {
                importSourceActions
            }
        // FR5.6/§5.52 重复检测：并排对比三态裁决 sheet（V3.72，绝不自动删除）
        .sheet(isPresented: duplicateAlertBinding) {
            DuplicateCompareSheet(
                existing: state.duplicateHits.first,
                newTitle: state.pendingDuplicate?.title ?? L10n.docDuplicateNewFile) { resolution in
                // 先挂草稿再释放裁决槽：clearPendingDuplicate 之后
                // queueSlotFree 才可能变 true，续跑队列不会覆盖刚裁决的草稿
                duplicateChoiceMade = true
                Task {
                    let draft = await state.resolveDuplicate(resolution)
                    pendingDraft = draft
                    state.clearPendingDuplicate()
                    duplicateChoiceMade = false
                }
            }
            .presentationDetents([.medium])
        }
        // FR6.1 确认卡：并存/替换与直接导入共用同一个确认环节
        .sheet(item: $pendingDraft) { draft in
            DocumentImportConfirmView(draft: draft)
        }
        // FR6.6 导入失败可见错误
        .alert(L10n.docImportFailedTitle, isPresented: $showImportError) {
            Button(L10n.onboard_gotIt, role: .cancel) { }
        } message: {
            Text(state.lastImportError ?? L10n.docImportFailed)
        }
        .onChange(of: state.lastImportError) { _, err in
            handleImportErrorChange(err)
        }
        // FR5.1/FR5.7 文件导入（PDF/图片；批量多选逐份入库，归属确认在文档层 FR3.3 覆盖）。
        .fileImporter(isPresented: $fileImporterActive,
                      allowedContentTypes: [.pdf, .image],
                      allowsMultipleSelection: true) { result in
            enqueueFiles(result)
        }
        // FR5.1 相册导入（逐份走归属确认——当前成员确认条在文档层已有 FR3.3 覆盖）
        .photosPicker(isPresented: $photosImporterActive, selection: $pickedPhotos,
                      maxSelectionCount: 5, matching: .images)
        .onChange(of: pickedPhotos) { _, items in
            enqueuePhotos(items)
        }
        // 单槽（确认卡/重复裁决 sheet）释放即续跑串行队列——两个 onChange
        // 合并为一个 Bool 观察，缩减 body 推断负载（CI 34038910193 实证）
        .onChange(of: queueSlotFree) { _, free in
            if free { resumeQueues() }
        }
        .sheet(isPresented: $showManualCreate) {
            ManualDocumentSheet { title, type, note in
                createManual(title: title, type: type, note: note)
            }
        }
        .task(id: app.currentPatientId) {
            await state.load(patientId: app.currentPatientId, includeArchived: showArchived)
        }
    }

    private var duplicateAlertBinding: Binding<Bool> {
        Binding(get: { state.pendingDuplicate != nil },
                set: { if !$0 && !duplicateChoiceMade {
                    Task { await state.resolveDuplicate(.keep) }
                } })
    }

    /// 单槽占用态：确认卡或重复裁决 sheet 任一打开即占用（串行队列暂停条件）
    private var queueSlotFree: Bool {
        state.pendingDuplicate == nil && pendingDraft == nil
    }

    private func handleImportErrorChange(_ err: String?) {
        // pendingDraft 打开时由确认卡自带「保存失败」告警呈现（Phase 3
        // 补漏：父级不叠加，同一失败不得双弹窗）
        showImportError = err != nil && pendingDraft == nil
    }

    /// 文件导入入队：追加而非替换（Phase 3 补漏：前一批未处理完时重开不丢件）
    private func enqueueFiles(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else { return }
        fileQueue.append(contentsOf: urls)
        processFileQueue()
    }

    /// 相册导入入队：串行队列（第四轮全仓审查修复）——多选命中多份重复时
    /// 后完成者不再覆盖先完成者；单槽占用时暂停，sheet 关掉后 onChange 续跑。
    private func enqueuePhotos(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        photoQueue.append(contentsOf: items)
        pickedPhotos = []
        processPhotoQueue()
    }

    private func resumeQueues() {
        processPhotoQueue()
        processFileQueue()
    }

    private func createManual(title: String, type: String, note: String) {
        Task {
            await state.createManual(patientId: app.currentPatientId, title: title,
                                     docType: type, note: note)
            showManualCreate = false
        }
    }

    /// 相册多选串行推进：单槽（确认卡/重复裁决 sheet）被占用时暂停，
    /// 关掉后续跑（onChange 驱动）。一张处理完再下一张——多选命中多份
    /// 重复时逐一呈现，绝不静默丢弃（第四轮全仓审查修复）。
    /// queueProcessing 互斥（第五轮全仓审查修复）：两条队列共用同一在途标志，
    /// 任一时刻至多一个导入在途——防止 fileQueue 与 photoQueue 并发在途时
    /// 后完成者覆盖先完成者的 pendingDraft、先完成草稿静默丢失。
    private func processPhotoQueue() {
        guard !queueProcessing else { return }
        guard !photoQueue.isEmpty else { return }
        guard state.pendingDuplicate == nil else { return }
        guard pendingDraft == nil else { return }
        queueProcessing = true
        let item = photoQueue.removeFirst()
        Task {
            if let data = try? await item.loadTransferable(type: Data.self) {   // try?-ok: 单项失败跳过，不阻塞批次（跳过即该项目不导入；准备/入库失败经 lastImportError 可见）
                // MIME 按字节嗅探（第四轮全仓审查修复：相册 HEIC 曾硬编码
                // image/jpeg 导致原件扩展名与内容不符）
                let mime = ImageInputRules.sniffMimeType(of: data)
                if let draft = await state.prepareImageDraft(
                    patientId: app.currentPatientId, originalData: data, processedData: data,
                    mimeType: mime, docType: L10n.docTypeRecord, title: nil,
                    isSensitive: false, origin: "photoLibrary") {
                    pendingDraft = draft
                }
            }
            queueProcessing = false
            resumeQueues()
        }
    }

    /// 文件多选串行推进（与 processPhotoQueue 同纪律）
    private func processFileQueue() {
        guard !queueProcessing else { return }
        guard !fileQueue.isEmpty else { return }
        guard state.pendingDuplicate == nil else { return }
        guard pendingDraft == nil else { return }
        queueProcessing = true
        let url = fileQueue.removeFirst()
        Task {
            if url.pathExtension.lowercased() == "pdf" {
                await state.importPDF(patientId: app.currentPatientId, url: url,
                                      docType: L10n.docTypeReport)
            } else if let draft = await state.importDocument(patientId: app.currentPatientId, url: url,
                                                              docType: L10n.docTypeReport) {
                pendingDraft = draft
            }
            queueProcessing = false
            resumeQueues()
        }
    }
}

/// FR5.1 手工新建（第五入口）：标题 + 类型 + 备注
private struct ManualDocumentSheet: View {
    let onCreate: (String, String, String) -> Void
    @State private var title = ""
    @State private var type = L10n.docTypeLabels[0]
    @State private var note = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField(L10n.docManualTitle, text: $title)
                Picker(L10n.docManualType, selection: $type) {
                    ForEach(L10n.docTypeLabels, id: \.self) { Text($0) }
                }
                TextField(L10n.docManualNote, text: $note, axis: .vertical)
                    .lineLimit(3...8)
            }
            .navigationTitle(L10n.docManualCreateTitle)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.reminder_save) {
                        onCreate(title, type, note)
                    }
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

/// 文档整行（独立子视图：NavigationLink + swipeActions + 行 label 结构过重，
/// Xcode 26 类型检查超时，拆小检查单元——「unable to type-check in
/// reasonable time」最佳实践；swipe 按钮用 label 闭包避开 String 参数重载歧义）
private struct DocumentLibraryRow: View {
    let doc: DocumentStore.DocumentRow
    let onSetArchived: (Bool) -> Void
    let onSetFavorite: (Bool) -> Void
    let onConfirmText: (() -> Void)?

    var body: some View {
        NavigationLink {
            DocumentDetailRouteView(documentId: doc.id)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(doc.docType)
                            .font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color(.systemGray5)))
                        // BR-003 来源徽章：D = 机器识别未确认（不进入检索/AI 事实链）
                        if doc.grade == "D" {
                            GradeBadge(grade: "D")
                        }
                        if doc.isSensitive {
                            Image(systemName: "lock.fill")
                                .font(.caption2).foregroundStyle(.orange)
                        }
                    }
                    Text(L10n.docTitle(doc.title))
                        .font(.subheadline)
                    Text(doc.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                if doc.status == "favorite" {
                    Image(systemName: "star.fill")
                        .font(.caption).foregroundStyle(.yellow)
                }
            }
        }
        .swipeActions(edge: .trailing) {
            let archiveTitle = doc.status == "archived" ? L10n.docUnarchive : L10n.docArchive
            let favoriteTitle = doc.status == "favorite" ? L10n.docUnfavorite : L10n.docFavorite
            Button {
                onSetArchived(doc.status != "archived")
            } label: {
                Text(archiveTitle)
            }
            .tint(.orange)
            Button {
                onSetFavorite(doc.status != "favorite")
            } label: {
                Text(favoriteTitle)
            }
            .tint(.yellow)
        }
        .contextMenu {
            if doc.grade == "D", let onConfirmText {
                // BR-003 D→C：显式确认机器识别文本后才进入检索与 AI 事实链
                Button {
                    onConfirmText()
                } label: {
                    Label(L10n.docConfirmText, systemImage: "checkmark.seal")
                }
            }
        }
        .accessibilityIdentifier("SP-09.document.row.\(doc.id.uuidString)")
    }
}

/// 空态（独立子视图：body 瘦身，类型检查单元最小化）
private struct DocumentLibraryEmptyView: View {
    var body: some View {
        ContentUnavailableView(L10n.docLibraryEmpty, systemImage: "folder",
                               description: Text(L10n.docLibraryEmptyHint))
            .accessibilityIdentifier("SP-09.document.empty")
    }
}

/// F5 资料库文档详情（DocumentStore 落地行专用）。
///
/// 修复记录：此前 `DocumentDetailRouteView` 先查 `app.timeline`（M1a 旧管线专用
/// 内存数组，V3.39 已随向导简化删除）——经 `DocumentsState`（首页快速拍摄 +
/// 资料库导入的当前生产路径）入库的文档点开恒显示「未找到」，且原图
/// 从未落盘、无处可查（BR-002/FR5.2 违规）。本视图 + `persistOriginal`/
/// `mergeOriginalPath`（`DocumentsState`）配合补齐：入库时落盘原图并记路径，
/// 详情页读路径展示；敏感文档经 `SensitiveMediaContainer` 逐次系统认证解锁
/// （BR-007/008），非敏感文档直接可看（与 `TimelineDocumentDetailView` 既有行为一致）。
struct DocumentStoreDetailView: View {
    @Environment(AppState.self) private var app
    let doc: DocumentStore.DocumentRow
    @State private var showOriginal = false
    @State private var showIssueSheet = false

    private var originalPath: String? {
        guard let json = doc.metaJSON, let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]   // try?-ok: meta_json 解析失败（如老版非 JSON 格式或损坏）按「无原图路径」降级，不阻断详情页展示其余字段
        else { return nil }
        return obj["original_path"] as? String
    }

    var body: some View {
        List {
            Section(L10n.docTitleSection) {
                Text(L10n.docTitle(doc.title)).font(.headline)
                LabeledContent(L10n.docDate, value: doc.createdAt.formatted(date: .abbreviated, time: .shortened))
                HStack(spacing: 6) {
                    Text(doc.docType).font(.caption).foregroundStyle(.secondary)
                    if doc.grade == "D" { GradeBadge(grade: "D") }
                }
            }
            if originalPath != nil {
                Section {
                    if doc.isSensitive {
                        // BR-007/008：敏感文档原图逐次系统认证解锁，不做免认证直显
                        SensitiveMediaContainer { _ in
                            Label(L10n.sensitiveMedia_unlockToView, systemImage: "lock.fill")
                                .foregroundStyle(.secondary)
                        } content: { _ in
                            Button {
                                showOriginal = true
                                app.auditViewSensitiveOriginal(documentId: doc.id, title: doc.title ?? "")
                            } label: {
                                Label(L10n.docViewOriginal, systemImage: "photo")
                            }
                        }
                        .accessibilityIdentifier("SP-09.document.detail.originalLocked")
                    } else {
                        Button {
                            showOriginal = true
                        } label: {
                            Label(L10n.docViewOriginal, systemImage: "photo")
                        }
                        .accessibilityIdentifier("SP-09.document.detail.original")
                    }
                }
            }
        }
        .sheet(isPresented: $showOriginal) {
            if let path = originalPath {
                if doc.isSensitive {
                    // BR-007/008：敏感原图经 SensitiveMediaOriginalView——认证后
                    // 拉取字节、逐次解锁、退后台重锁、ImageIO 降采样（第四轮
                    // 全仓审查修复：原手写 sheet 全分辨率直显且无快照重锁）
                    SensitiveMediaOriginalView(imageData: nil, caption: L10n.docTitle(doc.title),
                                               originalLoader: { try? Data(contentsOf: URL(fileURLWithPath: path)) })   // try?-ok: 读取失败按「不可查看」降级
                } else {
                    // 非敏感原图也走 ImageIO 降采样（§5.10 大图 OOM 纪律）
                    NavigationStack {
                        // 裸修饰符位于 ViewBuilder 内 if 之后会以 View 类型为基解析
                        // 失败（CI 34037986523 实证）——Group 包裹后修饰符挂 Group 结果
                        Group {
                            if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),   // try?-ok: 读取失败按「不可查看」降级
                               let image = ImageIOImageLoader.downsample(data: data, maxDimension: 2048) {
                                Image(uiImage: image)
                                    .resizable().scaledToFit()
                                    .padding(12)
                            }
                        }
                        .navigationTitle(L10n.docViewOriginal)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button(L10n.onboard_gotIt) { showOriginal = false }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(L10n.docDetailTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // FR6.7 报告识别问题（第四轮全仓审查修复：入口随旧详情页删除后
            // 全链路静默消失——reportRecognitionIssue 成为零调用死 API，
            // 用户无法反馈 OCR 错识；§5.53 表单随本页重建）
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showIssueSheet = true
                } label: {
                    Image(systemName: "exclamationmark.bubble")
                }
                .accessibilityLabel(L10n.docReportIssue)
                .accessibilityIdentifier("SP-09.document.detail.reportIssue")
            }
        }
        .sheet(isPresented: $showIssueSheet) {
            ReportIssueSheet(documentId: doc.id, fields: []) { kind, fieldKey, note in
                app.reportRecognitionIssue(documentId: doc.id,
                                           meta: "kind=\(kind);field=\(fieldKey);note=\(note)")
            }
        }
    }
}

/// 列表（独立子视图：ForEach+行子视图，body 只留一次调用）
private struct DocumentListView: View {
    @Environment(DocumentsState.self) private var state

    var body: some View {
        List {
            ForEach(state.documents) { doc in
                DocumentLibraryRow(doc: doc,
                                   onSetArchived: { archived in
                                       Task { await state.setArchived(id: doc.id, archived: archived) }
                                   },
                                   onSetFavorite: { favorite in
                                       Task { await state.setFavorite(id: doc.id, favorite: favorite) }
                                   },
                                   onConfirmText: doc.grade == "D"
                                       ? { Task { await state.confirmText(id: doc.id) } }
                                       : nil)
            }
        }
        .frame(maxWidth: 672)   // §9.1 正文行宽 ≤672pt（iPad 常宽列可读性）
    }
}

/// §5.52 重复检测对比（V3.72）：左右两栏（已有 vs 新）+ 三选一裁决，
/// 默认「保留已有」；绝不自动删除。
struct DuplicateCompareSheet: View {
    let existing: DocumentStore.DocumentRow?
    let newTitle: String
    let onResolve: (DocumentsState.DuplicateResolution) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var choice: DocumentsState.DuplicateResolution = .keep

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text(L10n.docDuplicateTitle).font(.headline)
                HStack(alignment: .top, spacing: 8) {
                    compareColumn(
                        title: L10n.docDuplicateExisting,
                        name: existing?.title ?? L10n.docUntitled,
                        date: existing.map { $0.createdAt.formatted(date: .abbreviated, time: .omitted) } ?? "",
                        // 第四轮全仓审查修复：原硬编码 "C"——已存在的 D 级未确认
                        // 文档在对比页被按已确认事实呈现（D 当事实渲染点）
                        grade: existing?.grade ?? "C")
                    compareColumn(
                        title: L10n.docDuplicateNewFile,
                        name: newTitle,
                        date: "",
                        grade: "D")
                }
                Picker("", selection: $choice) {
                    Text(L10n.docDuplicateKeep).tag(DocumentsState.DuplicateResolution.keep)
                    Text(L10n.docDuplicateReplace).tag(DocumentsState.DuplicateResolution.replace)
                    Text(L10n.docDuplicateKeepBoth).tag(DocumentsState.DuplicateResolution.coexist)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("SP-09.duplicate.choice")
                HStack {
                    Button(L10n.onboard_cancel) { dismiss() }
                        .buttonStyle(.bordered)
                    Button(L10n.onboard_saveEdit) {
                        onResolve(choice)
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                }
                Text(L10n.docDuplicateNeverAutoDelete)
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(20)
        }
    }

    private func compareColumn(title: String, name: String, date: String, grade: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(name).font(.subheadline).lineLimit(2)
            if !date.isEmpty {
                Text(date).font(.caption2).foregroundStyle(.secondary)
            }
            GradeBadge(grade: grade)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemGroupedBackground)))
    }
}

/// §5.53 识别错误反馈表单（V3.72）：错误类型四分类 + 错误字段 + 备注；
/// 提交即落审计并 Toast 已记录（FR22.5 最小化：默认只附脱敏信息）。
/// 第四轮全仓审查修复：随旧 TimelineDocumentDetailView 删除的 FR6.7 入口
/// 重建于 SP-09 文档详情页——错误类型/字段/备注随 meta 落审计。
struct ReportIssueSheet: View {
    let documentId: UUID
    let fields: [CandidateField]
    let onSubmit: (String, String, String) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var kind = "fieldWrong"
    @State private var fieldKey: String?
    @State private var note = ""
    @State private var submitted = false

    private let kinds = [
        ("fieldWrong", L10n.reportIssueFieldWrong),
        ("missingField", L10n.reportIssueMissing),
        ("layout", L10n.reportIssueLayout),
        ("engine", L10n.reportIssueEngine),
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.reportIssueKind) {
                    Picker("", selection: $kind) {
                        ForEach(kinds, id: \.0) { k in Text(k.1).tag(k.0) }
                    }
                    .pickerStyle(.inline)
                }
                if !fields.isEmpty {
                    Section(L10n.reportIssueField) {
                        Picker("", selection: $fieldKey) {
                            Text(L10n.reportIssueFieldAll).tag(String?.none)
                            ForEach(fields) { f in
                                Text(f.displayLabel).tag(String?.some(f.key))
                            }
                        }
                    }
                }
                Section(L10n.reportIssueNote) {
                    TextField(L10n.reportIssueNoteHint, text: $note, axis: .vertical)
                        .lineLimit(2...5)
                }
                Section {
                    Text(L10n.reportIssueMinimal)
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .navigationTitle(L10n.docReportIssue)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.onboard_cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.reportIssueSubmit) {
                        onSubmit(kind, fieldKey ?? "", note)
                        submitted = true
                    }
                }
            }
            .alert(L10n.reportIssueSubmitted, isPresented: $submitted) {
                Button(L10n.onboard_gotIt, role: .cancel) { dismiss() }
            }
        }
    }
}
