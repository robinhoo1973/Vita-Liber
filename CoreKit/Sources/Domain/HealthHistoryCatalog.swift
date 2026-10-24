import Foundation

/// 健康史目录（Domain 静态数据，不联网、不做诊断推断）。
///
/// 依据《中国防治慢性病中长期规划（2017—2025年）》与 WHO NCD 四大类的
/// 常见病名整理，作为「按部位查找 + 常见快捷项」的索引；病名是用户
/// 自报事实，选择本身不产生诊断。2026-10-24 业主：取消自由文本，
/// 名称/类别/器官由官方医保码表子集锁定；个人只能补别名。
public enum HealthHistoryCatalog {
    /// 码表与映射版本单一事实源（App 不得内联中文字面量）。
    public static let codeSystemName = "ICD-10 医保版 2.0"
    public static let mappingVersionName = "医保版 2.0"

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
            BodyOrgan(id: "head", name: "头部"), BodyOrgan(id: "brain", name: "脑"), BodyOrgan(id: "eye", name: "眼"), BodyOrgan(id: "ear", name: "耳"),
            BodyOrgan(id: "nose_throat", name: "鼻咽喉"), BodyOrgan(id: "mouth", name: "口腔"), BodyOrgan(id: "thyroid", name: "甲状腺"), BodyOrgan(id: "neck", name: "颈部"),
        ]),
        .init(id: "chest", name: "胸部", organs: [
            BodyOrgan(id: "heart", name: "心脏"), BodyOrgan(id: "lung", name: "肺"), BodyOrgan(id: "breast", name: "乳腺"), BodyOrgan(id: "esophagus", name: "食管"),
        ]),
        .init(id: "abdomen", name: "腹部", organs: [
            BodyOrgan(id: "stomach", name: "胃"), BodyOrgan(id: "liver", name: "肝"), BodyOrgan(id: "gallbladder", name: "胆囊"), BodyOrgan(id: "pancreas", name: "胰腺"),
            BodyOrgan(id: "intestine", name: "肠道"), BodyOrgan(id: "kidney", name: "肾"), BodyOrgan(id: "spleen", name: "脾"),
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
        /// 官方目录别名（用于搜索，不改变显示名）。
        public let aliases: [String]
        /// 疾病诊断分类与代码（医保版 2.0）；nil = 目录项尚未完成官方映射。
        public let code: String?
        public let codeSystem: String?
        /// 对应部位 id；systemic 表示全身/系统性疾病。
        public let regionID: String
        /// 官方映射的器官/组织 id（可多选；展示时按顺序取第一个）。
        public let organIDs: [String]
        public var organID: String? { organIDs.first }
        public init(id: String, name: String, aliases: [String] = [],
                    code: String? = nil, codeSystem: String? = "ICD-10 医保版 2.0",
                    regionID: String, organIDs: [String] = []) {
            self.id = id; self.name = name; self.aliases = aliases
            self.code = code; self.codeSystem = codeSystem
            self.regionID = regionID; self.organIDs = organIDs
        }
        /// 兼容旧调用：单器官目录项。
        public init(id: String, name: String, regionID: String, organID: String?) {
            self.init(id: id, name: name, regionID: regionID,
                      organIDs: organID.map { [$0] } ?? [])
        }
    }

    /// 常见慢性病目录（国家医保局《疾病诊断分类与代码 医保版 2.0》子集 +
    /// 常见基层病；不是穷举目录）。码值来源：code.nhsa.gov.cn；仅作目录映射，
    /// 不复制完整码表，不构成诊断。
    /// 2026-10-24 业主：取消自由文本，名称只能从此目录选择；码值仅作目录
    /// 映射与导出引用，不构成诊断或推断。
    public static let commonConditions: [CommonCondition] = [
        .init(id: "hypertension", name: "高血压", aliases: ["原发性高血压"], code: "I10", regionID: "systemic"),
        .init(id: "dyslipidemia", name: "高血脂", aliases: ["高脂血症", "血脂异常"], code: "E78.5", regionID: "systemic"),
        .init(id: "type2_diabetes", name: "糖尿病二型", aliases: ["2型糖尿病", "2 型糖尿病", "二型糖尿病"], code: "E11.900", regionID: "systemic", organIDs: ["endocrine"]),
        .init(id: "type1_diabetes", name: "糖尿病一型", aliases: ["1型糖尿病", "1 型糖尿病", "一型糖尿病"], code: "E10.900", regionID: "systemic", organIDs: ["endocrine"]),
        .init(id: "coronary_heart_disease", name: "冠心病", aliases: ["冠状动脉粥样硬化性心脏病"], code: "I25.100", regionID: "chest", organIDs: ["heart"]),
        .init(id: "stroke", name: "脑卒中", aliases: ["中风", "脑血管意外"], code: "I64.x00", regionID: "head_neck", organIDs: ["brain"]),
        .init(id: "chronic_heart_failure", name: "慢性心力衰竭", aliases: ["慢性心衰"], code: "I50.908", regionID: "chest", organIDs: ["heart"]),
        .init(id: "copd", name: "慢性阻塞性肺疾病", aliases: ["慢阻肺", "COPD"], code: "J44.900", regionID: "chest", organIDs: ["lung"]),
        .init(id: "asthma", name: "哮喘", aliases: ["支气管哮喘"], code: "J45.900", regionID: "chest", organIDs: ["lung"]),
        .init(id: "chronic_kidney_disease", name: "慢性肾病", aliases: ["慢性肾脏病", "CKD"], code: "N18.900", regionID: "abdomen", organIDs: ["kidney"]),
        .init(id: "hepatitis_b", name: "慢性乙型肝炎", aliases: ["慢乙肝", "乙肝"], code: "B18.100", regionID: "abdomen", organIDs: ["liver"]),
        .init(id: "hepatitis_c", name: "慢性丙型肝炎", aliases: ["慢丙肝", "丙肝"], code: "B18.200", regionID: "abdomen", organIDs: ["liver"]),
        .init(id: "fatty_liver", name: "脂肪肝", aliases: ["非酒精性脂肪肝"], code: "K76.000", regionID: "abdomen", organIDs: ["liver"]),
        .init(id: "cirrhosis", name: "肝硬化", aliases: ["肝硬变"], code: "K74.600", regionID: "abdomen", organIDs: ["liver"]),
        .init(id: "chronic_gastritis", name: "慢性胃炎", code: "K29.500", regionID: "abdomen", organIDs: ["stomach"]),
        .init(id: "peptic_ulcer", name: "消化性溃疡", aliases: ["胃溃疡", "十二指肠溃疡"], code: "K27.901", regionID: "abdomen", organIDs: ["stomach"]),
        .init(id: "hyperthyroidism", name: "甲状腺功能亢进", aliases: ["甲亢"], code: "E05.900x001", regionID: "head_neck", organIDs: ["thyroid"]),
        .init(id: "hypothyroidism", name: "甲状腺功能减退", aliases: ["甲减"], code: "E03.900", regionID: "head_neck", organIDs: ["thyroid"]),
        .init(id: "rheumatoid_arthritis", name: "类风湿关节炎", aliases: ["类风湿性关节炎"], code: "M06.900", regionID: "systemic", organIDs: ["skeletal"]),
        .init(id: "gout", name: "痛风", code: "M10.900", regionID: "systemic", organIDs: ["skeletal"]),
        .init(id: "hyperuricemia", name: "高尿酸血症", code: "E79.001", regionID: "systemic", organIDs: ["blood"]),
        .init(id: "osteoporosis", name: "骨质疏松", code: "M81.900", regionID: "systemic", organIDs: ["skeletal"]),
        .init(id: "depression", name: "抑郁症", aliases: ["抑郁发作"], code: "F32.900", regionID: "systemic", organIDs: ["mental"]),
        .init(id: "anxiety", name: "焦虑症", aliases: ["焦虑障碍"], code: "F41.900", regionID: "systemic", organIDs: ["mental"]),
        .init(id: "oral_ulcer", name: "复发性口腔溃疡", aliases: ["口腔溃疡", "阿弗他溃疡"], code: "K12.000", regionID: "head_neck", organIDs: ["mouth"]),
        .init(id: "chronic_pharyngitis", name: "慢性咽炎", code: "J31.200", regionID: "head_neck", organIDs: ["nose_throat"]),
        .init(id: "chronic_rhinitis", name: "慢性鼻炎", code: "J31.000", regionID: "head_neck", organIDs: ["nose_throat"]),
        .init(id: "chronic_sinusitis", name: "慢性鼻窦炎", code: "J32.900", regionID: "head_neck", organIDs: ["nose_throat"]),
        .init(id: "allergic_rhinitis", name: "过敏性鼻炎", aliases: ["变应性鼻炎"], code: "J30.400", regionID: "head_neck", organIDs: ["nose_throat"]),
        .init(id: "cataract", name: "白内障", code: "H26.900", regionID: "head_neck", organIDs: ["eye"]),
        .init(id: "glaucoma", name: "青光眼", code: "H40.900", regionID: "head_neck", organIDs: ["eye"]),
        .init(id: "otitis_media", name: "中耳炎", code: "H66.900", regionID: "head_neck", organIDs: ["ear"]),
        .init(id: "migraine", name: "偏头痛", code: "G43.900", regionID: "head_neck", organIDs: ["brain"]),
        .init(id: "epilepsy", name: "癫痫", code: "G40.900", regionID: "head_neck", organIDs: ["brain"]),
        .init(id: "parkinson", name: "帕金森病", code: "G20", regionID: "head_neck", organIDs: ["brain"]),
        .init(id: "alzheimer", name: "阿尔茨海默病", aliases: ["老年痴呆"], code: "G30.900", regionID: "head_neck", organIDs: ["brain"]),
        .init(id: "cervical_spondylosis", name: "颈椎病", code: "M47.800", regionID: "back", organIDs: ["spine"]),
        .init(id: "lumbar_disc_herniation", name: "腰椎间盘突出", aliases: ["腰椎间盘突出症"], code: "M51.202", regionID: "back", organIDs: ["spine"]),
        .init(id: "osteoarthritis", name: "骨关节炎", code: "M19.900", regionID: "lower_limb", organIDs: ["knee", "hip"]),
        .init(id: "frozen_shoulder", name: "肩周炎", code: "M75.001", regionID: "upper_limb", organIDs: ["shoulder"]),
        .init(id: "chronic_bronchitis", name: "慢性支气管炎", code: "J42.x00", regionID: "chest", organIDs: ["lung"]),
        .init(id: "bronchiectasis", name: "支气管扩张", code: "J47.x00", regionID: "chest", organIDs: ["lung"]),
        .init(id: "tuberculosis", name: "肺结核", code: "A16.200x002", regionID: "chest", organIDs: ["lung"]),
        .init(id: "cholecystitis", name: "胆囊炎", code: "K81.900", regionID: "abdomen", organIDs: ["gallbladder"]),
        .init(id: "gallstones", name: "胆结石", aliases: ["胆石症"], code: "K80.200", regionID: "abdomen", organIDs: ["gallbladder"]),
        .init(id: "chronic_pancreatitis", name: "慢性胰腺炎", code: "K86.100x002", regionID: "abdomen", organIDs: ["pancreas"]),
        .init(id: "ulcerative_colitis", name: "溃疡性结肠炎", code: "K51.900", regionID: "abdomen", organIDs: ["intestine"]),
        .init(id: "crohn", name: "克罗恩病", code: "K50.900", regionID: "abdomen", organIDs: ["intestine"]),
        .init(id: "ibs", name: "肠易激综合征", aliases: ["IBS"], code: "K58.801", regionID: "abdomen", organIDs: ["intestine"]),
        .init(id: "constipation", name: "便秘", code: "K59.000", regionID: "abdomen", organIDs: ["intestine"]),
        .init(id: "gerd", name: "胃食管反流", aliases: ["胃食管反流病"], code: "K21.900x003", regionID: "chest", organIDs: ["esophagus"]),
        .init(id: "chronic_prostatitis", name: "慢性前列腺炎", code: "N41.100", regionID: "pelvis", organIDs: ["prostate"]),
        .init(id: "bph", name: "前列腺增生", code: "N40.x00", regionID: "pelvis", organIDs: ["prostate"]),
        .init(id: "chronic_cystitis", name: "慢性膀胱炎", code: "N30.201", regionID: "pelvis", organIDs: ["bladder"]),
        .init(id: "urinary_stone", name: "尿路结石", aliases: ["肾结石"], code: "N20.000", regionID: "abdomen", organIDs: ["kidney"]),
        .init(id: "uterine_fibroid", name: "子宫肌瘤", code: "D25.900", regionID: "pelvis", organIDs: ["uterus"]),
        .init(id: "endometriosis", name: "子宫内膜异位症", code: "N80.900", regionID: "pelvis", organIDs: ["uterus", "ovary"]),
        .init(id: "pcos", name: "多囊卵巢综合征", aliases: ["PCOS"], code: "E28.200", regionID: "pelvis", organIDs: ["ovary"]),
        .init(id: "breast_hyperplasia", name: "乳腺增生", code: "N60.900", regionID: "chest", organIDs: ["breast"]),
        .init(id: "thyroid_nodule", name: "甲状腺结节", code: "E04.101", regionID: "head_neck", organIDs: ["thyroid"]),
        .init(id: "eczema", name: "湿疹", code: "L30.902", regionID: "systemic", organIDs: ["immune"]),
        .init(id: "psoriasis", name: "银屑病", aliases: ["牛皮癣"], code: "L40.900", regionID: "systemic", organIDs: ["immune"]),
        .init(id: "urticaria", name: "荨麻疹", code: "L50.900", regionID: "systemic", organIDs: ["immune"]),
        .init(id: "anemia", name: "贫血", code: "D64.900", regionID: "systemic", organIDs: ["blood"]),
        .init(id: "obesity", name: "肥胖症", code: "E66.900", regionID: "systemic", organIDs: ["endocrine"]),
        .init(id: "atrial_fibrillation", name: "心房颤动", aliases: ["房颤"], code: "I48.900", regionID: "chest", organIDs: ["heart"]),
        .init(id: "varicose_veins", name: "下肢静脉曲张", aliases: ["静脉曲张"], code: "I83.900x004", regionID: "lower_limb", organIDs: ["thigh", "ankle_foot"]),
        .init(id: "sleep_disorder", name: "睡眠障碍", aliases: ["失眠"], code: "G47.900", regionID: "systemic", organIDs: ["mental"]),
        .init(id: "bipolar", name: "双相情感障碍", aliases: ["双相障碍"], code: "F31.900", regionID: "systemic", organIDs: ["mental"]),
        .init(id: "schizophrenia", name: "精神分裂症", code: "F20.900", regionID: "systemic", organIDs: ["mental"]),
    ]

    /// 官方目录查找：新建/编辑/迁移共用，避免视图各自按名称猜。
    public static func condition(id: String) -> CommonCondition? {
        commonConditions.first { $0.id == id }
    }

    public static func condition(matching name: String) -> CommonCondition? {
        commonConditions.first { condition in
            condition.name == name || condition.aliases.contains(name)
        }
    }

    public static func conditions(in regionID: String) -> [CommonCondition] {
        commonConditions.filter { $0.regionID == regionID }
    }

    /// 部位 + 器官两层过滤：选中器官时只给该器官的已映射病种；
    /// 无专属条目时回落到部位级（organIDs 为空），否则为空——
    /// 不把其他器官的疾病当成该器官的常见项（语义准确性优先）。
    public static func conditions(in regionID: String, organID: String?) -> [CommonCondition] {
        let inRegion = conditions(in: regionID)
        guard let organID else { return inRegion }
        let matched = inRegion.filter { $0.organIDs.contains(organID) }
        return matched.isEmpty ? inRegion.filter { $0.organIDs.isEmpty } : matched
    }

    // MARK: - Common surgeries

    public struct CommonSurgery: Sendable, Equatable, Identifiable {
        public let id: String
        public let name: String
        public let regionID: String
        /// 对应器官/组织 id（可选）；用于人体图二级层面的相关性过滤。
        public let organID: String?
        public init(id: String, name: String, regionID: String, organID: String? = nil) {
            self.id = id; self.name = name; self.regionID = regionID; self.organID = organID
        }
    }

    public static let commonSurgeries: [CommonSurgery] = [
        .init(id: "thyroidectomy", name: "甲状腺切除术", regionID: "head_neck", organID: "thyroid"),
        .init(id: "tonsillectomy", name: "扁桃体/腺样体切除术", regionID: "head_neck", organID: "nose_throat"),
        .init(id: "cataract", name: "白内障手术", regionID: "head_neck", organID: "eye"),
        .init(id: "coronary_stent", name: "心脏支架植入", regionID: "chest", organID: "heart"),
        .init(id: "cabg", name: "冠脉搭桥术", regionID: "chest", organID: "heart"),
        .init(id: "lung_resection", name: "肺叶切除术", regionID: "chest", organID: "lung"),
        .init(id: "breast_surgery", name: "乳腺手术", regionID: "chest", organID: "breast"),
        .init(id: "appendectomy", name: "阑尾切除术", regionID: "abdomen", organID: "intestine"),
        .init(id: "cholecystectomy", name: "胆囊切除术", regionID: "abdomen", organID: "gallbladder"),
        .init(id: "hernia_repair", name: "疝修补术", regionID: "abdomen"),
        .init(id: "gastrectomy", name: "胃切除术", regionID: "abdomen", organID: "stomach"),
        .init(id: "bowel_resection", name: "肠切除/吻合术", regionID: "abdomen", organID: "intestine"),
        .init(id: "cesarean", name: "剖宫产", regionID: "pelvis", organID: "uterus"),
        .init(id: "hysterectomy", name: "子宫切除术", regionID: "pelvis", organID: "uterus"),
        .init(id: "ovarian_cystectomy", name: "卵巢囊肿手术", regionID: "pelvis", organID: "ovary"),
        .init(id: "prostatectomy", name: "前列腺手术", regionID: "pelvis", organID: "prostate"),
        .init(id: "spine_fusion", name: "脊柱融合/椎间盘手术", regionID: "back", organID: "spine"),
        .init(id: "fracture_fixation_upper", name: "上肢骨折内固定", regionID: "upper_limb", organID: "arm"),
        .init(id: "carpal_tunnel", name: "腕管松解术", regionID: "upper_limb", organID: "wrist_hand"),
        .init(id: "hip_replacement", name: "髋关节置换", regionID: "lower_limb", organID: "hip"),
        .init(id: "knee_replacement", name: "膝关节置换", regionID: "lower_limb", organID: "knee"),
        .init(id: "fracture_fixation_lower", name: "下肢骨折内固定", regionID: "lower_limb", organID: "thigh"),
    ]

    public static func surgery(id: String) -> CommonSurgery? {
        commonSurgeries.first { $0.id == id }
    }

    public static func surgeries(in regionID: String) -> [CommonSurgery] {
        commonSurgeries.filter { $0.regionID == regionID }
    }

    /// 部位 + 器官两层过滤；无专属条目时回落到部位级（organID == nil）。
    public static func surgeries(in regionID: String, organID: String?) -> [CommonSurgery] {
        let inRegion = surgeries(in: regionID)
        guard let organID else { return inRegion }
        let matched = inRegion.filter { $0.organID == organID }
        return matched.isEmpty ? inRegion.filter { $0.organID == nil } : matched
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
