"""转述层接地校验(对话语料构建与评测共用,单一实现)。

契约(ADR-024 L2 形态的机械化版本——「事实断言只来自检索命中 span」):
  assistant 的 restate/clarify 输出 = 连接词骨架 + 若干**逐字片段**。
  校验 = ① 每个片段是引用资料文本的逐字子串;
         ② 片段按序出现在 conclusion 中;
         ③ conclusion 去掉全部片段后的**残余文本**,其字符必须全部落在
            本层连接词字表内(即:模型未在骨架之外断言任何新内容)。

残余字表的纪律:字表 = 全部模板骨架常量 + 固定标点(「」。,?:?!)的字符并集,
由 _CONNECTIVES 集中声明。**新增模板必须走本模块的 add 校验路径**——
builder 在装配期对所有模板跑一遍 residual_check,模板库出现字表外字符即红
(fail-closed:防「新模板把字表偷偷撑大」)。
"""
from __future__ import annotations

import re

# 连接词骨架(全部模板的固定文字;占位符 {0} 由片段填充)。builder 的模板表必须
# 由这些常量拼装,不得自带字面量——残余字表由此派生,单一事实源。
_CONNECTIVES = [
    "资料里记录的用法是",
    "资料里记录的规格是",
    "资料里记录的科室是",
    "资料里记录的诊断是",
    "资料里记录的项目是",
    "资料里记录的名称是",
    "资料里记录的是",
    "类型为",
    "等级是",
    "想先确认一下您问的是还是",
    "具体用药请以医生或药师的意见为准",
    "。",
    "「",
    "」",
    "，",
    "、",
    "?",
    "？",
    " ",
]

# Swift → Python 的正则转译注意:本模块不解析 Swift;模板由本模块定义。
ALLOWED_RESIDUAL_CHARS = frozenset("".join(_CONNECTIVES))


class GroundingError(ValueError):
    """接地契约违例(构建期即红;评测期作 verdict 输入)。"""


def residual_of(conclusion: str, fragments: list[str]) -> str:
    """按序剥离片段,返回残余文本。片段缺失/次序错乱即抛。"""
    cursor = 0
    residual_parts: list[str] = []
    for fragment in fragments:
        if not fragment:
            raise GroundingError("空片段")
        index = conclusion.find(fragment, cursor)
        if index < 0:
            raise GroundingError(f"片段未按序出现在复述句中: {fragment!r}")
        residual_parts.append(conclusion[cursor:index])
        cursor = index + len(fragment)
    residual_parts.append(conclusion[cursor:])
    return "".join(residual_parts)


def check_grounding(conclusion: str, fragments: list[str], fact_texts: list[str]) -> None:
    """全量接地校验;违例抛 GroundingError。"""
    if not fragments:
        raise GroundingError("fragments 为空:复述句必须至少引用一个逐字片段")
    for fragment in fragments:
        if not any(fragment in fact for fact in fact_texts):
            raise GroundingError(f"片段不是引用资料的逐字子串: {fragment!r}")
    residual = residual_of(conclusion, fragments)
    stray = sorted(set(residual) - ALLOWED_RESIDUAL_CHARS)
    if stray:
        raise GroundingError(f"复述句残余含连接词字表外字符(疑似新增断言): {''.join(stray)!r} 残余={residual!r}")


def assert_template_vocabulary() -> None:
    """字表自检:连接词常量不得含空白变体/控制符(防字表悄悄扩宽)。"""
    for text in _CONNECTIVES:
        for ch in text:
            if ch not in ALLOWED_RESIDUAL_CHARS:
                raise GroundingError(f"连接词常量含字表外字符: {ch!r} in {text!r}")


def looks_like_zh(text: str) -> bool:
    return bool(re.search(r"[一-鿿]", text))
