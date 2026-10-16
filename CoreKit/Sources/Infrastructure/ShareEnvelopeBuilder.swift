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
    public static func build(id: UUID, from source: ExportService.Envelope,
                             selection: ShareSelection) throws -> SharePackage {
        var envelope = source
        envelope.media = nil          // 分享包不带媒体字节（原件级逐件勾选走单独载具链路，切片 3C 前零承诺）
        envelope.tombstones = nil     // 墓碑属同步域内部语义，不进分享
        envelope.syncRealmId = nil
        envelope.deviceId = nil
        envelope.seq = nil

        switch selection.tier {
        case .notification:
            // FR24.4 口径：成员+时段+确认态；标题/药名/剂量全部剥除
            envelope.reminders = envelope.reminders?.map { reminder in
                var copy = reminder
                copy.title = ""
                return copy
            }
            envelope.metrics = []
            envelope.ocrCardCommits = nil
            envelope.documents = nil
        case .summary:
            // 指标区间 + 用药时段；药名三档（默认仅时段+确认态）；病名恒不在本级。
            // 数据层只承载「含/不含」二元：ReminderExport.title 为唯一文本载体，
            // 药名 vs 药名+剂量的档位差异由接收端渲染层按 ShareSelection 档位取舍（登记债）
            envelope.reminders = envelope.reminders?.map { reminder in
                var copy = reminder
                if !ShareRules.summaryAllowsMedicationNames(selection.medicationNameLevel) {
                    copy.title = ""
                }
                return copy
            }
            envelope.ocrCardCommits = nil
            envelope.documents = nil
        case .card:
            // 选定信息卡整体（其余卡剥离）
            let selected = selection.selectedCardIds
            envelope.ocrCardCommits = envelope.ocrCardCommits?.filter { selected.contains($0.rowId) }
            envelope.documents = nil
        case .original:
            // 逐件显式勾选（水印与二次确认由 UI 层强制，BR-009）
            let selected = selection.selectedDocumentIds
            envelope.documents = envelope.documents?.filter { selected.contains($0.id) }
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
}
#endif
