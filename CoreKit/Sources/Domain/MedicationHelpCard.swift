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

    /// 卡片文案标签（第七轮全仓审查修复）：Domain 不得硬编码用户可见文案——
    /// 标题/字段前缀经 HelpCardLabels 注入，App 层取 L10n 三语词表；
    /// `zhFallback` 仅为诊断/测试默认值（Refusal.detail 同款降级纪律），
    /// 生产调用方必须注入本地化标签。
    public struct HelpCardLabels: Sendable, Equatable {
        public var title: String
        public var remainingPrefix: String   // 「剩余：约」
        public var storagePrefix: String     // 「存放位置：」
        public var expiryPrefix: String      // 「效期：」
        public static let zhFallback = HelpCardLabels(
            title: "药品求助卡", remainingPrefix: "剩余：约",
            storagePrefix: "存放位置：", expiryPrefix: "效期：")
        public init(title: String, remainingPrefix: String,
                    storagePrefix: String, expiryPrefix: String) {
            self.title = title; self.remainingPrefix = remainingPrefix
            self.storagePrefix = storagePrefix; self.expiryPrefix = expiryPrefix
        }
    }

    /// 组装单页文本。**位置照片不入文本**——照片以附件形式随分享带出，
    /// 且仅当 `includeStoragePhoto` 为 true 时由调用方附加（本函数无法、
    /// 也不应该接触二进制）。
    /// 第八轮全仓审查修复（空选择契约）：FR9.13a 前提是「选择一个或多个
    /// 药品批次/包装后」生成——空选择返回 nil。原实现恒返回标题行，测试
    /// 「空选择不产出卡片」断言 cardText([]) 含标题、恒真永不可败，反向
    /// 锁死了与规格相悖的行为。
    public static func cardText(_ items: [Input],
                                labels: HelpCardLabels = .zhFallback) -> String? {
        guard !items.isEmpty else { return nil }
        var lines = [labels.title]
        lines.append("")
        for item in items {
            lines.append("· \(item.medicationName)\(item.spec.map { "（\($0)）" } ?? "")")
            lines.append("  \(labels.remainingPrefix) \(String(format: "%g", item.remainingUnits)) \(item.unitKind)")
            if let note = item.storageNote, !note.isEmpty {
                lines.append("  \(labels.storagePrefix)\(note)")
            }
            if let expire = item.expireAt {
                lines.append("  \(labels.expiryPrefix)\(expire.formatted(date: .abbreviated, time: .omitted))")
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

/// FR24.2 发送状态（P0）：本地只记「发过什么、状态如何」。
///
/// 最小必要原则：**不存消息原文**——原文留在发送时刻的卡片里，状态页只展示
/// 类型/收件人/状态/时间。回执（acked）与超时（timeout）是 P1/D1 云端回执
/// 闭环的状态，M2 只产生 `sent`，状态机规则先立起来。
public enum MessageStatus: String, Sendable, Equatable, Codable, CaseIterable {
    case sent, ackPending, acked, timeout
}

public struct SentMessage: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var kind: String          // helpCard / sos
    public var recipient: String
    public var status: MessageStatus
    public var sentAt: Date
    public init(id: UUID = UUID(), kind: String, recipient: String,
                status: MessageStatus = .sent, sentAt: Date) {
        self.id = id; self.kind = kind; self.recipient = recipient
        self.status = status; self.sentAt = sentAt
    }
}

public enum MessageStatusRules {
    /// 状态迁移白名单：sent → ackPending（等待回执）/ timeout；ackPending → acked。
    /// 任何回退（acked → sent）与旁路跳变一律拒绝——状态不可伪造。
    public static func canTransition(from: MessageStatus, to: MessageStatus) -> Bool {
        switch (from, to) {
        case (.sent, .ackPending), (.sent, .timeout),
             (.ackPending, .acked), (.ackPending, .timeout):
            return true
        default:
            return false
        }
    }
}
