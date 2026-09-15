import Foundation

/// FR3.1 成员关系（结构轮 2026-09-15）：词表自视图收敛为 Domain 类型——
/// 此前 `MemberViews` 硬编码 `["配偶","子女","父母","祖父母","其他"]` 与中文
/// switch 分支，且 `memberIcon(_:)` 对粗粒度值全部回落通用图标（该文件注释
/// 记录的既有 bug 族）；而删除闸门曾因按显示串「本人」比较在多语言下失效
/// （同一根因：关系是**业务数据**，不该以视图字符串表示，tech-spec §1.1 规则 4）。
///
/// 存储兼容：`PatientProfile.relation` 仍为 String，rawValue 与既有落库值逐字一致
/// （「本人」为默认哨兵）——本类型是解析/分支层，不引入迁移。
public enum MemberRelation: String, Sendable, Equatable, CaseIterable, Codable {
    /// 本人哨兵（不可用 `self` 关键字作 case 名）。身份判定走 `LocalOwner.selfPatientId`，
    /// 本 case 仅表「关系」文案与图标。
    case selfMember = "本人"
    case partner = "配偶"
    case child = "子女"
    case parent = "父母"
    case grandparent = "祖父母"
    // 遗留细粒度值（历史/备份导入可能出现）：显示与图标各有专属映射。
    case father = "父亲"
    case mother = "母亲"
    case son = "儿子"
    case daughter = "女儿"
    case other = "其他"

    /// 新建成员可选集（粗粒度；与既有 sheet 目录逐字一致，保序）。
    public static let creatable: [MemberRelation] = [.partner, .child, .parent, .grandparent, .other]

    /// 容错解析：存储/遗留值 → 枚举。未知值归 `.other`（显示层仍走原文，不丢内容）；
    /// 常见同义（丈夫/妻子）归并到配偶。
    public init(tolerant raw: String) {
        if let known = MemberRelation(rawValue: raw) {
            self = known
            return
        }
        switch raw {
        case "丈夫", "妻子", "丈夫 ", "老婆": self = .partner
        default: self = .other
        }
    }

    /// 粗粒度归并（父亲/母亲 → 父母；儿子/女儿 → 子女）——筛选/分组用。
    public var coarse: MemberRelation {
        switch self {
        case .father, .mother: return .parent
        case .son, .daughter: return .child
        default: return self
        }
    }

    /// 是否本人哨兵（身份判定本身走 `selfPatientId`，此属性只用于关系展示分支）。
    public var isSelf: Bool { self == .selfMember }
}
