import Foundation

/// 商业化基础设施（comercial-spec V1.5 / tech §5.14）：
/// Pro 买断（¥68/年 或 ¥12/月，7 天试用）+ 三追加包；云订阅 D1 后。
/// 免费额度：云备份 5GB、高级 AI 20 次/月、成员 ≥4 免费。
public enum ProductID: String, Sendable, CaseIterable, Codable {
    case proBase            // Pro 买断基础包
    case addonInsurance     // 核保资料包
    case addonThreshold     // 自定义预警阈值
    case addonDispense      // 配药清单高级模板
    case cloudSubscription  // 云订阅（D1 后）
}

/// 五时机弹墙矩阵（comercial §3）：只有价值触发点弹墙，反向约束=免费边界绝不弹墙
public enum PaywallTrigger: String, Sendable, Equatable, Codable {
    case memberQuotaReached      // 第 5 个成员
    case proOutputFirstTap       // Pro 产出包首次点击
    case cloudSyncFirstToggle    // 云同步首次开启
    case aiQuotaExhausted        // 高级 AI 额度用尽
    case settingsResident        // 设置中心常驻入口（非弹墙，主动访问）
}

/// 免费红线能力清单（comercial §2.1：收费=产品缺陷）
public enum FreeRedLine {
    public static let capabilities: Set<String> = [
        "sensitiveProtection", "offline", "medicationReminder", "refillAlert",
        "basicHealthAlert", "search", "careMode", "emergencyCard", "helpDiagnostics",
        "voiceInput", "allergyRecord",
    ]
    public static func isFree(_ capability: String) -> Bool {
        capabilities.contains(capability)
    }
}

/// 额度计数（免费额度：云备份 5GB / 高级 AI 20 次/月 / 成员 4 人）
public struct FreeQuota: Sendable, Equatable, Codable {
    public var maxMembers: Int
    public var aiMonthlyUses: Int
    public var cloudBackupGB: Double
    public init(maxMembers: Int = 4, aiMonthlyUses: Int = 20, cloudBackupGB: Double = 5) {
        self.maxMembers = maxMembers
        self.aiMonthlyUses = aiMonthlyUses
        self.cloudBackupGB = cloudBackupGB
    }
}

/// 弹墙调度规则（Domain 纯函数，可单测）：
/// ①五时机任一触发且未解锁相关权益；②24h 频控（同 trigger 最多一次/24h）；
/// ③反向约束：免费红线能力绝不弹墙；④到期不删产出（信任文案）
public enum PaywallRules {
    public static let frequencyWindow: TimeInterval = 24 * 3600

    public static func shouldShow(
        trigger: PaywallTrigger,
        entitlementUnlocked: Bool,
        lastShownAt: Date?,
        now: Date
    ) -> Bool {
        guard !entitlementUnlocked else { return false }
        if let last = lastShownAt, now.timeIntervalSince(last) < frequencyWindow {
            return false   // 24h 频控
        }
        return true
    }

    /// 反向约束：免费能力绝不可因未付费被禁用（收费=产品缺陷）
    public static func isBlockable(_ capability: String) -> Bool {
        !FreeRedLine.isFree(capability)
    }

    /// FR3.7 成员配额判定：加第 N 个成员是否会越过免费配额（免费档 ≥4 人）。
    /// 判定「加一个会不会超」而不是「现在已超」——第 5 个成员的加入动作
    /// 才是价值触发点（comercial §3 memberQuotaReached）。
    public static func addingMemberWouldExceed(currentCount: Int,
                                               quota: FreeQuota = FreeQuota()) -> Bool {
        currentCount + 1 > quota.maxMembers
    }

    /// 信任文案（固定，不随状态变化）
    public static let trustCopy = "核心功能永久免费，付费只解锁增量能力。不续费不会删除你的任何数据。"
}

/// 权益状态（EntitlementStore 的领域模型；红线模块禁读该 store——静态断言）
public struct EntitlementState: Sendable, Equatable, Codable {
    public var ownedProducts: Set<ProductID>
    public var aiMonthlyUsed: Int
    public var memberCount: Int
    public var cloudBackupUsedGB: Double
    public init(ownedProducts: Set<ProductID> = [], aiMonthlyUsed: Int = 0,
                memberCount: Int = 1, cloudBackupUsedGB: Double = 0) {
        self.ownedProducts = ownedProducts
        self.aiMonthlyUsed = aiMonthlyUsed
        self.memberCount = memberCount
        self.cloudBackupUsedGB = cloudBackupUsedGB
    }

    public var hasPro: Bool { ownedProducts.contains(.proBase) }

    /// 额度判定（comercial §2.3）
    public func quotaExceeded(_ quota: FreeQuota) -> PaywallTrigger? {
        if memberCount > quota.maxMembers && !hasPro { return .memberQuotaReached }
        if aiMonthlyUsed >= quota.aiMonthlyUses && !hasPro { return .aiQuotaExhausted }
        return nil
    }
}
