"""查询与目录词条进入确定性召回前必须经过的同一折叠(folding)。

边界纪律(计划文档 §6 S1):
- 只做**无损**归一:NFKC 宽度收敛、小写、标点/空白剥离。
- 繁体**不**在此层转简体——TW/HK 目录行与简体查询的繁简差异由
  区域变体行(region 行恒胜通用行)与噪声评测带覆盖;折叠层擅自
  转繁简会制造「折叠前后不等价」的假匹配。
- 数字与字母保留原样(剂量/规格中的 0.5g、10mg 不可折叠)。
"""
from __future__ import annotations

import re
import unicodedata

# 标点/符号剥离:Unicode 类别 P*(标点)与 S*(符号,含 〇/々/〆 类 CJK 符号)。
# 医疗词条中的「-」「/」有语义(复方制剂、浓度),故 **不** 剥离 ASCII
# 连字符与斜杠——只剥离类别 P 中的 CJK 标点与全角形态;统一由 NFKC 收敛。
_STRIP_RE = re.compile(r"[　-〿＀-／：-＠［-｀｛-･﻿·•…—―‖‘’“”、。《》〈〉【】（）「」～｟〔〕·]")


def fold(text: str) -> str:
    """折叠一段文本:NFKC → 小写 → 剥离 CJK/全角标点与空白。

    NFKC 负责全角→半角、兼容字符收敛;重复调用幂等。
    """
    if not text:
        return ""
    text = unicodedata.normalize("NFKC", text)
    text = text.lower()
    text = _STRIP_RE.sub("", text)
    return re.sub(r"\s+", "", text)


def folded_set(text: str) -> str:
    """fold() 的显式别名,用于语料 manifest 里记录折叠版本语义。"""
    return fold(text)
