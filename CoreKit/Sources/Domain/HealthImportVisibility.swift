import Foundation

/// FR16.1 Apple 健康页面可见性三态（round2 H1/H3/H-N3/H-N4/H-N5）。
/// 优先级固定：关闭 > 不可用 > 缺本人档案 > 未连接 > 已连接（空/有数据）。
/// 「授权完成」不是状态输入——读取权限对 App 不可观察（H3），只有开关、设备能力、
/// 本人档案与绑定四个可观察事实进入判定。
public enum HealthImportPageState: Sendable, Equatable {
    /// 开关关闭：展示区/详情页/趋势链接整体不可见（直达路由亦呈已关闭态）
    case disabled
    /// 设备不提供 HealthKit（iPad/模拟器）：不显示请求按钮（H-N4）
    case unavailable
    /// 无本人档案：Apple 健康只能导入到本人名下（BR-001），引导创建/恢复（H-N3）
    case ownerMissing
    /// 已开启但尚未连接
    case notConnected
    /// 已连接但尚无已导入行（首次同步前 / 全部稀疏）——独立空态文案（H-N5）
    case connectedEmpty
    /// 已连接且有已导入数据
    case visible
}

public enum HealthImportVisibility {
    public static func state(enabled: Bool, available: Bool, ownerPresent: Bool,
                             connected: Bool, importedRows: Int) -> HealthImportPageState {
        guard enabled else { return .disabled }
        guard available else { return .unavailable }
        guard ownerPresent else { return .ownerMissing }
        guard connected else { return .notConnected }
        return importedRows > 0 ? .visible : .connectedEmpty
    }

    /// 展示区 + 详情页只在开关开且已连接时存在（H1）；空态用独立文案而非同步报告语句（H-N5）
    public static func showsImportedData(_ state: HealthImportPageState) -> Bool {
        state == .visible || state == .connectedEmpty
    }

    /// 趋势链接：有数据且身份已知（H2）——缺身份不得回落 currentPatientId（BR-001）
    public static func allowsTrendLink(_ state: HealthImportPageState, patientId: UUID?) -> Bool {
        state == .visible && patientId != nil
    }
}
