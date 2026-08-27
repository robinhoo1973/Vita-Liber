import Foundation

/// F18 关怀模式语义（§5.15）：环境化呈现层——全局覆盖尺寸/交互参数，
/// 非平行代码库（ADR-011）。语义规则纯函数化：触控目标/防抖/长按确认/SOS。
public struct CareModeMetrics: Sendable, Equatable {
    public var touchTarget: CGFloat       // 关怀 64pt / 常规 44pt
    public var spacing: CGFloat           // 关怀 16 / 常规 8
    public var primaryButtonHeight: CGFloat  // 关怀 72 / 常规 50
    public var tremorGuardSeconds: TimeInterval   // 关怀 0.3s 防抖
    public var holdConfirmSeconds: TimeInterval   // 关怀 ≥0.6s
    public init(touchTarget: CGFloat = 44, spacing: CGFloat = 8,
                primaryButtonHeight: CGFloat = 50,
                tremorGuardSeconds: TimeInterval = 0,
                holdConfirmSeconds: TimeInterval = 0) {
        self.touchTarget = touchTarget
        self.spacing = spacing
        self.primaryButtonHeight = primaryButtonHeight
        self.tremorGuardSeconds = tremorGuardSeconds
        self.holdConfirmSeconds = holdConfirmSeconds
    }
    public static let standard = CareModeMetrics()
    public static let care = CareModeMetrics(touchTarget: 64, spacing: 16,
                                             primaryButtonHeight: 72,
                                             tremorGuardSeconds: 0.3,
                                             holdConfirmSeconds: 0.6)
}

/// 震颤防抖（TremorGuard）：关怀模式下连续点击须间隔 ≥0.3s 才计一次
public enum TremorGuard {
    public static func shouldAccept(lastActionAt: Date?, now: Date, mode: CareModeMetrics) -> Bool {
        guard mode.tremorGuardSeconds > 0 else { return true }
        guard let last = lastActionAt else { return true }
        return now.timeIntervalSince(last) >= mode.tremorGuardSeconds
    }
}

/// 长按确认（HoldToConfirm）：危险/不可逆动作（删除/清除）在关怀模式
/// 必须长按 ≥0.6s；常规模式按系统确认弹窗
public enum HoldToConfirm {
    public static func requiredSeconds(mode: CareModeMetrics) -> TimeInterval {
        mode.holdConfirmSeconds
    }
    public static func accepted(holdSeconds: TimeInterval, mode: CareModeMetrics) -> Bool {
        mode.holdConfirmSeconds == 0 || holdSeconds >= mode.holdConfirmSeconds
    }
}

/// SOS 路径（FR1.8/§5.27）：两步可达（≤2 步）且永不被门禁/付费墙阻断
public enum SOSRules {
    public static let maxSteps = 2

    /// SOS 是门禁唯一豁免（FR1.8）——任何锁定状态都不得阻挡
    public static func isGateExempt(_ capability: String) -> Bool {
        capability == "sos"
    }

    /// 误触防护：SOS 大按钮需 0.6s 长按（常规模式）触发，误触率 <1% 验收
    public static func requiresHoldConfirm(_ capability: String, mode: CareModeMetrics) -> Bool {
        capability == "sos" || mode.holdConfirmSeconds > 0
    }
}

/// 挂号深链映射（FR10.6，§5.39）：本地映射表，无网可用；未覆盖医院走补录
public struct HospitalDeepLink: Sendable, Equatable {
    public var hospitalName: String
    public var baseURL: String
    public var template: String          // {bookingNo} 占位
    public init(hospitalName: String, baseURL: String, template: String) {
        self.hospitalName = hospitalName; self.baseURL = baseURL; self.template = template
    }
    public func url(bookingNo: String) -> String {
        template.replacingOccurrences(of: "{bookingNo}", with: bookingNo)
    }
}

public enum HospitalDeepLinkRegistry {
    public static func link(for hospitalName: String, in registry: [HospitalDeepLink]) -> HospitalDeepLink? {
        registry.first { $0.hospitalName == hospitalName }
    }

    /// FR10.6 本地映射表（默认档）：按医院名匹配主流挂号平台的**搜索深链**。
    /// 无网可用指「映射表在本地、不用服务端查询」——跳转后由平台自身承载联网。
    /// 不内嵌交易、不抽佣：我们只做「一键跳到平台搜索结果页」。
    /// 条目由本地维护；医院不在表内 → UI 提供手动补录预约编号的降级。
    public static let defaults: [HospitalDeepLink] = [
        HospitalDeepLink(hospitalName: "市一医院",
                         baseURL: "https://www.114yygh.com",
                         template: "https://www.114yygh.com/hospital/search?kw=市一医院"),
        HospitalDeepLink(hospitalName: "协和医院",
                         baseURL: "https://www.guahao.com",
                         template: "https://www.guahao.com/search/all?q=协和医院"),
        HospitalDeepLink(hospitalName: "社区卫生中心",
                         baseURL: "https://www.jkzr.com",
                         template: "https://www.jkzr.com/search?hospital=社区卫生中心"),
    ]

    /// 精确匹配失败时的模糊降级：按医院名关键字包含匹配（避免用户手输医院全名
    /// 与表内条目一字之差就丢了深链入口）
    public static func fuzzyLink(for hospitalName: String,
                                 in registry: [HospitalDeepLink]) -> HospitalDeepLink? {
        registry.first { entry in
            hospitalName.contains(entry.hospitalName)
                || entry.hospitalName.contains(hospitalName)
        }
    }
}
