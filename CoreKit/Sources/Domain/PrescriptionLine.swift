import Foundation

/// F9 处方行实体（v25 `prescription_line`，字段与 DDL 同名同序；子项目 D §C.6）。
/// BR-006/007：剂量/数量/频次/疗程一律原文 `*Text` + `*Unit`，不解析为数值、不换算、不推算给药方案；
/// 单价/金额为费用可 Double。`medicationId` 只由用户显式「采用为药品目录项」写入（不自动匹配）。
/// `sourcePage + sourceRowId`（= 回执 row_id）留痕；文档经表头 `prescriptionId` 到达。
public struct PrescriptionLine: Sendable, Equatable, Codable, Identifiable {
    /// 父键占位（`EntityCardProjection` 产出的行意图尚无表头/成员上下文，store 落库时填写）。
    public static let unassignedId = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

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
    /// BR-003：D 级草稿默认 false；OCR 经用户确认保存时由 store 置 1。
    public var confirmed: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), prescriptionId: UUID, patientId: UUID, ordinal: Int, printedName: String,
                genericName: String? = nil, brandName: String? = nil, drugForm: String? = nil, spec: String? = nil,
                doseText: String? = nil, doseUnit: String? = nil, quantityText: String? = nil, quantityUnit: String? = nil,
                frequencyText: String? = nil, routeText: String? = nil, durationText: String? = nil,
                startDate: Date? = nil, endDate: Date? = nil, asNeededText: String? = nil, medicationNotes: String? = nil,
                note: String? = nil, rawText: String? = nil, insuranceCode: String? = nil, itemCodeText: String? = nil,
                unitPrice: Double? = nil, amount: Double? = nil, medicationId: UUID? = nil,
                sourcePage: Int? = nil, sourceRowId: UUID? = nil, confirmed: Bool = false,
                createdAt: Date, updatedAt: Date) {
        self.id = id; self.prescriptionId = prescriptionId; self.patientId = patientId; self.ordinal = ordinal
        self.printedName = printedName; self.genericName = genericName; self.brandName = brandName
        self.drugForm = drugForm; self.spec = spec; self.doseText = doseText; self.doseUnit = doseUnit
        self.quantityText = quantityText; self.quantityUnit = quantityUnit; self.frequencyText = frequencyText
        self.routeText = routeText; self.durationText = durationText; self.startDate = startDate; self.endDate = endDate
        self.asNeededText = asNeededText; self.medicationNotes = medicationNotes; self.note = note; self.rawText = rawText
        self.insuranceCode = insuranceCode; self.itemCodeText = itemCodeText; self.unitPrice = unitPrice; self.amount = amount
        self.medicationId = medicationId; self.sourcePage = sourcePage; self.sourceRowId = sourceRowId
        self.confirmed = confirmed; self.createdAt = createdAt; self.updatedAt = updatedAt
    }
}
