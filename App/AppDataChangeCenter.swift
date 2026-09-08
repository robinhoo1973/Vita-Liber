import Foundation
import SwiftUI

/// 类型化数据变更信号（tech V3.86 / data-flow V1.9）：数据变更的源是 DB
/// 写入，本中心只提供**类型化版本计数**作为 UI 失效标记（数据库即事件总线
/// 原则——不引入 NotificationCenter 数据总线；裸 NotificationCenter 无类型、
/// 易漏注销，已被架构裁决否决）。各页数据仍经 Store 观察 DB，本计数只触发
/// 「重载」时机。
///
/// 消费方：健康资料/时间轴/健康问题页经 `.onChange(of: documentsVersion)`
/// 重载；指标总览经 `metricsVersion` 重载（设备读数入库后）。
@MainActor
@Observable
final class AppDataChangeCenter {
    /// 文档保存信号（FR11.4 懒创建触发携带）：病历类文档保存成功后由
    /// 确认卡消费（派生候选健康问题名 → 用户确认落库）。
    struct SavedDocumentSignal: Sendable, Equatable {
        var documentId: UUID
        /// 稳定类型键（DocumentTypeClassifierFallback 键族）
        var docTypeKey: String
        /// 病历类判定（HealthProblemDerivation 触发条件）
        var isClinical: Bool
    }

    private(set) var documentsVersion: UInt64 = 0
    private(set) var metricsVersion: UInt64 = 0
    private(set) var lastSavedDocument: SavedDocumentSignal?

    /// OCR/文档确认保存成功后 +1（携带 FR11.4 懒创建信号）。
    func documentSaved(_ signal: SavedDocumentSignal?) {
        documentsVersion &+= 1
        lastSavedDocument = signal
    }

    /// 设备读数落库后 +1（趋势/指标宫格失效标记）。
    func metricsChanged() {
        metricsVersion &+= 1
    }
}
