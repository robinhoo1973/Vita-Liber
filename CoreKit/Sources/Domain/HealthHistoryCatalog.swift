import Foundation

/// 健康史目录（Domain 静态数据，不联网、不做诊断推断）。
///
/// 依据《中国防治慢性病中长期规划（2017—2025年）》与 WHO NCD 四大类的
/// 常见病名整理，作为「按部位查找 + 常见快捷项」的索引；病名是用户
/// 自报事实，选择本身不产生诊断。自由文本始终是最终兜底。
public enum HealthHistoryCatalog {
    // MARK: - Body regions

    public struct BodyOrgan: Sendable, Equatable, Identifiable, Hashable {
        public let id: String
        public let name: String
        public init(id: String, name: String) { self.id = id; self.name = name }
    }

    public struct BodyRegion: Sendable, Equatable, Identifiable, Hashable {
        public let id: String
        public let name: String
        /// 二级器官/组织（展示名 + 稳定 id）
        public let organs: [BodyOrgan]
        public init(id: String, name: String, organs: [BodyOrgan]) {
            self.id = id; self.name = name; self.organs = organs
        }
        public static func == (lhs: BodyRegion, rhs: BodyRegion) -> Bool { lhs.id == rhs.id }
        public func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    public static let bodyRegions: [BodyRegion] = [
        .init(id: "head_neck", name: "头颈", organs: [
            BodyOrgan(id: "head", name: "头部"), BodyOrgan(id: "eye", name: "眼"), BodyOrgan(id: "ear", name: "耳"), BodyOrgan(id: "nose_throat", name: "鼻咽喉"),
            BodyOrgan(id: "mouth", name: "口腔"), BodyOrgan(id: "thyroid", name: "甲状腺"), BodyOrgan(id: "neck", name: "颈部"),
        ]),
        .init(id: "chest", name: "胸部", organs: [
            BodyOrgan(id: "heart", name: "心脏"), BodyOrgan(id: "lung", name: "肺"), BodyOrgan(id: "breast", name: "乳腺"), BodyOrgan(id: "esophagus", name: "食管"),
        ]),
        .init(id: "abdomen", name: "腹部", organs: [
            BodyOrgan(id: "stomach", name: "胃"), BodyOrgan(id: "liver", name: "肝"), BodyOrgan(id: "gallbladder", name: "胆囊"), BodyOrgan(id: "pancreas", name: "胰腺"),
            BodyOrgan(id: "intestine", name: "肠道"), BodyOrgan(id: "kidney", name: "肾"),
        ]),
        .init(id: "pelvis", name: "盆腔", organs: [
            BodyOrgan(id: "bladder", name: "膀胱"), BodyOrgan(id: "uterus", name: "子宫"), BodyOrgan(id: "ovary", name: "卵巢"), BodyOrgan(id: "prostate", name: "前列腺"),
        ]),
        .init(id: "back", name: "背部/脊柱", organs: [
            BodyOrgan(id: "spine", name: "脊柱"), BodyOrgan(id: "spinal_cord", name: "脊髓"),
        ]),
        .init(id: "upper_limb", name: "上肢", organs: [
            BodyOrgan(id: "shoulder", name: "肩"), BodyOrgan(id: "arm", name: "上臂/前臂"), BodyOrgan(id: "elbow", name: "肘"), BodyOrgan(id: "wrist_hand", name: "腕/手"),
        ]),
        .init(id: "lower_limb", name: "下肢", organs: [
            BodyOrgan(id: "hip", name: "髋"), BodyOrgan(id: "thigh", name: "大腿"), BodyOrgan(id: "knee", name: "膝"), BodyOrgan(id: "ankle_foot", name: "踝/足"),
        ]),
        .init(id: "systemic", name: "全身/系统", organs: [
            BodyOrgan(id: "endocrine", name: "内分泌代谢"), BodyOrgan(id: "blood", name: "血液"), BodyOrgan(id: "immune", name: "免疫"),
            BodyOrgan(id: "mental", name: "精神心理"), BodyOrgan(id: "skeletal", name: "骨骼"), BodyOrgan(id: "genetic", name: "遗传"),
        ]),
    ]

    // MARK: - Chronic conditions

    public struct CommonCondition: Sendable, Equatable, Identifiable {
        public let id: String
        public let name: String
        /// 对应部位 id；systemic 表示全身/系统性疾病。
        public let regionID: String
        public init(id: String, name: String, regionID: String) {
            self.id = id; self.name = name; self.regionID = regionID
        }
    }

    /// 常见慢性病快捷项（官方四大类 + 基层常见病；不是穷举目录）。
    public static let commonConditions: [CommonCondition] = [
        .init(id: "hypertension", name: "高血压", regionID: "systemic"),
        .init(id: "dyslipidemia", name: "高血脂", regionID: "systemic"),
        .init(id: "type2_diabetes", name: "2 型糖尿病", regionID: "systemic"),
        .init(id: "coronary_heart_disease", name: "冠心病", regionID: "chest"),
        .init(id: "stroke", name: "脑卒中", regionID: "head_neck"),
        .init(id: "chronic_heart_failure", name: "慢性心力衰竭", regionID: "chest"),
        .init(id: "copd", name: "慢性阻塞性肺疾病", regionID: "chest"),
        .init(id: "asthma", name: "哮喘", regionID: "chest"),
        .init(id: "chronic_kidney_disease", name: "慢性肾病", regionID: "abdomen"),
        .init(id: "hepatitis_b", name: "慢性乙型肝炎", regionID: "abdomen"),
        .init(id: "hepatitis_c", name: "慢性丙型肝炎", regionID: "abdomen"),
        .init(id: "fatty_liver", name: "脂肪肝", regionID: "abdomen"),
        .init(id: "cirrhosis", name: "肝硬化", regionID: "abdomen"),
        .init(id: "chronic_gastritis", name: "慢性胃炎", regionID: "abdomen"),
        .init(id: "peptic_ulcer", name: "消化性溃疡", regionID: "abdomen"),
        .init(id: "hyperthyroidism", name: "甲状腺功能亢进", regionID: "head_neck"),
        .init(id: "hypothyroidism", name: "甲状腺功能减退", regionID: "head_neck"),
        .init(id: "rheumatoid_arthritis", name: "类风湿关节炎", regionID: "systemic"),
        .init(id: "gout", name: "痛风/高尿酸血症", regionID: "systemic"),
        .init(id: "osteoporosis", name: "骨质疏松", regionID: "systemic"),
        .init(id: "depression", name: "抑郁症", regionID: "systemic"),
        .init(id: "anxiety", name: "焦虑症", regionID: "systemic"),
        .init(id: "oral_disease", name: "口腔疾病", regionID: "head_neck"),
        .init(id: "cancer", name: "肿瘤（按部位）", regionID: "systemic"),
    ]

    public static func conditions(in regionID: String) -> [CommonCondition] {
        commonConditions.filter { $0.regionID == regionID }
    }

    // MARK: - Common surgeries

    public struct CommonSurgery: Sendable, Equatable, Identifiable {
        public let id: String
        public let name: String
        public let regionID: String
    }

    public static let commonSurgeries: [CommonSurgery] = [
        .init(id: "thyroidectomy", name: "甲状腺切除术", regionID: "head_neck"),
        .init(id: "tonsillectomy", name: "扁桃体/腺样体切除术", regionID: "head_neck"),
        .init(id: "cataract", name: "白内障手术", regionID: "head_neck"),
        .init(id: "coronary_stent", name: "心脏支架植入", regionID: "chest"),
        .init(id: "cabg", name: "冠脉搭桥术", regionID: "chest"),
        .init(id: "lung_resection", name: "肺叶切除术", regionID: "chest"),
        .init(id: "breast_surgery", name: "乳腺手术", regionID: "chest"),
        .init(id: "appendectomy", name: "阑尾切除术", regionID: "abdomen"),
        .init(id: "cholecystectomy", name: "胆囊切除术", regionID: "abdomen"),
        .init(id: "hernia_repair", name: "疝修补术", regionID: "abdomen"),
        .init(id: "gastrectomy", name: "胃切除术", regionID: "abdomen"),
        .init(id: "bowel_resection", name: "肠切除/吻合术", regionID: "abdomen"),
        .init(id: "cesarean", name: "剖宫产", regionID: "pelvis"),
        .init(id: "hysterectomy", name: "子宫切除术", regionID: "pelvis"),
        .init(id: "ovarian_cystectomy", name: "卵巢囊肿手术", regionID: "pelvis"),
        .init(id: "prostatectomy", name: "前列腺手术", regionID: "pelvis"),
        .init(id: "spine_fusion", name: "脊柱融合/椎间盘手术", regionID: "back"),
        .init(id: "fracture_fixation_upper", name: "上肢骨折内固定", regionID: "upper_limb"),
        .init(id: "carpal_tunnel", name: "腕管松解术", regionID: "upper_limb"),
        .init(id: "hip_replacement", name: "髋关节置换", regionID: "lower_limb"),
        .init(id: "knee_replacement", name: "膝关节置换", regionID: "lower_limb"),
        .init(id: "fracture_fixation_lower", name: "下肢骨折内固定", regionID: "lower_limb"),
    ]

    public static func surgeries(in regionID: String) -> [CommonSurgery] {
        commonSurgeries.filter { $0.regionID == regionID }
    }

    // MARK: - Common allergens

    public struct CommonAllergen: Sendable, Equatable, Identifiable {
        public let id: String
        public let name: String
        /// 与 allergy_event.allergen_kind 同词表：药品/食物/环境/其他
        public let kind: String
    }

    public static let commonAllergens: [CommonAllergen] = [
        .init(id: "penicillin", name: "青霉素", kind: "药品"),
        .init(id: "cephalosporin", name: "头孢类", kind: "药品"),
        .init(id: "sulfonamide", name: "磺胺类", kind: "药品"),
        .init(id: "aspirin", name: "阿司匹林", kind: "药品"),
        .init(id: "nsaid", name: "布洛芬/NSAIDs", kind: "药品"),
        .init(id: "contrast_media", name: "造影剂", kind: "药品"),
        .init(id: "peanut", name: "花生", kind: "食物"),
        .init(id: "tree_nut", name: "坚果", kind: "食物"),
        .init(id: "egg", name: "鸡蛋", kind: "食物"),
        .init(id: "milk", name: "牛奶", kind: "食物"),
        .init(id: "wheat", name: "小麦/麸质", kind: "食物"),
        .init(id: "soy", name: "大豆", kind: "食物"),
        .init(id: "fish", name: "鱼", kind: "食物"),
        .init(id: "shellfish", name: "虾蟹贝类", kind: "食物"),
        .init(id: "mango", name: "芒果", kind: "食物"),
        .init(id: "pollen", name: "花粉", kind: "环境"),
        .init(id: "dust_mite", name: "尘螨", kind: "环境"),
        .init(id: "mold", name: "霉菌", kind: "环境"),
        .init(id: "cat", name: "猫毛", kind: "环境"),
        .init(id: "dog", name: "狗毛", kind: "环境"),
        .init(id: "latex", name: "乳胶", kind: "环境"),
        .init(id: "bee_venom", name: "蜂毒", kind: "其他"),
    ]

    public static func allergens(kind: String) -> [CommonAllergen] {
        commonAllergens.filter { $0.kind == kind }
    }
}
