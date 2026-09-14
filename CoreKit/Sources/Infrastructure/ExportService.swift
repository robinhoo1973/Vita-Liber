#if os(iOS) || os(macOS)
import Foundation
import GRDB
import Domain
import Protocols

/// F13 导出管线（§5.7/5.8）：JSON 往返（含版本 envelope）与 CSV 编码。
/// 往返一致性（M1c 一票否决）：导出 → 全新库导入 → 逐字段相等。
public actor ExportService {
    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) { self.writer = writer }

    /// 导出 envelope（VersionedData 语义：版本 + 生成时间 + 数据）
    public struct Envelope: Sendable, Codable, Equatable {
        /// 当前导出的 envelope 版本。v1 = 历史包；v2（v25 / 子项目 D D1-4）= `EncounterExport` 全列、
        /// `prescriptionLines`/`claimLines` 行数组、处方/票据表头新列、`DocumentExport.docTypeKey/titleSource`、
        /// 回执 `entityTable`。所有新键均为 Optional：v1 包照常可解；恢复侧对 v1 包的 adopt 只覆盖其原有列
        /// （不把本机既有新列刷成 NULL）。
        public static let currentSchemaVersion = 2
        public var schemaVersion: Int
        public var exportedAt: TimeInterval
        public var owner: LocalOwner?
        public var selfProfile: PatientProfile?
        /// 审查修复（BR-001/FR13.5）：家庭成员档案随包往返。缺失（旧包）时
        /// 兼容回落本人档案——但**不**再发生「全库改挂本人名下」的张冠李戴。
        public var members: [PatientProfile]?
        public var consentRecords: [ConsentRecord]
        public var timeline: [TimelineDocumentEntry]
        /// V3.39+ 文档维度（第四轮全仓审查修复）：document_file 直列导出。
        /// 旧 `timeline` 只承载历史备份包的 meta_json 投影（V3.39 起无写入方，
        /// 解码新格式恒失败导致活管线文档在备份恢复中静默丢失）——恢复时
        /// 优先 `documents`，缺失（旧包）回落 `timeline`。
        public var documents: [DocumentExport]?
        /// Committed OCR provenance only; pending snapshots never enter the envelope.
        public var ocrCardCommits: [OCRCardStore.AuditRecord]?
        /// 键名沿用 `ocrPrescriptions`（v2 起承载**全部** `confirmed = 1` 处方，不再过滤 `source = 'ocr'`——
        /// 手工/电子处方此前不进包；改名只会带来双读代码，登记为对 §C.12 建议项的有意不采纳）。
        public var ocrPrescriptions: [OCRPrescriptionExport]?
        public var ocrEncounterDetails: [OCREncounterDetails]?
        public var ocrMedications: [OCRMedicationExport]?
        public var claims: [ClaimExport]?
        /// v25（子项目 D §C.6/§C.7，D1-4）：处方行 / 费用明细行实体随包；恢复按拓扑序落在表头之后、
        /// 行随表头裁决（keep 跳过 / adopt 整组换 / coexist 随表头换 id）。旧包缺键 → nil（绝不从 advice_text 猜回行）。
        public var prescriptionLines: [PrescriptionLineExport]?
        public var claimLines: [ClaimLineExport]?
        /// v26（子项目 D §C.2–§C.5，D2-3）五表全列随包（元素类型 = Domain DDL 镜像值类型，字段与列同名 camelCase）。
        /// 全部 Optional：旧包缺键 → nil（零恢复，不猜）；envelope 版本仍为 2（只增可选键，不破坏 v2 读侧）。
        /// 恢复拓扑序（§C.12）：encounters → hospitalizations → labReports → metrics(lab_report_id) → labResults → … →
        /// examReports → ocrCardCommits → … → healthProblems → diagnoses(health_problem_id)。
        /// 裁决：lab_report / diagnosis / exam_report 为独立冲突表（keep/adopt/coexist）；hospitalization 随其就诊、
        /// lab_result 随其表头裁决（v25「行随表头」同纪律）。
        public var hospitalizations: [Hospitalization]?
        public var diagnoses: [Diagnosis]?
        public var examReports: [ExamReport]?
        public var labReports: [LabReport]?
        public var labResults: [LabResult]?
        public var plans: [PlanExport]
        public var appointments: [AppointmentExport]
        public var observations: [ObservationExport]
        public var allergies: [AllergyExport]
        public var encounters: [EncounterExport]
        public var metrics: [MetricExport]
        /// FR13.5/F16: frozen event history; absent in older envelopes.
        public var alertEvents: [AlertEventExport]?
        public var immunizations: [ImmunizationExport]
        public var voiceNotes: [VoiceNoteExport]
        public var healthProblems: [HealthProblemExport]
        public var sensitiveDocIds: Set<UUID>   // 评审 S1：敏感标记随包往返（BR-007/008 链）

        /// FR13.5 恢复后数据校验报告：导入记录计数（供恢复报告展示，不算附件）
        public var totalRecords: Int {
            (owner != nil ? 1 : 0) + (selfProfile != nil ? 1 : 0) + (members?.count ?? 0)
            + consentRecords.count + (documents?.count ?? timeline.count) + plans.count + appointments.count
            + observations.count + allergies.count + encounters.count + metrics.count
            + (alertEvents?.count ?? 0) + immunizations.count + voiceNotes.count + healthProblems.count
            + (ocrPrescriptions?.count ?? 0)
            + (ocrMedications?.count ?? 0) + (claims?.count ?? 0)
            + (hospitalizations?.count ?? 0) + (diagnoses?.count ?? 0) + (examReports?.count ?? 0)
            + (labReports?.count ?? 0) + (labResults?.count ?? 0)
        }

        /// document_file 直列导出（第四轮全仓审查修复：FR13.2 备份/恢复
        /// 的文档维度载体——meta_json 投影已退役，原图/OCR 文本/徽章/状态
        /// 全部按真实列随包往返）。
        public struct DocumentExport: Sendable, Codable, Equatable {
            public var id: UUID
            public var patientId: UUID?
            public var encounterId: UUID?
            public var docType: String
            public var status: String
            public var sha256: String?
            public var mimeType: String?
            public var isSensitive: Bool
            public var origin: String
            public var metaJson: String?
            public var title: String?
            public var ocrText: String?
            public var notes: String?
            public var grade: String
            public var createdAt: Date
            public var updatedAt: Date
            /// FR6.1 页语义（V3.99）：页文本随包往返；旧包 nil（不造页）
            public var pages: [PageExport]?
            /// v25（§C.10）：文档稳定类型键与标题来源；旧包 nil（App 层首启回填，不在此猜键）。
            public var docTypeKey: String?
            public var titleSource: String?
            public init(id: UUID, patientId: UUID?, encounterId: UUID?, docType: String,
                        status: String, sha256: String?, mimeType: String?, isSensitive: Bool,
                        origin: String, metaJson: String?, title: String?, ocrText: String?,
                        notes: String?, grade: String, createdAt: Date, updatedAt: Date,
                        pages: [PageExport]? = nil, docTypeKey: String? = nil, titleSource: String? = nil) {
                self.id = id; self.patientId = patientId; self.encounterId = encounterId
                self.docType = docType; self.status = status; self.sha256 = sha256
                self.mimeType = mimeType; self.isSensitive = isSensitive; self.origin = origin
                self.metaJson = metaJson; self.title = title; self.ocrText = ocrText
                self.notes = notes; self.grade = grade; self.createdAt = createdAt
                self.updatedAt = updatedAt; self.pages = pages
                self.docTypeKey = docTypeKey; self.titleSource = titleSource
            }
        }

        public struct PageExport: Sendable, Codable, Equatable {
            public var index: Int
            public var text: String?
            public var status: String
            public init(index: Int, text: String?, status: String) {
                self.index = index; self.text = text; self.status = status
            }
        }

        public struct OCRPrescriptionExport: Sendable, Codable, Equatable {
            public var id: UUID
            public var patientId: UUID
            public var documentId: UUID?
            public var encounterId: UUID?
            public var source: String
            public var hospital: String?
            public var doctor: String?
            public var prescribedAt: Date?
            public var adviceText: String?
            public var createdAt: Date
            public var updatedAt: Date
            /// v25（§C.6）处方表头打印字段；旧包缺键 → nil。
            public var department: String? = nil
            public var prescriptionNo: String? = nil
            public var prescriptionType: String? = nil
            public var feeTypeText: String? = nil
            public var clinicalDiagnosis: String? = nil
            public var pharmacistNames: String? = nil
            public var totalAmount: Double? = nil
        }

        /// v25（§C.6）处方行：字段与 `prescription_line` DDL 同名 camelCase、全列随包。
        /// BR-006/007：剂量/数量/频次/疗程为原文 `*Text` + `*Unit`，恢复原样写回、不解析不换算。
        /// `confirmed` 原样携带（BR-003：恢复绝不升级 D→C）；`medicationId` 只在目标库存在同成员药品时写回。
        public struct PrescriptionLineExport: Sendable, Codable, Equatable {
            public var id: UUID
            public var prescriptionId: UUID
            public var patientId: UUID
            public var ordinal: Int
            public var printedName: String
            public var genericName: String?
            public var brandName: String?
            public var drugForm: String?
            public var spec: String?
            public var doseText: String?
            public var doseUnit: String?
            public var quantityText: String?
            public var quantityUnit: String?
            public var frequencyText: String?
            public var routeText: String?
            public var durationText: String?
            public var startDate: Date?
            public var endDate: Date?
            public var asNeededText: String?
            public var medicationNotes: String?
            public var note: String?
            public var rawText: String?
            public var insuranceCode: String?
            public var itemCodeText: String?
            public var unitPrice: Double?
            public var amount: Double?
            public var medicationId: UUID?
            public var sourcePage: Int?
            public var sourceRowId: UUID?
            public var confirmed: Bool
            public var createdAt: Date
            public var updatedAt: Date
        }

        /// v25（§C.7）费用明细行：字段与 `claim_line` DDL 同名 camelCase、全列随包（该表无 confirmed 列）。
        public struct ClaimLineExport: Sendable, Codable, Equatable {
            public var id: UUID
            public var claimItemId: UUID
            public var patientId: UUID
            public var ordinal: Int
            public var itemName: String
            public var itemCodeText: String?
            public var insuranceCode: String?
            public var spec: String?
            public var unitPrice: Double?
            public var quantityText: String?
            public var quantityUnit: String?
            public var amount: Double?
            public var feeCategoryText: String?
            public var feeAt: Date?
            public var executingDept: String?
            public var selfPayRatioText: String?
            public var rawText: String?
            public var sourcePage: Int?
            public var sourceRowId: UUID?
            public var createdAt: Date
        }

        public struct OCREncounterDetails: Sendable, Codable, Equatable {
            public var id: UUID
            public var hospital: String?
            public var department: String?
            public var doctor: String?
            public var chiefComplaint: String?
            public var adviceText: String?
            public var followUpRequirement: String?
            public var feeAmount: Double?
            public var rescheduledFromId: UUID?
            public var createdAt: Date
            public var updatedAt: Date
        }

        public struct OCRMedicationExport: Sendable, Codable, Equatable {
            public var id: UUID
            public var patientId: UUID
            public var genericName: String
            public var brandName: String?
            public var spec: String?
            public var unitKind: String
            public var drugKey: String?
            public var createdAt: Date
            public var updatedAt: Date
        }
        public struct ClaimExport: Sendable, Codable, Equatable {
            public var id: UUID
            public var patientId: UUID
            public var encounterId: UUID?
            public var documentId: UUID?
            public var itemType: String
            public var amount: Double?
            public var currency: String?
            public var date: Date?
            public var merchant: String?
            public var summary: String?
            public var createdAt: Date
            public var updatedAt: Date
            /// v25（§C.7）票面支付三分 / 票据号 / 医保类型打印文本；旧包缺键 → nil。
            public var reimbursedAmount: Double? = nil
            public var outOfPocket: Double? = nil
            public var personalAccountAmount: Double? = nil
            public var invoiceNo: String? = nil
            public var insuranceTypeText: String? = nil
        }

        public struct PlanExport: Sendable, Codable, Equatable {
            public var id: UUID
            public var patientId: UUID?
            public var medicationName: String
            public var spec: String?
            public var schedule: MedicationSchedule
            public var status: PlanStatus
            public var startDate: Date
            public var endDate: Date?
            /// V3.94 往返完整性：单位类型/单剂剂量/停用原因/暂停时刻——
            /// 此前恢复恒写 unit_kind='tablet'（贴剂/注射剂单位被改写、剂量
            /// 展示失真），渐减计划剂量基线（dose_plan_units）丢失。
            /// 可选默认 nil 兼容旧包读取。
            public var unitKind: String?
            public var dosePlanUnits: Double?
            public var endedReason: String?
            public var pausedAt: Date?
        }
        public struct AppointmentExport: Sendable, Codable, Equatable {
            public var id: UUID
            public var patientId: UUID?
            public var hospital: String
            public var department: String
            public var startsAt: Date
            public var status: String
        }
        public struct ObservationExport: Sendable, Codable, Equatable {
            public var id: UUID
            public var patientId: UUID?
            public var kind: String
            public var occurredAt: Date
            public var capturedAt: Date?
            public var description: String?
            public var selfMark: String?
            /// FR8.2 扩展字段（FR13.5 V3.28 补强：随包往返，缺失即数据丢失）。
            /// 旧包无这些键 → decodeIfPresent 兼容（nil），但导出侧必须全量写出。
            public var mediaAssetIds: [String]
            public var bodyPart: String?
            public var durationMin: Int?
            public var frequency: String?
            public var isFirst: Bool?
            public var trigger: String?
            public var accompanying: String?
            public var painScore: Int?
            public var medsDiet: String?
            public var consultedDoctor: Bool
            public var encounterId: UUID?
            public var healthProblemId: UUID?
            public var groupId: UUID?
        }
        public struct AllergyExport: Sendable, Codable, Equatable {
            public var id: UUID
            public var patientId: UUID?
            public var substance: String
            public var severity: String
            public var occurredAt: Date
            /// V3.94 往返完整性：反应标签/就医医生/处理说明/备注/关联就诊与用药
            /// ——此前随备份丢失（恢复硬编码 reaction_tags='[]'，急救卡反应展示
            /// 恢复后为空，FR13.5 一票否决）。可选默认 nil 兼容旧包读取。
            public var reactionTags: String?
            public var consultedDoctor: Bool?
            public var durationMin: Int?
            public var treatmentNote: String?
            public var note: String?
            public var encounterId: UUID?
            public var medicationId: UUID?
        }
        public struct EncounterExport: Sendable, Codable, Equatable {
            public var id: UUID
            public var patientId: UUID?
            public var date: Date
            public var kind: String
            public var diagnosisText: String?
            /// 软删时间戳（第六轮全仓审查修复：旧实现导出未过滤、恢复未携带，
            /// 软删就诊在换机恢复后被复活为活跃行）
            public var deletedAt: TimeInterval?
            /// v25（子项目 D §C.1 / D1-4）全列随包——此前只有 OCR 就诊经 `ocrEncounterDetails` 补列，
            /// 手工就诊的医院/医生/主诉/医嘱在备份恢复中静默丢失；五叙事列原文保存、不摘要不改写。
            /// 全部 Optional：v1 包缺键解为 nil。
            public var hospital: String? = nil
            public var department: String? = nil
            public var doctor: String? = nil
            public var chiefComplaint: String? = nil
            public var adviceText: String? = nil
            public var followUpRequirement: String? = nil
            public var feeAmount: Double? = nil
            public var rescheduledFromId: UUID? = nil
            public var presentIllness: String? = nil
            public var visitSummary: String? = nil
            public var pastHistory: String? = nil
            public var physicalExam: String? = nil
            public var allergyHistory: String? = nil
            public var createdAt: Date? = nil
            public var updatedAt: Date? = nil
        }
        public struct MetricExport: Sendable, Codable, Equatable {
            public var id: UUID
            public var patientId: UUID?
            public var key: String
            public var value: Double
            public var unit: String
            public var origin: String
            public var measuredAt: Date
            public var excluded: Bool
            public var sourceRef: String?
            /// FR13.5/FR7.9: preserve stored meaning without making old envelopes unreadable.
            public var secondaryValue: Double?
            public var selfMeasured: Bool?
            public var refLow: Double?
            public var refHigh: Double?
            public var refSourceLabel: String?
            public var rawLabel: String?
            /// The referenced terminology catalog is not included in Envelope.
            /// Missing target concepts reject restoration atomically, never erase the code.
            public var codeConceptId: String?
            public var valueMin: Double?
            public var valueMax: Double?
            public var sampleCount: Int?
            public var sourceName: String?
            public var sourceVersion: String?
            public var sourceProduct: String?
            public var sourceIdentifier: String?
            public var aggregationKind: String?
            public var windowEnd: Date?
            public var createdAt: Date?
            /// v26（§C.5）：回指检验表头 / 报告打印的异常标记原文（不解释）；旧包缺键 → nil。
            public var labReportId: UUID? = nil
            public var abnormalFlag: String? = nil
        }
        public struct AlertEventExport: Sendable, Codable, Equatable {
            public var id: UUID
            public var patientId: UUID?
            public var ruleId: String
            public var severity: String
            public var evidenceJson: String
            public var deliveredState: String
            public var createdAt: Date
            public var qualified: Bool?
            public var scheduledAt: Date?
        }
        public struct ImmunizationExport: Sendable, Codable, Equatable {
            public var id: UUID
            public var patientId: UUID?
            public var vaccineName: String
            public var administeredAt: Date
            /// V3.94 往返完整性：剂次/批号（疫苗追溯核心）/提供方/来源/确认态/
            /// 关联就诊与不良反应——此前随备份丢失。可选默认 nil 兼容旧包。
            public var doseNumber: Int?
            public var provider: String?
            public var lotNumber: String?
            public var source: String?
            public var confirmed: Bool?
            public var encounterId: UUID?
            public var adverseReactionId: UUID?
        }
        public struct VoiceNoteExport: Sendable, Codable, Equatable {
            public var id: UUID
            public var patientId: UUID?
            public var body: String
            public var occurredAt: Date
            public var tags: [String]
            public var inTimeline: Bool
        }
        public struct HealthProblemExport: Sendable, Codable, Equatable {
            public var id: UUID
            public var patientId: UUID?
            public var name: String
            // 审查修复（FR13.5 往返保真）：旧导出缺 kind/archived、导入硬编码
            // archived=0——已归档问题恢复后「复活」为活跃问题（问题列表/
            // 时间轴/AI 事实组装全链误呈现）。默认值保证旧备份 JSON 可解。
            // 审查修复（合成 Codable 不读默认值）：属性默认值**不参与**合成的
            // init(from:)——旧备份缺 "archived"/"kind" 键时 keyNotFound 抛错、
            // 整个恢复失败。自定义解码按缺失键回落默认（archived=0、kind=nil），
            // 才兑现「默认值保证旧备份可解」的注释契约。
            public var kind: String?
            public var archived: Bool = false
            public var createdAt: Date
            public init(id: UUID, patientId: UUID?, name: String, kind: String? = nil,
                        archived: Bool = false, createdAt: Date) {
                self.id = id
                self.patientId = patientId
                self.name = name
                self.kind = kind
                self.archived = archived
                self.createdAt = createdAt
            }
            private enum CodingKeys: String, CodingKey {
                case id, patientId, name, kind, archived, createdAt
            }
            public init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                id = try c.decode(UUID.self, forKey: .id)
                patientId = try c.decodeIfPresent(UUID.self, forKey: .patientId)
                name = try c.decode(String.self, forKey: .name)
                kind = try c.decodeIfPresent(String.self, forKey: .kind)
                archived = try c.decodeIfPresent(Bool.self, forKey: .archived) ?? false
                createdAt = try c.decode(Date.self, forKey: .createdAt)
            }
        }
        public init(schemaVersion: Int = 1, exportedAt: TimeInterval = 0,
                    owner: LocalOwner? = nil, selfProfile: PatientProfile? = nil,
                    members: [PatientProfile]? = nil,
                    consentRecords: [ConsentRecord] = [],
                    timeline: [TimelineDocumentEntry] = [], plans: [PlanExport] = [],
                    appointments: [AppointmentExport] = []) {
            self.schemaVersion = schemaVersion
            self.exportedAt = exportedAt
            self.owner = owner
            self.selfProfile = selfProfile
            self.members = members
            self.consentRecords = consentRecords
            self.timeline = timeline
            self.documents = nil
            self.prescriptionLines = nil
            self.claimLines = nil
            self.hospitalizations = nil
            self.diagnoses = nil
            self.examReports = nil
            self.labReports = nil
            self.labResults = nil
            self.plans = plans
            self.appointments = appointments
            self.observations = []
            self.allergies = []
            self.encounters = []
            self.metrics = []
            self.alertEvents = nil
            self.immunizations = []
            self.voiceNotes = []
            self.healthProblems = []
            self.sensitiveDocIds = []
        }
    }

    /// 全量导出为 JSON envelope（数据所有权不随付费状态改变——comercial §1）
    public func exportJSON() async throws -> Envelope {
        try await writer.read { db in
            let ownerRow = try Row.fetchOne(db, sql: "SELECT * FROM local_owner LIMIT 1")
            let owner = ownerRow.map { row in
                LocalOwner(id: UUID(uuidString: row["id"] as String) ?? UUID(),
                           displayName: row["display_name"] as String,
                           selfPatientId: (row["self_patient_id"] as String?).flatMap(UUID.init(uuidString:)),
                           createdAt: row["created_at"] as Double)
            }
            let selfProfile = try Row.fetchOne(db, sql: """
                SELECT p.* FROM patient_profile p
                JOIN local_owner o ON o.self_patient_id = p.id
                LIMIT 1
                """).map { row in
                Self.profileRow(row)
            }
            // 审查修复（BR-001/FR13.5）：全部成员档案随包往返——
            // 恢复时各成员数据各归其位，绝不再静默改挂本人名下。
            // 第六轮全仓审查修复：不再过滤软删成员——已删成员的数据行
            // （文档/观察/就诊）仍以 patient_id 外键引用其档案，档案缺席
            // 会让换机恢复在 FK 上整体回滚（FR13.2 主路径不可恢复）；
            // 软删状态经 deletedAt 随包往返，恢复后保持软删。
            let members = try Row.fetchAll(db, sql: """
                SELECT * FROM patient_profile
                WHERE id != COALESCE((SELECT self_patient_id FROM local_owner LIMIT 1), '')
                ORDER BY created_at
                """).map(Self.profileRow)
            let consents = try Row.fetchAll(db, sql: "SELECT * FROM consent_record ORDER BY accepted_at").map { row in
                ConsentRecord(id: UUID(uuidString: row["id"] as String) ?? UUID(),
                              key: row["key"] as String,
                              level: row["level"] as Int,
                              version: row["version"] as String,
                              acceptedAt: row["accepted_at"] as Double)
            }
            // V3.39 起 meta_json 不再承载 TimelineDocumentEntry 投影（孤儿镜像已拆，
            // 写入方删除），文档维度改从 document_file 直列导出。第四轮全仓审查修复：
            // 此前按 TimelineDocumentEntry 解码 meta_json（新格式为 {original_path,...}
            // 信封）恒失败被静默丢弃——经活管线入库的文档在备份/恢复中全部丢失
            // （FR13.2 数据丢失）。timeline 字段保留为空数组（历史兼容：旧包恢复
            // 仍走该维度，新包不再生产）。
            let timeline: [TimelineDocumentEntry] = []
            let pagesByDocument: [String: [Envelope.PageExport]] = try Row.fetchAll(db, sql: """
                SELECT document_file_id, page_index, ocr_text, status FROM document_page ORDER BY page_index
                """).reduce(into: [:]) { acc, row in
                acc[row["document_file_id"] as String, default: []].append(
                    Envelope.PageExport(index: row["page_index"], text: row["ocr_text"], status: row["status"]))
            }
            let documents = try Row.fetchAll(db, sql: "SELECT * FROM document_file ORDER BY created_at").map { row in
                Envelope.DocumentExport(
                    id: UUID(uuidString: row["id"] as String) ?? UUID(),
                    patientId: (row["patient_id"] as String?).flatMap(UUID.init(uuidString:)),
                    encounterId: (row["encounter_id"] as String?).flatMap(UUID.init(uuidString:)),
                    docType: row["doc_type"] as String,
                    status: row["status"] as String,
                    sha256: row["sha256"] as String?,
                    mimeType: row["mime_type"] as String?,
                    isSensitive: (row["is_sensitive"] as Int?) == 1,
                    origin: row["origin"] as String,
                    metaJson: row["meta_json"] as String?,
                    title: row["title"] as String?,
                    ocrText: row["ocr_text"] as String?,
                    notes: row["notes"] as String?,
                    grade: (row["grade"] as String?) ?? "C",
                    createdAt: Date(timeIntervalSince1970: row["created_at"] as Double),
                    updatedAt: Date(timeIntervalSince1970: row["updated_at"] as Double),
                    pages: pagesByDocument[row["id"] as String],
                    docTypeKey: row["doc_type_key"] as String?,
                    titleSource: row["title_source"] as String?)
            }
            let plans = try Row.fetchAll(db, sql: """
                SELECT p.id, p.patient_id, p.status, p.start_date, p.end_date, p.schedule_json,
                       p.dose_plan_units, p.ended_reason, p.paused_at, m.generic_name, m.spec, m.unit_kind
                FROM medication_plan p JOIN medication m ON m.id = p.medication_id
                """).compactMap { row -> Envelope.PlanExport? in
                guard let json = (row["schedule_json"] as String?)?.data(using: .utf8) else { return nil }
                let schedule: MedicationSchedule
                do { schedule = try JSONDecoder().decode(MedicationSchedule.self, from: json) }
                catch { return nil }   // §7 禁 try?：损坏 schedule_json 跳过该计划
                return Envelope.PlanExport(
                    id: UUID(uuidString: row["id"] as String) ?? UUID(),
                    patientId: (row["patient_id"] as String?).flatMap(UUID.init(uuidString:)),
                    medicationName: row["generic_name"] as String,
                    spec: row["spec"] as String?,
                    schedule: schedule,
                    status: PlanStatus(rawValue: row["status"] as String) ?? .active,
                    startDate: Date(timeIntervalSince1970: row["start_date"] as Double),
                    endDate: (row["end_date"] as Double?).map { Date(timeIntervalSince1970: $0) },
                    unitKind: row["unit_kind"] as String?,
                    dosePlanUnits: row["dose_plan_units"] as Double?,
                    endedReason: row["ended_reason"] as String?,
                    pausedAt: (row["paused_at"] as Double?).map { Date(timeIntervalSince1970: $0) })
            }
            let appointments = try Row.fetchAll(db, sql: "SELECT * FROM appointment").map { row in
                Envelope.AppointmentExport(
                    id: UUID(uuidString: row["id"] as String) ?? UUID(),
                    patientId: (row["patient_id"] as String?).flatMap(UUID.init(uuidString:)),
                    hospital: (row["hospital"] as String?) ?? "",
                    department: (row["department"] as String?) ?? "",
                    startsAt: Date(timeIntervalSince1970: row["starts_at"] as Double),
                    status: row["status"] as String)
            }
            let observations = try Row.fetchAll(db, sql: "SELECT * FROM observation").map { row in
                Envelope.ObservationExport(
                    id: UUID(uuidString: row["id"] as String) ?? UUID(),
                    patientId: (row["patient_id"] as String?).flatMap(UUID.init(uuidString:)),
                    kind: row["kind"] as String,
                    occurredAt: Date(timeIntervalSince1970: row["occurred_at"] as Double),
                    capturedAt: (row["captured_at"] as Double?).map(Date.init(timeIntervalSince1970:)),
                    description: row["description"] as String?,
                    selfMark: row["self_mark"] as String?,
                    mediaAssetIds: Self.decodeMediaIds(row["media_asset_ids"] as String?),
                    bodyPart: row["body_part"] as String?,
                    durationMin: row["duration_min"] as Int?,
                    frequency: row["frequency"] as String?,
                    isFirst: (row["is_first"] as Int?).map { $0 != 0 },
                    trigger: row["trigger"] as String?,
                    accompanying: row["accompanying"] as String?,
                    painScore: row["pain_score"] as Int?,
                    medsDiet: row["meds_diet"] as String?,
                    consultedDoctor: (row["consulted_doctor"] as Int? ?? 0) != 0,
                    encounterId: (row["encounter_id"] as String?).flatMap(UUID.init(uuidString:)),
                    healthProblemId: (row["health_problem_id"] as String?).flatMap(UUID.init(uuidString:)),
                    groupId: (row["group_id"] as String?).flatMap(UUID.init(uuidString:)))
            }
            let allergies = try Row.fetchAll(db, sql: "SELECT * FROM allergy_event").map { row in
                Envelope.AllergyExport(
                    id: UUID(uuidString: row["id"] as String) ?? UUID(),
                    patientId: (row["patient_id"] as String?).flatMap(UUID.init(uuidString:)),
                    substance: row["substance"] as String,
                    severity: row["severity"] as String,
                    occurredAt: Date(timeIntervalSince1970: (row["occurred_at"] as Double?) ?? 0),
                    reactionTags: row["reaction_tags"] as String?,
                    consultedDoctor: (row["consulted_doctor"] as Int?) == 1,
                    durationMin: row["duration_min"] as Int?,
                    treatmentNote: row["treatment_note"] as String?,
                    note: row["note"] as String?,
                    encounterId: (row["encounter_id"] as String?).flatMap(UUID.init(uuidString:)),
                    medicationId: (row["medication_id"] as String?).flatMap(UUID.init(uuidString:)))
            }
            // v25（D1-4）：就诊全列导出（含五叙事列 + 时间戳）——手工就诊不再只剩 diagnosis_text。
            let encounters = try Row.fetchAll(db, sql: "SELECT * FROM encounter").map { row in
                Envelope.EncounterExport(
                    id: UUID(uuidString: row["id"] as String) ?? UUID(),
                    patientId: (row["patient_id"] as String?).flatMap(UUID.init(uuidString:)),
                    date: Date(timeIntervalSince1970: row["date"] as Double),
                    kind: row["kind"] as String,
                    diagnosisText: row["diagnosis_text"] as String?,
                    deletedAt: row["deleted_at"] as Double?,
                    hospital: row["hospital"] as String?,
                    department: row["department"] as String?,
                    doctor: row["doctor"] as String?,
                    chiefComplaint: row["chief_complaint"] as String?,
                    adviceText: row["advice_text"] as String?,
                    followUpRequirement: row["follow_up_requirement"] as String?,
                    feeAmount: row["fee_amount"] as Double?,
                    rescheduledFromId: (row["rescheduled_from_id"] as String?).flatMap(UUID.init(uuidString:)),
                    presentIllness: row["present_illness"] as String?,
                    visitSummary: row["visit_summary"] as String?,
                    pastHistory: row["past_history"] as String?,
                    physicalExam: row["physical_exam"] as String?,
                    allergyHistory: row["allergy_history"] as String?,
                    createdAt: Date(timeIntervalSince1970: row["created_at"] as Double),
                    updatedAt: Date(timeIntervalSince1970: row["updated_at"] as Double))
            }
            let metrics = try Row.fetchAll(db, sql: "SELECT * FROM metric_sample").map { row in
                Envelope.MetricExport(
                    id: UUID(uuidString: row["id"] as String) ?? UUID(),
                    patientId: (row["patient_id"] as String?).flatMap(UUID.init(uuidString:)),
                    key: row["metric_key"] as String,
                    value: row["value"] as Double,
                    unit: row["unit"] as String,
                    origin: row["origin"] as String,
                    measuredAt: Date(timeIntervalSince1970: row["measured_at"] as Double),
                    excluded: (row["excluded"] as Int?) == 1,
                    sourceRef: row["source_ref"] as String?,
                    secondaryValue: row["secondary_value"] as Double?,
                    selfMeasured: (row["self_measured"] as Int) == 1,
                    refLow: row["ref_low"] as Double?,
                    refHigh: row["ref_high"] as Double?,
                    refSourceLabel: row["ref_source_label"] as String?,
                    rawLabel: row["raw_label"] as String?,
                    codeConceptId: row["code_concept_id"] as String?,
                    valueMin: row["value_min"] as Double?,
                    valueMax: row["value_max"] as Double?,
                    sampleCount: row["sample_count"] as Int?,
                    sourceName: row["source_name"] as String?,
                    sourceVersion: row["source_version"] as String?,
                    sourceProduct: row["source_product"] as String?,
                    sourceIdentifier: row["source_identifier"] as String?,
                    aggregationKind: row["aggregation_kind"] as String?,
                    windowEnd: (row["window_end"] as Double?).map(Date.init(timeIntervalSince1970:)),
                    createdAt: Date(timeIntervalSince1970: row["created_at"] as Double),
                    labReportId: (row["lab_report_id"] as String?).flatMap(UUID.init(uuidString:)),
                    abnormalFlag: row["abnormal_flag"] as String?)
            }
            let alertEvents = try Row.fetchAll(db, sql: "SELECT * FROM alert_event ORDER BY created_at, id").map { row in
                Envelope.AlertEventExport(
                    id: UUID(uuidString: row["id"] as String) ?? UUID(),
                    patientId: (row["patient_id"] as String?).flatMap(UUID.init(uuidString:)),
                    ruleId: row["rule_id"] as String,
                    severity: row["severity"] as String,
                    evidenceJson: row["evidence_json"] as String,
                    deliveredState: row["delivered_state"] as String,
                    createdAt: Date(timeIntervalSince1970: row["created_at"] as Double),
                    qualified: (row["qualified"] as Int) == 1,
                    scheduledAt: (row["scheduled_at"] as Double?).map(Date.init(timeIntervalSince1970:)))
            }
            let immunizations = try Row.fetchAll(db, sql: "SELECT * FROM immunization").map { row in
                Envelope.ImmunizationExport(
                    id: UUID(uuidString: row["id"] as String) ?? UUID(),
                    patientId: (row["patient_id"] as String?).flatMap(UUID.init(uuidString:)),
                    vaccineName: row["vaccine_name"] as String,
                    administeredAt: Date(timeIntervalSince1970: (row["administered_at"] as Double?) ?? 0),
                    doseNumber: row["dose_number"] as Int?,
                    provider: row["provider"] as String?,
                    lotNumber: row["lot_number"] as String?,
                    source: row["source"] as String?,
                    confirmed: (row["confirmed"] as Int?) == 1,
                    encounterId: (row["encounter_id"] as String?).flatMap(UUID.init(uuidString:)),
                    adverseReactionId: (row["adverse_reaction_id"] as String?).flatMap(UUID.init(uuidString:)))
            }
            let voiceNotes = try Row.fetchAll(db, sql: "SELECT * FROM voice_note").map { row in
                let tags: [String] = (row["tags"] as String?).flatMap { json in
                    guard let data = json.data(using: .utf8) else { return [] }
                    do { return try JSONDecoder().decode([String].self, from: data) }
                    catch { return [] }
                } ?? []
                return Envelope.VoiceNoteExport(
                    id: UUID(uuidString: row["id"] as String) ?? UUID(),
                    patientId: (row["patient_id"] as String?).flatMap(UUID.init(uuidString:)),
                    body: row["body"] as String,
                    occurredAt: Date(timeIntervalSince1970: row["occurred_at"] as Double),
                    tags: tags,
                    inTimeline: (row["in_timeline"] as Int?) == 1)
            }
            let healthProblems = try Row.fetchAll(db, sql: "SELECT * FROM health_problem").map { row in
                Envelope.HealthProblemExport(
                    id: UUID(uuidString: row["id"] as String) ?? UUID(),
                    patientId: (row["patient_id"] as String?).flatMap(UUID.init(uuidString:)),
                    name: row["name"] as String,
                    kind: row["kind"] as String?,
                    archived: (row["archived"] as Int?) == 1,
                    createdAt: Date(timeIntervalSince1970: row["created_at"] as Double))
            }
            let sensitiveIds = try String.fetchAll(db, sql: "SELECT id FROM document_file WHERE is_sensitive = 1")
                .compactMap { UUID(uuidString: $0) }
            var envelope = Envelope(schemaVersion: Envelope.currentSchemaVersion, exportedAt: Date().timeIntervalSince1970,
                                    owner: owner, selfProfile: selfProfile, members: members,
                                    consentRecords: consents,
                                    timeline: timeline, plans: plans, appointments: appointments)
            envelope.documents = documents
            envelope.ocrCardCommits = try OCRCardStore.exportCommits(db)
            envelope.ocrMedications = try Row.fetchAll(db, sql: """
                SELECT m.* FROM medication m WHERE EXISTS
                  (SELECT 1 FROM ocr_card_commit c WHERE c.card_kind = 'medication' AND c.entity_id = m.id) ORDER BY m.id
                """).map { row in
                guard let id = UUID(uuidString: row["id"]), let patient = UUID(uuidString: row["patient_id"]) else { throw ExportError.invalidOCRBackup }
                return Envelope.OCRMedicationExport(id: id, patientId: patient, genericName: row["generic_name"], brandName: row["brand_name"],
                    spec: row["spec"], unitKind: row["unit_kind"], drugKey: row["drug_key"],
                    createdAt: Date(timeIntervalSince1970: row["created_at"]), updatedAt: Date(timeIntervalSince1970: row["updated_at"]))
            }
            envelope.claims = try Row.fetchAll(db, sql: "SELECT * FROM claim_item WHERE confirmed = 1 ORDER BY id").map { row in
                guard let id = UUID(uuidString: row["id"]), let patient = UUID(uuidString: row["patient_id"]) else { throw ExportError.invalidOCRBackup }
                return Envelope.ClaimExport(id: id, patientId: patient,
                    encounterId: (row["encounter_id"] as String?).flatMap(UUID.init(uuidString:)), documentId: (row["document_file_id"] as String?).flatMap(UUID.init(uuidString:)),
                    itemType: row["item_type"], amount: row["amount"], currency: row["currency"], date: (row["date"] as Double?).map(Date.init(timeIntervalSince1970:)),
                    merchant: row["merchant"], summary: row["summary"], createdAt: Date(timeIntervalSince1970: row["created_at"]), updatedAt: Date(timeIntervalSince1970: row["updated_at"]),
                    reimbursedAmount: row["reimbursed_amount"], outOfPocket: row["out_of_pocket"], personalAccountAmount: row["personal_account_amount"],
                    invoiceNo: row["invoice_no"], insuranceTypeText: row["insurance_type_text"])
            }
            // v25（D1-4）：费用明细行随其已确认表头导出（未确认表头不进包，其行亦不进包——行不能悬空）。
            envelope.claimLines = try Row.fetchAll(db, sql: """
                SELECT l.* FROM claim_line l JOIN claim_item c ON c.id = l.claim_item_id WHERE c.confirmed = 1
                ORDER BY l.claim_item_id, l.ordinal
                """).map { row in
                    guard let id = UUID(uuidString: row["id"]), let header = UUID(uuidString: row["claim_item_id"]),
                          let patient = UUID(uuidString: row["patient_id"]) else { throw ExportError.invalidOCRBackup }
                    return Envelope.ClaimLineExport(id: id, claimItemId: header, patientId: patient, ordinal: row["ordinal"], itemName: row["item_name"],
                        itemCodeText: row["item_code_text"], insuranceCode: row["insurance_code"], spec: row["spec"], unitPrice: row["unit_price"],
                        quantityText: row["quantity_text"], quantityUnit: row["quantity_unit"], amount: row["amount"], feeCategoryText: row["fee_category_text"],
                        feeAt: (row["fee_at"] as Double?).map(Date.init(timeIntervalSince1970:)), executingDept: row["executing_dept"],
                        selfPayRatioText: row["self_pay_ratio_text"], rawText: row["raw_text"], sourcePage: row["source_page"],
                        sourceRowId: (row["source_row_id"] as String?).flatMap(UUID.init(uuidString:)),
                        createdAt: Date(timeIntervalSince1970: row["created_at"]))
                }
            // v2 起导出**全部**已确认处方（手工/电子/OCR），不再按 source 过滤——手工处方此前不进包（§C.12「全来源」）。
            envelope.ocrPrescriptions = try Row.fetchAll(db, sql: """
                SELECT p.* FROM prescription p WHERE p.confirmed = 1
                ORDER BY p.id
                """).map { row in
                    guard let id = UUID(uuidString: row["id"]), let patient = UUID(uuidString: row["patient_id"]) else { throw ExportError.invalidOCRBackup }
                    let rawDocument: String? = row["document_file_id"]
                    let document = rawDocument.flatMap(UUID.init(uuidString:))
                    let date: Double? = row["prescribed_at"]
                    guard rawDocument == nil || document != nil, date?.isFinite != false else { throw ExportError.invalidOCRBackup }
                    return Envelope.OCRPrescriptionExport(id: id, patientId: patient, documentId: document,
                        encounterId: (row["encounter_id"] as String?).flatMap(UUID.init(uuidString:)),
                        source: row["source"], hospital: row["hospital"], doctor: row["doctor"],
                        prescribedAt: date.map(Date.init(timeIntervalSince1970:)), adviceText: row["advice_text"],
                        createdAt: Date(timeIntervalSince1970: row["created_at"]), updatedAt: Date(timeIntervalSince1970: row["updated_at"]),
                        department: row["department"], prescriptionNo: row["prescription_no"], prescriptionType: row["prescription_type"],
                        feeTypeText: row["fee_type_text"], clinicalDiagnosis: row["clinical_diagnosis"], pharmacistNames: row["pharmacist_names"],
                        totalAmount: row["total_amount"])
                }
            // v25（D1-4）：处方行随其已确认表头导出，全列（含 medication_notes / provenance / confirmed 原样）。
            envelope.prescriptionLines = try Row.fetchAll(db, sql: """
                SELECT l.* FROM prescription_line l JOIN prescription p ON p.id = l.prescription_id WHERE p.confirmed = 1
                ORDER BY l.prescription_id, l.ordinal
                """).map { row in
                    guard let id = UUID(uuidString: row["id"]), let header = UUID(uuidString: row["prescription_id"]),
                          let patient = UUID(uuidString: row["patient_id"]) else { throw ExportError.invalidOCRBackup }
                    return Envelope.PrescriptionLineExport(id: id, prescriptionId: header, patientId: patient, ordinal: row["ordinal"],
                        printedName: row["printed_name"], genericName: row["generic_name"], brandName: row["brand_name"], drugForm: row["drug_form"],
                        spec: row["spec"], doseText: row["dose_text"], doseUnit: row["dose_unit"], quantityText: row["quantity_text"],
                        quantityUnit: row["quantity_unit"], frequencyText: row["frequency_text"], routeText: row["route_text"],
                        durationText: row["duration_text"],
                        startDate: (row["start_date"] as Double?).map(Date.init(timeIntervalSince1970:)),
                        endDate: (row["end_date"] as Double?).map(Date.init(timeIntervalSince1970:)),
                        asNeededText: row["as_needed_text"], medicationNotes: row["medication_notes"], note: row["note"], rawText: row["raw_text"],
                        insuranceCode: row["insurance_code"], itemCodeText: row["item_code_text"], unitPrice: row["unit_price"], amount: row["amount"],
                        medicationId: (row["medication_id"] as String?).flatMap(UUID.init(uuidString:)),
                        sourcePage: row["source_page"], sourceRowId: (row["source_row_id"] as String?).flatMap(UUID.init(uuidString:)),
                        confirmed: (row["confirmed"] as Int) == 1,
                        createdAt: Date(timeIntervalSince1970: row["created_at"]), updatedAt: Date(timeIntervalSince1970: row["updated_at"]))
                }
            envelope.ocrEncounterDetails = try Row.fetchAll(db, sql: """
                SELECT e.* FROM encounter e WHERE EXISTS
                  (SELECT 1 FROM ocr_card_commit c WHERE c.card_kind = 'encounter' AND c.entity_id = e.id)
                ORDER BY e.id
                """).map { row in
                    guard let id = UUID(uuidString: row["id"]) else { throw ExportError.invalidOCRBackup }
                    return Envelope.OCREncounterDetails(id: id, hospital: row["hospital"], department: row["department"],
                        doctor: row["doctor"], chiefComplaint: row["chief_complaint"], adviceText: row["advice_text"],
                        followUpRequirement: row["follow_up_requirement"], feeAmount: row["fee_amount"],
                        rescheduledFromId: (row["rescheduled_from_id"] as String?).flatMap(UUID.init(uuidString:)),
                        createdAt: Date(timeIntervalSince1970: row["created_at"]), updatedAt: Date(timeIntervalSince1970: row["updated_at"]))
                }
            // v26（D2-3）五表全列导出（Domain 镜像值类型；confirmed 原样携带，恢复绝不升级 D→C）。
            envelope.hospitalizations = try Self.decodeRows(try Row.fetchAll(db, sql: "SELECT * FROM hospitalization ORDER BY created_at, id"),
                                                            OCRCardStore.hospitalization(from:))
            envelope.diagnoses = try Self.decodeRows(try Row.fetchAll(db, sql: "SELECT * FROM diagnosis ORDER BY created_at, ordinal, id"),
                                                     OCRCardStore.diagnosis(from:))
            envelope.examReports = try Self.decodeRows(try Row.fetchAll(db, sql: "SELECT * FROM exam_report ORDER BY created_at, id"),
                                                       OCRCardStore.examReport(from:))
            envelope.labReports = try Self.decodeRows(try Row.fetchAll(db, sql: "SELECT * FROM lab_report ORDER BY created_at, id"),
                                                      OCRCardStore.labReport(from:))
            envelope.labResults = try Self.decodeRows(try Row.fetchAll(db, sql: "SELECT * FROM lab_result ORDER BY lab_report_id, ordinal"),
                                                      OCRCardStore.labResult(from:))
            envelope.sensitiveDocIds = Set(sensitiveIds)
            envelope.observations = observations
            envelope.allergies = allergies
            envelope.encounters = encounters
            envelope.metrics = metrics
            envelope.alertEvents = alertEvents
            envelope.immunizations = immunizations
            envelope.voiceNotes = voiceNotes
            envelope.healthProblems = healthProblems
            try Self.validateOCRBackup(envelope)
            try Self.validateOCRGraph(db)
            return envelope
        }
    }

    // MARK: - ADR-019 冲突预览与逐项裁决（keep/adopt/coexist）

    /// 冲突条目（同一主键在目标库与备份中同时存在）。
    public struct ConflictItem: Sendable, Equatable, Identifiable {
        public var id: UUID
        public var table: String          // 表名（UI 映射为可读类别）
        public var backupTitle: String?   // 备份侧摘要
        public var existingTitle: String? // 目标库摘要
        public init(id: UUID, table: String, backupTitle: String?, existingTitle: String?) {
            self.id = id; self.table = table
            self.backupTitle = backupTitle; self.existingTitle = existingTitle
        }
    }

    /// 逐项裁决（ADR-019：保留本机 / 采用备份 / 并存——绝不静默覆盖或丢弃）。
    public enum ConflictResolution: String, Sendable, Equatable {
        case keep      // 保留本机，跳过备份行
        case adopt     // 采用备份，覆盖本机行（用户显式选择）
        case coexist   // 并存：备份行以新 id 落库，子行外键随映射重写
    }

    /// 冲突预览：备份与目标库的同名主键清单 + 双方摘要（UI 逐项呈现）。
    public func conflictReport(_ envelope: Envelope) async throws -> [ConflictItem] {
        try Self.validateOCRBackup(envelope)
        return try await writer.read { db in
            func conflictIds(table: String, ids: [String], column: String = "id") throws -> [String] {
                guard !ids.isEmpty else { return [] }
                let placeholders = ids.map { _ in "?" }.joined(separator: ",")
                return try String.fetchAll(db, sql: """
                    SELECT \(column) FROM \(table) WHERE \(column) IN (\(placeholders))
                    """, arguments: StatementArguments(ids))
            }
            let memberProfiles = envelope.members ?? []
            let profileIds = ([envelope.selfProfile].compactMap { $0 }.map(\.id)
                              + memberProfiles.map(\.id)).map(\.uuidString)
            var items: [ConflictItem] = []
            func add(_ table: String, ids: [String],
                     backupTitle: (String) -> String?, existingTitle: (String) -> String?) throws {
                for id in try conflictIds(table: table, ids: ids) {
                    let uid = UUID(uuidString: id) ?? UUID()
                    items.append(ConflictItem(id: uid, table: table,
                                              backupTitle: backupTitle(id),
                                              existingTitle: existingTitle(id)))
                }
            }
            let profileById = { (id: String) in
                memberProfiles.first { $0.id.uuidString == id }?.displayName
                    ?? (envelope.selfProfile?.id.uuidString == id ? envelope.selfProfile?.displayName : nil)
            }

            // 备份侧标题字典：冲突预览对每个冲突 id 直接查表——此前每 id 对全数组
            // 线性扫描，整库冲突时放大为 O(n²)（同库重导入的最坏情形）
            let consentTitle = Dictionary(uniqueKeysWithValues: envelope.consentRecords.map { ($0.id.uuidString, $0.key) })
            // 文档维度：新包走 documents（直列），旧包回落 timeline（meta 投影）
            let documentIds: [String] = (envelope.documents ?? []).map { $0.id.uuidString } + envelope.timeline.map { $0.id.uuidString }
            let timelineTitle = Dictionary(uniqueKeysWithValues: (envelope.documents ?? []).map { ($0.id.uuidString, $0.title) }
                                           + envelope.timeline.map { ($0.id.uuidString, $0.title) })
            let planTitle = Dictionary(uniqueKeysWithValues: envelope.plans.map { ($0.id.uuidString, $0.medicationName) })
            let aptTitle = Dictionary(uniqueKeysWithValues: envelope.appointments.map { ($0.id.uuidString, $0.hospital) })
            let obsTitle = Dictionary(uniqueKeysWithValues: envelope.observations.map { ($0.id.uuidString, $0.kind) })
            let allergyTitle = Dictionary(uniqueKeysWithValues: envelope.allergies.map { ($0.id.uuidString, $0.substance) })
            let encTitle = Dictionary(uniqueKeysWithValues: envelope.encounters.map { ($0.id.uuidString, $0.kind) })
            let metricTitle = Dictionary(uniqueKeysWithValues: envelope.metrics.map { ($0.id.uuidString, $0.key) })
            let alertTitle = Dictionary(uniqueKeysWithValues: (envelope.alertEvents ?? []).map { ($0.id.uuidString, $0.ruleId) })
            let immTitle = Dictionary(uniqueKeysWithValues: envelope.immunizations.map { ($0.id.uuidString, $0.vaccineName) })
            let noteTitle = Dictionary(uniqueKeysWithValues: envelope.voiceNotes.map { ($0.id.uuidString, $0.body) })
            let problemTitle = Dictionary(uniqueKeysWithValues: envelope.healthProblems.map { ($0.id.uuidString, $0.name) })
            func existingTitle(_ table: String, _ id: String, _ column: String = "display_name") -> String? {
                (try? String.fetchOne(db, sql: "SELECT \(column) FROM \(table) WHERE id = ?", arguments: [id])) ?? nil   // try?-ok: 摘要列缺失即 nil（纯展示）
            }
            try add("patient_profile", ids: profileIds,
                    backupTitle: { profileById($0) },
                    existingTitle: { existingTitle("patient_profile", $0) })
            try add("local_owner", ids: [envelope.owner].compactMap { $0 }.map { $0.id.uuidString },
                    backupTitle: { _ in envelope.owner?.displayName },
                    existingTitle: { existingTitle("local_owner", $0) })
            try add("consent_record", ids: envelope.consentRecords.map { $0.id.uuidString },
                    backupTitle: { consentTitle[$0] },
                    existingTitle: { existingTitle("consent_record", $0, "key") })
            try add("document_file", ids: documentIds,
                    backupTitle: { timelineTitle[$0] ?? nil },
                    existingTitle: { existingTitle("document_file", $0, "title") })
            // v2 起处方数组含手工/电子处方：摘要与目标库同列（hospital），不再写死 "OCR prescription"
            let prescriptionTitle = Dictionary(uniqueKeysWithValues: (envelope.ocrPrescriptions ?? []).map { ($0.id.uuidString, $0.hospital ?? $0.doctor) })
                .compactMapValues { $0 }
            try add("prescription", ids: (envelope.ocrPrescriptions ?? []).map { $0.id.uuidString },
                    backupTitle: { prescriptionTitle[$0] },
                    existingTitle: { existingTitle("prescription", $0, "hospital") })
            // 审查修复（O(n²) 回退）：medication/claim 的 backupTitle 闭包此前
            // 逐 id 线性扫全数组——整库冲突（同库重导备份）时每个冲突 id 一次
            // 全扫，UUID 字符串比较放大为 O(N²)（同文件内 consentTitle/planTitle
            // 已用字典规避，此二处为同类回退）。与邻接字典同法预建。
            // CI 34652541174 修复：genericName/summary 为可选字段，
            // 直接建表得 [String: String?] → 下标 String??，与
            // backupTitle 的 (String) -> String? 签名不匹配——compactMapValues 归一。
            let medicationTitle = Dictionary(uniqueKeysWithValues: (envelope.ocrMedications ?? []).map { ($0.id.uuidString, $0.genericName) })
                .compactMapValues { $0 }
            let claimTitle = Dictionary(uniqueKeysWithValues: (envelope.claims ?? []).map { ($0.id.uuidString, $0.summary) })
                .compactMapValues { $0 }
            try add("medication", ids: (envelope.ocrMedications ?? []).map { $0.id.uuidString },
                    backupTitle: { medicationTitle[$0] },
                    existingTitle: { existingTitle("medication", $0, "generic_name") })
            try add("claim_item", ids: (envelope.claims ?? []).map { $0.id.uuidString },
                    backupTitle: { claimTitle[$0] },
                    existingTitle: { existingTitle("claim_item", $0, "summary") })
            try add("medication_plan", ids: envelope.plans.map { $0.id.uuidString },
                    backupTitle: { planTitle[$0] },
                    existingTitle: { _ in nil })
            try add("appointment", ids: envelope.appointments.map { $0.id.uuidString },
                    backupTitle: { aptTitle[$0] },
                    existingTitle: { existingTitle("appointment", $0, "hospital") })
            try add("observation", ids: envelope.observations.map { $0.id.uuidString },
                    backupTitle: { obsTitle[$0] },
                    existingTitle: { existingTitle("observation", $0, "kind") })
            try add("allergy_event", ids: envelope.allergies.map { $0.id.uuidString },
                    backupTitle: { allergyTitle[$0] },
                    existingTitle: { existingTitle("allergy_event", $0, "substance") })
            try add("encounter", ids: envelope.encounters.map { $0.id.uuidString },
                    backupTitle: { encTitle[$0] },
                    existingTitle: { existingTitle("encounter", $0, "kind") })
            try add("metric_sample", ids: envelope.metrics.map { $0.id.uuidString },
                    backupTitle: { metricTitle[$0] },
                    existingTitle: { existingTitle("metric_sample", $0, "metric_key") })
            try add("alert_event", ids: (envelope.alertEvents ?? []).map { $0.id.uuidString },
                    backupTitle: { alertTitle[$0] },
                    existingTitle: { existingTitle("alert_event", $0, "rule_id") })
            try add("immunization", ids: envelope.immunizations.map { $0.id.uuidString },
                    backupTitle: { immTitle[$0] },
                    existingTitle: { existingTitle("immunization", $0, "vaccine_name") })
            try add("voice_note", ids: envelope.voiceNotes.map { $0.id.uuidString },
                    backupTitle: { noteTitle[$0] },
                    existingTitle: { existingTitle("voice_note", $0, "body") })
            try add("health_problem", ids: envelope.healthProblems.map { $0.id.uuidString },
                    backupTitle: { problemTitle[$0] },
                    existingTitle: { existingTitle("health_problem", $0, "name") })
            // v26（D2-3）独立冲突表：检验表头 / 诊断 / 检查报告（住院期随就诊、定性行随表头，不单列）
            let labTitle = Dictionary(uniqueKeysWithValues: (envelope.labReports ?? []).map { ($0.id.uuidString, $0.labName ?? $0.hospital) })
                .compactMapValues { $0 }
            let diagnosisTitle = Dictionary(uniqueKeysWithValues: (envelope.diagnoses ?? []).map { ($0.id.uuidString, $0.name) })
            let examTitle = Dictionary(uniqueKeysWithValues: (envelope.examReports ?? []).map { ($0.id.uuidString, $0.examPart ?? $0.reportType) })
            try add("lab_report", ids: (envelope.labReports ?? []).map { $0.id.uuidString },
                    backupTitle: { labTitle[$0] },
                    existingTitle: { existingTitle("lab_report", $0, "lab_name") })
            try add("diagnosis", ids: (envelope.diagnoses ?? []).map { $0.id.uuidString },
                    backupTitle: { diagnosisTitle[$0] },
                    existingTitle: { existingTitle("diagnosis", $0, "name") })
            try add("exam_report", ids: (envelope.examReports ?? []).map { $0.id.uuidString },
                    backupTitle: { examTitle[$0] },
                    existingTitle: { existingTitle("exam_report", $0, "report_type") })
            return items
        }
    }

    /// 行 → Domain 镜像值类型；解码失败（非 UUID 主键 / 非法枚举）按备份损坏拒收，不静默丢行。
    private static func decodeRows<T>(_ rows: [Row], _ decode: (Row) throws -> T) throws -> [T] {
        do { return try rows.map(decode) }
        catch { throw ExportError.invalidOCRBackup }
    }

    /// 导入（往返一致性的一票否决半场）：把 envelope 写回当前库。
    /// FK 拓扑序：patient_profile → local_owner → consent/document/plan/appointment（ERR#35）
    /// → … → encounter（全列；rescheduled_from_id 末段回填）→ prescription（表头）→ medication
    /// → prescription_line（medication_id 外键在药品之后）→ claim_item → claim_line → ocr_card_commit（末位，§C.12）。
    /// 行随表头裁决：表头 keep 跳过其行与行回执 / adopt 整组替换 / coexist 行 id 随表头重写。
    /// ADR-019：冲突项必须有逐项裁决（keep/adopt/coexist）；未裁决的冲突
    /// 抛 .conflict（绝不静默覆盖、绝不静默丢弃）。
    public func importJSON(_ envelope: Envelope,
                           resolutions: [UUID: ConflictResolution] = [:]) async throws {
        try Self.validateOCRBackup(envelope)
        try await writer.write { db in
            // 冲突检测（ADR-019）：不静默覆盖、不静默丢弃——存在即需裁决
            func conflictingIds(table: String, ids: [String], column: String = "id") throws -> Set<String> {
                guard !ids.isEmpty else { return [] }
                let placeholders = ids.map { _ in "?" }.joined(separator: ",")
                return Set(try String.fetchAll(db, sql: """
                    SELECT \(column) FROM \(table) WHERE \(column) IN (\(placeholders))
                    """, arguments: StatementArguments(ids)))
            }
            func resolution(_ id: UUID) -> ConflictResolution {
                // 冲突 id 必带显式裁决：下方检测循环已对每个冲突 id 强制存在性
                // （缺失即抛 .conflict），此处强制解包是类型级承诺——ADR-019
                // 绝不静默默认，不再保留隐藏的 ?? .keep 兜底。
                resolutions[id]!
            }
            let memberProfiles = envelope.members ?? []
            let allProfileIds = ([envelope.selfProfile].compactMap { $0 }.map(\.id)
                                 + memberProfiles.map(\.id)).map(\.uuidString)

            // 文档维度 id 清单：新包 documents（直列）+ 旧包 timeline（meta 投影）
            let documentIds = (envelope.documents ?? []).map { $0.id.uuidString }
                + envelope.timeline.map { $0.id.uuidString }

            // 冲突检测 + 未裁决拒绝（ADR-019）：14 张表同构——(表名, id 清单)
            // 一行描述，单循环完成检测与裁决缺失检查（缺裁决抛 .conflict——
            // UI 必须先呈现 preview，否则「未裁决即恢复」退化为静默丢弃）。
            let conflictPairs: [(table: String, ids: [String])] = [
                ("patient_profile", allProfileIds),
                ("local_owner", [envelope.owner].compactMap { $0 }.map { $0.id.uuidString }),
                ("consent_record", envelope.consentRecords.map { $0.id.uuidString }),
                ("document_file", documentIds),
                ("prescription", (envelope.ocrPrescriptions ?? []).map { $0.id.uuidString }),
                ("medication", (envelope.ocrMedications ?? []).map { $0.id.uuidString }),
                ("claim_item", (envelope.claims ?? []).map { $0.id.uuidString }),
                ("medication_plan", envelope.plans.map { $0.id.uuidString }),
                ("appointment", envelope.appointments.map { $0.id.uuidString }),
                ("observation", envelope.observations.map { $0.id.uuidString }),
                ("allergy_event", envelope.allergies.map { $0.id.uuidString }),
                ("encounter", envelope.encounters.map { $0.id.uuidString }),
                ("metric_sample", envelope.metrics.map { $0.id.uuidString }),
                ("alert_event", (envelope.alertEvents ?? []).map { $0.id.uuidString }),
                ("immunization", envelope.immunizations.map { $0.id.uuidString }),
                ("voice_note", envelope.voiceNotes.map { $0.id.uuidString }),
                ("health_problem", envelope.healthProblems.map { $0.id.uuidString }),
                // v26（D2-3）：检验表头 / 诊断 / 检查报告独立裁决；住院期随就诊、定性行随表头（不入冲突表）
                ("lab_report", (envelope.labReports ?? []).map { $0.id.uuidString }),
                ("diagnosis", (envelope.diagnoses ?? []).map { $0.id.uuidString }),
                ("exam_report", (envelope.examReports ?? []).map { $0.id.uuidString }),
            ]
            var conflictSets: [String: Set<String>] = [:]
            for (table, ids) in conflictPairs {
                let hits = try conflictingIds(table: table, ids: ids)
                for id in hits {
                    guard let uid = UUID(uuidString: id), resolutions[uid] != nil else {
                        throw ExportError.conflict(table: table, id: id)
                    }
                }
                conflictSets[table] = hits
            }
            let profileConflicts = conflictSets["patient_profile"] ?? []
            let ownerConflicts = conflictSets["local_owner"] ?? []
            let consentConflicts = conflictSets["consent_record"] ?? []
            let timelineConflicts = conflictSets["document_file"] ?? []
            let planConflicts = conflictSets["medication_plan"] ?? []
            let aptConflicts = conflictSets["appointment"] ?? []
            let obsConflicts = conflictSets["observation"] ?? []
            let allergyConflicts = conflictSets["allergy_event"] ?? []
            let encConflicts = conflictSets["encounter"] ?? []
            let metricConflicts = conflictSets["metric_sample"] ?? []
            let alertConflicts = conflictSets["alert_event"] ?? []
            let immConflicts = conflictSets["immunization"] ?? []
            let noteConflicts = conflictSets["voice_note"] ?? []
            let problemConflicts = conflictSets["health_problem"] ?? []

            /// ADR-019 三路裁决的唯一形态：冲突表任一行的 keep→跳过 / adopt→执行
            /// 覆盖并跳过 / coexist→落 INSERT（新 id 已由 idMap 重写）。
            /// 全部 12 张实体表共用（错误曾以 3 种手写姿态出现，审计要读 4 个版本）。
            func adoptOrSkip(_ conflicts: Set<String>, _ id: UUID,
                             adopt: () throws -> Void) throws -> Bool {
                guard conflicts.contains(id.uuidString) else { return false }
                switch resolution(id) {
                case .keep:
                    return true
                case .adopt:
                    try adopt()
                    return true
                case .coexist:
                    return false
                }
            }

            // coexist 的 id 重写映射：备份行以新 id 落库，子行外键随映射重写
            var idMap: [UUID: UUID] = [:]
            func remap(_ id: UUID?) -> UUID? {
                guard let id else { return nil }
                return idMap[id] ?? id
            }
            for (_, hits) in conflictSets {
                for id in hits {
                    guard let uid = UUID(uuidString: id), resolution(uid) == .coexist else { continue }
                    idMap[uid] = UUID()
                }
            }
            // v25（§C.12）行随表头并存：表头换新 id 时其处方行 / 费用行一并换新 id——主键与 UNIQUE(表头, ordinal)
            // 都不与本机既有行撞车；行回执 entity_id 经同一 idMap 重写（行不单独进冲突表：行无独立裁决）。
            let prescriptionLineRows = envelope.prescriptionLines ?? [], claimLineRows = envelope.claimLines ?? []
            for line in prescriptionLineRows where idMap[line.prescriptionId] != nil { idMap[line.id] = UUID() }
            for line in claimLineRows where idMap[line.claimItemId] != nil { idMap[line.id] = UUID() }
            // v26：住院期随其就诊并存换 id；定性行随其检验表头并存换 id（UNIQUE(encounter_id) / UNIQUE(lab_report_id, ordinal) 不撞车）。
            let hospitalizationRows = envelope.hospitalizations ?? [], labResultRows = envelope.labResults ?? []
            let labReportRows = envelope.labReports ?? []
            for h in hospitalizationRows where idMap[h.encounterId] != nil { idMap[h.id] = UUID() }
            for r in labResultRows where idMap[r.labReportId] != nil { idMap[r.id] = UUID() }
            let prescriptionLineById = Dictionary(uniqueKeysWithValues: prescriptionLineRows.map { ($0.id, $0) })
            let claimLineById = Dictionary(uniqueKeysWithValues: claimLineRows.map { ($0.id, $0) })
            let hospitalizationById = Dictionary(uniqueKeysWithValues: hospitalizationRows.map { ($0.id, $0) })
            let labResultById = Dictionary(uniqueKeysWithValues: labResultRows.map { ($0.id, $0) })
            /// 回执的裁决归属 (冲突表, 表头 id)：表头回执 = (card_kind, entity_id)；行回执经 envelope 行数组回到表头
            ///（validateOCRBackup 已保证行存在）；住院期回执归其就诊、定性行回执归其检验表头。
            func receiptGovernor(_ audit: OCRCardStore.AuditRecord) -> (table: String, header: UUID) {
                switch audit.entityTable ?? audit.cardKind {
                case "prescription_line": return ("prescription", prescriptionLineById[audit.entityId]?.prescriptionId ?? audit.entityId)
                case "claim_line": return ("claim_item", claimLineById[audit.entityId]?.claimItemId ?? audit.entityId)
                case "hospitalization": return ("encounter", hospitalizationById[audit.entityId]?.encounterId ?? audit.entityId)
                case "lab_result": return ("lab_report", labResultById[audit.entityId]?.labReportId ?? audit.entityId)
                case "lab_report": return ("lab_report", audit.entityId)
                default: return (audit.cardKind, audit.entityId)
                }
            }
            func receiptHeader(_ audit: OCRCardStore.AuditRecord) -> UUID { receiptGovernor(audit).header }
            /// 回执随表头裁决：表头 keep → 该表头的全部回执（表头回执 + 行回执）一律不落。
            func receiptKept(_ audit: OCRCardStore.AuditRecord) -> Bool {
                let governor = receiptGovernor(audit)
                return conflictSets[governor.table, default: []].contains(governor.header.uuidString) && resolution(governor.header) == .keep
            }
            /// v1 包（旧导出）缺 v25 列：adopt 只覆盖其原有列，不把本机既有新列刷成 NULL；v2 包按备份全列采纳。
            let legacyEnvelope = envelope.schemaVersion < Envelope.currentSchemaVersion
            func sourceReference(_ reference: String?) throws -> String? {
                guard let reference, reference.hasPrefix("doc:") else { return reference }
                let (document, page) = try Self.documentReference(reference)
                let target = remap(document) ?? document
                return page.map { HospitalSample.sourceRef(documentId: target, pageIndex: $0) } ?? "doc:\(target.uuidString)"
            }

            // FK 拓扑序（ERR#35）：patient_profile 先落——本人档案必须随 envelope
            // 往返（medication/plan/document 的 patient_id 外键目标）
            var profileId = envelope.owner?.selfPatientId ?? envelope.selfProfile?.id
            /// 备份行 patient_id 的最终落点：coexist 重映射 → 原 id → 本人档案。
            /// 12 处 INSERT/UPDATE 共用同一回落链（此前每处手写三元链）。
            func patientID(_ id: UUID?) -> String {
                (remap(id) ?? id)?.uuidString ?? profileId?.uuidString ?? ""
            }

            func putProfile(_ profile: PatientProfile) throws {
                let targetId = remap(profile.id) ?? profile.id
                if profileConflicts.contains(profile.id.uuidString) {
                    switch resolution(profile.id) {
                    case .keep:
                        return
                    case .adopt:
                        try db.execute(sql: """
                            UPDATE patient_profile SET display_name = ?, relation = ?, gender = ?,
                              birth_date = ?, blood_type = ?, id_no = ?, insurance_no = ?,
                              note = ?, created_at = ?, updated_at = ?, deleted_at = ? WHERE id = ?
                            """, arguments: [profile.displayName, profile.relation, profile.gender,
                                             profile.birthDate, profile.bloodType, profile.idNo,
                                             profile.insuranceNo, profile.note, profile.createdAt,
                                             profile.updatedAt, profile.deletedAt,
                                             profile.id.uuidString])
                        return
                    case .coexist:
                        break   // 落到下方 INSERT（新 id）
                    }
                }
                try db.execute(sql: """
                    INSERT INTO patient_profile
                      (id, owner_local_id, display_name, relation, gender, birth_date,
                       blood_type, id_no, insurance_no, note, created_at, updated_at, deleted_at)
                    VALUES (?, NULL, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [targetId.uuidString, profile.displayName,
                                       profile.relation, profile.gender, profile.birthDate,
                                       profile.bloodType, profile.idNo, profile.insuranceNo,
                                       profile.note, profile.createdAt, profile.updatedAt,
                                       profile.deletedAt])
            }
            if let profile = envelope.selfProfile {
                try putProfile(profile)
            }
            // 成员档案随包落库（BR-001：各成员数据各归其位）。
            // 审查修复：members 含本人（旧包/旧导出）时跳过——本人档案已先落，
            // 重复 INSERT 触发主键冲突导致整包恢复失败
            for member in memberProfiles where member.id != envelope.selfProfile?.id {
                try putProfile(member)
            }
            // 互环 FK 三段式破环（ERR#35 同款）：owner 落（回指 profile）→ 回填 owner_local_id
            if let owner = envelope.owner {
                let targetOwnerId = remap(owner.id) ?? owner.id
                let selfPatientId = remap(owner.selfPatientId) ?? owner.selfPatientId
                if ownerConflicts.contains(owner.id.uuidString) {
                    switch resolution(owner.id) {
                    case .keep:
                        break
                    case .adopt:
                        try db.execute(sql: """
                            UPDATE local_owner SET display_name = ?, self_patient_id = ?, created_at = ? WHERE id = ?
                            """, arguments: [owner.displayName, selfPatientId?.uuidString,
                                             owner.createdAt, owner.id.uuidString])
                    case .coexist:
                        try db.execute(sql: """
                            INSERT INTO local_owner (id, display_name, self_patient_id, created_at)
                            VALUES (?, ?, ?, ?)
                            """, arguments: [targetOwnerId.uuidString, owner.displayName,
                                             selfPatientId?.uuidString, owner.createdAt])
                    }
                } else {
                    try db.execute(sql: """
                        INSERT INTO local_owner (id, display_name, self_patient_id, created_at)
                        VALUES (?, ?, ?, ?)
                        """, arguments: [targetOwnerId.uuidString, owner.displayName,
                                         selfPatientId?.uuidString, owner.createdAt])
                }
                // 本人 + 全部成员的 owner_local_id 回填（coexist 的新 id 同样回填）
                for profile in memberProfiles + [envelope.selfProfile].compactMap({ $0 }) {
                    try db.execute(sql: "UPDATE patient_profile SET owner_local_id = ? WHERE id = ?",
                                   arguments: [targetOwnerId.uuidString,
                                               (remap(profile.id) ?? profile.id).uuidString])
                }
            }
            // 二轮复审 P2：无 owner 的旧包以 selfProfile 为本人回落——coexist 时本人档案
            // 已按新 id 落库，回落链必须同样经 remap，否则 patient_id 为空的旧指标行
            // 被挂到本机既有（另一个人的）档案上。
            profileId = remap(envelope.owner?.selfPatientId ?? envelope.selfProfile?.id) ?? profileId
            for c in envelope.consentRecords {
                if try adoptOrSkip(consentConflicts, c.id, adopt: {
                    try db.execute(sql: """
                        UPDATE consent_record SET key = ?, level = ?, version = ?, accepted_at = ? WHERE id = ?
                        """, arguments: [c.key, c.level, c.version, c.acceptedAt, c.id.uuidString])
                }) { continue }
                try db.execute(sql: """
                    INSERT INTO consent_record (id, key, level, version, accepted_at)
                    VALUES (?, ?, ?, ?, ?)
                    """, arguments: [(remap(c.id) ?? c.id).uuidString, c.key, c.level, c.version, c.acceptedAt])
            }
            // V3.39+ 文档维度恢复：document_file 直列随包往返（第四轮全仓审查修复——
            // 旧路径按 TimelineDocumentEntry 解码 meta_json 只能恢复历史投影行，
            // 经活管线入库的文档（title/ocr_text/grade 直列）在恢复中全部丢失）。
            // encounter_id 外键两段式：encounter 行恢复在文档之后（FK 拓扑序），
            // 先行落 NULL、encounters 恢复完成后统一回填——直接携带 encounter_id
            // 插入会触发 FOREIGN KEY constraint failed、整包恢复回滚（第四轮
            // 全仓审查 Phase 3 补漏：旧 timeline 路径从不写该列，无此失败模式）。
            var cardMap: [UUID: UUID] = [:]
            for audit in envelope.ocrCardCommits ?? [] {
                if idMap[audit.documentId] != nil || idMap[audit.patientId] != nil || idMap[audit.entityId] != nil {
                    if cardMap[audit.cardId] == nil { cardMap[audit.cardId] = UUID() }
                }
            }
            // Pending-only cards are absent from the receipt array but still need a new identity on coexist.
            for document in envelope.documents ?? [] where idMap[document.id] != nil || document.patientId.flatMap({ idMap[$0] }) != nil {
                for id in try Self.reviewCardIDs(document.metaJson) where cardMap[id] == nil { cardMap[id] = UUID() }
            }
            // v26：并存的检验表头 = 一张新卡（source_card_id UNIQUE 不撞车；其行回执随同一 cardMap 换卡 id）。
            for report in labReportRows where idMap[report.id] != nil {
                if let card = report.sourceCardId, cardMap[card] == nil { cardMap[card] = UUID() }
            }
            var docEncounterLinks: [String: UUID?] = [:]
            for d in envelope.documents ?? [] {
                let targetId = remap(d.id) ?? d.id
                let targetPatientId = (remap(d.patientId) ?? d.patientId)?.uuidString
                let targetEncounterId = (remap(d.encounterId) ?? d.encounterId)
                let reviewMetadata = try Self.remapReviewMetadata(d.metaJson, cardMap: cardMap, entityMap: idMap)
                // 第五轮全仓审查修复（5WHY）：keep 裁决的行必须原样保留、绝不
                // 记入回填清单——此前回填循环对所有 envelope 行统一
                // UPDATE encounter_id，keep 行（既有行被跳过、未被 INSERT/UPDATE）
                // 的 encounter_id 被备份值（或 nil）覆写：本地已挂接的就诊关系
                // 被静默改写或摘除，keep=「现有行不触碰」的 ADR-019 语义被破坏。
                // adopt 行 UPDATE 不含 encounter_id 列，故回填仍须覆盖 adopt 行；
                // 回填只应发生在插入/采纳的行上。
                let keepExisting = timelineConflicts.contains(d.id.uuidString) && resolution(d.id) == .keep
                if !keepExisting {
                    docEncounterLinks[targetId.uuidString] = targetEncounterId
                }
                if try adoptOrSkip(timelineConflicts, d.id, adopt: {
                    try Self.restoreOCRPages(d, targetId: targetId, replacing: true, db: db)
                    // v25 两列（doc_type_key / title_source）只在 v2 包上采纳；v1 包不触碰本机既有键
                    let v25Columns = legacyEnvelope ? "" : ", doc_type_key = ?, title_source = ?"
                    let v25Arguments: [DatabaseValueConvertible?] = legacyEnvelope ? [] : [d.docTypeKey, d.titleSource]
                    let baseArguments: [DatabaseValueConvertible?] = [targetPatientId,
                                         d.docType, d.status, d.sha256, d.mimeType,
                                          d.isSensitive ? 1 : 0, d.origin, reviewMetadata, d.title,
                                         d.ocrText, d.notes, d.grade,
                                         d.createdAt.timeIntervalSince1970,
                                         d.updatedAt.timeIntervalSince1970]
                    try db.execute(sql: """
                        UPDATE document_file SET
                            patient_id = ?, doc_type = ?, status = ?,
                            sha256 = ?, mime_type = ?, is_sensitive = ?, origin = ?,
                            meta_json = ?, title = ?, ocr_text = ?, notes = ?, grade = ?,
                            created_at = ?, updated_at = ?\(v25Columns)
                        WHERE id = ?
                        """, arguments: StatementArguments(baseArguments + v25Arguments + [targetId.uuidString]))
                }) { continue }
                try db.execute(sql: """
                    INSERT INTO document_file
                      (id, patient_id, encounter_id, doc_type, status, sha256, mime_type,
                       is_sensitive, origin, meta_json, title, ocr_text, notes, grade,
                       created_at, updated_at, doc_type_key, title_source)
                    VALUES (?, ?, NULL, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [targetId.uuidString, targetPatientId,
                                     d.docType, d.status, d.sha256, d.mimeType,
                                      d.isSensitive ? 1 : 0, d.origin, reviewMetadata, d.title,
                                     d.ocrText, d.notes, d.grade,
                                     d.createdAt.timeIntervalSince1970,
                                     d.updatedAt.timeIntervalSince1970, d.docTypeKey, d.titleSource])
                try Self.restoreOCRPages(d, targetId: targetId, replacing: false, db: db)
            }
            // 旧备份包（无 documents 维度）的投影行恢复——历史兼容路径
            for e in envelope.timeline {
                if try adoptOrSkip(timelineConflicts, e.id, adopt: {
                    let meta = String(data: try JSONEncoder().encode(e), encoding: .utf8) ?? "{}"
                    try db.execute(sql: """
                        UPDATE document_file SET patient_id = ?, meta_json = ?, title = ?, created_at = ?, updated_at = ?
                        WHERE id = ?
                        """, arguments: [(remap(e.patientId) ?? e.patientId).uuidString, meta, e.title,
                                         e.occurredAt, e.occurredAt, e.id.uuidString])
                }) { continue }
                let meta = String(data: try JSONEncoder().encode(e), encoding: .utf8) ?? "{}"
                let targetId = remap(e.id) ?? e.id
                try db.execute(sql: """
                    INSERT INTO document_file
                      (id, patient_id, doc_type, sha256, mime_type, origin, meta_json, created_at, updated_at)
                    VALUES (?, ?, 'ocr_document', ?, 'application/json', 'scanner', ?, ?, ?)
                    """, arguments: [targetId.uuidString, (remap(e.patientId) ?? e.patientId).uuidString,
                                     "sha:" + targetId.uuidString,
                                     meta, e.occurredAt, e.occurredAt])
            }
            for p in envelope.plans {
                if try adoptOrSkip(planConflicts, p.id, adopt: {
                    let scheduleJSON = String(data: try JSONEncoder().encode(p.schedule), encoding: .utf8) ?? "{}"
                    // 审查修复（ADR-019 采纳语义）：采纳 = 以备份版本为准——
                    // 旧 UPDATE 只改 4 列，备份的 dose_plan_units（安全线单剂
                    // 基线）与 ended_reason/paused_at 被静默丢弃，恢复后库存
                    // 扣减与暂停/结束语义跑在错误基线上（V3.94 往返契约）
                    try db.execute(sql: """
                        UPDATE medication_plan SET status = ?, schedule_json = ?, start_date = ?, end_date = ?,
                          dose_plan_units = ?, ended_reason = ?, paused_at = ?
                        WHERE id = ?
                        """, arguments: [p.status.rawValue, scheduleJSON,
                                         p.startDate.timeIntervalSince1970,
                                         p.endDate?.timeIntervalSince1970,
                                         p.dosePlanUnits, p.endedReason,
                                         p.pausedAt?.timeIntervalSince1970, p.id.uuidString])
                }) { continue }
                // 药品行先落（medication_plan.medication_id 外键，ERR#35）
                let planPatient = remap(p.patientId) ?? p.patientId ?? profileId
                let medId = UUID()
                try db.execute(sql: """
                    INSERT INTO medication (id, patient_id, generic_name, spec, unit_kind, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [medId.uuidString, planPatient?.uuidString ?? "",
                                       p.medicationName, p.spec, p.unitKind ?? "tablet",
                                       p.startDate.timeIntervalSince1970, p.startDate.timeIntervalSince1970])
                let scheduleJSON = String(data: try JSONEncoder().encode(p.schedule), encoding: .utf8) ?? "{}"
                try db.execute(sql: """
                    INSERT INTO medication_plan
                      (id, patient_id, medication_id, status, schedule_json, start_date, end_date,
                       dose_plan_units, ended_reason, paused_at, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [(remap(p.id) ?? p.id).uuidString, planPatient?.uuidString ?? "", medId.uuidString, p.status.rawValue, scheduleJSON,
                                     p.startDate.timeIntervalSince1970, p.endDate?.timeIntervalSince1970,
                                     p.dosePlanUnits, p.endedReason, p.pausedAt?.timeIntervalSince1970,
                                     p.startDate.timeIntervalSince1970, p.startDate.timeIntervalSince1970])
            }
            for a in envelope.appointments {
                if try adoptOrSkip(aptConflicts, a.id, adopt: {
                    try db.execute(sql: """
                        UPDATE appointment SET patient_id = ?, hospital = ?, department = ?, starts_at = ?, status = ?
                        WHERE id = ?
                        """, arguments: [(remap(a.patientId) ?? a.patientId)?.uuidString ?? "", a.hospital,
                                         a.department, a.startsAt.timeIntervalSince1970, a.status, a.id.uuidString])
                }) { continue }
                try db.execute(sql: """
                    INSERT INTO appointment (id, patient_id, hospital, department, starts_at, status, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [(remap(a.id) ?? a.id).uuidString, patientID(a.patientId), a.hospital, a.department,
                                     a.startsAt.timeIntervalSince1970, a.status,
                                     a.startsAt.timeIntervalSince1970, a.startsAt.timeIntervalSince1970])
            }
            for o in envelope.observations {
                // FR13.5 V3.28：扩展字段随包往返——adopt 全列覆盖、INSERT 全列写入
                if try adoptOrSkip(obsConflicts, o.id, adopt: {
                    try db.execute(sql: """
                        UPDATE observation SET patient_id = ?, kind = ?, occurred_at = ?, captured_at = ?,
                          description = ?, self_mark = ?, media_asset_ids = ?, body_part = ?,
                          duration_min = ?, frequency = ?, is_first = ?, trigger = ?,
                          accompanying = ?, pain_score = ?, meds_diet = ?, consulted_doctor = ?,
                          encounter_id = ?, health_problem_id = ?, group_id = ?
                        WHERE id = ?
                        """, arguments: [(remap(o.patientId) ?? o.patientId)?.uuidString ?? "", o.kind,
                                         o.occurredAt.timeIntervalSince1970, o.capturedAt?.timeIntervalSince1970,
                                         o.description, o.selfMark, Self.encodeMediaIds(o.mediaAssetIds),
                                         o.bodyPart, o.durationMin, o.frequency,
                                         o.isFirst.map { $0 ? 1 : 0 }, o.trigger, o.accompanying,
                                         o.painScore, o.medsDiet, o.consultedDoctor ? 1 : 0,
                                         o.encounterId?.uuidString, o.healthProblemId?.uuidString,
                                         o.groupId?.uuidString, o.id.uuidString])
                }) { continue }
                try db.execute(sql: """
                    INSERT INTO observation (id, patient_id, kind, occurred_at, captured_at,
                      description, self_mark, media_asset_ids, body_part, duration_min, frequency,
                      is_first, trigger, accompanying, pain_score, meds_diet, consulted_doctor,
                      encounter_id, health_problem_id, group_id, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [(remap(o.id) ?? o.id).uuidString, patientID(o.patientId), o.kind,
                                     o.occurredAt.timeIntervalSince1970, o.capturedAt?.timeIntervalSince1970,
                                     o.description, o.selfMark, Self.encodeMediaIds(o.mediaAssetIds),
                                     o.bodyPart, o.durationMin, o.frequency,
                                     o.isFirst.map { $0 ? 1 : 0 }, o.trigger, o.accompanying,
                                     o.painScore, o.medsDiet, o.consultedDoctor ? 1 : 0,
                                     o.encounterId?.uuidString, o.healthProblemId?.uuidString,
                                     o.groupId?.uuidString,
                                     o.occurredAt.timeIntervalSince1970, o.occurredAt.timeIntervalSince1970])
            }
            for a in envelope.allergies {
                if try adoptOrSkip(allergyConflicts, a.id, adopt: {
                    try db.execute(sql: """
                        UPDATE allergy_event SET patient_id = ?, substance = ?, reaction_tags = ?,
                          severity = ?, occurred_at = ?, consulted_doctor = ?, duration_min = ?,
                          treatment_note = ?, note = ?, encounter_id = ?, medication_id = ?
                        WHERE id = ?
                        """, arguments: [(remap(a.patientId) ?? a.patientId)?.uuidString ?? "", a.substance,
                                         a.reactionTags ?? "[]", a.severity, a.occurredAt.timeIntervalSince1970,
                                         (a.consultedDoctor ?? false) ? 1 : 0, a.durationMin, a.treatmentNote,
                                         a.note, a.encounterId?.uuidString, a.medicationId?.uuidString,
                                         a.id.uuidString])
                }) { continue }
                try db.execute(sql: """
                    INSERT INTO allergy_event (id, patient_id, substance, reaction_tags, severity, occurred_at,
                                              consulted_doctor, duration_min, treatment_note, note,
                                              encounter_id, medication_id, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [(remap(a.id) ?? a.id).uuidString, patientID(a.patientId), a.substance,
                                     a.reactionTags ?? "[]", a.severity, a.occurredAt.timeIntervalSince1970,
                                     (a.consultedDoctor ?? false) ? 1 : 0, a.durationMin, a.treatmentNote,
                                     a.note, a.encounterId?.uuidString, a.medicationId?.uuidString,
                                     a.occurredAt.timeIntervalSince1970, a.occurredAt.timeIntervalSince1970])
            }
            // v25（D1-4）就诊全列恢复。rescheduled_from_id 自引用 FK：先落 NULL、全部就诊落库后统一回填
            // （备份内改期链的前驱可能排在后面，直接携带会触发 FOREIGN KEY constraint failed 整包回滚）。
            var rescheduleLinks: [(encounterId: String, from: String?)] = []
            for e in envelope.encounters {
                let targetId = (remap(e.id) ?? e.id).uuidString
                let rescheduledFrom = remap(e.rescheduledFromId)?.uuidString
                let narrative: [DatabaseValueConvertible?] = [e.hospital, e.department, e.doctor, e.chiefComplaint, e.diagnosisText,
                                                             e.adviceText, e.followUpRequirement, e.feeAmount,
                                                             e.presentIllness, e.visitSummary, e.pastHistory, e.physicalExam, e.allergyHistory]
                if try adoptOrSkip(encConflicts, e.id, adopt: {
                    if legacyEnvelope {
                        // v1 包只有五列：其余列由 ocrEncounterDetails（仅 OCR 就诊）补，手工列保持本机现值
                        try db.execute(sql: """
                            UPDATE encounter SET patient_id = ?, date = ?, kind = ?, diagnosis_text = ?,
                              deleted_at = ?
                            WHERE id = ?
                            """, arguments: [(remap(e.patientId) ?? e.patientId)?.uuidString ?? "", e.date.timeIntervalSince1970,
                                             e.kind, e.diagnosisText, e.deletedAt, e.id.uuidString])
                        return
                    }
                    let head: [DatabaseValueConvertible?] = [(remap(e.patientId) ?? e.patientId)?.uuidString ?? "", e.date.timeIntervalSince1970, e.kind]
                    let tail: [DatabaseValueConvertible?] = [e.deletedAt, (e.createdAt ?? e.date).timeIntervalSince1970,
                                                            (e.updatedAt ?? e.date).timeIntervalSince1970, e.id.uuidString]
                    try db.execute(sql: """
                        UPDATE encounter SET patient_id = ?, date = ?, kind = ?,
                          hospital = ?, department = ?, doctor = ?, chief_complaint = ?, diagnosis_text = ?,
                          advice_text = ?, follow_up_requirement = ?, fee_amount = ?,
                          present_illness = ?, visit_summary = ?, past_history = ?, physical_exam = ?, allergy_history = ?,
                          deleted_at = ?, created_at = ?, updated_at = ?
                        WHERE id = ?
                        """, arguments: StatementArguments(head + narrative + tail))
                    rescheduleLinks.append((e.id.uuidString, rescheduledFrom))
                }) { continue }
                let head: [DatabaseValueConvertible?] = [targetId, patientID(e.patientId), e.date.timeIntervalSince1970, e.kind]
                let tail: [DatabaseValueConvertible?] = [e.deletedAt, (e.createdAt ?? e.date).timeIntervalSince1970,
                                                        (e.updatedAt ?? e.date).timeIntervalSince1970]
                try db.execute(sql: """
                    INSERT INTO encounter (id, patient_id, date, kind,
                      hospital, department, doctor, chief_complaint, diagnosis_text,
                      advice_text, follow_up_requirement, fee_amount,
                      present_illness, visit_summary, past_history, physical_exam, allergy_history,
                      deleted_at, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: StatementArguments(head + narrative + tail))
                if rescheduledFrom != nil { rescheduleLinks.append((targetId, rescheduledFrom)) }
            }
            for link in rescheduleLinks {
                try db.execute(sql: "UPDATE encounter SET rescheduled_from_id = ? WHERE id = ?", arguments: [link.from, link.encounterId])
            }
            // document_file.encounter_id 外键回填（第四轮全仓审查 Phase 3 补漏）：
            // encounter 行已全部落库，此时统一挂接（含 nil → 清除 adopt 行残留）
            for (docId, encId) in docEncounterLinks {
                try db.execute(sql: "UPDATE document_file SET encounter_id = ? WHERE id = ?",
                               arguments: [encId?.uuidString, docId])
            }
            // v26（§C.12 第 2 位）住院期：随就诊裁决——就诊 keep → 跳过；否则按 UNIQUE(encounter_id) 落到该就诊的唯一住院期
            //（本机已有同就诊住院期 → 采纳备份列、保留本机 id 并把备份 id 重映射到它，回执随之指向存活行；同 id 已有 → 覆盖；
            //   否则 INSERT，coexist 的新 id 已随就诊重写）。
            for h in hospitalizationRows {
                if encConflicts.contains(h.encounterId.uuidString), resolution(h.encounterId) == .keep { continue }
                let targetEncounter = (remap(h.encounterId) ?? h.encounterId).uuidString
                var target = (remap(h.id) ?? h.id).uuidString
                let facts = OCRCardStore.hospitalizationFacts(h)
                let stamps: [DatabaseValueConvertible?] = [h.source.rawValue, h.confirmed ? 1 : 0,
                                                          h.createdAt.timeIntervalSince1970, h.updatedAt.timeIntervalSince1970]
                let localUnderEncounter = try String.fetchOne(db, sql: "SELECT id FROM hospitalization WHERE encounter_id = ?", arguments: [targetEncounter])
                if let local = localUnderEncounter, local != target {
                    if let localId = UUID(uuidString: local) { idMap[h.id] = localId }
                    target = local
                }
                let sameIdCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM hospitalization WHERE id = ?", arguments: [target]) ?? 0
                let exists = localUnderEncounter != nil || sameIdCount > 0
                let head: [DatabaseValueConvertible?] = [patientID(h.patientId), targetEncounter, remap(h.documentFileId)?.uuidString]
                if exists {
                    try db.execute(sql: """
                        UPDATE hospitalization SET patient_id = ?, encounter_id = ?, document_file_id = ?,
                          hospital = ?, medical_record_no = ?, inpatient_times = ?, admit_at = ?, discharge_at = ?, actual_days = ?,
                          admit_dept = ?, discharge_dept = ?, ward = ?, bed_no = ?, admit_route_text = ?, payment_type_text = ?, discharge_way_text = ?,
                          attending_physician = ?, admit_diagnosis_text = ?, discharge_diagnosis_text = ?, admit_condition = ?, treatment_course = ?,
                          discharge_condition = ?, discharge_orders = ?, take_home_drugs_text = ?, total_cost = ?, summary_doctor = ?, summary_date = ?,
                          source = ?, confirmed = ?, created_at = ?, updated_at = ?
                        WHERE id = ?
                        """, arguments: StatementArguments(head + facts + stamps + [target]))
                } else {
                    try db.execute(sql: """
                        INSERT INTO hospitalization (id, patient_id, encounter_id, document_file_id,
                          hospital, medical_record_no, inpatient_times, admit_at, discharge_at, actual_days, admit_dept, discharge_dept, ward, bed_no,
                          admit_route_text, payment_type_text, discharge_way_text, attending_physician, admit_diagnosis_text, discharge_diagnosis_text,
                          admit_condition, treatment_course, discharge_condition, discharge_orders, take_home_drugs_text, total_cost, summary_doctor, summary_date,
                          source, confirmed, created_at, updated_at)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """, arguments: StatementArguments([target] + head + facts + stamps))
                }
            }
            // v26（§C.12 第 7 位）检验表头：独立裁决（keep 跳过 / adopt 全列覆盖 / coexist 新 id + 新卡 id），先于 metric_sample.lab_report_id 落库。
            let labReportConflicts = conflictSets["lab_report"] ?? []
            for r in labReportRows {
                let target = remap(r.id) ?? r.id
                let sourceCard = r.sourceCardId.map { (cardMap[$0] ?? $0).uuidString }
                let facts: [DatabaseValueConvertible?] = [
                    patientID(r.patientId), remap(r.encounterId)?.uuidString, remap(r.documentFileId)?.uuidString,
                    r.hospital, r.department, r.labName, r.reportNo, r.specimenType, r.specimenNo, r.testClassText, r.clinicalDiagnosis,
                    r.collectedAt?.timeIntervalSince1970, r.receivedAt?.timeIntervalSince1970, r.reportedAt?.timeIntervalSince1970,
                    r.sendDoctor, r.testDoctor, r.reviewDoctor, sourceCard, r.source.rawValue, r.confirmed ? 1 : 0,
                    r.createdAt.timeIntervalSince1970, r.updatedAt.timeIntervalSince1970,
                ]
                if try adoptOrSkip(labReportConflicts, r.id, adopt: {
                    try db.execute(sql: """
                        UPDATE lab_report SET patient_id = ?, encounter_id = ?, document_file_id = ?,
                          hospital = ?, department = ?, lab_name = ?, report_no = ?, specimen_type = ?, specimen_no = ?, test_class_text = ?, clinical_diagnosis = ?,
                          collected_at = ?, received_at = ?, reported_at = ?, send_doctor = ?, test_doctor = ?, review_doctor = ?,
                          source_card_id = ?, source = ?, confirmed = ?, created_at = ?, updated_at = ?
                        WHERE id = ?
                        """, arguments: StatementArguments(facts + [r.id.uuidString]))
                }) { continue }
                try db.execute(sql: """
                    INSERT INTO lab_report (id, patient_id, encounter_id, document_file_id, hospital, department, lab_name, report_no,
                      specimen_type, specimen_no, test_class_text, clinical_diagnosis, collected_at, received_at, reported_at,
                      send_doctor, test_doctor, review_doctor, source_card_id, source, confirmed, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: StatementArguments([target.uuidString] + facts))
            }
            for m in envelope.metrics {
                let restoredSourceRef = try sourceReference(m.sourceRef)
                let selfMeasured = (m.selfMeasured ?? (m.origin != "hospital")) ? 1 : 0
                let createdAt = (m.createdAt ?? m.measuredAt).timeIntervalSince1970
                // v26 两列：v1 包 adopt 不触碰本机既有 lab_report_id/abnormal_flag；v2 包按备份全列采纳。
                let labColumns = legacyEnvelope ? "" : ", lab_report_id = ?, abnormal_flag = ?"
                let labArguments: [DatabaseValueConvertible?] = legacyEnvelope ? [] : [remap(m.labReportId)?.uuidString, m.abnormalFlag]
                if try adoptOrSkip(metricConflicts, m.id, adopt: {
                    let base: [DatabaseValueConvertible?] = [patientID(m.patientId), m.key, m.value, m.secondaryValue,
                                         m.unit, m.origin, selfMeasured, m.excluded ? 1 : 0, restoredSourceRef,
                                         m.refLow, m.refHigh, m.refSourceLabel, m.rawLabel, m.codeConceptId,
                                         m.valueMin, m.valueMax, m.sampleCount, m.sourceName, m.sourceVersion,
                                         m.sourceProduct, m.sourceIdentifier, m.aggregationKind,
                                         m.windowEnd?.timeIntervalSince1970, m.measuredAt.timeIntervalSince1970, createdAt]
                    try db.execute(sql: """
                        UPDATE metric_sample SET patient_id = ?, metric_key = ?, value = ?, secondary_value = ?,
                          unit = ?, origin = ?, self_measured = ?, excluded = ?, source_ref = ?,
                          ref_low = ?, ref_high = ?, ref_source_label = ?, raw_label = ?, code_concept_id = ?,
                          value_min = ?, value_max = ?, sample_count = ?, source_name = ?, source_version = ?,
                          source_product = ?, source_identifier = ?, aggregation_kind = ?, window_end = ?,
                          measured_at = ?, created_at = ?\(labColumns)
                        WHERE id = ?
                        """, arguments: StatementArguments(base + labArguments + [m.id.uuidString]))
                }) { continue }
                try db.execute(sql: """
                    INSERT INTO metric_sample
                      (id, patient_id, metric_key, value, secondary_value, unit, origin, self_measured,
                       excluded, source_ref, ref_low, ref_high, ref_source_label, raw_label, code_concept_id,
                       value_min, value_max, sample_count, source_name, source_version, source_product,
                       source_identifier, aggregation_kind, window_end, measured_at, created_at, lab_report_id, abnormal_flag)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [(remap(m.id) ?? m.id).uuidString, patientID(m.patientId), m.key, m.value,
                                     m.secondaryValue, m.unit, m.origin, selfMeasured, m.excluded ? 1 : 0,
                                     restoredSourceRef, m.refLow, m.refHigh, m.refSourceLabel, m.rawLabel, m.codeConceptId,
                                     m.valueMin, m.valueMax, m.sampleCount, m.sourceName, m.sourceVersion,
                                     m.sourceProduct, m.sourceIdentifier, m.aggregationKind,
                                     m.windowEnd?.timeIntervalSince1970, m.measuredAt.timeIntervalSince1970, createdAt,
                                     remap(m.labReportId)?.uuidString, m.abnormalFlag])
            }
            // v26（§C.12 第 9 位）定性行随表头裁决（keep 跳过 / adopt 整组换、本机回执指向的行保留 / 新增·coexist 直接 INSERT）。
            let labResultUpsert = """
                ON CONFLICT(id) DO UPDATE SET patient_id=excluded.patient_id, lab_report_id=excluded.lab_report_id, ordinal=excluded.ordinal,
                  item_name=excluded.item_name, item_code_text=excluded.item_code_text, result_text=excluded.result_text, comparator=excluded.comparator,
                  unit=excluded.unit, reference_text=excluded.reference_text, abnormal_flag=excluded.abnormal_flag, method=excluded.method,
                  code_concept_id=excluded.code_concept_id, source_page=excluded.source_page, source_row_id=excluded.source_row_id, created_at=excluded.created_at
                """
            for (headerId, rows) in Dictionary(grouping: labResultRows, by: \.labReportId) {
                let conflicting = labReportConflicts.contains(headerId.uuidString)
                if conflicting, resolution(headerId) == .keep { continue }
                let adopting = conflicting && resolution(headerId) == .adopt
                let header = (remap(headerId) ?? headerId).uuidString
                if adopting { try parkExistingLines(table: "lab_result", parentColumn: "lab_report_id", header: header) }
                for row in rows.sorted(by: { $0.ordinal < $1.ordinal }) {
                    let identity: [DatabaseValueConvertible?] = [(remap(row.id) ?? row.id).uuidString, patientID(row.patientId), header, row.ordinal, row.itemName]
                    let facts: [DatabaseValueConvertible?] = [row.itemCodeText, row.resultText, row.comparator, row.unit, row.referenceText,
                                                             row.abnormalFlag, row.method, row.codeConceptId]
                    let provenance: [DatabaseValueConvertible?] = [row.sourcePage, row.sourceRowId?.uuidString, row.createdAt.timeIntervalSince1970]
                    try db.execute(sql: """
                        INSERT INTO lab_result (id, patient_id, lab_report_id, ordinal, item_name, item_code_text, result_text, comparator, unit,
                          reference_text, abnormal_flag, method, code_concept_id, source_page, source_row_id, created_at)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        \(adopting ? labResultUpsert : "")
                        """, arguments: StatementArguments(identity + facts + provenance))
                }
                if adopting {
                    try settleParkedLines(table: "lab_result", parentColumn: "lab_report_id", header: header, retainedBy: [
                        "SELECT entity_id FROM ocr_card_commit WHERE entity_table = 'lab_result'",
                    ])
                }
            }
            for details in envelope.ocrEncounterDetails ?? [] {
                if encConflicts.contains(details.id.uuidString), resolution(details.id) == .keep { continue }
                try db.execute(sql: """
                    UPDATE encounter SET hospital = ?, department = ?, doctor = ?, chief_complaint = ?, advice_text = ?,
                      follow_up_requirement = ?, fee_amount = ?, rescheduled_from_id = ?, created_at = ?, updated_at = ? WHERE id = ?
                    """, arguments: [details.hospital, details.department, details.doctor, details.chiefComplaint, details.adviceText,
                        details.followUpRequirement, details.feeAmount, remap(details.rescheduledFromId)?.uuidString,
                        details.createdAt.timeIntervalSince1970, details.updatedAt.timeIntervalSince1970,
                        (remap(details.id) ?? details.id).uuidString])
                guard db.changesCount == 1 else { throw ExportError.invalidOCRBackup }
            }
            let prescriptionConflicts = conflictSets["prescription"] ?? []
            for prescription in envelope.ocrPrescriptions ?? [] {
                let target = remap(prescription.id) ?? prescription.id
                let owner = patientID(prescription.patientId)
                let source = remap(prescription.documentId)?.uuidString
                let head: [DatabaseValueConvertible?] = [owner, source, remap(prescription.encounterId)?.uuidString, prescription.source,
                    prescription.hospital, prescription.doctor, prescription.prescribedAt?.timeIntervalSince1970, prescription.adviceText]
                // v25（§C.6）表头七列
                let header: [DatabaseValueConvertible?] = [prescription.department, prescription.prescriptionNo, prescription.prescriptionType,
                    prescription.feeTypeText, prescription.clinicalDiagnosis, prescription.pharmacistNames, prescription.totalAmount]
                let stamps: [DatabaseValueConvertible?] = [prescription.createdAt.timeIntervalSince1970, prescription.updatedAt.timeIntervalSince1970]
                if try adoptOrSkip(prescriptionConflicts, prescription.id, adopt: {
                    if legacyEnvelope {
                        try db.execute(sql: """
                            UPDATE prescription SET patient_id = ?, document_file_id = ?, encounter_id = ?, source = ?,
                              hospital = ?, doctor = ?, prescribed_at = ?, advice_text = ?, confirmed = 1, created_at = ?, updated_at = ? WHERE id = ?
                            """, arguments: StatementArguments(head + stamps + [target.uuidString]))
                        return
                    }
                    try db.execute(sql: """
                        UPDATE prescription SET patient_id = ?, document_file_id = ?, encounter_id = ?, source = ?,
                          hospital = ?, doctor = ?, prescribed_at = ?, advice_text = ?,
                          department = ?, prescription_no = ?, prescription_type = ?, fee_type_text = ?, clinical_diagnosis = ?,
                          pharmacist_names = ?, total_amount = ?, confirmed = 1, created_at = ?, updated_at = ? WHERE id = ?
                        """, arguments: StatementArguments(head + header + stamps + [target.uuidString]))
                }) { continue }
                try db.execute(sql: """
                    INSERT INTO prescription (id, patient_id, document_file_id, encounter_id, source, hospital, doctor,
                      prescribed_at, advice_text, department, prescription_no, prescription_type, fee_type_text, clinical_diagnosis,
                      pharmacist_names, total_amount, confirmed, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?)
                    """, arguments: StatementArguments([target.uuidString] + head + header + stamps))
            }
            // A kept source cannot silently supply another version's pages to newly restored facts.
            for document in envelope.documents ?? [] where timelineConflicts.contains(document.id.uuidString) && resolution(document.id) == .keep {
                let referenced = try envelope.metrics.contains { metric in
                    guard !(metricConflicts.contains(metric.id.uuidString) && resolution(metric.id) == .keep),
                          let ref = metric.sourceRef, ref.hasPrefix("doc:") else { return false }
                    return try Self.documentReference(ref).0 == document.id
                } || (envelope.ocrCardCommits ?? []).contains { audit in
                    audit.documentId == document.id && !receiptKept(audit)   // 行回执随其表头裁决
                }
                if referenced {
                    let localPages = try Self.ocrPages(document.id, db: db)
                    let localHash = try String.fetchOne(db, sql: "SELECT sha256 FROM document_file WHERE id = ?", arguments: [document.id.uuidString])
                    guard localHash == document.sha256,
                          document.pages == nil || localPages == document.pages?.sorted(by: { $0.index < $1.index }) else {
                        throw ExportError.invalidOCRBackup
                    }
                }
            }
            let existingAudits = try OCRCardStore.exportCommits(db)
            for medication in envelope.ocrMedications ?? [] {
                let target = remap(medication.id) ?? medication.id
                if conflictSets["medication", default: []].contains(medication.id.uuidString), resolution(medication.id) == .keep { continue }
                try db.execute(sql: """
                    INSERT INTO medication (id, patient_id, generic_name, brand_name, spec, unit_kind, drug_key, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET patient_id=excluded.patient_id, generic_name=excluded.generic_name,
                      brand_name=excluded.brand_name, spec=excluded.spec, unit_kind=excluded.unit_kind, drug_key=excluded.drug_key,
                      created_at=excluded.created_at, updated_at=excluded.updated_at
                    """, arguments: [target.uuidString, patientID(medication.patientId), medication.genericName,
                        medication.brandName, medication.spec, medication.unitKind, medication.drugKey,
                        medication.createdAt.timeIntervalSince1970, medication.updatedAt.timeIntervalSince1970])
            }
            // v25（§C.12 第 4 位）处方行：表头与药品都已落库（prescription_line.medication_id → medication 外键），行随表头裁决：
            //   keep → 整组跳过；adopt → 本机既有行先挪到负 ordinal 区，备份行按 id upsert（同 id 覆盖、异 id 新增），
            //   再删多余本机行——但被 stock_lot 引用（FK，用户显式建立的药箱链接）或被本机回执指向（备份之后又确认的页；
            //   ocr_result 只增不改，回执不得悬空）的行挪回尾部保留；新增 / coexist → 直接 INSERT（coexist 的行 id 已随表头
            //   一并重写）。UNIQUE(prescription_id, ordinal) 全程不撞车。
            /// 行的药品目录链接只在目标库存在**同成员**药品时写回（用药计划恢复新建药品行、id 不保留；不伪造外键目标、不跨成员）。
            func restoredMedication(_ id: UUID?, patient: String) throws -> String? {
                guard let id else { return nil }
                let target = (remap(id) ?? id).uuidString
                let present = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM medication WHERE id = ? AND patient_id = ?", arguments: [target, patient]) ?? 0
                return present == 1 ? target : nil
            }
            /// 表头 adopt 时的行组替换前半场（挪走既有行）与后半场（清理 / 归位）。
            func parkExistingLines(table: String, parentColumn: String, header: String) throws {
                try db.execute(sql: "UPDATE \(table) SET ordinal = -(ordinal + 1) WHERE \(parentColumn) = ?", arguments: [header])
            }
            /// `retainedBy`：返回须保留的行 id 的子查询（静态 SQL 字面量），其余挪走的本机行删除。
            func settleParkedLines(table: String, parentColumn: String, header: String, retainedBy: [String]) throws {
                let retained = retainedBy.map { " AND id NOT IN (\($0))" }.joined()
                try db.execute(sql: "DELETE FROM \(table) WHERE \(parentColumn) = ? AND ordinal < 0\(retained)", arguments: [header])
                let parked = try String.fetchAll(db, sql: "SELECT id FROM \(table) WHERE \(parentColumn) = ? AND ordinal < 0 ORDER BY ordinal DESC", arguments: [header])
                for id in parked {
                    try db.execute(sql: """
                        UPDATE \(table) SET ordinal = (SELECT COALESCE(MAX(ordinal), -1) + 1 FROM \(table) WHERE \(parentColumn) = ?) WHERE id = ?
                        """, arguments: [header, id])
                }
            }
            let prescriptionLineUpsert = """
                ON CONFLICT(id) DO UPDATE SET prescription_id=excluded.prescription_id, patient_id=excluded.patient_id, ordinal=excluded.ordinal,
                  printed_name=excluded.printed_name, generic_name=excluded.generic_name, brand_name=excluded.brand_name, drug_form=excluded.drug_form,
                  spec=excluded.spec, dose_text=excluded.dose_text, dose_unit=excluded.dose_unit, quantity_text=excluded.quantity_text,
                  quantity_unit=excluded.quantity_unit, frequency_text=excluded.frequency_text, route_text=excluded.route_text,
                  duration_text=excluded.duration_text, start_date=excluded.start_date, end_date=excluded.end_date, as_needed_text=excluded.as_needed_text,
                  medication_notes=excluded.medication_notes, note=excluded.note, raw_text=excluded.raw_text, insurance_code=excluded.insurance_code,
                  item_code_text=excluded.item_code_text, unit_price=excluded.unit_price, amount=excluded.amount, medication_id=excluded.medication_id,
                  source_page=excluded.source_page, source_row_id=excluded.source_row_id, confirmed=excluded.confirmed,
                  created_at=excluded.created_at, updated_at=excluded.updated_at
                """
            for (headerId, lines) in Dictionary(grouping: prescriptionLineRows, by: \.prescriptionId) {
                let conflicting = prescriptionConflicts.contains(headerId.uuidString)
                if conflicting, resolution(headerId) == .keep { continue }
                let adopting = conflicting && resolution(headerId) == .adopt
                let header = (remap(headerId) ?? headerId).uuidString
                if adopting { try parkExistingLines(table: "prescription_line", parentColumn: "prescription_id", header: header) }
                for line in lines.sorted(by: { $0.ordinal < $1.ordinal }) {
                    let patient = patientID(line.patientId)
                    let medication = try restoredMedication(line.medicationId, patient: patient)
                    let identity: [DatabaseValueConvertible?] = [(remap(line.id) ?? line.id).uuidString, header, patient, line.ordinal, line.printedName]
                    let texts: [DatabaseValueConvertible?] = [line.genericName, line.brandName, line.drugForm, line.spec, line.doseText, line.doseUnit,
                        line.quantityText, line.quantityUnit, line.frequencyText, line.routeText, line.durationText]
                    let facts: [DatabaseValueConvertible?] = [line.startDate?.timeIntervalSince1970, line.endDate?.timeIntervalSince1970, line.asNeededText,
                        line.medicationNotes, line.note, line.rawText, line.insuranceCode, line.itemCodeText, line.unitPrice, line.amount, medication]
                    let provenance: [DatabaseValueConvertible?] = [line.sourcePage, line.sourceRowId?.uuidString, line.confirmed ? 1 : 0,
                        line.createdAt.timeIntervalSince1970, line.updatedAt.timeIntervalSince1970]
                    try db.execute(sql: """
                        INSERT INTO prescription_line (id, prescription_id, patient_id, ordinal, printed_name, generic_name, brand_name, drug_form, spec,
                          dose_text, dose_unit, quantity_text, quantity_unit, frequency_text, route_text, duration_text, start_date, end_date, as_needed_text,
                          medication_notes, note, raw_text, insurance_code, item_code_text, unit_price, amount, medication_id, source_page, source_row_id,
                          confirmed, created_at, updated_at)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        \(adopting ? prescriptionLineUpsert : "")
                        """, arguments: StatementArguments(identity + texts + facts + provenance))
                }
                if adopting {
                    try settleParkedLines(table: "prescription_line", parentColumn: "prescription_id", header: header, retainedBy: [
                        "SELECT prescription_line_id FROM stock_lot WHERE prescription_line_id IS NOT NULL",
                        "SELECT entity_id FROM ocr_card_commit WHERE entity_table = 'prescription_line'",
                    ])
                }
            }
            let claimConflicts = conflictSets["claim_item"] ?? []
            for claim in envelope.claims ?? [] {
                let target = remap(claim.id) ?? claim.id
                if claimConflicts.contains(claim.id.uuidString), resolution(claim.id) == .keep { continue }
                let head: [DatabaseValueConvertible?] = [target.uuidString, patientID(claim.patientId), remap(claim.encounterId)?.uuidString,
                    remap(claim.documentId)?.uuidString, claim.itemType, claim.amount, claim.currency, claim.date?.timeIntervalSince1970,
                    claim.merchant, claim.summary, claim.createdAt.timeIntervalSince1970, claim.updatedAt.timeIntervalSince1970]
                if legacyEnvelope {
                    // v1 包：原十列 upsert，v25 五列保持本机现值（新增行为 NULL）
                    try db.execute(sql: """
                        INSERT INTO claim_item (id, patient_id, encounter_id, document_file_id, item_type, amount, currency, date, merchant, summary, confirmed, created_at, updated_at)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?)
                        ON CONFLICT(id) DO UPDATE SET patient_id=excluded.patient_id, encounter_id=excluded.encounter_id,
                          document_file_id=excluded.document_file_id, item_type=excluded.item_type, amount=excluded.amount,
                          currency=excluded.currency, date=excluded.date, merchant=excluded.merchant, summary=excluded.summary,
                          confirmed=1, created_at=excluded.created_at, updated_at=excluded.updated_at
                        """, arguments: StatementArguments(head))
                    continue
                }
                // v25（§C.7）票面支付三分 / 票据号 / 医保类型
                let v25: [DatabaseValueConvertible?] = [claim.reimbursedAmount, claim.outOfPocket, claim.personalAccountAmount, claim.invoiceNo, claim.insuranceTypeText]
                try db.execute(sql: """
                    INSERT INTO claim_item (id, patient_id, encounter_id, document_file_id, item_type, amount, currency, date, merchant, summary, confirmed, created_at, updated_at,
                      reimbursed_amount, out_of_pocket, personal_account_amount, invoice_no, insurance_type_text)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET patient_id=excluded.patient_id, encounter_id=excluded.encounter_id,
                      document_file_id=excluded.document_file_id, item_type=excluded.item_type, amount=excluded.amount,
                      currency=excluded.currency, date=excluded.date, merchant=excluded.merchant, summary=excluded.summary,
                      confirmed=1, created_at=excluded.created_at, updated_at=excluded.updated_at,
                      reimbursed_amount=excluded.reimbursed_amount, out_of_pocket=excluded.out_of_pocket,
                      personal_account_amount=excluded.personal_account_amount, invoice_no=excluded.invoice_no, insurance_type_text=excluded.insurance_type_text
                    """, arguments: StatementArguments(head + v25))
            }
            // v25（§C.12 第 6 位）费用明细行：与处方行同一「行随表头裁决」纪律（claim_line 无 FK 引用；adopt 多余行只保留被本机回执指向者）。
            let claimLineUpsert = """
                ON CONFLICT(id) DO UPDATE SET claim_item_id=excluded.claim_item_id, patient_id=excluded.patient_id, ordinal=excluded.ordinal,
                  item_name=excluded.item_name, item_code_text=excluded.item_code_text, insurance_code=excluded.insurance_code, spec=excluded.spec,
                  unit_price=excluded.unit_price, quantity_text=excluded.quantity_text, quantity_unit=excluded.quantity_unit, amount=excluded.amount,
                  fee_category_text=excluded.fee_category_text, fee_at=excluded.fee_at, executing_dept=excluded.executing_dept,
                  self_pay_ratio_text=excluded.self_pay_ratio_text, raw_text=excluded.raw_text, source_page=excluded.source_page,
                  source_row_id=excluded.source_row_id, created_at=excluded.created_at
                """
            for (headerId, lines) in Dictionary(grouping: claimLineRows, by: \.claimItemId) {
                let conflicting = claimConflicts.contains(headerId.uuidString)
                if conflicting, resolution(headerId) == .keep { continue }
                let adopting = conflicting && resolution(headerId) == .adopt
                let header = (remap(headerId) ?? headerId).uuidString
                if adopting { try parkExistingLines(table: "claim_line", parentColumn: "claim_item_id", header: header) }
                for line in lines.sorted(by: { $0.ordinal < $1.ordinal }) {
                    let identity: [DatabaseValueConvertible?] = [(remap(line.id) ?? line.id).uuidString, header, patientID(line.patientId), line.ordinal, line.itemName]
                    let facts: [DatabaseValueConvertible?] = [line.itemCodeText, line.insuranceCode, line.spec, line.unitPrice, line.quantityText, line.quantityUnit,
                        line.amount, line.feeCategoryText, line.feeAt?.timeIntervalSince1970, line.executingDept, line.selfPayRatioText, line.rawText]
                    let provenance: [DatabaseValueConvertible?] = [line.sourcePage, line.sourceRowId?.uuidString, line.createdAt.timeIntervalSince1970]
                    try db.execute(sql: """
                        INSERT INTO claim_line (id, claim_item_id, patient_id, ordinal, item_name, item_code_text, insurance_code, spec, unit_price,
                          quantity_text, quantity_unit, amount, fee_category_text, fee_at, executing_dept, self_pay_ratio_text, raw_text,
                          source_page, source_row_id, created_at)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        \(adopting ? claimLineUpsert : "")
                        """, arguments: StatementArguments(identity + facts + provenance))
                }
                if adopting {
                    try settleParkedLines(table: "claim_line", parentColumn: "claim_item_id", header: header, retainedBy: [
                        "SELECT entity_id FROM ocr_card_commit WHERE entity_table = 'claim_line'",
                    ])
                }
            }
            // v26（§C.12 第 10 位）检查报告：独立裁决（keep / adopt 全列 / coexist 新 id）；就诊与文档已先落库。
            let examConflicts = conflictSets["exam_report"] ?? []
            for r in envelope.examReports ?? [] {
                let facts: [DatabaseValueConvertible?] = [
                    patientID(r.patientId), remap(r.encounterId)?.uuidString, remap(r.documentFileId)?.uuidString, r.reportType,
                    r.hospital, r.department, r.reportNo, r.examPart, r.examMethod,
                    r.examAt?.timeIntervalSince1970, r.reportedAt?.timeIntervalSince1970, r.findings, r.impression,
                    r.applyDoctor, r.reportDoctor, r.reviewDoctor, r.source.rawValue, r.confirmed ? 1 : 0,
                    r.createdAt.timeIntervalSince1970, r.updatedAt.timeIntervalSince1970,
                ]
                if try adoptOrSkip(examConflicts, r.id, adopt: {
                    try db.execute(sql: """
                        UPDATE exam_report SET patient_id = ?, encounter_id = ?, document_file_id = ?, report_type = ?,
                          hospital = ?, department = ?, report_no = ?, exam_part = ?, exam_method = ?, exam_at = ?, reported_at = ?,
                          findings = ?, impression = ?, apply_doctor = ?, report_doctor = ?, review_doctor = ?,
                          source = ?, confirmed = ?, created_at = ?, updated_at = ?
                        WHERE id = ?
                        """, arguments: StatementArguments(facts + [r.id.uuidString]))
                }) { continue }
                try db.execute(sql: """
                    INSERT INTO exam_report (id, patient_id, encounter_id, document_file_id, report_type, hospital, department, report_no, exam_part, exam_method,
                      exam_at, reported_at, findings, impression, apply_doctor, report_doctor, review_doctor, source, confirmed, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: StatementArguments([(remap(r.id) ?? r.id).uuidString] + facts))
            }
            // 回执末位落库（§C.12）：entity_table 沿 JSON 值（旧包缺省 = cardKind，insertReceipt 同口径），
            // entity_id 经同一 idMap 重写——表头回执指表头、行回执指行（行 id 已随表头 coexist 一并重写）。
            let auditMap = Dictionary(uniqueKeysWithValues: existingAudits.map { ("\($0.cardId.uuidString)/\($0.rowId.uuidString)", $0) })
            for original in envelope.ocrCardCommits ?? [] {
                if receiptKept(original) { continue }
                var audit = original
                audit.cardId = cardMap[original.cardId] ?? original.cardId
                audit.patientId = remap(original.patientId) ?? original.patientId
                audit.documentId = remap(original.documentId) ?? original.documentId
                audit.entityId = remap(original.entityId) ?? original.entityId
                audit.encounterId = remap(original.encounterId)
                if let existing = auditMap["\(audit.cardId.uuidString)/\(audit.rowId.uuidString)"] {
                    var immutable = existing
                    immutable.encounterId = audit.encounterId
                    guard immutable == audit else { throw ExportError.invalidOCRBackup }
                    if existing.encounterId != audit.encounterId {
                        let governor = receiptGovernor(original)
                        guard conflictSets[governor.table, default: []].contains(governor.header.uuidString),
                              resolution(governor.header) == .adopt else { throw ExportError.invalidOCRBackup }
                        try db.execute(sql: "UPDATE ocr_card_commit SET encounter_id = ? WHERE card_id = ? AND row_id = ? AND patient_id = ?",
                            arguments: [audit.encounterId?.uuidString, audit.cardId.uuidString, audit.rowId.uuidString, audit.patientId.uuidString])
                    }
                    continue
                }
                try OCRCardStore.insertReceipt(audit, db: db)
            }
            func archiveRestoredAlert(_ id: UUID) throws {
                try db.execute(sql: """
                    INSERT INTO notification_state (item_key, kind, archived_at) VALUES (?, 'notification', ?)
                    ON CONFLICT(item_key) DO UPDATE SET archived_at = excluded.archived_at
                    """, arguments: ["alert-\(id.uuidString)", Date().timeIntervalSince1970])
            }
            for a in envelope.alertEvents ?? [] {
                // History must not re-enter HealthKitSyncService's pending/deferred retry query.
                // "restored" claims neither delivery nor a new scheduled_at timestamp.
                let deliveredState = a.deliveredState == "pending" || a.deliveredState == "deferred"
                    ? "restored" : a.deliveredState
                if try adoptOrSkip(alertConflicts, a.id, adopt: {
                    try db.execute(sql: """
                        UPDATE alert_event SET patient_id = ?, rule_id = ?, severity = ?, evidence_json = ?,
                          qualified = ?, scheduled_at = ?, delivered_state = ?, created_at = ?
                        WHERE id = ?
                        """, arguments: [patientID(a.patientId), a.ruleId, a.severity, a.evidenceJson,
                                         (a.qualified ?? false) ? 1 : 0, a.scheduledAt?.timeIntervalSince1970,
                                         deliveredState, a.createdAt.timeIntervalSince1970, a.id.uuidString])
                    try archiveRestoredAlert(a.id)
                }) { continue }
                try db.execute(sql: """
                    INSERT INTO alert_event
                      (id, patient_id, rule_id, severity, evidence_json, qualified, scheduled_at, delivered_state, created_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [(remap(a.id) ?? a.id).uuidString, patientID(a.patientId), a.ruleId,
                                     a.severity, a.evidenceJson, (a.qualified ?? false) ? 1 : 0,
                                     a.scheduledAt?.timeIntervalSince1970, deliveredState, a.createdAt.timeIntervalSince1970])
                try archiveRestoredAlert(remap(a.id) ?? a.id)
            }
            if envelope.owner != nil || envelope.metrics.contains(where: { $0.origin == "device" }) {
                // Restoring facts invalidates local checkpoints and in-flight binding tokens, not read permissions.
                try db.execute(sql: "DELETE FROM hk_sample_index; DELETE FROM hk_sync_anchor; DELETE FROM hk_import_binding;")
            }
            for i in envelope.immunizations {
                if try adoptOrSkip(immConflicts, i.id, adopt: {
                    // 审查修复（ADR-019 采纳语义）：旧 UPDATE 只改 3 列，备份的
                    // 批号/剂次（追溯核心）与提供者等被静默丢弃，恢复后记录是
                    // 本地+备份的混合态——与其余各表全列采纳口径不一致
                    // 审查修复（全列 UPDATE 的 NULL 与降级陷阱）：旧备份缺
                    // source/confirmed 键时——source 直绑 NULL 违反 NOT NULL
                    // 令整个恢复事务回滚；confirmed 落 0 把本地已确认记录
                    // 静默降级。source 与 INSERT 同口径回落 'manual'；
                    // confirmed 缺失时 COALESCE 保留本地现值（不降级）。
                    try db.execute(sql: """
                        UPDATE immunization SET patient_id = ?, vaccine_name = ?, dose_number = ?,
                          administered_at = ?, provider = ?, lot_number = ?, encounter_id = ?,
                          source = COALESCE(?, 'manual'), confirmed = COALESCE(?, confirmed),
                          adverse_reaction_id = ?
                        WHERE id = ?
                        """, arguments: [patientID(i.patientId), i.vaccineName,
                                         i.doseNumber, i.administeredAt.timeIntervalSince1970,
                                          i.provider, i.lotNumber, remap(i.encounterId)?.uuidString,
                                         i.source, (i.confirmed).map { $0 ? 1 : 0 },
                                          remap(i.adverseReactionId)?.uuidString,
                                         i.id.uuidString])
                }) { continue }
                try db.execute(sql: """
                    INSERT INTO immunization (id, patient_id, vaccine_name, dose_number, administered_at,
                                              provider, lot_number, encounter_id, source, confirmed,
                                              adverse_reaction_id, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [(remap(i.id) ?? i.id).uuidString, patientID(i.patientId), i.vaccineName,
                                     i.doseNumber, i.administeredAt.timeIntervalSince1970,
                                      i.provider, i.lotNumber, remap(i.encounterId)?.uuidString,
                                     i.source ?? "manual", (i.confirmed ?? false) ? 1 : 0,
                                      remap(i.adverseReactionId)?.uuidString,
                                     i.administeredAt.timeIntervalSince1970, i.administeredAt.timeIntervalSince1970])
            }
            for v in envelope.voiceNotes {
                if try adoptOrSkip(noteConflicts, v.id, adopt: {
                    let tagsJSON = String(data: (try JSONEncoder().encode(v.tags)), encoding: .utf8) ?? "[]"
                    try db.execute(sql: """
                        UPDATE voice_note SET patient_id = ?, body = ?, occurred_at = ?, tags = ?, in_timeline = ?
                        WHERE id = ?
                        """, arguments: [(remap(v.patientId) ?? v.patientId)?.uuidString ?? "", v.body,
                                         v.occurredAt.timeIntervalSince1970, tagsJSON, v.inTimeline ? 1 : 0, v.id.uuidString])
                }) { continue }
                let tagsJSON = String(data: (try JSONEncoder().encode(v.tags)), encoding: .utf8) ?? "[]"
                try db.execute(sql: """
                    INSERT INTO voice_note (id, patient_id, body, occurred_at, tags, in_timeline, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [(remap(v.id) ?? v.id).uuidString, patientID(v.patientId), v.body,
                                     v.occurredAt.timeIntervalSince1970, tagsJSON, v.inTimeline ? 1 : 0,
                                     v.occurredAt.timeIntervalSince1970, v.occurredAt.timeIntervalSince1970])
            }
            // 敏感标记回写（BR-007/008 链必须随往返保持）
            // 第六轮全仓审查修复：keep 裁决的行绝不触碰（ADR-019）——原实现
            // 无条件回写 is_sensitive=1，用户「保留本机」且本机已解除敏感
            // 标记的行被备份值反改回敏感（与 docEncounterLinks 同族残根）
            for docId in envelope.sensitiveDocIds {
                if timelineConflicts.contains(docId.uuidString), resolution(docId) == .keep {
                    continue
                }
                try db.execute(sql: "UPDATE document_file SET is_sensitive = 1 WHERE id = ?",
                               arguments: [(remap(docId) ?? docId).uuidString])
            }
            for h in envelope.healthProblems {
                if try adoptOrSkip(problemConflicts, h.id, adopt: {
                    try db.execute(sql: """
                        UPDATE health_problem SET patient_id = ?, name = ?, kind = ?, archived = ?, created_at = ?
                        WHERE id = ?
                        """, arguments: [(remap(h.patientId) ?? h.patientId)?.uuidString ?? "", h.name,
                                         h.kind, h.archived ? 1 : 0,
                                         h.createdAt.timeIntervalSince1970, h.id.uuidString])
                }) { continue }
                try db.execute(sql: """
                    INSERT INTO health_problem (id, patient_id, name, kind, archived, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [(remap(h.id) ?? h.id).uuidString, patientID(h.patientId), h.name,
                                      h.kind, h.archived ? 1 : 0,
                                      h.createdAt.timeIntervalSince1970, h.createdAt.timeIntervalSince1970])
            }
            // v26（§C.12 第 11 位）诊断：置于 health_problem 之后（health_problem_id 外键）；独立裁决；回执已落，末位校验兜底。
            let diagnosisConflicts = conflictSets["diagnosis"] ?? []
            for d in envelope.diagnoses ?? [] {
                let facts: [DatabaseValueConvertible?] = [
                    patientID(d.patientId), remap(d.encounterId)?.uuidString, d.ordinal, d.diagnosisType, d.name, d.codeText, d.codeSystemText,
                    d.diagnosedAt?.timeIntervalSince1970, remap(d.healthProblemId)?.uuidString, d.note, d.sourcePage, d.sourceRowId?.uuidString,
                    remap(d.documentFileId)?.uuidString, d.confirmed ? 1 : 0, d.createdAt.timeIntervalSince1970, d.updatedAt.timeIntervalSince1970,
                ]
                if try adoptOrSkip(diagnosisConflicts, d.id, adopt: {
                    try db.execute(sql: """
                        UPDATE diagnosis SET patient_id = ?, encounter_id = ?, ordinal = ?, diagnosis_type = ?, name = ?, code_text = ?, code_system_text = ?,
                          diagnosed_at = ?, health_problem_id = ?, note = ?, source_page = ?, source_row_id = ?, document_file_id = ?,
                          confirmed = ?, created_at = ?, updated_at = ?
                        WHERE id = ?
                        """, arguments: StatementArguments(facts + [d.id.uuidString]))
                }) { continue }
                try db.execute(sql: """
                    INSERT INTO diagnosis (id, patient_id, encounter_id, ordinal, diagnosis_type, name, code_text, code_system_text, diagnosed_at,
                      health_problem_id, note, source_page, source_row_id, document_file_id, confirmed, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: StatementArguments([(remap(d.id) ?? d.id).uuidString] + facts))
            }
            try Self.validateOCRGraph(db)
        }
    }

    /// 审查修复：ADR-019 冲突显式错误——UI 据此呈现「目标设备已有数据」，
    /// 不再把合法备份误报为「校验失败」。
    public enum ExportError: Error, Sendable, Equatable {
        case conflict(table: String, id: String)
        case invalidOCRBackup
    }

    private static func reviewCardIDs(_ metadata: String?) throws -> [UUID] {
        guard let metadata else { return [] }
        guard let object = try JSONSerialization.jsonObject(with: Data(metadata.utf8)) as? [String: Any] else {
            throw ExportError.invalidOCRBackup
        }
        guard let value = object["ocr_review"] else { return [] }
        guard let json = value as? String,
              let review = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let cards = review["cards"] as? [[String: Any]] else { throw ExportError.invalidOCRBackup }
        let ids = try cards.map { card -> UUID in
            guard let id = (card["id"] as? String).flatMap(UUID.init(uuidString:)) else { throw ExportError.invalidOCRBackup }
            return id
        }
        guard Set(ids).count == ids.count else { throw ExportError.invalidOCRBackup }
        return ids
    }

    private static func remapReviewMetadata(_ metadata: String?, cardMap: [UUID: UUID], entityMap: [UUID: UUID]) throws -> String? {
        guard let metadata, !cardMap.isEmpty || !entityMap.isEmpty else { return metadata }
        let ids = try reviewCardIDs(metadata)
        guard !ids.isEmpty else { return metadata }
        guard var object = try JSONSerialization.jsonObject(with: Data(metadata.utf8)) as? [String: Any],
              let json = object["ocr_review"] as? String,
              var review = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              var cards = review["cards"] as? [[String: Any]] else { throw ExportError.invalidOCRBackup }
        for index in cards.indices {
            if let remapped = cardMap[ids[index]] { cards[index]["id"] = remapped.uuidString }
            // 草稿关系不是已确认事实：恢复时重新提建议，不保留指向旧成员/旧就诊的选择。
            if cards[index]["encounterAssociation"] != nil {
                cards[index]["encounterAssociation"] = ["unselected": [String: String]()]
            }
        }
        review["cards"] = cards
        object["ocr_review"] = String(decoding: try JSONSerialization.data(withJSONObject: review, options: [.sortedKeys]), as: UTF8.self)
        return String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    private static func documentReference(_ ref: String) throws -> (UUID, Int?) {
        let parts = String(ref.dropFirst(4)).components(separatedBy: "#p")
        guard parts.count == 1 || parts.count == 2, let document = UUID(uuidString: parts[0]) else { throw ExportError.invalidOCRBackup }
        if parts.count == 1 { return (document, nil) }
        guard let page = Int(parts[1]), page >= 0, String(page) == parts[1] else { throw ExportError.invalidOCRBackup }
        return (document, page)
    }

    private static func validateOCRBackup(_ envelope: Envelope) throws {
        let documents = envelope.documents ?? []
        let ids = documents.map(\.id) + envelope.timeline.map(\.id)
        guard Set(ids).count == ids.count else { throw ExportError.invalidOCRBackup }
        for document in documents {
            let pages = document.pages ?? []
            guard document.createdAt.timeIntervalSince1970.isFinite, document.updatedAt.timeIntervalSince1970.isFinite,
                  Set(pages.map(\.index)).count == pages.count,
                  pages.allSatisfy({ $0.index >= 0 && ["ok", "failed", "skipped"].contains($0.status) }) else {
                throw ExportError.invalidOCRBackup
            }
        }
        let prescriptions = envelope.ocrPrescriptions ?? [], details = envelope.ocrEncounterDetails ?? []
        guard Set(prescriptions.map(\.id)).count == prescriptions.count,
              Set(details.map(\.id)).count == details.count,
              Set(envelope.metrics.map(\.id)).count == envelope.metrics.count,
              Set(envelope.encounters.map(\.id)).count == envelope.encounters.count else { throw ExportError.invalidOCRBackup }
        let docs = Dictionary(uniqueKeysWithValues: documents.map { ($0.id, $0) })
        let metrics = Dictionary(uniqueKeysWithValues: envelope.metrics.map { ($0.id, $0) })
        let encounters = Dictionary(uniqueKeysWithValues: envelope.encounters.map { ($0.id, $0) })
        let rx = Dictionary(uniqueKeysWithValues: prescriptions.map { ($0.id, $0) })
        let detailIds = Set(details.map(\.id))
        let medications = envelope.ocrMedications ?? [], claims = envelope.claims ?? []
        guard Set(medications.map(\.id)).count == medications.count, Set(claims.map(\.id)).count == claims.count else { throw ExportError.invalidOCRBackup }
        let medicationMap = Dictionary(uniqueKeysWithValues: medications.map { ($0.id, $0) })
        let claimMap = Dictionary(uniqueKeysWithValues: claims.map { ($0.id, $0) })
        for medication in medications {
            guard !medication.genericName.isEmpty, ["tablet", "capsule", "patch", "vial"].contains(medication.unitKind),
                  medication.createdAt.timeIntervalSince1970.isFinite, medication.updatedAt.timeIntervalSince1970.isFinite else { throw ExportError.invalidOCRBackup }
        }
        for claim in claims {
            guard claim.amount?.isFinite != false, claim.date?.timeIntervalSince1970.isFinite != false,
                  ["invoice", "fee", "receipt"].contains(claim.itemType),
                  claim.reimbursedAmount?.isFinite != false, claim.outOfPocket?.isFinite != false, claim.personalAccountAmount?.isFinite != false,
                  claim.encounterId == nil || encounters[claim.encounterId!]?.patientId == claim.patientId,
                  claim.documentId == nil || docs[claim.documentId!]?.patientId == claim.patientId else { throw ExportError.invalidOCRBackup }
        }
        // v25（§C.10）文档稳定键列：title_source 走 DDL CHECK 同枚举（在包内先拒，不让 CHECK 失败整包回滚）
        for document in documents where document.titleSource != nil {
            guard ["user", "suggested", "filename", "none"].contains(document.titleSource!) else { throw ExportError.invalidOCRBackup }
        }
        // v25（§C.6/§C.7）行实体：行必须挂在包内表头且与表头同成员（跨成员行拒收）；UNIQUE(表头, ordinal) 在包内即成立；
        // 行数组缺失（v1 包）= 无行，绝不从 advice_text 猜回（BR-003）。
        let prescriptionLines = envelope.prescriptionLines ?? [], claimLines = envelope.claimLines ?? []
        guard Set(prescriptionLines.map(\.id)).count == prescriptionLines.count,
              Set(claimLines.map(\.id)).count == claimLines.count else { throw ExportError.invalidOCRBackup }
        let rxLineMap = Dictionary(uniqueKeysWithValues: prescriptionLines.map { ($0.id, $0) })
        let claimLineMap = Dictionary(uniqueKeysWithValues: claimLines.map { ($0.id, $0) })
        var rxOrdinals = Set<String>(), claimOrdinals = Set<String>()
        for line in prescriptionLines {
            guard let header = rx[line.prescriptionId], header.patientId == line.patientId, !line.printedName.isEmpty,
                  rxOrdinals.insert("\(line.prescriptionId.uuidString)/\(line.ordinal)").inserted, (line.sourcePage ?? 0) >= 0,
                  line.startDate?.timeIntervalSince1970.isFinite != false, line.endDate?.timeIntervalSince1970.isFinite != false,
                  line.unitPrice?.isFinite != false, line.amount?.isFinite != false,
                  line.createdAt.timeIntervalSince1970.isFinite, line.updatedAt.timeIntervalSince1970.isFinite else { throw ExportError.invalidOCRBackup }
        }
        for line in claimLines {
            guard let header = claimMap[line.claimItemId], header.patientId == line.patientId, !line.itemName.isEmpty,
                  claimOrdinals.insert("\(line.claimItemId.uuidString)/\(line.ordinal)").inserted, (line.sourcePage ?? 0) >= 0,
                  line.unitPrice?.isFinite != false, line.amount?.isFinite != false, line.feeAt?.timeIntervalSince1970.isFinite != false,
                  line.createdAt.timeIntervalSince1970.isFinite else { throw ExportError.invalidOCRBackup }
        }
        // v26（§C.2–§C.5）五表：主键唯一；父键（就诊 / 文档 / 表头 / 健康问题）须在包内且同成员；枚举走 DDL CHECK 同集合；
        // 数值有限；lab_result UNIQUE(lab_report_id, ordinal) 在包内即成立；metric_sample.labReportId 回指同成员表头。
        let hospitalizations = envelope.hospitalizations ?? [], diagnoses = envelope.diagnoses ?? [], examReports = envelope.examReports ?? []
        let labReports = envelope.labReports ?? [], labResults = envelope.labResults ?? []
        guard Set(hospitalizations.map(\.id)).count == hospitalizations.count, Set(diagnoses.map(\.id)).count == diagnoses.count,
              Set(examReports.map(\.id)).count == examReports.count, Set(labReports.map(\.id)).count == labReports.count,
              Set(labResults.map(\.id)).count == labResults.count,
              Set(hospitalizations.map(\.encounterId)).count == hospitalizations.count,
              Set(labReports.compactMap(\.sourceCardId)).count == labReports.compactMap(\.sourceCardId).count else { throw ExportError.invalidOCRBackup }
        let hospitalizationMap = Dictionary(uniqueKeysWithValues: hospitalizations.map { ($0.id, $0) })
        let diagnosisMap = Dictionary(uniqueKeysWithValues: diagnoses.map { ($0.id, $0) })
        let examMap = Dictionary(uniqueKeysWithValues: examReports.map { ($0.id, $0) })
        let labReportMap = Dictionary(uniqueKeysWithValues: labReports.map { ($0.id, $0) })
        let labResultMap = Dictionary(uniqueKeysWithValues: labResults.map { ($0.id, $0) })
        let problemMap = Dictionary(envelope.healthProblems.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func finite(_ value: Double?) -> Bool { value?.isFinite != false }
        func finite(_ date: Date?) -> Bool { date?.timeIntervalSince1970.isFinite != false }
        for h in hospitalizations {
            guard encounters[h.encounterId]?.patientId == h.patientId,
                  h.documentFileId == nil || docs[h.documentFileId!]?.patientId == h.patientId,
                  finite(h.admitAt), finite(h.dischargeAt), finite(h.summaryDate), finite(h.totalCost),
                  h.createdAt.timeIntervalSince1970.isFinite, h.updatedAt.timeIntervalSince1970.isFinite else { throw ExportError.invalidOCRBackup }
        }
        for d in diagnoses {
            guard Diagnosis.diagnosisTypes.contains(d.diagnosisType), !d.name.isEmpty,
                  d.encounterId == nil || encounters[d.encounterId!]?.patientId == d.patientId,
                  d.documentFileId == nil || docs[d.documentFileId!]?.patientId == d.patientId,
                  d.healthProblemId == nil || problemMap[d.healthProblemId!]?.patientId == d.patientId,
                  finite(d.diagnosedAt), (d.sourcePage ?? 0) >= 0,
                  d.createdAt.timeIntervalSince1970.isFinite, d.updatedAt.timeIntervalSince1970.isFinite else { throw ExportError.invalidOCRBackup }
        }
        for r in examReports {
            guard ExamReport.reportTypes.contains(r.reportType),
                  r.encounterId == nil || encounters[r.encounterId!]?.patientId == r.patientId,
                  r.documentFileId == nil || docs[r.documentFileId!]?.patientId == r.patientId,
                  finite(r.examAt), finite(r.reportedAt),
                  r.createdAt.timeIntervalSince1970.isFinite, r.updatedAt.timeIntervalSince1970.isFinite else { throw ExportError.invalidOCRBackup }
        }
        for r in labReports {
            guard r.encounterId == nil || encounters[r.encounterId!]?.patientId == r.patientId,
                  r.documentFileId == nil || docs[r.documentFileId!]?.patientId == r.patientId,
                  finite(r.collectedAt), finite(r.receivedAt), finite(r.reportedAt),
                  r.createdAt.timeIntervalSince1970.isFinite, r.updatedAt.timeIntervalSince1970.isFinite else { throw ExportError.invalidOCRBackup }
        }
        var labOrdinals = Set<String>()
        for row in labResults {
            guard let header = labReportMap[row.labReportId], header.patientId == row.patientId, !row.itemName.isEmpty, !row.resultText.isEmpty,
                  labOrdinals.insert("\(row.labReportId.uuidString)/\(row.ordinal)").inserted, (row.sourcePage ?? 0) >= 0,
                  row.createdAt.timeIntervalSince1970.isFinite else { throw ExportError.invalidOCRBackup }
        }
        for metric in envelope.metrics where metric.labReportId != nil {
            guard labReportMap[metric.labReportId!]?.patientId == metric.patientId else { throw ExportError.invalidOCRBackup }
        }
        /// 回执所指表头：表头回执 = entity_id；行回执经包内行数组回到表头（行缺失 → nil → 拒收）。
        func headerEntity(of audit: OCRCardStore.AuditRecord) -> UUID? {
            switch audit.entityTable ?? audit.cardKind {
            case "prescription_line": return rxLineMap[audit.entityId]?.prescriptionId
            case "claim_line": return claimLineMap[audit.entityId]?.claimItemId
            case "lab_result": return labResultMap[audit.entityId]?.labReportId
            default: return audit.entityId
            }
        }
        var keys = Set<String>()
        var cards: [UUID: OCRCardStore.AuditRecord] = [:]
        for audit in envelope.ocrCardCommits ?? [] {
            // entity_table 缺省 = cardKind（旧回执）；必须是该卡类注册的事实表（insertReceipt 同口径，在包内先拒）
            let table = audit.entityTable ?? audit.cardKind
            guard keys.insert("\(audit.cardId.uuidString)/\(audit.rowId.uuidString)").inserted,
                  OCRCardStore.supportedKinds.contains(audit.cardKind), audit.pageIndex >= 0,
                  CardKindRegistry.entry(for: audit.cardKind)?.entityTables.contains(table) == true,
                  audit.recordedAt.timeIntervalSince1970.isFinite,
                  (audit.shared + audit.fields).allSatisfy(\.isConfirmed),
                  let document = docs[audit.documentId], document.patientId == audit.patientId,
                  document.pages?.contains(where: { $0.index == audit.pageIndex && $0.status == "ok" }) == true,
                  let header = headerEntity(of: audit) else {
                throw ExportError.invalidOCRBackup
            }
            if let other = cards[audit.cardId] {
                // 有行实体的卡类（处方/费用）：一张卡的表头回执 + N 条行回执必须回到同一表头
                guard other.patientId == audit.patientId, other.documentId == audit.documentId,
                      other.pageIndex == audit.pageIndex, other.cardKind == audit.cardKind, other.shared == audit.shared,
                      OCRCardStore.lineTable(for: audit.cardKind) == nil || headerEntity(of: other) == header else { throw ExportError.invalidOCRBackup }
            }
            cards[audit.cardId] = audit
            if let encounterId = audit.encounterId, encounters[encounterId]?.patientId != audit.patientId { throw ExportError.invalidOCRBackup }
            switch table {
            case "metric_sample":
                guard let sample = metrics[audit.entityId], sample.patientId == audit.patientId,
                      sample.origin == "hospital", sample.sourceRef == HospitalSample.sourceRef(documentId: audit.documentId, pageIndex: audit.pageIndex),
                      // v26：回指的表头须同成员、同来源文档（validateReceipt 同口径）
                      sample.labReportId == nil || labReportMap[sample.labReportId!]?.documentFileId == audit.documentId else {
                    throw ExportError.invalidOCRBackup
                }
            case "lab_result":
                // 定性行随其表头：表头 = 本卡的 lab_report（source_card_id = card_id）、同成员、同来源文档、已确认
                guard let row = labResultMap[audit.entityId], row.patientId == audit.patientId,
                      let report = labReportMap[row.labReportId], report.patientId == audit.patientId, report.confirmed,
                      report.documentFileId == audit.documentId, report.sourceCardId == audit.cardId else { throw ExportError.invalidOCRBackup }
            case "lab_report":
                guard let report = labReportMap[audit.entityId], report.patientId == audit.patientId, report.confirmed,
                      report.documentFileId == audit.documentId else { throw ExportError.invalidOCRBackup }
            case "hospitalization":
                // 住院期可由多份原件补空（document_file_id 保留首份）：只校验同成员、已确认、其就诊在包内且同成员
                guard let h = hospitalizationMap[audit.entityId], h.patientId == audit.patientId, h.confirmed, h.source == .ocr,
                      encounters[h.encounterId]?.patientId == audit.patientId else { throw ExportError.invalidOCRBackup }
            case "diagnosis":
                guard let d = diagnosisMap[audit.entityId], d.patientId == audit.patientId, d.confirmed,
                      d.documentFileId == audit.documentId else { throw ExportError.invalidOCRBackup }
            case "exam_report":
                guard let r = examMap[audit.entityId], r.patientId == audit.patientId, r.confirmed, r.source == .ocr,
                      r.documentFileId == audit.documentId else { throw ExportError.invalidOCRBackup }
            case "encounter":
                guard encounters[audit.entityId]?.patientId == audit.patientId, detailIds.contains(audit.entityId) else { throw ExportError.invalidOCRBackup }
            case "prescription", "prescription_line":
                // 表头（经行回到的表头亦然）：同成员、同来源文档、有处方日期；被回执引用的处方必须 source = 'ocr'
                //（手工/电子处方自 v2 起随包，但不得挂 OCR 回执）；行回执的行自身亦须与回执同成员。
                guard let prescription = rx[header], prescription.patientId == audit.patientId,
                      table == "prescription" || rxLineMap[audit.entityId]?.patientId == audit.patientId,
                      prescription.documentId == audit.documentId, prescription.prescribedAt != nil,
                      prescription.source == PrescriptionSource.ocr.rawValue else { throw ExportError.invalidOCRBackup }
            case "medication":
                guard medicationMap[audit.entityId]?.patientId == audit.patientId else { throw ExportError.invalidOCRBackup }
            case "claim_item", "claim_line":
                guard let claim = claimMap[header], claim.patientId == audit.patientId,
                      table == "claim_item" || claimLineMap[audit.entityId]?.patientId == audit.patientId,
                      claim.documentId == audit.documentId else { throw ExportError.invalidOCRBackup }
            case "immunization":
                guard envelope.immunizations.contains(where: { $0.id == audit.entityId && $0.patientId == audit.patientId && $0.confirmed == true }) else { throw ExportError.invalidOCRBackup }
            default: throw ExportError.invalidOCRBackup
            }
        }
        let sourcedEncounters = Set((envelope.ocrCardCommits ?? []).filter { $0.cardKind == "encounter" }.map(\.entityId))
        guard details.allSatisfy({ encounters[$0.id] != nil && sourcedEncounters.contains($0.id) }) else { throw ExportError.invalidOCRBackup }
        // v2 起处方数组含全部来源（source 走 Domain 枚举、prescription_type 走 CHECK 同枚举）；OCR 约束只对被回执引用的处方（上方逐回执校验）
        for prescription in prescriptions {
            guard PrescriptionSource(rawValue: prescription.source) != nil,
                  prescription.prescribedAt?.timeIntervalSince1970.isFinite != false,
                  prescription.prescriptionType == nil || EntityCardProjection.prescriptionTypes.contains(prescription.prescriptionType!),
                  prescription.totalAmount?.isFinite != false,
                  prescription.createdAt.timeIntervalSince1970.isFinite, prescription.updatedAt.timeIntervalSince1970.isFinite else {
                throw ExportError.invalidOCRBackup
            }
        }
        // 就诊全列（v25）：数值列有限；改期前驱须在包内且同成员（自引用 FK 回填前先拒）
        for encounter in envelope.encounters {
            guard encounter.feeAmount?.isFinite != false,
                  encounter.createdAt?.timeIntervalSince1970.isFinite != false, encounter.updatedAt?.timeIntervalSince1970.isFinite != false,
                  encounter.rescheduledFromId == nil || encounters[encounter.rescheduledFromId!]?.patientId == encounter.patientId else {
                throw ExportError.invalidOCRBackup
            }
        }
        for metric in envelope.metrics where metric.sourceRef?.hasPrefix("doc:") == true {
            _ = try documentReference(metric.sourceRef!)
            guard metric.value.isFinite, metric.measuredAt.timeIntervalSince1970.isFinite,
                  metric.refLow?.isFinite != false, metric.refHigh?.isFinite != false else { throw ExportError.invalidOCRBackup }
            if let low = metric.refLow, let high = metric.refHigh, low > high { throw ExportError.invalidOCRBackup }
        }
    }

    private static func ocrPages(_ document: UUID, db: Database) throws -> [Envelope.PageExport] {
        try Row.fetchAll(db, sql: "SELECT page_index, ocr_text, status FROM document_page WHERE document_file_id = ? ORDER BY page_index",
                         arguments: [document.uuidString]).map { .init(index: $0["page_index"], text: $0["ocr_text"], status: $0["status"]) }
    }

    private static func restoreOCRPages(_ document: Envelope.DocumentExport, targetId: UUID,
                                       replacing: Bool, db: Database) throws {
        let incoming = (document.pages ?? []).sorted { $0.index < $1.index }
        if replacing {
            let oldPages = try ocrPages(targetId, db: db)
            let old = try Row.fetchOne(db, sql: "SELECT patient_id, sha256, ocr_text FROM document_file WHERE id = ?", arguments: [targetId.uuidString])
            let sourceChanged = oldPages != incoming || (old?["sha256"] as String?) != document.sha256
                || (old?["ocr_text"] as String?) != document.ocrText
            let retained = try MemberDeletionService.hasRetainedOCRLinks(documentId: targetId, db: db)
                || (Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ocr_result WHERE document_file_id = ?", arguments: [targetId.uuidString]) ?? 0) > 0
            if sourceChanged && retained { throw ExportError.invalidOCRBackup }
            if oldPages == incoming { return }
            try db.execute(sql: "DELETE FROM document_page WHERE document_file_id = ?", arguments: [targetId.uuidString])
        }
        for page in incoming {
            try db.execute(sql: """
                INSERT INTO document_page (id, document_file_id, page_index, ocr_text, status, created_at) VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [UUID().uuidString, targetId.uuidString, page.index, page.text, page.status, document.createdAt.timeIntervalSince1970])
        }
    }

    private static func validateOCRGraph(_ db: Database) throws {
        for row in try Row.fetchAll(db, sql: "SELECT patient_id, source_ref, metric_key, code_concept_id FROM metric_sample WHERE source_ref LIKE 'doc:%'") {
            let (document, page) = try documentReference(row["source_ref"])
            guard try String.fetchOne(db, sql: "SELECT patient_id FROM document_file WHERE id = ?", arguments: [document.uuidString]) == (row["patient_id"] as String) else {
                throw ExportError.invalidOCRBackup
            }
            if let page {
                guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM document_page WHERE document_file_id = ? AND page_index = ? AND status = 'ok'",
                                       arguments: [document.uuidString, page]) == 1 else { throw ExportError.invalidOCRBackup }
            }
            if (row["metric_key"] as String).hasPrefix("code.") {
                guard let concept = row["code_concept_id"] as String?,
                      let code = try Row.fetchOne(db, sql: "SELECT canonical_code, kind FROM code_concept WHERE id = ?", arguments: [concept]),
                      (code["kind"] as String) == "metric", (row["metric_key"] as String) == "code.\(code["canonical_code"] as String)" else {
                    throw ExportError.invalidOCRBackup
                }
            }
        }
        let mismatched = try Int.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM pending_card p JOIN document_file d ON d.id = p.source_doc_id
              WHERE p.patient_id != d.patient_id OR (p.source_page IS NOT NULL AND NOT EXISTS
                (SELECT 1 FROM document_page page WHERE page.document_file_id = d.id AND page.page_index = p.source_page)))
              OR EXISTS(SELECT 1 FROM prescription p JOIN document_file d ON d.id = p.document_file_id WHERE p.patient_id != d.patient_id)
              OR EXISTS(SELECT 1 FROM document_file d JOIN encounter e ON e.id = d.encounter_id WHERE d.patient_id != e.patient_id)
              OR EXISTS(SELECT 1 FROM prescription p JOIN encounter e ON e.id = p.encounter_id WHERE p.patient_id != e.patient_id)
              OR EXISTS(SELECT 1 FROM claim_item c JOIN encounter e ON e.id = c.encounter_id WHERE c.patient_id != e.patient_id)
              OR EXISTS(SELECT 1 FROM claim_item c JOIN document_file d ON d.id = c.document_file_id WHERE c.patient_id != d.patient_id)
              OR EXISTS(SELECT 1 FROM immunization i JOIN encounter e ON e.id = i.encounter_id WHERE i.patient_id != e.patient_id)
              OR EXISTS(SELECT 1 FROM prescription_line l JOIN prescription p ON p.id = l.prescription_id WHERE l.patient_id != p.patient_id)
              OR EXISTS(SELECT 1 FROM prescription_line l JOIN medication m ON m.id = l.medication_id WHERE l.patient_id != m.patient_id)
              OR EXISTS(SELECT 1 FROM stock_lot s JOIN prescription_line l ON l.id = s.prescription_line_id WHERE s.patient_id != l.patient_id)
              OR EXISTS(SELECT 1 FROM claim_line l JOIN claim_item c ON c.id = l.claim_item_id WHERE l.patient_id != c.patient_id)
              OR EXISTS(SELECT 1 FROM hospitalization h JOIN encounter e ON e.id = h.encounter_id WHERE h.patient_id != e.patient_id)
              OR EXISTS(SELECT 1 FROM hospitalization h JOIN document_file d ON d.id = h.document_file_id WHERE h.patient_id != d.patient_id)
              OR EXISTS(SELECT 1 FROM diagnosis x JOIN encounter e ON e.id = x.encounter_id WHERE x.patient_id != e.patient_id)
              OR EXISTS(SELECT 1 FROM diagnosis x JOIN document_file d ON d.id = x.document_file_id WHERE x.patient_id != d.patient_id)
              OR EXISTS(SELECT 1 FROM diagnosis x JOIN health_problem p ON p.id = x.health_problem_id WHERE x.patient_id != p.patient_id)
              OR EXISTS(SELECT 1 FROM exam_report x JOIN encounter e ON e.id = x.encounter_id WHERE x.patient_id != e.patient_id)
              OR EXISTS(SELECT 1 FROM exam_report x JOIN document_file d ON d.id = x.document_file_id WHERE x.patient_id != d.patient_id)
              OR EXISTS(SELECT 1 FROM lab_report x JOIN encounter e ON e.id = x.encounter_id WHERE x.patient_id != e.patient_id)
              OR EXISTS(SELECT 1 FROM lab_report x JOIN document_file d ON d.id = x.document_file_id WHERE x.patient_id != d.patient_id)
              OR EXISTS(SELECT 1 FROM metric_sample m JOIN lab_report l ON l.id = m.lab_report_id WHERE m.patient_id != l.patient_id)
              OR EXISTS(SELECT 1 FROM lab_result r JOIN lab_report l ON l.id = r.lab_report_id WHERE r.patient_id != l.patient_id)
              OR EXISTS(SELECT card_id FROM ocr_card_commit GROUP BY card_id
                HAVING COUNT(DISTINCT patient_id) != 1 OR COUNT(DISTINCT document_file_id) != 1
                  OR COUNT(DISTINCT page_index) != 1 OR COUNT(DISTINCT card_kind) != 1)
            """) ?? 0
        guard mismatched == 0 else { throw ExportError.invalidOCRBackup }
        for receipt in try Row.fetchAll(db, sql: "SELECT * FROM ocr_card_commit") { try OCRCardStore.validateReceipt(receipt, db: db) }
    }

    /// patient_profile 行 → PatientProfile 实体（本人/成员共用一条映射）
    /// media_asset_ids JSON 列编解码（与 ObservationStore 同语义：损坏降级空数组/空列）。
    private static func decodeMediaIds(_ json: String?) -> [String] {
        guard let json, let data = json.data(using: .utf8) else { return [] }
        do { return try JSONDecoder().decode([String].self, from: data) }
        catch { return [] }
    }
    private static func encodeMediaIds(_ ids: [String]) -> String? {
        guard !ids.isEmpty else { return nil }
        do {
            let data = try JSONEncoder().encode(ids)
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    private static func profileRow(_ row: Row) -> PatientProfile {
        // 第六轮全仓审查修复：血型/证件号/医保号（FR3.1 P0 字段）此前
        // 未映射——备份→恢复静默清零，急救卡血型消失（FR13.5 一票否决项）
        PatientProfile(id: UUID(uuidString: row["id"] as String) ?? UUID(),
                       displayName: row["display_name"] as String,
                       relation: row["relation"] as String,
                       gender: row["gender"] as String?,
                       birthDate: row["birth_date"] as String?,
                       bloodType: row["blood_type"] as String?,
                       idNo: row["id_no"] as String?,
                       insuranceNo: row["insurance_no"] as String?,
                       note: row["note"] as String?,
                       createdAt: row["created_at"] as Double,
                       updatedAt: row["updated_at"] as Double,
                       deletedAt: row["deleted_at"] as Double?)
    }

    /// 编码 envelope 为 JSON Data（含 UTF-8）
    public func encode(_ envelope: Envelope) throws -> Data {
        try JSONEncoder().encode(envelope)
    }

    public func decode(_ data: Data) throws -> Envelope {
        try JSONDecoder().decode(Envelope.self, from: data)
    }

    /// CSV 导出（配药清单等表格型数据，FR13.3/FR13.8）：复用 Domain CSVWriter
    public func csv(headers: [String], rows: [[String]]) -> Data {
        CSVWriter.encode(headers: headers, rows: rows)
    }
}
#endif
