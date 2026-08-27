import Foundation

/// FR9.13a 药品求助卡（P1 第一批）：用户选择批次后一键生成单页求助卡，
/// 经系统分享渠道发送给**用户显式选择的联系人**——家属协助取药/代购场景。
///
/// 最小必要原则（FR9.13a / §16.2）：
/// - 卡内默认只有：药名/规格/剩余量/存放位置**文字**/失效日期；
/// - 位置**照片**默认不在卡内，须用户显式勾选才纳入；
/// - 默认不含诊断类信息；急救卡与求助卡分离（FR15.5）。
public enum MedicationHelpCardRules {

    public struct Input: Sendable, Equatable, Identifiable {
        public var lotId: UUID
        public var medicationName: String
        public var spec: String?
        public var remainingUnits: Double
        public var unitKind: String
        public var expireAt: Date?
        public var storageNote: String?
        public var includeStoragePhoto: Bool = false   // 显式勾选才纳入
        public var id: UUID { lotId }
        public init(lotId: UUID, medicationName: String, spec: String?,
                    remainingUnits: Double, unitKind: String, expireAt: Date?,
                    storageNote: String?, includeStoragePhoto: Bool = false) {
            self.lotId = lotId; self.medicationName = medicationName; self.spec = spec
            self.remainingUnits = remainingUnits; self.unitKind = unitKind
            self.expireAt = expireAt; self.storageNote = storageNote
            self.includeStoragePhoto = includeStoragePhoto
        }
    }

    /// 组装单页文本。**位置照片不入文本**——照片以附件形式随分享带出，
    /// 且仅当 `includeStoragePhoto` 为 true 时由调用方附加（本函数无法、
    /// 也不应该接触二进制）。
    public static func cardText(_ items: [Input]) -> String {
        var lines = ["药品求助卡"]
        lines.append("")
        for item in items {
            lines.append("· \(item.medicationName)\(item.spec.map { "（\($0)）" } ?? "")")
            lines.append("  剩余：约 \(String(format: "%g", item.remainingUnits)) \(item.unitKind)")
            if let note = item.storageNote, !note.isEmpty {
                lines.append("  存放位置：\(note)")
            }
            if let expire = item.expireAt {
                lines.append("  效期：\(expire.formatted(date: .abbreviated, time: .omitted))")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// 隐私裁决：位置照片仅在显式勾选时纳入（默认不含——FR9.13a）
    public static func shouldAttachPhoto(_ item: Input) -> Bool {
        item.includeStoragePhoto
    }

    /// 求助卡内容不含诊断类信息——组装函数只接受药品字段，
    /// 结构上就无法混入诊断（FR15.5 分离语义的类型化表达）
    public static let forbiddenDiagnosisMarkers = ["诊断", "病症", "病情"]
}
