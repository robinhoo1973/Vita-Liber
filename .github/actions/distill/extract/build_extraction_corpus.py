# -*- coding: utf-8 -*-
"""
抽取训练语料构建器（真实数据驱动 + 注册表可扩展，2026-09-24）

—— 2026-10-07 迁入 CI 簇（scripts/distill/extract/）说明：本文件是
   refactor/tools/training/{macos,windows}/scripts/corpus/build_extraction_corpus.py
   的正本迁入（同轮迁入 extraction_noise.py 与 datamatrix.py 裁剪版），改动仅三处：
   ① 数据源路径说明（CI 的 data-dir 由 catalog_source.py 从 CNB Release 目录物化）；
   ② datamatrix 改为同目录 import（CI 无 trainlib 包布局）；
   ③ 默认路径改为仓锚定（prompts 落本目录 prompts/、tokenizer 取 scripts/distill/gen/）。
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
   --prompts-dir prompts/（scripts/distill/extract/export_prompts.sh 从 CoreKit Domain 编译导出）

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
)

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


def L(region, text):
    """地区版式文字：CN 原样；TW/HK 按 S2T 字表转繁体（仅用于本文件模板常量）。"""
    return text if region == "CN" else text.translate(S2T)


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
    "prescription": {"mode": "ocr", "weight": 0.45, "builder": "gen_prescription"},
    "medication":   {"mode": "asr", "weight": 0.20, "builder": "gen_medication"},
    "encounter":    {"mode": "ocr", "weight": 0.20, "builder": "gen_encounter"},
    "metric_sample": {"mode": "ocr", "weight": 0.15, "builder": "gen_metric_sample"},
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


def spec_char_ok(value, vocab_chars):
    return not oov_chars(value, vocab_chars)


# ================================================================ 规格/提示词装载

def load_specs(prompts_dir, kinds):
    specs = {}
    for kind in kinds:
        prompt_path = os.path.join(prompts_dir, f"prompt_{kind}.txt")
        spec_path = os.path.join(prompts_dir, f"spec_{kind}.json")
        if not (os.path.exists(prompt_path) and os.path.exists(spec_path)):
            log(f"[skip] {kind}: 缺 prompt_/spec_ 文件（跑 scripts/distill/extract/export_prompts.sh 导出）")
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


def make_line(segments, rng, level=None):
    """segments: (text, role, key|None)（旧两元组兼容）；value 段加噪后即 span 基。
    返回 (行文本, [(key, 加噪后段文本)…]) —— span value 取加噪后原文，verbatim 由构造保证。"""
    norm = []
    for seg in segments:
        if len(seg) == 3:
            text, role, key = seg
        else:
            text, role = seg
            key = None
        norm.append((text, role, key))
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

    # —— 表头（行序号即 lineIndex）——
    h = _hospital(pools, rng, region)
    push(*make_line([(h, "value", "hospital"), (L(region, "门诊处方笺"), "label", None)], rng))

    dept = _department(pools, rng, region)
    push(*make_line([(L(region, "科室"), "label", None), (dept, "value", "department")], rng))

    if rng.random() < 0.7:
        push(*make_line([(L(region, "医师"), "label", None), (_doctor(rng, trad), "value", "doctor")], rng))
    push(*make_line([(L(region, "处方日期"), "label", None), (_date(rng), "value", "prescribed_at")], rng))  # 必填：恒定出现
    if rng.random() < 0.6:
        no = f"{rng.choice('ABC')}{rng.randint(100000, 999999)}"
        push(*make_line([(L(region, "处方号"), "label", None), (no, "value", "prescription_no")], rng))
    if rng.random() < 0.6 and (pools["diseases"] or pools["ref"]["diagnoses"].get(region)):
        d1 = _diagnosis(pools, rng, region)
        d2 = _diagnosis(pools, rng, region) if rng.random() < 0.35 else ""
        diag = d1 + ("、" + d2 if d2 else "")
        push(*make_line([(L(region, "临床诊断"), "label", None), (diag, "value", "clinical_diagnosis")], rng))
    if rng.random() < 0.35:
        # 硬负例：过敏史里出现的药名不得建行（无 key 即不入 span）
        push(*make_line([(L(region, "既往"), "label", None), (L(region, rng.choice(ALLERGY_LINES)), "value", None)], rng))

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
            line, seg_spans = make_line(segs, rng)
            lines.append(line)
            rows.append(_finish(line, seg_spans, len(lines) - 1))
        elif variant == "labeled":
            segs1 = [(f"{i + 1}.", "label", None), (name, "value", "drug_name")]
            if base_spec:
                segs1 += [(L(region, "规格"), "label", None), (base_spec, "value", "spec")]
            if qty:
                segs1 += [(L(region, "数量"), "label", None), (qty, "value", "quantity")]
            line1, sp1 = make_line(segs1, rng)
            lines.append(line1)
            li1 = len(lines) - 1
            segs2 = [(L(region, "用法"), "label", None), (dosage_seg, "value", "dosage"),
                     (freq, "value", "frequency"), (route, "value", "route")]
            if days:
                segs2.append((f"{days}天", "value", "days"))
            line2, sp2 = make_line(segs2, rng)
            lines.append(line2)
            li2 = len(lines) - 1
            row = _finish(line1, sp1, li1) + _finish(line2, sp2, li2)
            rows.append(row)
        else:  # split：药名规格一行，用法一行（无标签）
            segs1 = [(f"{i + 1}.", "label", None), (name, "value", "drug_name")]
            if base_spec:
                segs1.append((base_spec, "value", "spec"))
            line1, sp1 = make_line(segs1, rng)
            lines.append(line1)
            li1 = len(lines) - 1
            segs2 = [(f"用法：{dosage_seg}", "value", "dosage"), (freq, "value", "frequency"),
                     (route, "value", "route")]
            if days:
                segs2.append((f"{days}天", "value", "days"))
            line2, sp2 = make_line(segs2, rng)
            lines.append(line2)
            li2 = len(lines) - 1
            row = _finish(line1, sp1, li1) + _finish(line2, sp2, li2)
            rows.append(row)

    if rng.random() < 0.4:
        push(*make_line([(L(region, "医嘱"), "label", None), (L(region, rng.choice(TCM_ADVICES)), "value", "advice_text")], rng))

    return lines, shared, rows


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
        line, seg_spans = make_line(segs, rng)
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
    return lines, shared, rows


# ================================================================ 门诊记录（OCR 页）

def gen_encounter(pools, rng, vocab_chars):
    lines, shared, rows = [], [], []

    def push(line, spans):
        idx = len(lines)
        lines.append(line)
        for key, value in spans:
            if value:
                shared.append(span(key, value, idx))

    region = _region(pools, rng, need_drugs=False)
    trad = region != "CN"
    push(*make_line([(L(region, "就诊日期"), "label", None), (_date(rng), "value", "date")], rng))  # 必填：恒定出现
    h = _hospital(pools, rng, region)
    push(*make_line([(h, "value", "hospital"), (L(region, "门诊病历"), "label", None)], rng))
    dept = _department(pools, rng, region)
    push(*make_line([(L(region, "科室"), "label", None), (dept, "value", "department")], rng))
    if rng.random() < 0.7:
        push(*make_line([(L(region, "医师"), "label", None), (_doctor(rng, trad), "value", "doctor")], rng))
    push(*make_line([(L(region, "主诉"), "label", None), (L(region, rng.choice(COMPLAINTS)), "value", "chief_complaint")], rng))
    d1 = _diagnosis(pools, rng, region)
    d2 = _diagnosis(pools, rng, region) if rng.random() < 0.4 else ""
    diag = d1 + ("、" + d2 if d2 else "")
    push(*make_line([(L(region, "诊断"), "label", None), (diag, "value", "diagnosis_text")], rng))
    if rng.random() < 0.4:  # advice_text 在 encounter spec 的 shared 键内（见 spec_encounter.json）
        push(*make_line([(L(region, "医嘱"), "label", None), (L(region, rng.choice(TCM_ADVICES)), "value", "advice_text")], rng))
    return lines, shared, rows


# ================================================================ 检验报告（字母数字表）

def gen_metric_sample(pools, rng, vocab_chars):
    lines, shared, rows = [], [], []

    def push(line, spans):
        idx = len(lines)
        lines.append(line)
        for key, value in spans:
            if value:
                shared.append(span(key, value, idx))

    region = _region(pools, rng, need_drugs=False)
    push(*make_line([(L(region, "报告日期"), "label", None), (_date(rng), "value", "measured_at")], rng))
    if rng.random() < 0.6:
        push(*make_line([(L(region, "医院"), "label", None), (_hospital(pools, rng, region), "value", "hospital")], rng))
    if rng.random() < 0.5:
        push(*make_line([(L(region, "标本类型"), "label", None), (L(region, "静脉血"), "value", "specimen_type")], rng))
    n = rng.randint(3, 7)
    ref_exams = pools["ref"]["exams"].get(region) or []
    if ref_exams and rng.random() < 0.5:
        # 真实检查检验项目名（健保支付标准等）：只知道名称/单位，不编造参考范围与异常标记
        for item in rng.sample(ref_exams, min(n, len(ref_exams))):
            lo, hi, digits = rng.choice([(0.1, 10, 2), (1, 100, 1), (10, 500, 0)])
            segs = [(item["name"], "value", "raw_label"), (f"{round(rng.uniform(lo, hi), digits) if digits else int(rng.uniform(lo, hi))}", "value", "value")]
            if item["unit"]:
                segs.append((item["unit"], "value", "unit"))
            line, seg_spans = make_line(segs, rng, level=rng.choices(["clean", "light"], weights=[45, 55])[0])
            lines.append(line)
            rows.append([span(key, v, len(lines) - 1) for key, v in seg_spans if v and key])
        return lines, shared, rows
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
        line, seg_spans = make_line(segs, rng, level=rng.choices(["clean", "light"], weights=[45, 55])[0])
        lines.append(line)
        idx = len(lines) - 1
        row = [span(key, v, idx) for key, v in seg_spans if v and key]
        rows.append(row)
    return lines, shared, rows


BUILDERS = {
    "prescription": gen_prescription,
    "medication": gen_medication,
    "encounter": gen_encounter,
    "metric_sample": gen_metric_sample,
}


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

    rng = random.Random(args.seed)
    global _EST
    vocab_chars = load_vocab_chars(args.tokenizer)
    _EST, counter_mode = make_token_counter(args.tokenizer)
    log(f"[init] token counter={counter_mode}; vocab_chars="
        f"{'none(byte-level BPE，无 OOV)' if vocab_chars is None else len(vocab_chars)}; budget={args.budget}")

    kinds = [k.strip() for k in args.kinds.split(",") if k.strip()] or list(REGISTRY.keys())
    specs = load_specs(args.prompts_dir, kinds)
    if not specs:
        log("[FAIL] 无可用规格文件——先跑 scripts/distill/extract/export_prompts.sh")
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
    pools = {"drugs": drugs, "drugs_by_region": drugs_by_region, "regions": [r.upper() for r in regions], "drug_regions": drug_regions,
             "ref": ref, "diseases": sorted(diseases), "aliases": aliases, "groups": groups}

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

    def bump(reason):
        stats["dropped"][reason] = stats["dropped"].get(reason, 0) + 1

    with open(sft_tmp_path, "w", encoding="utf-8", newline="\n") as fsft, open(eval_tmp_path, "w", encoding="utf-8", newline="\n") as feval:
        for kind in kinds:
            made, attempts = 0, 0
            while made < counts[kind] and attempts < counts[kind] * 8:
                attempts += 1
                lines, shared, rows = BUILDERS[kind](pools, rng, vocab_chars)
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
                target = feval if rng.random() < args.eval_ratio else fsft
                target.write(json.dumps(sample, ensure_ascii=False) + "\n")
                if target is feval:
                    stats["eval"] += 1
                made += 1
            stats["counts"][kind] = made
            log(f"[gen] {kind}: {made} 条（尝试 {attempts}）")

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
                   "seed": args.seed, "budget": args.budget},
        "data_feed": data_feed,
        "pools": {"drugs": len(pools["drugs"]), "drugs_by_region": {k: len(v) for k, v in sorted(drugs_by_region.items())},
                  "ref": ref_stats, "aliases": len(pools["aliases"]),
                  "groups": len(pools["groups"]), "diseases": len(pools["diseases"])},
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
