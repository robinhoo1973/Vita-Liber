"""安全词表同源导出:从 CoreKit/Sources/Domain/AILocal.swift 解析急救/高风险关键词。

与 gate/wording.py 同一纪律(App 侧单一事实源,Python 侧零复刻):
- 急救词表 = `EmergencyKeywordRules.keywords`(BR-012 短路词);
- 高风险词表 = `HighRiskTopicRules.keywords`(BR-006 调药/停药/剂量类拒识词)。
对话语料的**用户提问**从这两张表采样构造句面——训练分布与运行时门槛词表同源,
不存在「CI 造了一批运行时永远命中不了的问法」的漂移。

fail-closed:任一表解析条目数低于下限即抛(防解析器与 Swift 源码形状漂移后
静默取到空表——那样语料会「全绿但零安全样本」)。
"""
from __future__ import annotations

import re
from pathlib import Path

_ARRAY = re.compile(r"static let keywords\s*=\s*\[(.*?)\]", re.S)
_STRING = re.compile(r'"((?:[^"\\]|\\.)*)"')

MIN_EMERGENCY = 12
MIN_HIGH_RISK = 12


def _parse_enum_array(text: str, enum_name: str, minimum: int) -> list[str]:
    start = text.find("enum " + enum_name)
    if start < 0:
        raise ValueError(f"AILocal.swift 未找到 enum {enum_name}")
    match = _ARRAY.search(text, start)
    if match is None:
        raise ValueError(f"{enum_name} 未找到 static let keywords 数组")
    values = [m.group(1) for m in _STRING.finditer(match.group(1))]
    if len(values) < minimum:
        raise ValueError(f"{enum_name}.keywords 条目异常缩减({len(values)} < {minimum})——解析漂移,fail-closed")
    return values


def load_safety_lexicon(alert_source: Path) -> dict:
    text = alert_source.read_text(encoding="utf-8")
    return {
        "source": str(alert_source),
        "emergency": _parse_enum_array(text, "EmergencyKeywordRules", MIN_EMERGENCY),
        "high_risk": _parse_enum_array(text, "HighRiskTopicRules", MIN_HIGH_RISK),
    }
