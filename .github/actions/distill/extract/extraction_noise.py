# -*- coding: utf-8 -*-
"""
OCR / ASR 噪声模型（抽取训练语料专用，2026-09-24）

2026-10-07 迁入 CI 簇（.github/actions/distill/extract/；来源 refactor/tools/training/
{macos,windows}/scripts/corpus/extraction_noise.py，训练机正本）。**逐字节一致为
纪律**：任何修改必须两侧同步（训练/推理同分布的组成部分——噪声分布即输入分布）。
本副本不参与训练机部署，仅由 CI 语料构建器消费。

设计约束（hard，违一条即为污染语料）：
  1) **逐字契约不破**：噪声按「段」施加——每段文本先加噪，再由加噪后的段拼行、
     由加噪后的段生成 span value。value = 段加噪文本原样 → 必然是行文本的子串，
     与 App 端 ModelSpanAssembler / OCRGrounding 的 verbatim 校验同一口径。
  2) **字符安全**：ASCII 双引号 / 反斜杠 / 控制符不进输出（GBNF `str` 字符类排除、
     JSON 转义后不再是逐字子串）；任意变换后段不得为空。
  3) 强度分级：clean / light / heavy——模型同时见过干净与脏输入，不偏科。

调用方：build_extraction_corpus.py。所有函数用注入的 random.Random 实例，
保证语料可复现（同 seed 同输出）。
"""
import random
import re

# ---------------------------------------------------------------- 硬清理

_FORBIDDEN = str.maketrans({"\"": "", "\\": "", "\n": " ", "\r": " ", "\t": " "})
_CONTROL = re.compile(r"[\u0000-\u001F\u007F]")


def sanitize_hard(text: str) -> str:
    """去掉 GBNF str 类别不容的 ASCII 引号/反斜杠/控制符；词内空白归并为单空格。"""
    text = text.translate(_FORBIDDEN)
    text = _CONTROL.sub("", text)
    return re.sub(r"\s+", " ", text).strip()


# ---------------------------------------------------------------- OCR 噪声

FULLWIDTH_MAP = {chr(ord("0") + i): chr(0xFF10 + i) for i in range(10)}
FULLWIDTH_MAP.update({chr(ord("A") + i): chr(0xFF21 + i) for i in range(26)})
FULLWIDTH_MAP.update({chr(ord("a") + i): chr(0xFF41 + i) for i in range(26)})
FULLWIDTH_MAP.update({".": "．", "%": "％", ":": "："})

# 视觉/形体混淆对（双向应用）——处方/报告 OCR 的常见误读家族
OCR_CHAR_CONFUSIONS = [
    ("已", "己"), ("未", "末"), ("日", "曰"), ("千", "干"), ("0", "O"),
    ("1", "l"), ("5", "S"), ("8", "B"), ("2", "Z"), ("6", "G"),
    ("氨", "氨"), ("苷", "甘"), ("酮", "同"), ("嗪", "秦"), ("喹", "奎"),
    ("啶", "定"), ("唑", "坐"), ("酯", "脂"), ("洛", "落"), ("坦", "毯"),
    ("硝", "销"), ("沙", "砂"), ("盐", "监"), ("酸", "酸"), ("酚", "酣"),
]
_OCR_PAIRS = [(a, b) for a, b in OCR_CHAR_CONFUSIONS if a != b]

_LATIN_DIGIT = re.compile(r"[0-9A-Za-z]")


def fullwidth_noise(seg: str, rng: random.Random, p: float = 0.5) -> str:
    """数字/字母/常见符号整段转全角（OCR 全半角混排的典型形态）。"""
    if rng.random() >= p:
        return seg
    return "".join(FULLWIDTH_MAP.get(ch, ch) for ch in seg)


def confuse_chars(seg: str, rng: random.Random, p: float = 0.03) -> str:
    """按字符逐位替换为混淆对另一侧。"""
    out = []
    for ch in seg:
        if rng.random() < p:
            for a, b in _OCR_PAIRS:
                if ch == a:
                    ch = b
                    break
                if ch == b:
                    ch = a
                    break
        out.append(ch)
    return "".join(out)


def jitter_spaces(seg: str, rng: random.Random, p: float = 0.2) -> str:
    """在拉丁/数字与中文边界、数字与单位之间随机撒空格（识别框拼接痕迹）。"""
    out = []
    for ch in seg:
        if out and rng.random() < p:
            prev = out[-1]
            boundary = (_LATIN_DIGIT.match(prev) is not None) != (_LATIN_DIGIT.match(ch) is not None)
            if boundary and prev not in " " and ch not in " ":
                out.append(" ")
        out.append(ch)
    return "".join(out)


def punctuation_loosen(seg: str, rng: random.Random) -> str:
    """标点形态漂移：全角↔半角、偶尔丢失。只動分隔符形态，不动字。"""
    table = {"：": rng.choice([":", "：", ""]), "：": "：", "。": rng.choice(["。", "", "."]),
             "，": rng.choice(["，", ",", "、"]), "；": rng.choice(["；", ";"]), "、": rng.choice(["、", ","])}
    return "".join(table.get(ch, ch) for ch in seg)


def heavy_artifacts(seg: str, rng: random.Random) -> str:
    """重度噪声：偶发粘字符 / 丢失单字 / 多余空格串。"""
    if len(seg) >= 3 and rng.random() < 0.5:
        i = rng.randrange(len(seg))
        seg = seg[:i] + seg[i] + seg[i:]      # 粘字符
    if len(seg) >= 4 and rng.random() < 0.3:
        i = rng.randrange(1, len(seg) - 1)
        seg = seg[:i] + seg[i + 1:]           # 丢单字
    if rng.random() < 0.3:
        seg = seg.replace(" ", "  ", 1)
    return seg


def ocr_noise_segment(seg: str, rng: random.Random, level: str = None) -> str:
    """对单个段施加 OCR 噪声；返回非空段。level=None 时按 30/50/20 分布抽样。"""
    if level is None:
        level = rng.choices(["clean", "light", "heavy"], weights=[30, 50, 20])[0]
    original = sanitize_hard(seg)
    if level == "clean" or not original:
        return original
    out = fullwidth_noise(original, rng)
    out = confuse_chars(out, rng, p=0.03 if level == "light" else 0.06)
    out = jitter_spaces(out, rng, p=0.2 if level == "light" else 0.35)
    out = punctuation_loosen(out, rng) if level == "light" else punctuation_loosen(out, rng)
    if level == "heavy":
        out = heavy_artifacts(out, rng)
    out = sanitize_hard(out)
    return out if out else original


def ocr_separator(rng: random.Random) -> str:
    """段间分隔（列对齐 / 标签冒号 / 纯空格三类）。"""
    return rng.choices(["  ", " ", "", "：", "： ", ": ", " · "], weights=[30, 25, 10, 10, 10, 8, 7])[0]


# ---------------------------------------------------------------- ASR 噪声

ASR_HOMOPHONES = [
    ("氨", "安"), ("苷", "甘"), ("唑", "坐"), ("沙", "砂"), ("洛", "络"),
    ("坦", "毯"), ("酯", "脂"), ("硝", "消"), ("仑", "伦"), ("嗪", "琴"),
    ("西林", "希林"), ("地尔", "第尔"), ("胶囊", "胶南"), ("颗粒", "科粒"),
]
_ASR_PAIRS = [(a, b) for a, b in ASR_HOMOPHONES if a != b]

_CN_NUM = {"1": "一", "2": "两", "3": "三", "4": "四", "5": "五", "6": "六", "7": "七", "8": "八", "9": "九", "10": "十"}
_FILLERS = ["嗯", "那个", "就是", "然后", "呃"]


def asr_homophone(seg: str, rng: random.Random, p: float = 0.08) -> str:
    for a, b in _ASR_PAIRS:
        if a in seg and rng.random() < p:
            seg = seg.replace(a, b if rng.random() < 0.7 else a, 1)
    return seg


def asr_number_style(seg: str, rng: random.Random) -> str:
    """口播数字形态：2片→两片、0.25→零点二五 之类的合理近似（只动本品内形态）。"""
    m = re.match(r"^(\d+)(片|粒|袋|支|瓶|贴|丸)$", seg)
    if m and m.group(1) in _CN_NUM and rng.random() < 0.6:
        return _CN_NUM[m.group(1)] + m.group(2)
    if rng.random() < 0.4:
        seg = seg.replace("0.", "零点", 1) if seg.startswith("0.") else seg
    return seg


def asr_fillers(seg: str, rng: random.Random, p: float = 0.35) -> str:
    if rng.random() < p:
        seg = rng.choice(_FILLERS) + " " + seg
    if rng.random() < p * 0.6:
        parts = seg.split(" ")
        if len(parts) > 2:
            i = rng.randrange(1, len(parts))
            parts.insert(i, rng.choice(_FILLERS))
            seg = " ".join(parts)
    return seg


def asr_noise_segment(seg: str, rng: random.Random, level: str = None) -> str:
    """对单个段施加 ASR 噪声（同音字 / 口播数字 / 语气词；无标点）。"""
    if level is None:
        level = rng.choices(["clean", "light", "heavy"], weights=[25, 55, 20])[0]
    original = sanitize_hard(seg)
    if level == "clean" or not original:
        return original
    out = asr_homophone(original, rng, p=0.06 if level == "light" else 0.12)
    out = asr_number_style(out, rng)
    if level == "heavy":
        out = asr_fillers(out, rng, p=0.5)
    out = out.replace("。", "").replace("，", " ").replace(",", " ")
    out = sanitize_hard(out)
    return out if out else original


def voiced(qty_unit: str, rng: random.Random) -> str:
    """口播数量形态（用于 ASR 语料的“说了什么”一侧；gold span 用加噪后原样）。"""
    m = re.match(r"^(\d+)(片|粒|袋|支|瓶|贴|丸)$", qty_unit)
    if m and rng.random() < 0.5 and m.group(1) in _CN_NUM:
        return _CN_NUM[m.group(1)] + m.group(2)
    return qty_unit


# ================================================================ 噪声 v2(目标 CER 编辑预算;2026-10-08 round5 α/C 终案)
#
# 与 legacy 的关系:legacy 函数原样保留(训练机兼容);v2 由构建器主路径消费。
# 常量镜像 policy.json(.github/config/distill/policy.json 为单一事实源):
# - extract 侧运行期不依赖 policy 文件(训练机副本无此布局)→ 常量在此 + 双侧断言:
#   ①tests/test_noise_policy_sync.py(CI 零依赖断言两处相等)
#   ②builder main 启动时若找到 policy.json 则再断一次(fail-closed)。

NOISE_VERSION = "2.1"
BAND_CER = {"clean": 0.0, "light": 0.02, "medium": 0.05, "heavy": 0.10, "extreme": 0.18}
# 与 policy.json noise.trainMix 同口径(分数,非百分数——交叉断言逐值相等)
DEFAULT_TRAIN_MIX = {"clean": 0.15, "light": 0.30, "medium": 0.30, "heavy": 0.17, "extreme": 0.08}

# ASR 族份额(音近为主:同音表 + 增删字;数字风格由 asr_number_style 前置处理)
ASR_BAND_SHARES = {
    "light": {"confusion": 0.75, "delete": 0.25},
    "medium": {"confusion": 0.70, "delete": 0.15, "insert": 0.15},
    "heavy": {"confusion": 0.65, "delete": 0.20, "insert": 0.15},
    "extreme": {"confusion": 0.60, "delete": 0.25, "insert": 0.15},
}

_TABLES = None


def _confusion_tables():
    global _TABLES
    if _TABLES is None:
        try:
            from extract.confusion import ConfusionTables  # CI 布局
        except ImportError:
            from confusion import ConfusionTables  # 训练机平铺布局
        _TABLES = ConfusionTables.load()
    return _TABLES


class _PinyinTierTables:
    """ASR 侧表视图:只暴露同音两层(音近错误主族;形近层留给 OCR 侧)。"""

    def __init__(self, tables):
        self._tables = tables

    def mirrors_for(self, ch):
        return self._tables.mirrors_for(ch, tiers=("pinyin_same_tone", "pinyin_diff_tone"))


def confusion_tables_sha256():
    """入仓两表合哈希(manifest provenance;加载失败返 None 不阻断)。"""
    try:
        return _confusion_tables().tables_sha256()
    except Exception:  # noqa: BLE001 - 表缺失属环境问题,由构建端其它断言兜
        return None


def new_noise_ctx(rng: random.Random, *, mode: str = "ocr", mix: dict | None = None) -> dict:
    """样本级噪声上下文:抽带位(混比)+表+计数槽;随样本落 noise 元数据。"""
    weights = dict(mix or DEFAULT_TRAIN_MIX)
    bands = list(weights)
    band = rng.choices(bands, weights=[weights[b] for b in bands])[0]
    tables = _confusion_tables()
    return {"version": NOISE_VERSION, "mode": mode, "band": band,
            "cer_target": BAND_CER[band],
            "tables": _PinyinTierTables(tables) if mode == "asr" else tables,
            "span_total": 0, "span_damaged": 0, "ops": {}}


def noise_ctx_summary(ctx: dict) -> dict:
    """样本 noise 元数据(不携带 tables 对象)。"""
    cer_n = ctx.get("cer_n") or 0
    return {"version": ctx["version"], "mode": ctx["mode"], "band": ctx["band"],
            "cer_target": ctx["cer_target"],
            "cer_mean": round(ctx.get("cer_sum", 0.0) / cer_n, 4) if cer_n else 0.0,
            "spans": ctx["span_total"], "spans_damaged": ctx["span_damaged"],
            "ops": dict(sorted(ctx["ops"].items()))}


def ocr_noise_segment_v2(seg: str, rng: random.Random, *, band: str,
                         tables=None) -> tuple[str, dict]:
    """OCR 段级 v2:调度器驱动(族份额见 noise_scheduler.BAND_SHARES)。"""
    try:
        from extract.noise_scheduler import noisify_segment
    except ImportError:
        from noise_scheduler import noisify_segment
    clean = sanitize_hard(seg)
    if not clean or band == "clean":
        return (clean or seg), {"band": band, "cer_target": BAND_CER.get(band, 0.0),
                                "cer_measured": 0.0, "families": [], "ops": {},
                                "damaged": False}
    noisy, meta = noisify_segment(clean, band=band, cer_target=BAND_CER[band],
                                  rng=rng, tables=tables or _confusion_tables())
    noisy = sanitize_hard(noisy) or clean
    meta["damaged"] = noisy != clean
    return noisy, meta


def asr_noise_segment_v2(seg: str, rng: random.Random, *, band: str,
                         tables=None) -> tuple[str, dict]:
    """ASR 段级 v2:数字风格前置 + 音近/增删字族(无标点输出)。"""
    try:
        from extract.noise_scheduler import noisify_segment
    except ImportError:
        from noise_scheduler import noisify_segment
    clean = sanitize_hard(seg)
    if not clean or band == "clean":
        return (clean or seg), {"band": band, "cer_target": BAND_CER.get(band, 0.0),
                                "cer_measured": 0.0, "families": [], "ops": {},
                                "damaged": False}
    styled = asr_number_style(clean, rng)
    noisy, meta = noisify_segment(styled, band=band, cer_target=BAND_CER[band],
                                  rng=rng, tables=tables or _PinyinTierTables(_confusion_tables()),
                                  shares=ASR_BAND_SHARES[band])
    noisy = noisy.replace("。", "").replace("，", " ").replace(",", " ")
    noisy = sanitize_hard(noisy) or clean
    meta["damaged"] = noisy != clean  # 与 clean 比(数字风格也是伤害)
    return noisy, meta
