# -*- coding: utf-8 -*-
"""
抽取训练语料构建器（真实数据驱动 + 注册表可扩展，2026-09-24）

—— 2026-10-07 迁入 CI 簇（.github/actions/distill/extract/）说明：本文件是
   refactor/tools/training/{macos,windows}/scripts/corpus/build_extraction_corpus.py
   的正本迁入（同轮迁入 extraction_noise.py 与 datamatrix.py 裁剪版），改动仅三处：
   ① 数据源路径说明（CI 的 data-dir 由 catalog_source.py 从 CNB Release 目录物化）；
   ② datamatrix 改为同目录 import（CI 无 trainlib 包布局）；
   ③ 默认路径改为仓锚定（prompts 落本目录 prompts/、tokenizer 取 .github/actions/distill/gen/）。
   生成逻辑（REGISTRY/POOLS/噪声/预算/verbatim 守卫）与训练机逐字一致——
   两端同步纪律：任何修改必须两侧同步（训练/推理同分布的组成部分）。

—— 目标（业主定案）：让小模型对 OCR/ASR 文本**快速精准定位**并抽出处方信息卡所需
   字段（药名 / 规格 / 用量 / 频次 / 途径 / 天数 …），并可直接服务后续的医院、
   科室、疾病、检查/检验名称等实体类型训练。

—— 输出契约 = App 端 T2 解码契约（三者同形的机械保证）：
   {"shared":[{"key","value","unit","lineIndex"}],"rows":[[…]]}
   训练数据由 `prompts/prompt_<kind>.txt`（App `ExtractionPromptBuilder`
   逐字导出，export_prompts.sh 编译 Domain 源代码生成）作为 system 段、
   App 同款「[i] 行」编号作为 user 段——训练/推理同分布。

—— 输入：
   --data-dir    CI：catalog_source.py 从目录 SQLite 物化的 data-dir
                 （drugs_cn / drugs_nhsa / tw_records / hk_records /
                 medical_details / medical_index / ref/<域>_<地区>.jsonl …）
   --cells       训练数据格子「类型/地区」（datamatrix 唯一事实源：drugs|hospitals|departments|diagnoses|exams ×
                 cn|hk|tw）。药品池按地区加载；医院/科室/诊断/检验名称池优先取 data/ref/<域>_<地区>.jsonl，
                 缺文件退回内置名单并在清单 pools.ref 标 fallback。样本按所选地区分布生成（TW/HK 繁体版式）。
                 --regions/--types 交叉、旧 --sources（药品源）仍可用，取舍规则见 datamatrix.resolve_cells。
   --prompts-dir prompts/（.github/actions/distill/extract/export_prompts.sh 从 CoreKit Domain 编译导出）

—— 输出（--out-dir，默认 out/extract-dataset）：
   extraction_sft.jsonl      多任务 SFT（conversations 形状；assistant=span JSON）
   extraction_pretrain.jsonl 领域继续预训练文本（{"text": …}）
   extraction_eval.jsonl     留出集（同 SFT 形状；训练侧自动排除）
   extraction_manifest.json  参数 + 计数 + 抽样统计 + sha256（可复现）

—— 扩展方式（新增实体类型 = 三件事，零改训练代码）：
   1) 跑一次 export_prompts.sh → 新卡种 prompt_/spec_ 文件自动出现；
   2) REGISTRY 追加一项：{mode, weight, builder}；
   3) 如需要新的值来源，在 POOLS 装配处补一个 Source 适配器（照 load_drugs 的写法）。

—— 纪律：
   * 噪声只在「段」级施加，span value 取加噪后原文 → verbatim 契约由构造保证；
   * 字符集与 tokenizer 词表比对（`--tokenizer`；字节级 BPE 无 OOV 概念，自动跳过）；
   * token 预算守卫（--budget，默认 2000 ≈ SFT max_seq_len 2048 - 帧/EOS 余量）：
     超预算先削可选 span 再削行，仍超则丢弃；
   * 全流程只用 stdlib + 本地文件；不使用网络。
"""
import argparse
import hashlib
import json
import os
import random
import re
import sys
import unicodedata

# Windows 重定向守则（2026-09-24 首跑教训）：Python 3.14 在非 UTF-8 机器上，stdout 被
# 重定向为管道/文件时退回 cp1252 → 中文 print 直接 UnicodeEncodeError。显式切 UTF-8。
for _std in (sys.stdout, sys.stderr):
    if _std and hasattr(_std, "reconfigure"):
        try:
            _std.reconfigure(encoding="utf-8", errors="replace")
        except Exception:
            pass

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from extraction_noise import (  # noqa: E402
    sanitize_hard, ocr_noise_segment, ocr_separator, asr_noise_segment, voiced,
    NOISE_VERSION, BAND_CER, DEFAULT_TRAIN_MIX, new_noise_ctx, noise_ctx_summary,
    ocr_noise_segment_v2, asr_noise_segment_v2, confusion_tables_sha256,
)
from line_ops import apply_line_ops  # noqa: E402

ROOT = os.path.dirname(os.path.abspath(__file__))
while ROOT != os.path.dirname(ROOT) and not os.path.isdir(os.path.join(ROOT, "CoreKit", "Sources", "Domain")):
    ROOT = os.path.dirname(ROOT)  # 仓锚探测（禁用固定层级 parents[N]——脚本搬迁不改语义）


def _load_datamatrix():
    """datamatrix = 「类型 × 地区」矩阵的唯一事实源（格子 → 文件 / 派生规则）。
    CI 布局：与本文件同目录（训练机正本迁入裁剪版，CELLS 表逐字保留）。stdlib only。"""
    from datamatrix import CELLS, CELL_BY_KEY  # noqa: F401,E402  （import 即验证可用）
    import datamatrix  # noqa: E402
    return datamatrix


DM = _load_datamatrix()

# ================================================================ 常量与工具

DEFAULT_BUDGET = 2000  # SFT 训练 max_seq_len=2048（system 提示词实测 1351 tokens；见 2026-09-24 实测报告）

CN_NUM = {"1": "一", "2": "两", "3": "三", "4": "四", "5": "五", "6": "六", "7": "七", "8": "八", "9": "九", "10": "十"}

FREQ_TIMES = ["每日1次", "每日2次", "每日3次", "每日4次", "每天1次", "每天2次", "每天3次",
              "每8小时1次", "每12小时1次", "一天3次", "一天2次", "每日一次", "每日三次"]
ROUTES = ["口服", "餐后口服", "餐前口服", "外用", "含服", "嚼服", "睡前口服", "吸入", "皮下注射", "静脉滴注"]
QUANTITY_UNITS = ["盒", "瓶", "袋", "支", "板", "包"]
DOSAGE_UNITS_DEFAULT = ["片", "粒", "袋", "支", "瓶", "贴"]
FORM_TO_UNIT = [("片", "片"), ("胶囊", "粒"), ("颗粒", "袋"), ("口服液", "支"), ("溶液", "瓶"),
                ("软膏", "支"), ("乳膏", "支"), ("凝胶", "支"), ("滴眼", "瓶"), ("滴鼻", "瓶"),
                ("喷雾", "瓶"), ("注射", "支"), ("栓", "粒"), ("贴", "贴"), ("散", "袋"), ("丸", "丸")]
HOSPITAL_CITIES = ["北京", "上海", "广州", "深圳", "杭州", "南京", "成都", "武汉", "西安", "重庆",
                   "苏州", "长沙", "郑州", "青岛", "宁波", "厦门", "合肥", "济南", "福州", "昆明"]
HOSPITAL_SUFFIX = ["市第一人民医院", "市人民医院", "市中心医院", "大学附属第一医院", "市中医院",
                   "区人民医院", "社区卫生服务中心", "大学附属医院", "市第二人民医院"]
DEPTS_CN = ["心内科", "呼吸内科", "消化内科", "内分泌科", "神经内科", "全科", "骨科", "皮肤科",
            "儿科", "妇科", "眼科", "耳鼻喉科", "口腔科", "泌尿外科", "急诊科", "中医科",
            "感染科", "风湿免疫科", "肾内科", "血液科", "精神科", "康复科", "疼痛科", "老年病科"]
DEPTS_TW = ["心臟內科", "胸腔內科", "胃腸肝膽科", "內分泌科", "神經內科", "家醫科", "骨科", "皮膚科",
            "兒科", "婦產科", "眼科", "耳鼻喉科", "牙科", "泌尿科", "急診醫學科", "中醫科"]
# TW/HK 内置医院兜底（真实公立/教学医院名；data/ref/hospital_<地区>.jsonl 存在时不用）
HOSPITAL_FALLBACK = {
    "TW": ["臺大醫院", "臺北榮民總醫院", "三軍總醫院", "林口長庚紀念醫院", "高雄長庚紀念醫院", "臺中榮民總醫院",
           "中國醫藥大學附設醫院", "成大醫院", "高雄醫學大學附設中和紀念醫院", "馬偕紀念醫院", "新光醫院",
           "國泰綜合醫院", "彰化基督教醫院", "奇美醫院", "臺北市立聯合醫院"],
    "HK": ["瑪麗醫院", "威爾斯親王醫院", "伊利沙伯醫院", "廣華醫院", "屯門醫院", "九龍醫院", "東區尤德夫人那打素醫院",
           "基督教聯合醫院", "仁濟醫院", "博愛醫院", "北區醫院", "將軍澳醫院", "明愛醫院", "瑪嘉烈醫院"],
}
# 简 → 繁 字表：只覆盖本文件模板常量里出现的字（版式标签/主诉/医嘱/途径/频次/检验名），TW/HK 版式用；
# 不是通用转换器——药名/机构名等真实数据本身已是对应地区文字，不经过它。
_S2T_PAIRS = ("临臨 丸丸 乳乳 关關 冠冠 减減 凝凝 刺刺 劳勞 医醫 历歷 压壓 双雙 发發 号號 后後 呼呼 咳咳 咽咽 喷噴 嗽嗽 嘱囑 "
              "囊囊 处處 复復 头頭 孢孢 室室 尿尿 差差 师師 床床 应應 悸悸 态態 总總 报報 支支 敏敏 数數 断斷 时時 晕暈 "
              "机機 构構 松鬆 板板 标標 栓栓 梗梗 检檢 椎椎 气氣 氨氨 氮氮 沉沉 油油 注注 涕涕 液液 淋淋 湿濕 溃潰 "
              "滴滴 烧燒 热熱 焦焦 瓶瓶 疏疏 疡瘍 疹疹 痒癢 痰痰 盐鹽 盘盤 眠眠 离離 笺箋 类類 粒粒 糖糖 累累 红紅 "
              "纳納 细細 缺缺 肌肌 肤膚 肾腎 肿腫 胆膽 胞胞 胶膠 胺胺 脂脂 脉脈 脑腦 腺腺 膏膏 节節 荨蕁 药藥 虑慮 "
              "衰衰 袋袋 规規 诉訴 诊診 谷穀 质質 贫貧 贴貼 转轉 软軟 过過 适適 郁鬱 酐酐 酯酯 酶酶 钠鈉 钾鉀 铁鐵 "
              "张張 刘劉 陈陳 杨楊 赵趙 黄黃 吴吳 孙孫 马馬 门門 间間 闷悶 随隨 雾霧 霉黴 静靜 项項 颗顆 风風 饭飯 饮飲 验驗 麻麻 术術 综綜 结結 计計 单單 参參 "
              "围圍 异異 检檢 测測 剂劑 见見 说說 书書 让讓 帮幫 个個 还還 吗嗎 记記 录錄 写寫 为為 现現 请請 对對 与與")
S2T = str.maketrans({pair[0]: pair[1] for pair in _S2T_PAIRS.split() if len(pair) == 2 and pair[0] != pair[1]})


_S2T_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "tables", "s2t")


def _load_char_map(name):
    """读入仓钉版简繁表(OpenCC 数据;PROVENANCE.md 记来源/sha256/许可)。缺文件→{}。"""
    path = os.path.join(_S2T_DIR, name)
    out = {}
    if os.path.isfile(path):
        with open(path, "r", encoding="utf-8") as fh:
            for line in fh:
                parts = line.split()
                if len(parts) >= 2:
                    out.setdefault(parts[0], parts[1])
    return out


_S2T_OTC = _load_char_map("STCharacters.txt")
_TW_VARIANTS = _load_char_map("TWVariants.txt")
_HK_VARIANTS = _load_char_map("HKVariants.txt")


def L(region, text):
    """地区版式文字：CN 原样；TW/HK 走 OpenCC 钉版表(STCharacters + 地区变体;
    2026-10-08 换表,手抄 120 对表仅剩兜底——表缺失=训练机旧布局回落)。"""
    if region == "CN":
        return text
    if _S2T_OTC:
        out = "".join(_S2T_OTC.get(ch, ch) for ch in text)
        variants = _TW_VARIANTS if region == "TW" else _HK_VARIANTS
        if variants:
            out = "".join(variants.get(ch, ch) for ch in out)
        return out
    return text.translate(S2T)


DOCTOR_SURNAMES = ["王", "李", "张", "刘", "陈", "杨", "赵", "黄", "周", "吴", "徐", "孙", "马", "朱", "胡", "郭", "何", "林"]
COMPLAINTS = ["头晕伴头痛3天", "咳嗽咳痰1周", "多饮多尿2月", "胸闷气促2天", "上腹痛1周",
              "腰痛伴左下肢放射痛3天", "皮肤瘙痒2周", "失眠1月", "关节疼痛1周", "发热2天",
              "咽痛伴流涕3天", "反酸烧心2周", "心悸1周", "乏力纳差半月", "双下肢水肿1周"]
TCM_ADVICES = ["饭后服用，多饮水", "忌辛辣刺激饮食", "不适随诊", "定期复查肝肾功能",
               "注意休息，避免劳累", "低盐低脂饮食", "一周后复诊"]
ALLERGY_LINES = ["青霉素过敏史", "磺胺类药物过敏", "头孢过敏史", "阿司匹林过敏"]

LAB_ITEMS = [
    ("白细胞", "WBC", "×10^9/L", 3.5, 9.5), ("红细胞", "RBC", "×10^12/L", 3.8, 5.8),
    ("血红蛋白", "HGB", "g/L", 115, 175), ("血小板", "PLT", "×10^9/L", 125, 350),
    ("中性粒细胞", "NEUT", "×10^9/L", 1.8, 6.3), ("淋巴细胞", "LYMPH", "×10^9/L", 1.1, 3.2),
    ("空腹血糖", "GLU", "mmol/L", 3.9, 6.1), ("糖化血红蛋白", "HbA1c", "%", 4.0, 6.0),
    ("总胆固醇", "TC", "mmol/L", 2.9, 5.2), ("甘油三酯", "TG", "mmol/L", 0.56, 1.7),
    ("高密度脂蛋白", "HDL-C", "mmol/L", 1.0, 1.55), ("低密度脂蛋白", "LDL-C", "mmol/L", 1.5, 3.4),
    ("谷丙转氨酶", "ALT", "U/L", 7, 40), ("谷草转氨酶", "AST", "U/L", 13, 35),
    ("总胆红素", "TBIL", "μmol/L", 3.4, 20.5), ("肌酐", "Cr", "μmol/L", 44, 106),
    ("尿素氮", "BUN", "mmol/L", 2.6, 7.5), ("尿酸", "UA", "μmol/L", 155, 428),
    ("促甲状腺激素", "TSH", "mIU/L", 0.27, 4.2), ("游离甲状腺素", "FT4", "pmol/L", 12, 22),
    ("C反应蛋白", "CRP", "mg/L", 0, 8), ("血沉", "ESR", "mm/h", 0, 20),
    ("钾", "K", "mmol/L", 3.5, 5.3), ("钠", "Na", "mmol/L", 137, 147),
]

# 疾病词表兜底（真实数据不足时并入；真实来源 = medical_details.indications 后缀抽取）
DISEASE_FALLBACK = ["高血压", "2型糖尿病", "冠心病", "高脂血症", "痛风", "慢性胃炎", "胃溃疡",
                    "上呼吸道感染", "支气管炎", "哮喘", "过敏性鼻炎", "荨麻疹", "湿疹",
                    "缺铁性贫血", "甲状腺功能减退", "腰椎间盘突出", "骨质疏松", "失眠症",
                    "焦虑状态", "抑郁症", "尿路感染", "胆囊炎", "脂肪肝", "肝硬化",
                    "脑梗死", "脑出血", "心肌梗死", "心律失常", "心力衰竭", "慢性支气管炎"]
DISEASE_SUFFIXES = ("病", "炎", "症", "瘤", "癌", "溃疡", "综合征", "感染", "结石", "骨折",
                    "外伤", "哮喘", "高血压", "糖尿病", "冠心病", "皮炎", "鼻炎", "咽炎",
                    "胃炎", "贫血", "癫痫", "湿疹", "栓塞", "梗死", "衰竭", "中毒", "增生病")

# ================================================================ 注册表（扩展点）

REGISTRY = {
    "prescription": {"mode": "ocr", "weight": 0.20, "builder": "gen_prescription"},
    "medication":   {"mode": "asr", "weight": 0.09, "builder": "gen_medication"},
    "encounter":    {"mode": "ocr", "weight": 0.10, "builder": "gen_encounter"},
    "metric_sample": {"mode": "ocr", "weight": 0.06, "builder": "gen_metric_sample"},
    # 卡种 4→13（2026-10-08 数据批；App ExtractionSpecRegistry 单一事实源）
    "hospitalization": {"mode": "ocr", "weight": 0.09, "builder": "gen_generic_card"},
    "exam_report":     {"mode": "ocr", "weight": 0.09, "builder": "gen_generic_card"},
    "diagnosis":       {"mode": "ocr", "weight": 0.08, "builder": "gen_generic_card"},
    "health_exam":     {"mode": "ocr", "weight": 0.08, "builder": "gen_generic_card"},
    "claim_item":      {"mode": "ocr", "weight": 0.05, "builder": "gen_generic_card"},
    "surgery":         {"mode": "ocr", "weight": 0.05, "builder": "gen_generic_card"},
    "treatment_record": {"mode": "ocr", "weight": 0.05, "builder": "gen_generic_card"},
    "clinical_conclusion": {"mode": "ocr", "weight": 0.03, "builder": "gen_generic_card"},
    "immunization":    {"mode": "ocr", "weight": 0.03, "builder": "gen_generic_card"},
}


def log(msg):
    print(msg, flush=True)


def _est_fallback(text):
    """无 tokenizers 库时的保守估算（标定：CJK≈1.5 tok/char，其余≈0.62 tok/char——偏大侧，宁多勿少）。"""
    cjk = sum(1 for ch in text if "\u4e00" <= ch <= "\u9fff" or "\u3400" <= ch <= "\u4dbf")
    return int(cjk * 1.5 + (len(text) - cjk) * 0.62 + 4)


_EST = _est_fallback


def est_tokens(text):
    return _EST(text)


def make_token_counter(tokenizer_path):
    """真实 tokenizer（tokenizers 库）优先——预算守卫必须与训练侧同一口径。

    本工程 tokenizer 为字节级 BPE：system 提示词实测 1351 tokens（2630 chars），
    估算函数在中文上会系统偏低，因此能用真分词就绝不用估算。
    """
    try:
        from tokenizers import Tokenizer  # type: ignore
    except Exception:
        return _est_fallback, "heuristic-fallback（tokenizers 未安装）"
    if not tokenizer_path or not os.path.exists(tokenizer_path):
        return _est_fallback, "heuristic-fallback（tokenizer.json 缺失）"
    try:
        tok = Tokenizer.from_file(tokenizer_path)
    except Exception:
        return _est_fallback, "heuristic-fallback（tokenizer 载入失败）"
    return (lambda text: len(tok.encode(text).ids)), "tokenizers（真实分词）"


def load_vocab_chars(tokenizer_path):
    """tokenizer.json → 可编码字符集合；**byte-level BPE 无 OOV 概念**（任意字符由字节序列合成）→ 返回 None。

    2026-09-24 实测：本工程 tokenizer 为 GPT-2 风格字节级 BPE（pre_tokenizer=ByteLevel，
    基础字符集≈256 字节映射）——此前的字符集检测把全部汉字误判为 OOV，药品池被丢空。
    """
    if not tokenizer_path or not os.path.exists(tokenizer_path):
        return None
    with open(tokenizer_path, "r", encoding="utf-8") as fh:
        tok = json.load(fh)
    pre = tok.get("pre_tokenizer") or {}
    if isinstance(pre, dict) and pre.get("type") == "ByteLevel":
        return None
    vocab = tok.get("model", {}).get("vocab", {})
    chars = set()
    for key in vocab:
        chars.update(key)
    if len(chars) <= 320:  # 字节映射表规模 → 同判无 OOV
        return None
    return chars


def oov_chars(text, vocab_chars):
    if vocab_chars is None:
        return set()
    return {ch for ch in text if ch not in vocab_chars}


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


# eval 分配(round5 §2.2):per-sample 确定性抽样键 + 每单元(kind×band)定额 ≥60,
# 不再盲抽固定比例;同输入逐位可复现(eval=内容寻址冻结快照,可重放)。
EVAL_MAX_SHARE = 0.15  # 微构建保护:eval 占比上限,小样本时 SFT 份额不被配额吃穿
# 值级 holdout(round2 X2 裁决):实体池按稳定哈希留出 10%——SFT 永不见,强制入 eval,
# 度量「部署真实条件」(每天新药名/新机构/新术式)下的泛化。
VALUE_HOLDOUT_RATIO = 0.10


def sample_draw(seed: int, sample_id: str) -> int:
    """per-sample 抽样键 = hash(master_seed, sample_id) 前 64 位(整数比较,无浮点)。"""
    digest = hashlib.sha256(f"{seed}:{sample_id}".encode("utf-8")).digest()
    return int.from_bytes(digest[:8], "big")


def assign_eval_splits(entries, *, eval_ratio: float, quota: int,
                       max_share: float = EVAL_MAX_SHARE, forced_eval=(),
                       quota_unit: str = "cell"):
    """确定性 eval/SFT 分配(round5 §2.2 定额制)。

    entries: [(cell, draw, key)];cell=(kind, band),draw=sample_draw(...),key=样本 id。
    规则:①主分配 draw < eval_ratio·2^64;②cell 不足定额 quota 时按 draw 升序补足,
    补足量受 max_share 限(微构建/冒烟自动保 SFT);③quota=0 等价纯比例(冒烟/测试)。
    返回 (split_by_key, cells);cells[cell] = {"total","eval","primary","promoted","deficit"}。
    """
    from collections import defaultdict
    threshold = int(eval_ratio * (1 << 64))
    forced = set(forced_eval)
    by_cell = defaultdict(list)
    for cell, draw, key in entries:
        by_cell[cell].append((draw, key))
    split, cells = {}, {}

    def _promote(items, need):
        """在 items(按 draw 序)上补足 need 个非主分配项;受 max_share 限。返回提升数。"""
        n = len(items)
        prim = {k for d, k in items if d < threshold or k in forced}
        cap = int(n * max_share)
        promote = min(max(0, need - len(prim)), max(0, cap - len(prim)))
        promoted = 0
        for _, k in items:
            if k in prim:
                split[k] = "eval"
            elif promoted < promote:
                split[k] = "eval"
                promoted += 1
            else:
                split[k] = "sft"
        return len(prim) + promoted, promoted, len(prim)

    if quota_unit == "kind":
        # 验收单元=kind(X2 裁决:band 只是噪声条件切片;细格±tau 会吃穿整语料):
        # 以 kind 汇总为主补足单元;cells 明细按 (kind,band) 照记(诊断用)。
        by_kind = defaultdict(list)
        for cell, draw, key in entries:
            by_kind[cell[0]].extend(by_cell[cell])
        kind_eval = {}
        for kind, items in sorted(by_kind.items()):
            items.sort()
            kind_eval[kind] = _promote(items, quota)
        for cell, items in sorted(by_cell.items()):
            items.sort()
            n = len(items)
            ev = sum(1 for d, k in items if split.get(k) == "eval")
            prim = sum(1 for d, k in items if d < threshold or k in forced)
            cells[f"{cell[0]}|{cell[1]}"] = {
                "total": n, "eval": ev, "primary": prim,
                "promoted": max(0, ev - prim),
                "deficit": 0,   # 细格不再计 deficit(验收单元=kind)
            }
        for kind, (ev, promoted, prim) in kind_eval.items():
            cells[f"kind:{kind}"] = {"total": len(by_kind[kind]), "eval": ev, "primary": prim,
                                     "promoted": promoted,
                                     "deficit": max(0, quota - ev)}
        return split, cells

    for cell, items in sorted(by_cell.items()):
        items.sort()
        n = len(items)
        ev, promoted, prim = _promote(items, quota)
        cells[f"{cell[0]}|{cell[1]}"] = {
            "total": n, "eval": ev, "primary": prim,
            "promoted": promoted, "deficit": max(0, quota - ev)}
    return split, cells


def spec_char_ok(value, vocab_chars):
    return not oov_chars(value, vocab_chars)


# ================================================================ 规格/提示词装载

def load_specs(prompts_dir, kinds):
    specs = {}
    for kind in kinds:
        prompt_path = os.path.join(prompts_dir, f"prompt_{kind}.txt")
        spec_path = os.path.join(prompts_dir, f"spec_{kind}.json")
        if not (os.path.exists(prompt_path) and os.path.exists(spec_path)):
            log(f"[skip] {kind}: 缺 prompt_/spec_ 文件（跑 .github/actions/distill/extract/export_prompts.sh 导出）")
            continue
        with open(prompt_path, "r", encoding="utf-8") as fh:
            prompt = fh.read().strip("\n")
        with open(spec_path, "r", encoding="utf-8") as fh:
            spec = json.load(fh)
        specs[kind] = {
            "prompt": prompt,
            "shared": [f["key"] for f in spec.get("shared", [])],
            "row": [f["key"] for f in spec.get("row", [])],
            "required_shared": [f["key"] for f in spec.get("shared", []) if f.get("required")],
            "required_row": [f["key"] for f in spec.get("row", []) if f.get("required")],
            "rowAnchor": spec.get("rowAnchor") or "",
            "maxRows": int(spec.get("maxRowsPerRegion") or 8),
            # 通用卡种生成需要完整字段元数据（labels/type/枚举词形/fallback 打印词形）
            "shared_fields": spec.get("shared", []),
            "row_fields": spec.get("row", []),
        }
    return specs


# ================================================================ 值来源（POOLS）

_SPECDOSE = re.compile(r"(\d+(?:\.\d+)?)\s*(mg|g|ml|mL|ug|μg|IU|mg/ml|%)", re.IGNORECASE)


def _clean(s):
    return sanitize_hard(s or "")


def _to_base_spec(s):
    """把任意规格文本收敛到「数字+单位」基座（后续可由包装数合成 ×24 形态）。"""
    s = _clean(s)
    m = _SPECDOSE.search(s)
    if m:
        return f"{m.group(1)}{m.group(2)}"
    m = re.search(r"(\d+(?:\.\d+)?)(毫克|公絲|公克|微克|毫升|單位)", s)
    if m:
        return f"{m.group(1)}{m.group(2)}"
    return ""


def load_drugs(data_dir, rng, vocab_chars, caps, sources=("cn", "nhsa", "tw", "hk")):
    """药品池：CN 医保目录（精简字段）+ NHSA 目录（海量）+ TW 记录（繁体名+剂量内嵌）+ HK 注册药品（多为英文名）。
    `sources` 由所选药品格子推导（datamatrix.drug_sources_for）；未选中的文件即使存在也不读取。"""
    sources = set(sources)
    drugs = []
    dropped_oov = 0

    def keep(name, spec, form, usage, region):
        nonlocal dropped_oov
        name = _clean(name)
        if not name or len(name) > 40:
            return False
        if vocab_chars is not None and oov_chars(name, vocab_chars):
            dropped_oov += 1
            return False
        drugs.append({"name": name, "spec": spec, "form": _clean(form),
                      "usage": _clean(usage)[:120], "region": region})
        return True

    cn_path = os.path.join(data_dir, "drugs_cn.jsonl")
    if "cn" in sources and os.path.exists(cn_path):
        with open(cn_path, "r", encoding="utf-8") as fh:
            for line in fh:
                try:
                    d = json.loads(line)
                except Exception:
                    continue
                keep(d.get("name_zh"), _to_base_spec(d.get("specification")), d.get("dosage_form"),
                     d.get("usage_text"), "CN")

    nhsa_path = os.path.join(data_dir, "drugs_nhsa.jsonl")
    if "nhsa" in sources and os.path.exists(nhsa_path):
        p = min(1.0, caps["nhsa"] / 273665)
        with open(nhsa_path, "r", encoding="utf-8") as fh:
            for line in fh:
                if rng.random() >= p:
                    continue
                try:
                    d = json.loads(line)
                except Exception:
                    continue
                rs = d.get("region_specific", {}) or {}
                keep(d.get("name_zh"), _to_base_spec(rs.get("spec")), rs.get("dosage_form"), "", "CN")

    tw_path = os.path.join(data_dir, "tw_records.jsonl")
    if "tw" in sources and os.path.exists(tw_path):
        p = min(1.0, caps["tw"] / 26207)
        with open(tw_path, "r", encoding="utf-8") as fh:
            for line in fh:
                if rng.random() >= p:
                    continue
                try:
                    d = json.loads(line)
                except Exception:
                    continue
                # tw_records 名称/规格/用法在顶层字段（medical_reference 才是嵌套 names——
                # 2026-09-24 冒烟修复：此前按嵌套读取导致 TW 池恒空、用法 join 恒 0）。
                name = d.get("name_zh") or ""
                if not name:
                    names = d.get("names", {}) or {}
                    name = names.get("name_zh") or ""
                spec = _to_base_spec(d.get("specification") or "") or _to_base_spec(name)
                if keep(name, spec, d.get("dosage_form") or "", d.get("usage_text") or "", "TW") and d.get("source_id"):
                    drugs[-1]["sid"] = d["source_id"]  # medical_details 用法 join 键（次级富化）

    hk_path = os.path.join(data_dir, "hk_records.jsonl")
    if "hk" in sources and os.path.exists(hk_path):
        p = min(1.0, caps["hk"] / 14264)
        with open(hk_path, "r", encoding="utf-8") as fh:
            for line in fh:
                if rng.random() >= p:
                    continue
                try:
                    d = json.loads(line)
                except Exception:
                    continue
                # 香港注册药品绝大多数只有英文名（处方/药袋亦以英文为主）；去掉登记名里的引号
                name = (d.get("name_zh") or d.get("name_en") or "").replace('"', "").strip()
                spec = _to_base_spec(d.get("specification") or "") or _to_base_spec(name)
                keep(name, spec, d.get("dosage_form") or "", d.get("usage_text") or "", "HK")

    by_region = {}
    for d in drugs:
        by_region[d["region"]] = by_region.get(d["region"], 0) + 1
    log(f"[pool] drugs={len(drugs)}（sources={','.join(sorted(sources))}；按地区 {by_region}；OOV 丢 {dropped_oov}）")
    return drugs


def load_ref_pool(data_dir, dtype, region, rng, cap=5000):
    """四域名称池：按矩阵格子读 data/ref/<域>_<地区>.jsonl → ([{"name","unit"}], 去重总数)。蓄水池抽样 cap 条。
    派生格子（departments/tw）从 hospital_tw.jsonl 的 depts[].name_zh 取科别。缺文件 → ([], 0)，调用方退回内置名单。"""
    cell = DM.CELL_BY_KEY[f"{dtype}/{region}"]
    items, seen, total = [], set(), 0
    for rel in cell.files:
        path = os.path.join(data_dir, rel)
        if not os.path.isfile(path) or os.path.getsize(path) == 0:
            continue
        derive = cell.derive and os.path.basename(rel).startswith("hospital_")
        with open(path, "r", encoding="utf-8") as fh:
            for line in fh:
                try:
                    d = json.loads(line)
                except Exception:
                    continue
                if derive:
                    names = [(x.get("name_zh") or "") for x in (d.get("depts") or []) if isinstance(x, dict)]
                else:
                    names = [d.get("name_zh") or d.get("name") or d.get("name_en") or ""]
                unit = _clean(d.get("unit") or "") if dtype == "exams" else ""
                for name in names:
                    name = _clean(name)
                    if not (2 <= len(name) <= 30) or name in seen:
                        continue
                    seen.add(name)
                    total += 1
                    item = {"name": name, "unit": unit}
                    if len(items) < cap:
                        items.append(item)
                    else:
                        j = rng.randrange(total)
                        if j < cap:
                            items[j] = item
    if total:
        log(f"[pool] ref {dtype}/{region}: {total} 个名称（抽样 {len(items)}）← {', '.join(os.path.basename(f) for f in cell.files)}")
    return items, total


def load_derived_pools(data_dir, regions, rng, cap=8000):
    """派生值域(2026-10-08 数据批;round2 X 席实证):目录物化的
    ref/vaccine_<r>.jsonl(药表谓词派生,去重)、ref/procedure_tw.jsonl(術式∪處置)、
    ref/fee_tw.jsonl(TW 支付标准全量带价)。缺文件→空(调用方常量兜底+fail-closed 判定)。"""
    out = {"vaccines": {}, "procedures": [], "fees": [], "procedures_cn": [], "fees_cn": []}
    for region in regions:
        path = os.path.join(data_dir, "ref", f"vaccine_{region.lower()}.jsonl")
        names = []
        if os.path.isfile(path):
            with open(path, "r", encoding="utf-8") as fh:
                for line in fh:
                    try:
                        name = _clean(json.loads(line).get("name_zh") or "")
                    except Exception:
                        continue
                    if name:
                        names.append(name)
        if names:
            out["vaccines"][region.upper()] = names[:cap]
    # CN 导入槽(官方件一次性导入;文件缺席=常量兜底——CN 术式/收费项目录登录墙,导入批)
    for key, fname in (("procedures", "procedure_tw.jsonl"), ("fees", "fee_tw.jsonl"),
                       ("procedures_cn", "procedure_cn.jsonl"), ("fees_cn", "fee_cn.jsonl")):
        path = os.path.join(data_dir, "ref", fname)
        rows = []
        if os.path.isfile(path):
            with open(path, "r", encoding="utf-8") as fh:
                for line in fh:
                    try:
                        d = json.loads(line)
                    except Exception:
                        continue
                    name = _clean(d.get("name_zh") or "")
                    if name:
                        rows.append({"name": name, "price": _clean(str(d.get("price_ref") or ""))})
        out[key] = rows[:cap]
    if any(out[k] for k in ("procedures", "fees")) or out["vaccines"]:
        log(f"[pool] derived: vaccines={ {r: len(v) for r, v in out['vaccines'].items()} } "
            f"procedures_tw={len(out['procedures'])} fees_tw={len(out['fees'])}")
    return out


def load_details(data_dir, tw_names, diseases_out, rng):
    """medical_details.jsonl 单遍流式：① 抽 TW 用法；② 每 25 行抽 indications 扩充疾病词表。"""
    path = os.path.join(data_dir, "medical_details.jsonl")
    usage_by_id = {}
    if not os.path.exists(path):
        return usage_by_id
    diseases = set()
    picked = 0
    with open(path, "r", encoding="utf-8") as fh:
        for i, line in enumerate(fh):
            if i % 25 == 0 and len(diseases) < 20000:
                try:
                    d = json.loads(line)
                except Exception:
                    continue
                ind = d.get("indications") or ""
                if ind:
                    for seg in re.split(r"[、，,；;。()（）/]", ind):
                        seg = _clean(seg)
                        seg = re.sub(r"^(用于治療|用于治疗|適用於治療|適用于|適用於|用于|缓解|緩解|改善|治疗|治療|预防|預防)", "", seg).strip()
                        if 2 <= len(seg) <= 12 and seg.endswith(DISEASE_SUFFIXES) and not re.search(r"\d", seg):
                            diseases.add(seg)
            elif tw_names and picked < 4000:
                try:
                    d = json.loads(line)
                except Exception:
                    continue
                sid = d.get("source_id")
                if sid in tw_names and d.get("usage_text"):
                    usage_by_id[sid] = _clean(d["usage_text"])[:100]
                    picked += 1
    diseases_out.update(diseases)
    log(f"[pool] disease-lexicon={len(diseases)}（indications 抽取）; tw-usage-joined={len(usage_by_id)}")
    return usage_by_id


def load_aliases(data_dir, vocab_chars, cap_alias=24000, cap_group=8000):
    """medical_index.json：① 别名串池；② 同 id 组（同药不同写法，事实安全的共指对）。"""
    path = os.path.join(data_dir, "medical_index.json")
    aliases, groups = [], []
    if not os.path.exists(path):
        return aliases, groups
    with open(path, "r", encoding="utf-8") as fh:
        idx = json.load(fh)
    seen_groups = set()
    for alias, ids in idx.get("index", {}).items():
        a = _clean(alias)
        if not (3 <= len(a) <= 26):
            continue
        if vocab_chars is not None and oov_chars(a, vocab_chars):
            continue
        aliases.append(a)
        if len(aliases) >= cap_alias:
            break
    # 组需要二次遍历（取同 id 的前两条别名做共指句）——收集 id→alias
    by_id = {}
    for alias, ids in idx.get("index", {}).items():
        if not ids:
            continue
        i = ids[0]
        bucket = by_id.setdefault(i, [])
        if len(bucket) < 2:
            a = _clean(alias)
            if 3 <= len(a) <= 26 and (vocab_chars is None or not oov_chars(a, vocab_chars)):
                bucket.append(a)
    for i, bucket in by_id.items():
        if len(bucket) == 2 and i not in seen_groups:
            seen_groups.add(i)
            groups.append(tuple(bucket))
            if len(groups) >= cap_group:
                break
    log(f"[pool] aliases={len(aliases)}; co-ref groups={len(groups)}")
    return aliases, groups


# ================================================================ span / 行 构造

def span(key, value, line_index):
    return {"key": key, "value": value, "unit": None, "lineIndex": line_index}


def order_spans(spans, key_order):
    pos = {k: i for i, k in enumerate(key_order)}
    return sorted(spans, key=lambda s: pos.get(s["key"], 99))


def normalize_doses(text, rng):
    """把 TW/长文本里的「一天3至4次」等压成训练友好形态。"""
    return text


def make_line(segments, rng, level=None, nz=None):
    """segments: (text, role, key|None)（旧两元组兼容）；value 段加噪后即 span 基。
    返回 (行文本, [(key, 加噪后段文本)…]) —— span value 取加噪后原文，verbatim 由构造保证。

    nz(样本级噪声上下文,噪声 v2)给定时走目标 CER 编辑预算路径并累计 span 损伤;
    nz=None 时保持 legacy level 分布路径(逐字节兼容)。
    """
    norm = []
    for seg in segments:
        if len(seg) == 3:
            text, role, key = seg
        else:
            text, role = seg
            key = None
        norm.append((text, role, key))
    if nz is not None:
        noised = []
        for text, role, key in norm:
            if not text:
                noised.append(text)
                continue
            fn = asr_noise_segment_v2 if nz["mode"] == "asr" else ocr_noise_segment_v2
            noisy, meta = fn(text, rng, band=nz["band"], tables=nz["tables"])
            noised.append(noisy)
            nz["cer_sum"] = nz.get("cer_sum", 0.0) + float(meta.get("cer_measured") or 0.0)
            nz["cer_n"] = nz.get("cer_n", 0) + 1
            if key:
                nz["span_total"] += 1
                if meta.get("damaged"):
                    nz["span_damaged"] += 1
            for op, count in (meta.get("ops") or {}).items():
                nz["ops"][op] = nz["ops"].get(op, 0) + count
        line = ""
        for i, seg in enumerate(noised):
            if i:
                line += ocr_separator(rng)
            line += seg
        spans = [(key, noised[i]) for i, (_, _, key) in enumerate(norm) if key and noised[i]]
        return line, spans
    noised = []
    for text, role, _ in norm:
        seg_level = level if role == "value" else ("light" if level == "clean" else level)
        noised.append(ocr_noise_segment(text, rng, seg_level) if text else text)
    line = ""
    for i, seg in enumerate(noised):
        if i:
            line += ocr_separator(rng)
        line += seg
    spans = [(key, noised[i]) for i, (_, _, key) in enumerate(norm) if key and noised[i]]
    return line, spans


def make_sample(kind, specs, lines, shared_spans, rows_spans, est_budget):
    """装配 conversations 样本；返回 (sample_dict|None, reason|None, est)。"""
    spec = specs[kind]
    shared_spans = order_spans([s for s in shared_spans if s["key"] in spec["shared"] and s["value"]],
                               spec["shared"])
    rows_out = []
    for row in rows_spans:
        row = order_spans([s for s in row if s["key"] in spec["row"] and s["value"]], spec["row"])
        if row:
            rows_out.append(row)
    if spec["required_row"] and not rows_out:
        return None, "no_rows", 0
    for req in spec["required_shared"]:
        if not any(s["key"] == req for s in shared_spans):
            return None, "missing_required_shared", 0
    if not shared_spans and not rows_out:
        return None, "no_spans", 0

    user = "\n".join(f"[{i}] {ln}" for i, ln in enumerate(lines))

    def build(sh, rows):
        asst_obj = {"shared": sh, "rows": rows}
        asst = json.dumps(asst_obj, ensure_ascii=False, separators=(",", ":"))
        est = est_tokens(spec["prompt"]) + est_tokens(user) + est_tokens(asst) + 12
        return asst, est

    # 预算守卫：先削可选的共享 span（按声明序从后往前），再削尾行
    drop_order = [k for k in reversed(spec["shared"]) if k not in spec["required_shared"]]
    sh, rows = list(shared_spans), [list(r) for r in rows_out]
    asst, est = build(sh, rows)
    trimmed = False
    for key in drop_order:
        if est <= est_budget:
            break
        keep = [s for s in sh if s["key"] != key]
        if len(keep) != len(sh):
            sh = keep
            asst, est = build(sh, rows)
            trimmed = True
    while est > est_budget and len(rows) > 1:
        rows = rows[:-1]
        asst, est = build(sh, rows)
        trimmed = True
    if est > est_budget:
        return None, "budget", est

    sample = {"conversations": [
        {"role": "system", "content": spec["prompt"]},
        {"role": "user", "content": user},
        {"role": "assistant", "content": asst},
    ]}
    return sample, ("trimmed" if trimmed else None), est


def check_verbatim(lines, shared, rows):
    """构造期自检：所有 value 必须是对应行的逐字子串（违者即语料污染）。"""
    for s in shared:
        if s["value"] not in lines[s["lineIndex"]]:
            return False
    for row in rows:
        for s in row:
            if s["value"] not in lines[s["lineIndex"]]:
                return False
    return True


# ================================================================ 处方（OCR 页）

def _dose_unit(form, rng):
    for key, unit in FORM_TO_UNIT:
        if key in (form or ""):
            return unit
    return rng.choice(DOSAGE_UNITS_DEFAULT)


def _date(rng):
    y = rng.randint(2023, 2026)
    return f"{y}-{rng.randint(1, 12):02d}-{rng.randint(1, 28):02d}"


def _region(pools, rng, need_drugs):
    """样本所属地区：处方/用药只在有药品池的地区里选，其余在所选地区里选。"""
    return rng.choice(pools["drug_regions"] if need_drugs else pools["regions"])


def _hospital(pools, rng, region):
    ref = pools["ref"]["hospitals"].get(region)
    if ref:
        return rng.choice(ref)["name"]
    if region == "CN":
        return rng.choice(HOSPITAL_CITIES) + rng.choice(HOSPITAL_SUFFIX)
    return rng.choice(HOSPITAL_FALLBACK[region])


def _department(pools, rng, region):
    ref = pools["ref"]["departments"].get(region)
    if ref:
        return rng.choice(ref)["name"]
    return rng.choice(DEPTS_CN if region == "CN" else DEPTS_TW)


def _diagnosis(pools, rng, region):
    ref = pools["ref"]["diagnoses"].get(region)
    if ref:
        return rng.choice(ref)["name"]
    return L(region, rng.choice(pools["diseases"])) if pools["diseases"] else L(region, "高血压")


def _doctor(rng, trad=False):
    surname = rng.choice(DOCTOR_SURNAMES)
    return (L("TW", surname) + "醫師") if trad else (surname + "医生")


def gen_prescription(pools, rng, vocab_chars):
    nz = new_noise_ctx(rng, mode="ocr")
    """处方页面：表头（日期/医院/科室/医师/处方号/诊断/医嘱）+ 1-3 行药品行（三种版式）。"""
    region = _region(pools, rng, need_drugs=True)   # 一张处方一个地区：机构/科别/版式/药品同地区
    drugs = pools["drugs_by_region"][region]
    trad = region != "CN"
    n_rows = rng.choices([1, 2, 3], weights=[35, 45, 20])[0]
    chosen = [rng.choice(drugs) for _ in range(n_rows)]
    lines, shared, rows = [], [], []

    def push(line, spans):
        idx = len(lines)
        lines.append(line)
        for key, value in spans:
            if value:
                shared.append(span(key, value, idx))

    for pos, text in decoy_lines(rng, region):
        if pos == "head":
            lines.append(text)

    # —— 表头（行序号即 lineIndex）——
    h = _hospital(pools, rng, region)
    push(*make_line([(h, "value", "hospital"), (L(region, "门诊处方笺"), "label", None)], rng, nz=nz))

    dept = _department(pools, rng, region)
    push(*make_line([(L(region, "科室"), "label", None), (dept, "value", "department")], rng, nz=nz))

    if rng.random() < 0.7:
        push(*make_line([(L(region, "医师"), "label", None), (_doctor(rng, trad), "value", "doctor")], rng, nz=nz))
    push(*make_line([(L(region, "处方日期"), "label", None), (_date(rng), "value", "prescribed_at")], rng, nz=nz))  # 必填：恒定出现
    if rng.random() < 0.6:
        no = f"{rng.choice('ABC')}{rng.randint(100000, 999999)}"
        push(*make_line([(L(region, "处方号"), "label", None), (no, "value", "prescription_no")], rng, nz=nz))
    if rng.random() < 0.6 and (pools["diseases"] or pools["ref"]["diagnoses"].get(region)):
        d1 = _diagnosis(pools, rng, region)
        d2 = _diagnosis(pools, rng, region) if rng.random() < 0.35 else ""
        diag = d1 + ("、" + d2 if d2 else "")
        push(*make_line([(L(region, "临床诊断"), "label", None), (diag, "value", "clinical_diagnosis")], rng, nz=nz))
    if rng.random() < 0.35:
        # 硬负例：过敏史里出现的药名不得建行（无 key 即不入 span）
        push(*make_line([(L(region, "既往"), "label", None), (L(region, rng.choice(ALLERGY_LINES)), "value", None)], rng, nz=nz))

    # —— 药品行 ——
    for i, drug in enumerate(chosen):
        name = drug["name"]
        unit = L(region, _dose_unit(drug["form"], rng))
        dqty = rng.choice(["1", "2", "3", "1/2", "半"])
        dosage_seg = f"每次{dqty}{unit}" if rng.random() < 0.8 else f"{dqty}{unit}"
        freq = L(region, rng.choice(FREQ_TIMES))
        route = L(region, rng.choice(ROUTES))
        days = rng.choice(["7", "14", "3", "5", "10"]) if rng.random() < 0.6 else ""
        qty = f"{rng.randint(1, 3)}{rng.choice(QUANTITY_UNITS)}" if rng.random() < 0.5 else ""
        base_spec = drug["spec"] or ""
        if base_spec and rng.random() < 0.5:
            base_spec = f"{base_spec}×{rng.choice(['12', '24', '36', '20', '10', '100'])}"

        variant = rng.choices(["cols", "labeled", "split"], weights=[55, 25, 20])[0]
        prefix = rng.choice([f"{i + 1}. ", f"{i + 1}、", f"{CN_NUM.get(str(i + 1), '')}、", ""])

        def _finish(line, seg_spans, li, prefix=prefix):
            row = []
            for key, v in seg_spans:
                if key == "drug_name" and prefix and v.startswith(prefix):
                    v = v[len(prefix):]
                if key == "drug_name" and any(sep in prefix for sep in (".", "．", "、")):
                    # 噪声可能把 "1." 拆成 "1 . "/"1．"——仅当原前缀含分隔符时按正则剥除，
                    # 避免误伤以数字开头的真实药名（如「999感冒灵」）
                    v = re.sub(r"^\s*\d+\s*[.．、]\s*", "", v)
                if key == "dosage":
                    v = v.replace("每次", "") if v.startswith("每次") else v
                if key == "days":
                    m = re.search(r"\d+", v)
                    v = m.group(0) if m else ""
                if v:
                    row.append(span(key, v, li))
            return row

        if variant == "cols":
            segs = [(prefix + name, "value", "drug_name")]
            if base_spec:
                segs.append((base_spec, "value", "spec"))
            if qty:
                segs.append((qty, "value", "quantity"))
            segs += [(dosage_seg, "value", "dosage"), (freq, "value", "frequency"), (route, "value", "route")]
            if days:
                segs.append((f"{days}天", "value", "days"))
            line, seg_spans = make_line(segs, rng, nz=nz)
            lines.append(line)
            rows.append(_finish(line, seg_spans, len(lines) - 1))
        elif variant == "labeled":
            segs1 = [(f"{i + 1}.", "label", None), (name, "value", "drug_name")]
            if base_spec:
                segs1 += [(L(region, "规格"), "label", None), (base_spec, "value", "spec")]
            if qty:
                segs1 += [(L(region, "数量"), "label", None), (qty, "value", "quantity")]
            line1, sp1 = make_line(segs1, rng, nz=nz)
            lines.append(line1)
            li1 = len(lines) - 1
            segs2 = [(L(region, "用法"), "label", None), (dosage_seg, "value", "dosage"),
                     (freq, "value", "frequency"), (route, "value", "route")]
            if days:
                segs2.append((f"{days}天", "value", "days"))
            line2, sp2 = make_line(segs2, rng, nz=nz)
            lines.append(line2)
            li2 = len(lines) - 1
            row = _finish(line1, sp1, li1) + _finish(line2, sp2, li2)
            rows.append(row)
        else:  # split：药名规格一行，用法一行（无标签）
            segs1 = [(f"{i + 1}.", "label", None), (name, "value", "drug_name")]
            if base_spec:
                segs1.append((base_spec, "value", "spec"))
            line1, sp1 = make_line(segs1, rng, nz=nz)
            lines.append(line1)
            li1 = len(lines) - 1
            # 金标统一(round5 数据批):「用法」归 label 段,dosage 金标=数量+单位,
            # 与 cols/labeled 变式一致——此前 (f"用法：{dosage_seg}") 使同字段两套金标
            segs2 = [(L(region, "用法"), "label", None), (dosage_seg, "value", "dosage"),
                     (freq, "value", "frequency"), (route, "value", "route")]
            if days:
                segs2.append((f"{days}天", "value", "days"))
            line2, sp2 = make_line(segs2, rng, nz=nz)
            lines.append(line2)
            li2 = len(lines) - 1
            row = _finish(line1, sp1, li1) + _finish(line2, sp2, li2)
            rows.append(row)

    if rng.random() < 0.4:
        push(*make_line([(L(region, "医嘱"), "label", None), (L(region, rng.choice(TCM_ADVICES)), "value", "advice_text")], rng, nz=nz))

    for pos, text in decoy_lines(rng, region):
        if pos == "foot":
            lines.append(text)
    return lines, shared, rows, nz


# ================================================================ 用药（ASR 口述）

ASR_FRAMES = [
    "我{time}吃了{qty}",
    "{time}吃了{qty}",
    "医生让我{time}吃{qty}",
    "那个{qty}我今天{time}吃的",
    "帮我记一下{time}吃的{qty}",
    "{time}吃的{qty}还可以吧",
]


def gen_medication(pools, rng, vocab_chars):
    nz = new_noise_ctx(rng, mode="asr")
    region = _region(pools, rng, need_drugs=True)   # 一段口述一个说话人/地区
    drugs = pools["drugs_by_region"][region]
    n = rng.choices([1, 2], weights=[80, 20])[0]
    chosen = [rng.choice(drugs) for _ in range(n)]
    lines, shared, rows = [], [], []
    for drug in chosen:
        name = drug["name"]
        unit = L(region, _dose_unit(drug["form"], rng))
        qty_raw = f"{rng.randint(1, 3)}{unit}"
        qty = voiced(qty_raw, rng)
        spec_spoken = ""
        if drug["spec"]:
            m = re.match(r"(\d+(?:\.\d+)?)(mg|g|ml|mg/ml|%)", drug["spec"])
            if m:
                num, unit_s = m.group(1), m.group(2)
                spoken_unit = {"mg": "毫克", "g": "克", "ml": "毫升"}.get(unit_s, unit_s)
                spec_spoken = rng.choice([f"{num}{spoken_unit}", f"{num}{unit_s}"])
        segs = [(name, "value", "generic_name"), (qty, "value", "unit_kind")]
        if spec_spoken and rng.random() < 0.6:
            segs.append((spec_spoken, "value", "spec"))
        line, seg_spans = make_line(segs, rng, nz=nz)
        lines.append(line)
        idx = len(lines) - 1
        row = []
        for key, v in seg_spans:
            if key == "unit_kind":
                # 口播单位词（片/粒/…）——enum 归一化在下游，训练恒逐字
                m = re.search(r"[片粒袋支瓶贴貼丸]", v)
                v = m.group(0) if m else ""
            if v:
                row.append(span(key, v, idx))
        if row:
            rows.append(row)
    return lines, shared, rows, nz


# ================================================================ 门诊记录（OCR 页）

def gen_encounter(pools, rng, vocab_chars):
    nz = new_noise_ctx(rng, mode="ocr")
    lines, shared, rows = [], [], []

    def push(line, spans):
        idx = len(lines)
        lines.append(line)
        for key, value in spans:
            if value:
                shared.append(span(key, value, idx))

    region = _region(pools, rng, need_drugs=False)
    for pos, text in decoy_lines(rng, region):
        if pos == "head":
            lines.append(text)
    trad = region != "CN"
    push(*make_line([(L(region, "就诊日期"), "label", None), (_date(rng), "value", "date")], rng, nz=nz))  # 必填：恒定出现
    h = _hospital(pools, rng, region)
    push(*make_line([(h, "value", "hospital"), (L(region, "门诊病历"), "label", None)], rng, nz=nz))
    dept = _department(pools, rng, region)
    push(*make_line([(L(region, "科室"), "label", None), (dept, "value", "department")], rng, nz=nz))
    if rng.random() < 0.7:
        push(*make_line([(L(region, "医师"), "label", None), (_doctor(rng, trad), "value", "doctor")], rng, nz=nz))
    push(*make_line([(L(region, "主诉"), "label", None), (L(region, rng.choice(COMPLAINTS)), "value", "chief_complaint")], rng, nz=nz))
    d1 = _diagnosis(pools, rng, region)
    d2 = _diagnosis(pools, rng, region) if rng.random() < 0.4 else ""
    diag = d1 + ("、" + d2 if d2 else "")
    push(*make_line([(L(region, "诊断"), "label", None), (diag, "value", "diagnosis_text")], rng, nz=nz))
    if rng.random() < 0.4:  # advice_text 在 encounter spec 的 shared 键内（见 spec_encounter.json）
        push(*make_line([(L(region, "医嘱"), "label", None), (L(region, rng.choice(TCM_ADVICES)), "value", "advice_text")], rng, nz=nz))
    for pos, text in decoy_lines(rng, region):
        if pos == "foot":
            lines.append(text)
    return lines, shared, rows, nz


# ================================================================ 检验报告（字母数字表）

def gen_metric_sample(pools, rng, vocab_chars):
    nz = new_noise_ctx(rng, mode="ocr")
    lines, shared, rows = [], [], []

    def push(line, spans):
        idx = len(lines)
        lines.append(line)
        for key, value in spans:
            if value:
                shared.append(span(key, value, idx))

    region = _region(pools, rng, need_drugs=False)
    for pos, text in decoy_lines(rng, region):
        if pos == "head":
            lines.append(text)
    push(*make_line([(L(region, "报告日期"), "label", None), (_date(rng), "value", "measured_at")], rng, nz=nz))
    if rng.random() < 0.6:
        push(*make_line([(L(region, "医院"), "label", None), (_hospital(pools, rng, region), "value", "hospital")], rng, nz=nz))
    if rng.random() < 0.5:
        push(*make_line([(L(region, "标本类型"), "label", None), (L(region, "静脉血"), "value", "specimen_type")], rng, nz=nz))
    n = rng.randint(3, 7)
    ref_exams = pools["ref"]["exams"].get(region) or []
    if ref_exams and rng.random() < 0.5:
        # 真实检查检验项目名（健保支付标准等）：只知道名称/单位，不编造参考范围与异常标记
        for item in rng.sample(ref_exams, min(n, len(ref_exams))):
            lo, hi, digits = rng.choice([(0.1, 10, 2), (1, 100, 1), (10, 500, 0)])
            segs = [(item["name"], "value", "raw_label"), (f"{round(rng.uniform(lo, hi), digits) if digits else int(rng.uniform(lo, hi))}", "value", "value")]
            if item["unit"]:
                segs.append((item["unit"], "value", "unit"))
            line, seg_spans = make_line(segs, rng, nz=nz)
            lines.append(line)
            rows.append([span(key, v, len(lines) - 1) for key, v in seg_spans if v and key])
        for pos, text in decoy_lines(rng, region):
            if pos == "foot":
                lines.append(text)
        return lines, shared, rows, nz
    items = rng.sample(LAB_ITEMS, min(n, len(LAB_ITEMS)))
    for label, abbr, unit, lo, hi in items:
        label = L(region, label)
        span_m = (lo + hi) / 2
        val = round(span_m * rng.uniform(0.75, 1.25), rng.choice([1, 1, 2]))
        abn = ""
        if rng.random() < 0.28:
            if rng.random() < 0.5 and lo > 0:
                val = round(lo * rng.uniform(0.6, 0.9), 1); abn = rng.choice(["↓", "偏低", "L"])
            else:
                val = round(hi * rng.uniform(1.1, 1.5), 1); abn = rng.choice(["↑", "偏高", "H"])
        segs = [(label, "value", "raw_label"), (f"{val}", "value", "value"),
                (unit, "value", "unit"), (f"{lo}-{hi}", "value", "reference_range")]
        if abn:
            segs.append((abn, "value", "abnormal_flag"))
        line, seg_spans = make_line(segs, rng, nz=nz)
        lines.append(line)
        idx = len(lines) - 1
        row = [span(key, v, idx) for key, v in seg_spans if v and key]
        rows.append(row)
    for pos, text in decoy_lines(rng, region):
        if pos == "foot":
            lines.append(text)
    return lines, shared, rows, nz


BUILDERS = {
    "prescription": gen_prescription,
    "medication": gen_medication,
    "encounter": gen_encounter,
    "metric_sample": gen_metric_sample,
}


# ================================================================ 通用卡种（卡种 4→13；2026-10-08 数据批）
# spec 驱动：标签（labels）/ 枚举打印词形（value_tokens、fallback_tokens）随导出 spec 单一
# 事实源流入；值由 provider 表合成，兜底序=provider → fallback_tokens → 枚举域 → 类型兜底。
# 覆盖：hospitalization / diagnosis / exam_report / claim_item / immunization /
# health_exam / clinical_conclusion / surgery / treatment_record（均为 OCR 面）。

VACCINES = ["乙肝疫苗", "流感疫苗", "肺炎球菌疫苗", "麻腮风疫苗", "水痘疫苗", "HPV疫苗",
            "新冠疫苗", "带状疱疹疫苗", "百白破疫苗"]
SURGERY_NAMES = ["腹腔镜胆囊切除术", "阑尾切除术", "骨折切开复位内固定术", "冠状动脉支架植入术",
                 "剖宫产术", "甲状腺部分切除术", "经尿道前列腺电切术", "全膝关节置换术"]
SURGERY_LEVELS = ["一级手术", "二级手术", "三级手术", "四级手术"]
ANESTHESIA_METHODS = ["全身麻醉", "椎管内麻醉", "局部麻醉", "硬膜外麻醉"]
EXAM_PARTS = ["胸部", "腹部", "头颅", "腰椎", "膝关节", "甲状腺", "心脏", "肝胆脾胰", "盆腔", "颈部血管"]
EXAM_METHODS = ["平扫", "增强扫描", "彩色多普勒超声", "数字化摄影", "内镜检查"]
CLAIM_ITEMS = [("门诊诊查费", "30.00"), ("血常规", "25.00"), ("尿常规", "18.00"),
               ("胸部CT平扫", "320.00"), ("腹部彩超", "180.00"), ("心电图", "35.00"),
               ("静脉输液", "12.00"), ("西药费", "86.50"), ("中药费", "42.30"), ("换药", "20.00")]
PACKAGE_NAMES = ["基础健康体检套餐", "入职体检套餐A", "老年人健康体检套餐", "女性专项体检套餐",
                 "心脑血管风险筛查套餐"]
ADMIT_ROUTES = ["门诊", "急诊", "转入"]
PAYMENT_TYPES = ["医保", "自费", "公费医疗"]
DISCHARGE_WAYS = ["医嘱离院", "转院", "自动离院"]
SEVERITIES = ["轻度", "中度", "重度", "未见异常"]
THERAPIES = ["针灸", "推拿", "理疗", "雾化吸入", "换药", "静脉输液"]
GENERIC_TEXT_FALLBACK = ["无", "未见异常", "详见报告", "略"]

_CARD_DATES = ("date", "prescribed_at", "measured_at", "exam_at", "reported_at", "report_date",
               "treated_at", "surgery_at", "diagnosed_at", "administered_at", "admit_at",
               "discharge_at", "ended_at", "summary_date")
_CARD_HOSPITALS = ("hospital", "org_name", "merchant", "provider")
_CARD_DEPTS = ("department", "admit_dept", "discharge_dept")
_CARD_DOCTORS = ("doctor", "attending_physician", "surgeon", "apply_doctor", "report_doctor",
                 "review_doctor", "summary_doctor", "total_doctor", "executor", "anesthesiologist")

NARRATIVE_TEMPLATES = {
    # 2026-10-08 字节批扩面(round2 X 席:23 键/40 句→5 键 top1>10%/9 键单句)——
    # 每键 ≥5 变体,槽位语法({d}{d2}{t}{adv}{drug}{op}{anes}{therapy}{part})组合;
    # 措辞中性(源文档文本,不引入诊断/剂量结论语气;BR-006 抽面闸待扩)。
    "present_illness": ["患者{t}前无明显诱因出现{d}，伴乏力，无发热，为进一步诊治来院。",
                        "患者{t}前出现{d}，症状逐渐加重，现门诊收入院。",
                        "患者{t}前起病，主要表现为{d}，于外院未行系统诊治，今来我院。",
                        "患者{t}前出现{d}，休息后可稍缓解，为明确诊治来诊。",
                        "患者自述{t}前开始出现{d}，无明显加重或缓解因素。",
                        "患者{t}前出现{d}，伴食欲减退，二便如常。",
                        "患者{t}前出现{d}，病程中无意识障碍，无咯血。",
                        "患者{t}前无明显诱因出现{d}，曾自行口服药物，效果欠佳。"],
    "past_history": ["既往体健，否认高血压、糖尿病史。",
                     "既往{d}病史5年，规律服药，病情稳定。",
                     "既往{d}病史，间断治疗，控制一般。",
                     "既往否认肝炎、结核等传染病史，无手术外伤史。",
                     "既往体健，无药物及食物过敏史。",
                     "既往{d}病史3年，未规律监测。",
                     "既往曾于外院诊断{d}，具体诊治不详。"],
    "physical_exam": ["T 36.8℃，P 82次/分，R 18次/分，BP 128/82mmHg；神志清楚，双肺呼吸音清，心律齐，腹软无压痛。",
                      "神志清楚，查体合作；心肺未见明显异常，腹平软，肝脾肋下未及。",
                      "T 37.1℃，P 88次/分，R 20次/分，BP 136/85mmHg；咽部稍充血，双肺呼吸音粗，未闻及干湿啰音。",
                      "神清，全身皮肤黏膜无黄染，浅表淋巴结未触及肿大；双下肢无水肿。",
                      "T 36.5℃，P 76次/分，R 18次/分，BP 120/78mmHg；心律齐，各瓣膜听诊区未闻及杂音。",
                      "腹部平坦，无压痛及反跳痛，肠鸣音正常；神经系统查体未见异常。"],
    "diagnosis_text": ["{d}", "{d}、{d2}", "{d}；{d2}", "初步诊断：{d}", "{d}（{d2}）"],
    "visit_summary": ["本次因{d}就诊，予对症治疗，嘱{adv}。",
                      "本次以{d}收入院，完善检查后予相应处理，嘱{adv}。",
                      "因{d}来诊，经治疗后症状缓解，嘱{adv}。",
                      "本次就诊考虑与{d}相关，予对症支持治疗，嘱{adv}。",
                      "为诊治{d}入院，治疗过程顺利，嘱{adv}。"],
    "admit_condition": ["患者{t}前出现{d}，入院时神志清楚，生命体征平稳。",
                        "入院时患者一般情况尚可，{d}症状明显，生命体征平稳。",
                        "入院时神清，{d}反复发作，饮食睡眠一般。",
                        "入院时患者精神状态可，因{d}收入院进一步诊治。"],
    "discharge_condition": ["患者一般情况可，{d}症状好转，生命体征平稳。",
                            "出院时患者神清，{d}症状明显缓解，饮食睡眠改善。",
                            "出院时一般情况良好，{d}未再发作。",
                            "出院时生命体征平稳，{d}症状较入院时减轻。"],
    "discharge_orders": ["{adv}。", "规律服药，{adv}。", "遵医嘱服药，{adv}。",
                         "定期复查，{adv}。", "如有不适及时就诊，{adv}。"],
    "take_home_drugs": ["出院带药：{drug}，按医嘱服用。",
                        "出院带药：{drug}；余药按医嘱继续服用。",
                        "带药：{drug}，用药期间注意观察。",
                        "出院带药：{drug}，按说明书及医嘱使用。"],
    "treatment_course": ["入院后完善相关检查，予对症支持治疗，{d}症状逐步改善。",
                         "入院后予药物治疗及饮食指导，病情平稳。",
                         "入院后完善相关检查，明确{d}，予相应治疗，恢复顺利。",
                         "入院后予对症治疗，{d}症状较前减轻，未见明显不良反应。",
                         "入院后积极完善检查并予综合治疗，病情逐步好转。"],
    "preop_diagnosis": ["{d}", "{d}；{d2}", "{d}待查", "{d}（{d2}）"],
    "postop_diagnosis": ["{d}", "{d}；{d2}", "术后诊断同术前：{d}", "{d}（{d2}）"],
    "procedure_course": ["{anes}下行{op}，术中止血确切，清点无误，术毕安返病房。",
                         "{anes}下行{op}，手术过程顺利，术中出血不多。",
                         "在{anes}下完成{op}，操作顺利，术后安返。",
                         "{anes}下施{op}，探查所见如前，术程平稳。"],
    "intraop_findings": ["术中探查可见{d}相关改变，无活动性出血，周围组织未见明显异常。",
                         "术中所见：{part}区域可见轻度粘连，未见明显占位。",
                         "术中探查组织色泽血运可，未见明确异常结构。",
                         "术中所见与术前评估基本相符，创面渗血少。"],
    "complications": ["无。", "术后出现切口疼痛，予对症处理后缓解。",
                      "术后第一天出现低热，物理降温后好转。", "未出现明显并发症。"],
    "postop_orders": ["{adv}。", "卧床休息，{adv}。", "术后禁食至肛门排气，{adv}。",
                      "观察切口情况，{adv}。"],
    "content": ["{d}予{therapy}治疗，患者耐受良好。",
                "予{therapy}治疗，过程顺利。",
                "针对{d}行{therapy}，治疗后症状减轻。",
                "予{therapy}综合治疗，无特殊不适。",
                "行{therapy}治疗，疗程中病情平稳。"],
    "drugs_text": ["{drug}，按医嘱使用。", "予{drug}，观察用药反应。",
                   "{drug}，用法用量遵医嘱。", "予以{drug}对症处理。"],
    "adverse_reaction": ["无药物过敏及不良反应。", "治疗后出现轻度皮疹，停药后缓解。",
                         "无。", "治疗后有一过性头晕，休息后自行缓解。",
                         "未诉特殊不适。", "输液部位轻微疼痛，调整后好转。"],
    "overall_conclusion": ["未见明显异常。", "血压偏高，建议内科随诊；血脂异常，建议低脂饮食并复查。",
                           "本次体检各项指标基本正常。", "个别指标轻度异常，建议定期复查。",
                           "总体健康状况良好，建议保持规律作息。"],
    "health_guidance": ["{adv}。", "适量运动，{adv}。", "合理膳食，{adv}。",
                        "保持良好作息，{adv}。", "戒烟限酒，{adv}。"],
    "findings": ["{part}未见明显异常。", "{part}可见结节样高密度影，边界清楚。",
                 "{part}形态及信号未见明显异常。",
                 "{part}扫描显示结构清晰，未见异常密度灶。",
                 "{part}可见少量积液信号，范围局限。",
                 "{part}纹理增多，未见实变影。"],
    "impression": ["未见明显异常，建议随访复查。", "考虑{d}可能，建议结合临床进一步检查。",
                   "{d}待排，建议复查。", "所见与{d}相符，建议结合临床。",
                   "未见明确异常征象，必要时复查。", "{d}可能，建议随诊观察。"],
}


def set_specs(specs):
    """main() 注入 load_specs 结果（通用卡种需要字段元数据：labels/type/枚举词形）。"""
    global _SPECS
    _SPECS = specs


_SPECS = {}


def _card_label(fd, rng, region):
    labels = fd.get("labels") or [fd.get("key", "")]
    return L(region, rng.choice(labels))


def _card_drug_text(pools, rng, region):
    drugs = pools["drugs_by_region"].get(region) or pools["drugs"]
    d = rng.choice(drugs)
    unit = L(region, _dose_unit(d["form"], rng))
    return f"{d['name']} {rng.choice(['1', '2'])}{unit} {rng.choice(FREQ_TIMES)} {rng.choice(ROUTES)}"


def _card_sentence(key, rng, pools, region):
    d = (rng.choice(pools["diseases"]) if pools["diseases"] else "高血压")
    tmpl = rng.choice(NARRATIVE_TEMPLATES[key])
    return L(region, tmpl.format(d=d, d2=d, t=rng.choice(["3天", "1周", "2月", "半年"]),
                                 adv=rng.choice(TCM_ADVICES),
                                 drug=_card_drug_text(pools, rng, region),
                                 op=rng.choice(SURGERY_NAMES),
                                 anes=rng.choice(ANESTHESIA_METHODS),
                                 therapy=rng.choice(THERAPIES),
                                 part=rng.choice(EXAM_PARTS)))


def _card_value(key, fd, pools, rng, region):
    """单字段值：provider → 打印词形 → 枚举域 → 类型兜底。返回 None = 该字段此行跳过。"""
    if key in _CARD_DATES:
        return _date(rng)
    if key in _CARD_HOSPITALS:
        return _hospital(pools, rng, region)
    if key in _CARD_DEPTS:
        return _department(pools, rng, region)
    if key in _CARD_DOCTORS:
        return _doctor(rng, trad=region != "CN")
    if key in NARRATIVE_TEMPLATES:
        return sanitize_hard(_card_sentence(key, rng, pools, region))
    if key in ("chief_complaint",):
        return L(region, rng.choice(COMPLAINTS))
    if key == "allergy_history":
        return L(region, rng.choice(ALLERGY_LINES + ["否认药物过敏史"]))
    if key == "advice_text":
        return L(region, "，".join(rng.sample(TCM_ADVICES, rng.randint(1, 2))))
    if key == "exam_part":
        return L(region, rng.choice(EXAM_PARTS))
    if key == "exam_method":
        return L(region, rng.choice(EXAM_METHODS))
    if key == "report_type":
        vt = fd.get("value_tokens") or []
        if vt:
            return rng.choice(vt)["tokens"][0]
    if key in ("treatment_type", "diagnosis_type", "conclusion_type"):
        vt = fd.get("value_tokens") or []
        if vt:
            return rng.choice(vt)["tokens"][0]
    if key == "severity":
        return L(region, rng.choice(SEVERITIES))
    if key == "vaccine_name":
        pool = (pools.get("derived", {}).get("vaccines") or {}).get(region) or []
        if pool:
            return _clean(rng.choice(pool))
        return L(region, rng.choice(VACCINES))
    if key == "dose_number":
        return str(rng.randint(1, 4))
    if key == "lot_number":
        return f"L{rng.randint(2023, 2026)}{rng.randint(1000, 9999)}"
    if key in ("medical_record_no", "report_no", "exam_no"):
        return f"{rng.choice(['ZY', 'JZ', 'BG', 'TJ'])}{rng.randint(1000000, 9999999)}"
    if key == "invoice_no":
        return f"No.{rng.randint(10000000, 99999999)}"
    if key == "surgery_name":
        if region == "TW":
            procs = pools.get("derived", {}).get("procedures") or []
        else:
            procs = pools.get("derived", {}).get("procedures_cn") or []
        if procs:
            return _clean(rng.choice(procs)["name"])
        return L(region, rng.choice(SURGERY_NAMES))
    if key == "surgery_level":
        return L(region, rng.choice(SURGERY_LEVELS))
    if key == "anesthesia_method":
        return L(region, rng.choice(ANESTHESIA_METHODS))
    if key == "surgery_code":
        return f"{rng.randint(40, 99)}.{rng.randint(1, 9)}"
    if key == "assistants":
        return _doctor(rng, trad=region != "CN") + "、" + _doctor(rng, trad=region != "CN")
    if key in ("ward",):
        return L(region, f"{rng.randint(1, 30)}病区")
    if key == "bed_no":
        return L(region, f"{rng.randint(1, 45)}床")
    if key == "admit_route":
        return L(region, rng.choice(ADMIT_ROUTES))
    if key == "payment_type":
        return L(region, rng.choice(PAYMENT_TYPES))
    if key == "discharge_way":
        return L(region, rng.choice(DISCHARGE_WAYS))
    if key in ("actual_days",):
        return str(rng.randint(2, 14))
    if key in ("inpatient_times",):
        return str(rng.randint(1, 3))
    if key == "session":
        return L(region, f"第{rng.randint(1, 10)}次")
    if key == "package_name":
        return L(region, rng.choice(PACKAGE_NAMES))
    if key in ("height",):
        return f"{rng.randint(150, 185)}cm"
    if key == "weight":
        return f"{rng.randint(45, 95)}kg"
    if key == "bmi":
        return f"{rng.randint(17, 28)}.{rng.randint(0, 9)}"
    if key == "pulse":
        return f"{rng.randint(60, 100)}次/分"
    if key == "waist":
        return f"{rng.randint(60, 105)}cm"
    if key in ("vision_left", "vision_right"):
        return rng.choice(["4.8", "4.9", "5.0", "1.0", "0.8"])
    if key in ("total_cost", "amount", "reimbursed_amount", "out_of_pocket"):
        return f"{rng.randint(6, 380)}.{rng.randint(10, 99)}"
    if key in ("item_amount", "unit_price"):
        # 票据行自洽(round2 X 席:金额=单价×数量此前恒不成立)——行级三元由 row_ctx 提供,
        # 无上下文时退回随机(旧行为)以不破坏单字段调用。
        ctx = pools.get("_row_ctx") if isinstance(pools, dict) else None
        if key == "unit_price":
            if ctx is not None:
                ctx["unit_price"] = f"{rng.randint(6, 380)}.{rng.randint(10, 99)}"
                return ctx["unit_price"]
            return f"{rng.randint(6, 380)}.{rng.randint(10, 99)}"
        if ctx is not None and "unit_price" in ctx:
            qty = int(ctx.get("qty") or 1)
            return f"{float(ctx['unit_price']) * qty:.2f}"
        return f"{rng.randint(6, 380)}.{rng.randint(10, 99)}"
    if key in ("currency", "item_type"):
        ftok = fd.get("fallback_tokens") or []
        if ftok:
            return rng.choice(ftok)
        return rng.choice(fd.get("domain") or ["invoice"])
    if key in ("implants", "specimen", "transfusion", "drainage"):
        return L(region, {"implants": ["无", "留置支架一枚"],
                          "specimen": ["胆囊组织，已送病理", "无"],
                          "transfusion": ["无", "红细胞2U"],
                          "drainage": ["留置引流管，引流通畅", "无"]}[key][rng.randint(0, 1)])
    if key == "blood_loss":
        return rng.choice(["20ml", "50ml", "100ml", "200ml"])
    if key == "code_text":
        return f"{rng.choice('ABEIJKMN')}{rng.randint(10, 99)}.{rng.randint(0, 9)}"
    if key == "code_system":
        return "ICD-10"
    if key == "item_name":
        fees = (pools.get("derived", {}).get("fees") if region == "TW"
                else pools.get("derived", {}).get("fees_cn")) or []
        name = _clean(rng.choice(fees)["name"]) if fees else L(region, rng.choice(CLAIM_ITEMS)[0])
        ctx = pools.get("_row_ctx") if isinstance(pools, dict) else None
        if ctx is not None:
            ctx["item_name"] = name
        return name
    if key == "item_quantity":
        n = rng.randint(1, 3)
        ctx = pools.get("_row_ctx") if isinstance(pools, dict) else None
        if ctx is not None:
            ctx["qty"] = n
        return f"{n}{rng.choice(QUANTITY_UNITS)}"
    if key == "item_spec":
        # 非药品项目不带药械规格(round2 X 席:血常规/换药 100% 带 '12s/5mg' 为伪形态);
        # 仅"药/费"类项目名(西药费/中药费/材料)给规格,其余返回 None → 该字段跳过
        name = ""
        ctx = pools.get("_row_ctx") if isinstance(pools, dict) else None
        if ctx is not None:
            name = ctx.get("item_name") or ""
        if ("药" in name) or ("材料" in name):
            return rng.choice(["10ml", "0.25g", "12s", "100ml", "5mg"])
        return None
    if key == "name":
        return _diagnosis(pools, rng, region)
    if key == "diagnosis_text":
        return _card_sentence("diagnosis_text", rng, pools, region)
    ftype = fd.get("type")
    if ftype == "enumerated":
        dom = fd.get("domain") or []
        if dom:
            return rng.choice(dom)
    if ftype == "date":
        return _date(rng)
    if ftype == "number":
        return str(rng.randint(1, 200)) if fd.get("integer") else f"{rng.randint(1, 99)}.{rng.randint(0, 9)}"
    if ftype == "quantityWithUnit":
        return f"{rng.randint(1, 200)}{rng.choice(['mg', 'g', 'ml', 'mm'])}"
    if ftype in ("text", "narrative"):
        return L(region, rng.choice(GENERIC_TEXT_FALLBACK))
    return None


_DECOY_HEADERS = ("门诊病历", "住院病案首页", "检查报告单", "收费票据", "体检报告", "出院记录", "检验报告单")
_DECOY_FOOTERS = ("本页信息仅供参考，以原件为准", "打印时间：{d} {t}", "第{n}页 共{m}页",
                  "审核人：{doc}", "机打单据 请妥善保存")


def decoy_lines(rng, region, n_max=2):
    """无 span 诱饵行(表头/页脚/页码)——行级噪声(drop/merge/interleave/split)的触发面
    (round2 X 席:实现后全卡种触发率 0,因所有行都带 span)。返回 [(text, None)] 段列表。"""
    out = []
    if rng.random() < 0.55:
        out.append(("head", L(region, rng.choice(_DECOY_HEADERS))))
    if rng.random() < 0.5:
        tmpl = rng.choice(_DECOY_FOOTERS)
        text = tmpl.format(d=f"{rng.randint(2023, 2026)}-{rng.randint(1, 12):02d}-{rng.randint(1, 28):02d}",
                           t=f"{rng.randint(8, 20):02d}:{rng.randint(0, 59):02d}",
                           n=rng.randint(1, 3), m=rng.randint(1, 5), doc=_doctor(rng, trad=region != "CN"))
        out.append(("foot", L(region, text)))
    return out[:n_max]


def gen_generic_card(kind, pools, rng, vocab_chars):
    """spec 驱动的通用卡种生成（shared 行 + row 块）；行锚必出，行内 ≥2 键。"""
    spec = _SPECS.get(kind) or {}
    nz = new_noise_ctx(rng, mode="ocr")
    region = _region(pools, rng, need_drugs=kind in ("treatment_record", "surgery"))
    lines, shared, rows = [], [], []

    def push(line, spans):
        idx = len(lines)
        lines.append(line)
        for key, value in spans:
            if value:
                shared.append(span(key, value, idx))

    for pos, text in decoy_lines(rng, region):
        if pos == "head":
            lines.append(text)
    for fd in spec.get("shared_fields") or []:
        # 真实文档字段残缺常态:非必填按 40% 概率出现(全量输出会超 token 预算;
        # 也避免模型学到「字段必成对出现」的版式先验)
        if not fd.get("required") and rng.random() > 0.4:
            continue
        value = _card_value(fd.get("key", ""), fd, pools, rng, region)
        if not value:
            continue
        push(*make_line([(_card_label(fd, rng, region) + "：", "label", None),
                         (value, "value", fd["key"])], rng, nz=nz))

    row_fields = spec.get("row_fields") or []
    if row_fields:
        max_rows = min(int(spec.get("maxRows") or 3), 3)
        for _ in range(rng.randint(1, max(1, max_rows))):
            # 两遍:先定 item_name/unit_price/qty(自洽三元),再生成其余字段(如 item_amount=单价×数量)
            pools["_row_ctx"] = {}
            pre = {}
            for fd in row_fields:
                if fd.get("key") in ("item_name", "unit_price", "item_quantity"):
                    pre[fd["key"]] = _card_value(fd["key"], fd, pools, rng, region)
            segs = []
            for fd in row_fields:
                value = pre.get(fd.get("key")) or _card_value(fd.get("key", ""), fd, pools, rng, region)
                if not value:
                    continue
                segs.append((_card_label(fd, rng, region) + "：", "label", None))
                segs.append((value, "value", fd["key"]))
            if len(segs) < 4:      # 行锚 + ≥1 键（rowMinFields≥1）
                continue
            pools.pop("_row_ctx", None)
            line, sp = make_line(segs, rng, nz=nz)
            lines.append(line)
            li = len(lines) - 1
            rows.append([span(k, v, li) for k, v in sp])

    for pos, text in decoy_lines(rng, region):
        if pos == "foot":
            lines.append(text)

    return lines, shared, rows, nz


GENERIC_KINDS = ("hospitalization", "diagnosis", "exam_report", "claim_item", "immunization",
                 "health_exam", "clinical_conclusion", "surgery", "treatment_record")
for _gk in GENERIC_KINDS:
    BUILDERS[_gk] = (lambda k: (lambda pools, rng, vocab_chars:
                                gen_generic_card(k, pools, rng, vocab_chars)))(_gk)


# ================================================================ 预训练语料

def gen_pretrain_lines(pools, rng, n, vocab_chars, out_counter):
    drugs = pools["drugs"]
    aliases = pools["aliases"]
    groups = pools["groups"]
    diseases = pools["diseases"]
    ref_regions = [r for r in pools["regions"] if any(pools["ref"][t].get(r) for t in ("hospitals", "departments", "exams"))]
    lines = []
    while len(lines) < n:
        r = rng.random()
        d = rng.choice(drugs)
        name = d["name"]
        if ref_regions and r < 0.12:
            # 四域参考行（仅机构/科别/项目名称的陈述，不含任何医学结论）
            region = rng.choice(ref_regions)
            parts = []
            if pools["ref"]["hospitals"].get(region):
                parts.append(L(region, "就诊机构：") + _hospital(pools, rng, region))
            if pools["ref"]["departments"].get(region):
                parts.append(L(region, "科室：") + _department(pools, rng, region))
            if pools["ref"]["exams"].get(region):
                parts.append(L(region, "检验项目：") + rng.choice(pools["ref"]["exams"][region])["name"])
            text = "，".join(parts) + "。"
        elif r < 0.35:
            parts = [f"药品名称：{name}"]
            if d["spec"]:
                parts.append(f"规格：{d['spec']}")
            if d["form"]:
                parts.append(f"剂型：{d['form']}")
            if d["usage"]:
                parts.append(f"用法：{d['usage'][:60]}")
            text = "，".join(parts) + "。"
        elif r < 0.5 and groups:
            a, b = rng.choice(groups)
            text = f"{a}、{b} 为同一药品的不同写法。"
        elif r < 0.72 and diseases:
            text = f"{name}用于{diseases and rng.choice(diseases) or ''}等症状，具体用药请遵医嘱。"
        elif r < 0.86 and aliases:
            text = f"处方上出现「{rng.choice(aliases)}」时，请核对药品名称是否与包装一致。"
        else:
            text = f"{name}的常见规格为{d['spec'] or '见包装'}，请按说明书或医嘱使用。"
        text = _clean(text)
        if len(text) < 8:
            continue
        text = "".join(ch for ch in text if vocab_chars is None or ch in vocab_chars)
        if len(text) >= 8:
            lines.append(text)
    out_counter["pretrain"] = len(lines)
    return lines


# ================================================================ 主流程

def main():
    here = os.path.dirname(os.path.abspath(__file__))
    ap = argparse.ArgumentParser(description="抽取训练语料构建器（真实数据驱动）")
    ap.add_argument("--data-dir", default=os.environ.get("VITALIBER_DATA_DIR", ""),
                    help="data-dir 路径（CI：catalog_source.py 物化产物；或设 VITALIBER_DATA_DIR）")
    ap.add_argument("--prompts-dir", default=os.path.join(here, "prompts"))
    ap.add_argument("--out-dir", default=os.path.join(ROOT, "out", "extract-dataset"))
    ap.add_argument("--tokenizer", default=os.path.join(here, "..", "gen", "tokenizer.json"))
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--sft-count", type=int, default=27000, help="SFT 样本总量（按注册表权重切分）")
    ap.add_argument("--pretrain-count", type=int, default=40000)
    ap.add_argument("--eval-ratio", type=float, default=0.03)
    ap.add_argument("--allow-deferred", action="store_true",
                    help="显式解冻 policy.corpus.deferredKinds(默认跳过)")
    ap.add_argument("--eval-min-per-cell", type=int, default=60,
                    help="eval 定额/kinc×band 单元(round5 §2.2;dry-run 不计定额)")
    ap.add_argument("--budget", type=int, default=DEFAULT_BUDGET)
    ap.add_argument("--kinds", default="", help="只生成指定卡种（逗号分隔；默认全部）")
    ap.add_argument("--cells", default="", help="训练数据格子 <类型>/<地区>，逗号分隔（drugs|hospitals|departments|diagnoses|exams × cn|hk|tw）；"
                                                "留空且无 --regions/--types/--sources = 三地药品 drugs/cn,drugs/hk,drugs/tw")
    ap.add_argument("--regions", default="", help="按地区选（与 --types 交叉）：cn,hk,tw；给了 --cells 时忽略")
    ap.add_argument("--types", default="", help="按类型选（与 --regions 交叉）：drugs,hospitals,departments,diagnoses,exams；给了 --cells 时忽略")
    ap.add_argument("--sources", default="", help="旧写法：药品数据源 cn,nhsa,hk,tw → drugs/<地区> 格子（新脚本用 --cells）")
    ap.add_argument("--dry-run", action="store_true", help="快速冒烟：总量 60 条")
    args = ap.parse_args()

    if not args.data_dir or not os.path.isdir(args.data_dir):
        log("[FAIL] 缺 --data-dir（CI：先跑 catalog_source.py 物化；或设 VITALIBER_DATA_DIR）")
        return 2

    # 噪声常量 vs policy.json 单一事实源交叉断言(CI 布局有 policy.json;训练机副本
    # 无此布局 → 记 not-found,由 tests 侧断言兜)。不一致 = 拒绝产出(fail-closed)。
    policy_note = {"status": "not-found"}
    license_entries = {}
    deferred_kinds = {}
    pol = None
    policy_path = os.path.join(ROOT, ".github", "config", "distill", "policy.json")
    if os.path.exists(policy_path):
        try:
            with open(policy_path, encoding="utf-8") as fh:
                pol = json.load(fh)
            same = (pol["noise"]["bandTargets"] == BAND_CER
                    and pol["noise"]["trainMix"] == DEFAULT_TRAIN_MIX)
            policy_note = {"status": "match" if same else "mismatch",
                           "sha256": sha256_file(policy_path)}
            if not same:
                log("[FAIL] 噪声常量与 policy.json 不一致——拒绝产出(先同步两处)")
                return 2
            # 许可块:policy.licenses 单一事实源(H5 矩阵)——来源必须已登记且非禁再分发类
            deferred_kinds = pol.get("corpus", {}).get("deferredKinds") or {}
            lic_srcs = pol["licenses"]["sources"]
            for key in ("TFDA", "NHSA", "HK", "CN-REF", "PyCorrector"):
                entry = lic_srcs.get(key)
                if not entry:
                    log(f"[FAIL] 来源 {key} 未登记于 policy.licenses.sources")
                    return 2
                license_entries[key] = {"class": entry["class"], "attribution": entry["attribution"]}
        except (OSError, ValueError, KeyError) as exc:
            log(f"[FAIL] policy.json 读取失败: {exc}")
            return 2

    rng = random.Random(args.seed)
    global _EST
    vocab_chars = load_vocab_chars(args.tokenizer)
    _EST, counter_mode = make_token_counter(args.tokenizer)
    log(f"[init] token counter={counter_mode}; vocab_chars="
        f"{'none(byte-level BPE，无 OOV)' if vocab_chars is None else len(vocab_chars)}; budget={args.budget}")

    kinds = [k.strip() for k in args.kinds.split(",") if k.strip()] or list(REGISTRY.keys())
    # 预算冻结卡种(policy.corpus.deferredKinds;round2:prompt>budget=整类零样本,
    # 空跑浪费 CI 墙钟)——--allow-deferred 显式解冻
    if deferred_kinds and not args.allow_deferred:
        skipped = [k for k in kinds if k in deferred_kinds]
        if skipped:
            log(f"[skip] 预算冻结卡种(policy.deferredKinds): {', '.join(skipped)}")
        kinds = [k for k in kinds if k not in deferred_kinds]
    specs = load_specs(args.prompts_dir, kinds)
    set_specs(specs)   # 通用卡种生成器需要完整字段元数据（labels/type/枚举词形）
    if not specs:
        log("[FAIL] 无可用规格文件——先跑 .github/actions/distill/extract/export_prompts.sh")
        return 2
    kinds = [k for k in kinds if k in specs]

    # ---- 池装配（按「类型 × 地区」格子）----
    try:
        cells = DM.resolve_cells(args.cells, args.regions, args.types, args.sources)
    except ValueError as exc:
        log(f"[FAIL] {exc}")
        return 2
    regions, types = DM.cells_to_regions_types(cells)
    sources = DM.drug_sources_for(cells)
    if not sources:
        log(f"[FAIL] 至少选一个药品格子（drugs/cn|hk|tw）：处方/用药样本与预训练行都需要药品池（收到 {','.join(cells)}）")
        return 2
    log(f"[build] cells={','.join(cells)}  regions={','.join(regions)}  types={','.join(types)}")
    caps = {"nhsa": 9000, "tw": 2600, "hk": 2600}
    log("[build] 装载药品池（CN 全量 + NHSA/TW/HK 抽样）…")
    drugs = load_drugs(args.data_dir, rng, vocab_chars, caps, sources)
    if not drugs:
        log("[FAIL] 药品池为空——检查 --data-dir")
        return 2
    drugs_by_region = {}
    for d in drugs:
        drugs_by_region.setdefault(d["region"], []).append(d)
    drug_regions = [r.upper() for r in regions if drugs_by_region.get(r.upper())]
    if not drug_regions:
        log(f"[FAIL] 所选地区 {','.join(regions)} 没有装到任何药品——对应 drugs_*/tw_records/hk_records 文件缺失或为空")
        return 2
    tw_ids = {d.get("sid") for d in drugs if d["region"] == "TW" and d.get("sid")}
    diseases = set(DISEASE_FALLBACK)
    log("[build] 流式读取 medical_details（TW 用法 join + 疾病词表抽取）…")
    usage_by_id = load_details(args.data_dir, tw_ids, diseases, rng)
    for d in drugs:
        if d["region"] == "TW" and d.get("sid") in usage_by_id:
            d["usage"] = usage_by_id[d["sid"]][:80]
    log("[build] 装载别名池（medical_index）…")
    aliases, groups = load_aliases(args.data_dir, vocab_chars)
    # 四域名称池：只装所选格子；缺文件 → 内置名单兜底（清单 pools.ref 标 fallback，训练端菜单据此提示）
    ref = {t: {} for t in ("hospitals", "departments", "diagnoses", "exams")}
    ref_stats = {}
    for dtype in ref:
        for r in regions:
            key = f"{dtype}/{r}"
            if key not in cells:
                continue
            items, total = load_ref_pool(args.data_dir, dtype, r, rng)
            if items:
                ref[dtype][r.upper()] = items
            ref_stats[key] = {"records": total, "sampled": len(items), "fallback": not items}
            if not items:
                log(f"[pool] ref {key}: 本机无 {', '.join(DM.CELL_BY_KEY[key].files)} → 退回内置名单（{DM.CELL_BY_KEY[key].how}）")
    derived = load_derived_pools(args.data_dir, regions, rng)
    # fail-closed(round2 X 席 F:声明走目录却回落常量=「缺证据当有证据」的反面)——
    # 仅在「已物化的生产 data-dir」(training_feed_manifest.json 在场)下强制;
    # 测试夹具/训练机自造目录不触发。TW 在选且术式/收费派生为空 = 目录版本异常,拒绝产出。
    if os.path.exists(os.path.join(args.data_dir, "training_feed_manifest.json")):
        missing = []
        if not derived["vaccines"]:
            missing.append("vaccine_*.jsonl(疫苗谓词派生)")
        if "TW" in [r.upper() for r in regions]:
            if not derived["procedures"]:
                missing.append("procedure_tw.jsonl(術式∪處置)")
            if not derived["fees"]:
                missing.append("fee_tw.jsonl(TW 带价收费项)")
        if missing:
            log(f"[FAIL] 派生域缺失(生产目录下 fail-closed): {', '.join(missing)}——"
                f"检查 catalog_source 物化/目录 schema")
            return 2
    pools = {"drugs": drugs, "drugs_by_region": drugs_by_region, "regions": [r.upper() for r in regions], "drug_regions": drug_regions,
             "ref": ref, "derived": derived, "diseases": sorted(diseases), "aliases": aliases, "groups": groups}
    # —— 值级 holdout 集(round2 X2:实体池 10% 稳定哈希留出;仅目录来源域) ——
    def _is_holdout_value(v):
        return sample_draw(args.seed, f"holdout:{v}") < int(VALUE_HOLDOUT_RATIO * (1 << 64))

    domain_names = {
        "drug_name": [d["name"] for d in drugs] + list(aliases),
        "generic_name": [d["name"] for d in drugs],
        "hospital": [i["name"] for r in ref["hospitals"].values() for i in r],
        "org_name": [i["name"] for r in ref["hospitals"].values() for i in r],
        "merchant": [i["name"] for r in ref["hospitals"].values() for i in r],
        "provider": [i["name"] for r in ref["hospitals"].values() for i in r],
        "raw_label": [i["name"] for r in ref["exams"].values() for i in r],
        "name": [i["name"] for r in ref["diagnoses"].values() for i in r] or sorted(diseases),
        "vaccine_name": [n for names in derived["vaccines"].values() for n in names],
        "surgery_name": [p["name"] for p in derived["procedures"]],
        "item_name": [f["name"] for f in derived["fees"]],
    }
    holdout_by_key = {k: {v for v in names if _is_holdout_value(v)}
                      for k, names in domain_names.items() if names}
    log(f"[holdout] 值级留出集: " + ", ".join(f"{k}={len(v)}" for k, v in sorted(holdout_by_key.items())))

    # ---- 样本生成 ----
    total = 60 if args.dry_run else args.sft_count
    weights = {k: REGISTRY[k]["weight"] for k in kinds}
    wsum = sum(weights.values())
    counts = {k: int(total * weights[k] / wsum) for k in kinds}

    os.makedirs(args.out_dir, exist_ok=True)
    sft_path = os.path.join(args.out_dir, "extraction_sft.jsonl")
    eval_path = os.path.join(args.out_dir, "extraction_eval.jsonl")
    pre_path = os.path.join(args.out_dir, "extraction_pretrain.jsonl")
    sft_tmp_path = sft_path + ".tmp"
    eval_tmp_path = eval_path + ".tmp"
    pre_tmp_path = pre_path + ".tmp"
    for stale_tmp in (sft_tmp_path, eval_tmp_path, pre_tmp_path):
        try:
            os.remove(stale_tmp)
        except FileNotFoundError:
            pass

    stats = {"counts": {}, "dropped": {}, "est": [], "trimmed": 0, "eval": 0, "oov_values": 0}
    est_vals = []
    pending, eval_entries = [], []
    forced_eval_ids = set()

    def bump(reason):
        stats["dropped"][reason] = stats["dropped"].get(reason, 0) + 1

    with open(sft_tmp_path, "w", encoding="utf-8", newline="\n") as fsft, open(eval_tmp_path, "w", encoding="utf-8", newline="\n") as feval:
        for kind in kinds:
            made, attempts = 0, 0
            while made < counts[kind] and attempts < counts[kind] * 8:
                attempts += 1
                lines, shared, rows, nz = BUILDERS[kind](pools, rng, vocab_chars)
                # 行级结构噪声(round5 §2.2;lineIndex 结构映射重算)——
                # 在构造期自检之前施加,ops 破坏 verbatim 即整条丢弃(兜底闸)
                lines, shared, rows, line_stats = apply_line_ops(
                    lines, shared, rows, rng, band=nz["band"])
                if not check_verbatim(lines, shared, rows):
                    bump("verbatim_construct")  # 构造期自检失败（理论不可达；响了就是噪声模块改坏了）
                    continue
                # OOV 值守卫：span 含词表外字符 → 整条丢弃（小模型无法逐字拷贝）
                bad = False
                for s in shared + [s for row in rows for s in row]:
                    if vocab_chars is not None and oov_chars(s["value"], vocab_chars):
                        bad = True
                        break
                if bad:
                    stats["oov_values"] += 1
                    bump("oov_value")
                    continue
                sample, reason, est = make_sample(kind, specs, lines, shared, rows, args.budget)
                if sample is None:
                    bump(reason or "unknown")
                    continue
                if reason == "trimmed":
                    stats["trimmed"] += 1
                est_vals.append(est)
                # 噪声 v2 元数据:样本 id(评测/对账主键,与 split 无关=内容寻址可重放)
                sample["id"] = f"extract-{kind}-{made:06d}"
                sample["noise"] = noise_ctx_summary(nz)
                if any(line_stats.values()):
                    sample["line_ops"] = dict(line_stats)
                glo = stats.setdefault("line_ops",
                                       {"drop": 0, "merge": 0, "interleave": 0, "split": 0})
                for k, v in line_stats.items():
                    glo[k] += v
                band_stats = stats.setdefault("noise", {"version": NOISE_VERSION, "bands": {}})
                agg = band_stats["bands"].setdefault(
                    nz["band"], {"samples": 0, "spans": 0, "damaged": 0, "cer_n": 0, "cer_sum": 0.0})
                agg["samples"] += 1
                agg["spans"] += nz["span_total"]
                agg["damaged"] += nz["span_damaged"]
                agg["cer_n"] += nz.get("cer_n", 0)
                agg["cer_sum"] += nz.get("cer_sum", 0.0)
                forced = False
                for s in list(shared) + [s for row in rows for s in row]:
                    if s["value"] in holdout_by_key.get(s["key"], ()):
                        forced = True
                        break
                if forced:
                    sample["value_holdout"] = True
                    forced_eval_ids.add(sample["id"])
                pending.append(sample)
                eval_entries.append(((kind, nz["band"]),
                                     sample_draw(args.seed, sample["id"]), sample["id"]))
                made += 1
            stats["counts"][kind] = made
            log(f"[gen] {kind}: {made} 条（尝试 {attempts}）")

        # —— eval/SFT 分配(定额制;round5 §2.2)——
        quota = 0 if args.dry_run else args.eval_min_per_cell
        split, eval_cells = assign_eval_splits(
            eval_entries, eval_ratio=args.eval_ratio, quota=quota,
            forced_eval=forced_eval_ids,
            quota_unit=(pol.get("gates", {}).get("extraction", {}).get("evalQuotaUnit", "cell")
                        if pol else "cell"))
        n_eval = 0
        for sample in pending:
            if split[sample["id"]] == "eval":
                feval.write(json.dumps(sample, ensure_ascii=False) + "\n")
                n_eval += 1
            else:
                fsft.write(json.dumps(sample, ensure_ascii=False) + "\n")
        stats["eval"] = n_eval
        stats["eval_cells"] = eval_cells
        stats["value_holdout"] = {"ratio": VALUE_HOLDOUT_RATIO, "forced": len(forced_eval_ids),
                                  "keys": {k: len(v) for k, v in sorted(holdout_by_key.items())}}
        deficits = {c: v["deficit"] for c, v in eval_cells.items() if v["deficit"]}
        log(f"[eval] quota={quota}/单元 cells={len(eval_cells)} eval={n_eval}/{len(pending)}"
            + (f" deficit={deficits}" if deficits else ""))

    with open(pre_tmp_path, "w", encoding="utf-8", newline="\n") as fpre:
        n_pre = 60 if args.dry_run else args.pretrain_count
        counter = {}
        for text in gen_pretrain_lines(pools, rng, n_pre, vocab_chars, counter):
            fpre.write(json.dumps({"text": text}, ensure_ascii=False) + "\n")

    for tmp_path, final_path in ((sft_tmp_path, sft_path), (eval_tmp_path, eval_path), (pre_tmp_path, pre_path)):
        os.replace(tmp_path, final_path)

    est_vals.sort()
    def pct(p):
        return est_vals[min(len(est_vals) - 1, int(len(est_vals) * p))] if est_vals else 0
    stats["est"] = {"min": est_vals[0] if est_vals else 0, "p50": pct(0.5), "p95": pct(0.95),
                    "max": est_vals[-1] if est_vals else 0}

    feed_path = os.path.join(args.data_dir, "training_feed_manifest.json")
    data_feed = None
    if os.path.exists(feed_path):
        try:
            with open(feed_path, "r", encoding="utf-8") as fh:
                feed_meta = json.load(fh)
            data_feed = {"stamp": feed_meta.get("stamp"), "generated_at": feed_meta.get("generated_at"),
                         "sha256": sha256_file(feed_path)}
        except (OSError, ValueError):
            data_feed = {"error": "unreadable training_feed_manifest.json"}
    manifest = {
        "generatedAt": __import__("datetime").datetime.now().isoformat(timespec="seconds"),
        "seed": args.seed, "budget": args.budget,
        # 训练端数据菜单据此判断「现有语料是否可复用」；权重 .meta.json 据此溯源到数据批次。
        "params": {"cells": list(cells), "regions": list(regions), "types": list(types), "sources": list(sources),
                   "kinds": list(kinds), "sft_count": args.sft_count,
                   "pretrain_count": args.pretrain_count, "eval_ratio": args.eval_ratio,
                   "eval_min_per_cell": args.eval_min_per_cell,
                   "eval_max_share": EVAL_MAX_SHARE,
                   "seed": args.seed, "budget": args.budget},
        "data_feed": data_feed,
        # 逐源许可义务(H5 矩阵;policy 单一事实源)——顶层键(round2 质询席 E:不得埋进 noise 块)
        "licenses": license_entries,
        "pools": {"drugs": len(pools["drugs"]), "drugs_by_region": {k: len(v) for k, v in sorted(drugs_by_region.items())},
                  "ref": ref_stats, "aliases": len(pools["aliases"]),
                  "groups": len(pools["groups"]), "diseases": len(pools["diseases"]),
                  # 派生值域来源构成(H3 D 席;值来源可审计——常量占比治理的数据面)
                  "source_mix": {"vaccines": {r: len(v) for r, v in sorted(derived["vaccines"].items())},
                                 "procedures_tw": len(derived["procedures"]),
                                 "fees_tw": len(derived["fees"]),
                                 "procedures_cn_import": len(derived["procedures_cn"]),
                                 "fees_cn_import": len(derived["fees_cn"])}},
        "noise": {
            "version": NOISE_VERSION,
            "band_targets": dict(BAND_CER),
            "train_mix": dict(DEFAULT_TRAIN_MIX),
            "tables_sha256": confusion_tables_sha256(),
            # 带位验收量:span 损伤率(samples/spans/damaged;目标见 policy/round5 §2.2)
            "span_damage_by_band": {
                band: {"samples": agg["samples"], "spans": agg["spans"],
                       "damaged": agg["damaged"],
                       "rate": round(agg["damaged"] / max(agg["spans"], 1), 4),
                       "cer_mean": round(agg["cer_sum"] / max(agg["cer_n"], 1), 4),
                       "cer_n": agg["cer_n"]}
                for band, agg in (stats.get("noise", {}).get("bands") or {}).items()},
            "policy": policy_note,
        },
        "stats": stats,
        "files": {},
    }
    for path in [sft_path, eval_path, pre_path]:
        manifest["files"][os.path.basename(path)] = {
            "lines": sum(1 for _ in open(path, encoding="utf-8")),
            "sha256": sha256_file(path),
        }
    manifest_path = os.path.join(args.out_dir, "extraction_manifest.json")
    with open(manifest_path, "w", encoding="utf-8") as fh:
        json.dump(manifest, fh, ensure_ascii=False, indent=2)

    log("")
    log("================ 构建完成 ================")
    log(f"SFT    {sft_path}  {manifest['files'][os.path.basename(sft_path)]['lines']} 行")
    log(f"EVAL   {eval_path}  {manifest['files'][os.path.basename(eval_path)]['lines']} 行")
    log(f"PRE    {pre_path}  {manifest['files'][os.path.basename(pre_path)]['lines']} 行")
    log(f"est tokens: {stats['est']}  trimmed={stats['trimmed']}  dropped={stats['dropped']}")
    log(f"manifest -> {manifest_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
