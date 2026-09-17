import Foundation
import SwiftUI
import Perception

/// 类型化数据变更信号（tech V3.86 / data-flow V1.9）：数据变更的源是 DB
/// 写入，本中心只提供**类型化版本计数**作为 UI 失效标记（数据库即事件总线
/// 原则——不引入 NotificationCenter 数据总线；裸 NotificationCenter 无类型、
/// 易漏注销，已被架构裁决否决）。各页数据仍经 Store 观察 DB，本计数只触发
/// 「重载」时机。
///
/// 消费方：健康资料/时间轴/健康问题页经 `.onChange(of: documentsVersion)`
/// 重载；指标总览经 `metricsVersion` 重载（设备读数入库后）。
@MainActor
@Perceptible
final class AppDataChangeCenter {
    private(set) var documentsVersion: UInt64 = 0
    private(set) var metricsVersion: UInt64 = 0
    private(set) var alertsVersion: UInt64 = 0
    /// 模型资产版本（2026-09-16 业主实测修复）：ASR 模型安装完成后 +1——语言列表的
    /// 可选性判定（`inputCapability`）此前只随「进页/切档位/场景恢复」重算，同页内
    /// 下载完成不触发任何一条，导致「下载完了还是不能选」。资产是一等失效源
    /// （同时影响语言列表、档位可用性、会话解析），故并入本中心。
    private(set) var assetsVersion: UInt64 = 0

    /// OCR/文档确认保存成功后 +1（触发健康资料/时间轴/健康问题页重载）。
    /// FR11.4 懒创建触发判定由确认卡按**保存时** docType 判定
    /// （DocumentsState.isClinicalDocType）——不再经本中心全局槽位透传
    /// （共享可变槽永不清理 = 后来者误读「最近一次保存」；docTypeKey
    /// 写入后无任何读者，属死载荷）。
    func documentSaved() {
        documentsVersion &+= 1
    }

    /// 设备读数落库后 +1（趋势/指标宫格失效标记）。
    func metricsChanged() {
        metricsVersion &+= 1
    }

    func alertsChanged() { alertsVersion &+= 1 }

    /// ASR 模型安装成功后 +1（语言列表/档位可用性失效标记）。
    func assetsChanged() { assetsVersion &+= 1 }

    /// 清空全部后全量失效（审查修复）：数据生命周期「清空全部」此前只删
    /// DB 与 AppState 镜像——各页（首页/提醒/观察/文档…）的内存投影仍
    /// 渲染刚被清掉的数据，直到某个无关刷新恰好发生。四槽齐拍让所有
    /// 观察方重载（数据库即事件总线的既有原则，不新增总线）。
    func dataWiped() {
        documentsVersion &+= 1
        metricsVersion &+= 1
        alertsVersion &+= 1
        assetsVersion &+= 1
    }
}
