import Foundation
import Domain

/// 切片安装器协议（U-批 B5，2026-10-28；零网络证据一级）。
///
/// App 组合根与 `CatalogSlicesState` 只依赖本协议：测试注入 spy（记录调用次数
/// 恒为零）即可机械证明「启动/自检/展示路径零升级调用」。传输实现四符号
/// （`URLSessionMedicalCatalogPackageFetcher` 等）继续留在 Infrastructure 内部
/// ——L0 家族 Q 禁止 App 层引用（进度/错误/形态经 Domain 值类型）。
///
/// 一致性由 `CatalogSliceUpdateService`（actor）满足：其 `Progress` typealias
/// 与本协议回调类型逐字相同。
public protocol CatalogSliceInstalling: Sendable {
    /// 安装单个已验签候选；进度经 Domain `MedicalCatalogUpdateProgress` 回调。
    /// 语义同 `CatalogSliceUpdateService.update`：二验 minApp/尺寸、下载→
    /// 验包→解密→验库→激活（journal 起不再响应取消）。
    func update(_ candidate: VerifiedCatalogSliceCandidate,
                progress: @escaping @Sendable (MedicalCatalogUpdateProgress) -> Void) async throws
}
