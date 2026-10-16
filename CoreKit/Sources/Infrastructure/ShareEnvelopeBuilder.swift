#if os(iOS) || os(macOS)
// linux-blind: （平台守卫：ExportService/Envelope 整文件在 Linux 编译为空单元，本套件仅 macOS CI 执行）
import Foundation
import Domain

/// 分享包（FR13.13）：裁剪后的信封 + 元数据。
/// 撤回语义（function V4.22 通道区分）：离线信封无远程撤回——expiry 届满拒绝打开 +
/// 分享方销毁本机密钥 + 提示接收方删除；已交付内容不可远程擦除。
public struct SharePackage: Sendable, Equatable {
    public var id: UUID
    public var tier: ShareTier
    public var expiry: Date
    public var watermark: Bool
    public var envelope: ExportService.Envelope
    public init(id: UUID, tier: ShareTier, expiry: Date, watermark: Bool,
                envelope: ExportService.Envelope) {
        self.id = id
        self.tier = tier
        self.expiry = expiry
        self.watermark = watermark
        self.envelope = envelope
    }
}

/// 分级分享包裁剪（discussions/2026-10-16-backup-sync-share-design.md §5.5/§8.5）：
/// 逐项勾选、最小必要、可撤回。强制负向：D 级文档/未确认回执拒入（BR-003 显式）；
/// 敏感文档仅原件级显式勾选可入（BR-007/008）；HealthKit 数据恒不在信封（导出链既有白名单）。
/// 裁剪后经 BackupCrypto 帧封装（每分享随机 DEK + QR 密钥交换——切片 3C）。
public enum ShareEnvelopeBuilder {

    /// 逐级裁剪（原地副本，不污染源信封）。
    /// 白名单纪律（评审重写）：原实现是「短黑名单」——只在个别级清掉 4 个字段，其余全部
    /// 临床数组（时间轴/病历正文/处方/检验/就诊/过敏史/语音记录/免疫…）随包全量透传，
    /// 四级「最小必要」承诺在数据层整体失效（通知级分享=整库病历外发）。重写为逐级白名单：
    /// 先零基线全清临床数据，再按级回填本级条款字段——新增字段默认被清
    /// （白名单失效方向安全：漏清=泄漏；漏回填=功能缺项可测），function V4.22 四级语义。
    public static func build(id: UUID, from source: ExportService.Envelope,
                             selection: ShareSelection) throws -> SharePackage {
        var envelope = source
        envelope.media = nil          // 分享包不带媒体字节（原件级逐件勾选走单独载具链路，切片 3C 前零承诺）
        envelope.tombstones = nil     // 墓碑属同步域内部语义，不进分享
        envelope.syncRealmId = nil
        envelope.deviceId = nil
        envelope.seq = nil
        envelope.assets = nil         // F8 资产行随媒体字节走（同媒体纪律，不进信封）

        // 零基线：全部临床数据清除——以下仅回填本级条款字段
        clearClinicalFields(&envelope)

        switch selection.tier {
        case .notification:
            // FR24.4 口径：成员+时段+确认态；标题/药名/剂量/指标区间全部剥除
            envelope.reminders = source.reminders?.map { reminder in
                var copy = reminder
                copy.title = ""
                return copy
            }
        case .summary:
            // 指标区间 + 用药时段；药名三档（默认仅时段+确认态）；病名恒不在本级。
            // 数据层只承载「含/不含」二元：ReminderExport.title 为唯一文本载体，
            // 药名 vs 药名+剂量的档位差异由接收端渲染层按 ShareSelection 档位取舍（登记债）
            envelope.reminders = source.reminders?.map { reminder in
                var copy = reminder
                if !ShareRules.summaryAllowsMedicationNames(selection.medicationNameLevel) {
                    copy.title = ""
                }
                return copy
            }
            envelope.metrics = source.metrics
        case .card:
            // 选定信息卡整体（其余卡剥离）
            let selected = selection.selectedCardIds
            envelope.ocrCardCommits = source.ocrCardCommits?.filter { selected.contains($0.rowId) }
        case .original:
            // 逐件显式勾选（水印与二次确认由 UI 层强制，BR-009）：
            // 仅入选文档及其时间轴投影、对应回执；其余临床数组一律不入（含他成员数据）
            let selected = selection.selectedDocumentIds
            envelope.documents = source.documents?.filter { selected.contains($0.id) }
            envelope.timeline = source.timeline.filter { selected.contains($0.id) }
            envelope.ocrCardCommits = source.ocrCardCommits?.filter { selected.contains($0.documentId) }
        }

        // BR-003 显式条款：D 级文档绝不参与分享（全级）
        if let docs = envelope.documents {
            envelope.documents = docs.filter { !ShareRules.excludesUnconfirmed(grade: $0.grade) }
        }
        // 未确认字段绝不入分享（全级）：回执逐字段剥除 ocrUnconfirmed（D）草稿
        if let commits = envelope.ocrCardCommits {
            envelope.ocrCardCommits = commits.map { commit in
                var copy = commit
                copy.shared = copy.shared.filter { $0.grade != .ocrUnconfirmed }
                copy.fields = copy.fields.filter { $0.grade != .ocrUnconfirmed }
                return copy
            }
        }
        // 敏感文档仅原件级显式勾选可入（其余级剥离，BR-007/008）
        if selection.tier != .original, let docs = envelope.documents {
            envelope.documents = docs.filter { !$0.isSensitive }
        }

        return SharePackage(id: id, tier: selection.tier,
                            expiry: ShareExpiryRules.clamped(selection.expiry, tier: selection.tier),
                            watermark: selection.tier == .original,
                            envelope: envelope)
    }

    /// 分享零基线（白名单执行面）：全部临床数据清空——数组→[]、可选→nil。
    /// 不动身份/骨架字段（schemaVersion/exportedAt/owner/selfProfile/members/consentRecords）：
    /// 成员档案是各级「成员」条款的载体，接收端导入也需要患者映射锚。
    private static func clearClinicalFields(_ envelope: inout ExportService.Envelope) {
        envelope.timeline = []
        envelope.documents = nil
        envelope.ocrCardCommits = nil
        envelope.ocrPrescriptions = nil
        envelope.ocrEncounterDetails = nil
        envelope.ocrMedications = nil
        envelope.claims = nil
        envelope.prescriptionLines = nil
        envelope.claimLines = nil
        envelope.hospitalizations = nil
        envelope.diagnoses = nil
        envelope.examReports = nil
        envelope.labReports = nil
        envelope.labResults = nil
        envelope.healthExams = nil
        envelope.clinicalConclusions = nil
        envelope.surgeries = nil
        envelope.treatmentRecords = nil
        envelope.reminders = nil
        envelope.plans = []
        envelope.appointments = []
        envelope.observations = []
        envelope.allergies = []
        envelope.encounters = []
        envelope.metrics = []
        envelope.alertEvents = nil
        envelope.immunizations = []
        envelope.voiceNotes = []
        envelope.healthProblems = []
        envelope.sensitiveDocIds = []
    }
}
#endif
