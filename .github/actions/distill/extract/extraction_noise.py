# -*- coding: utf-8 -*-
"""
OCR / ASR 噪声模型（抽取训练语料专用，2026-09-24）

2026-10-07 迁入 CI 簇（scripts/distill/extract/；来源 refactor/tools/training/
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
