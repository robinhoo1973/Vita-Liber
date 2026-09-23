import Foundation

/// FR11.5 脏器档案（V4.05，业主 2026-09-23）：器官封闭目录——OCR/ASR 后处理抽取的
/// 「脏器功能性陈述」按器官归档（`OrganFindingRules` 匹配；`organ_entry` 落库随实现批 v33）。
/// 匹配词集 = zh-Hans 主集 + 常用 zh-Hant 形（区域词表扩展走词表批，F25 单一事实源纪律）。
public enum OrganSite: String, CaseIterable, Sendable, Codable, Equatable {
    case lung, liver, gallbladder, kidney, thyroid, heart, stomach, intestine, pancreas, spleen,
         brain, breast, prostate, uterusOvary, bone, eye, ent, skin, blood, lymph

    /// 匹配关键词（任一命中即归属；封闭集、可扩展——新增器官走词表批并同步 ui-ux 图标目录）。
    public var matchTerms: [String] {
        switch self {
        case .lung: return ["双肺", "肺部", "肺叶", "肺", "支气管"]
        case .liver: return ["肝脏", "肝内", "肝胆", "肝"]
        case .gallbladder: return ["胆囊", "胆管", "胆道", "胆"]
        case .kidney: return ["双肾", "肾脏", "肾盂", "输尿管", "肾"]
        case .thyroid: return ["甲状腺", "甲狀腺", "甲状旁腺"]
        case .heart: return ["心脏", "心臟", "心包", "心肌", "心尖", "心影", "冠脉", "冠状动脉"]
        case .stomach: return ["胃窦", "胃体", "胃底", "胃"]
        case .intestine: return ["小肠", "结肠", "直肠", "乙状结肠", "十二指肠", "肠道", "腸", "肠"]
        case .pancreas: return ["胰腺", "胰"]
        case .spleen: return ["脾脏", "副脾", "脾"]
        case .brain: return ["颅脑", "脑实质", "脑室", "脑血管", "脑干", "小脑", "腦", "脑"]
        case .breast: return ["乳腺", "乳房"]
        case .prostate: return ["前列腺"]
        case .uterusOvary: return ["子宫", "子宮", "卵巢", "宫颈", "宫腔", "附件"]
        case .bone: return ["脊柱", "椎体", "椎间盘", "关节", "骨质", "骨骼", "骨"]
        case .eye: return ["眼底", "视网膜", "晶状体", "角膜", "眼"]
        case .ent: return ["鼻窦", "鼻咽", "咽部", "扁桃体", "中耳", "声带", "咽", "喉", "耳", "鼻"]
        case .skin: return ["皮肤", "皮膚", "皮疹", "皮损"]
        case .blood: return ["血常规", "血红蛋白", "白细胞", "红细胞", "血小板", "凝血", "血液"]
        case .lymph: return ["淋巴结", "淋巴"]
        }
    }
}
