"""BR-006 措辞负清单同源导出:从 App Swift 源码解析,Python 侧零复刻。

单一事实源 = CoreKit/Sources/Domain/AlertEngine.swift 的 WordingBlacklist.patterns
(评测席纪律:禁 Python 复刻第二套词表)。本模块只做**解析与转译**,不做词表维护。
"""
from __future__ import annotations

import json
import re
from pathlib import Path

_PATTERN_LINE = re.compile(r'^\s*\("(.+)",\s*"(.+)"\),?\s*(?://.*)?$')
_BLOCK_START = re.compile(r"static let patterns")


def export_wording_blacklist(alert_engine_path: Path) -> dict:
    """解析 AlertEngine.swift 的 WordingBlacklist.patterns → {pattern, label} 列表。

    解析范围:patterns 数组内 `("pat", "label"),` 行;数组结束(])即停。
    未找到数组或条目数 < 8 即抛(fail-closed:词表漂移不得静默缩水)。
    """
    text = alert_engine_path.read_text(encoding="utf-8")
    lines = text.splitlines()
    start = None
    for i, line in enumerate(lines):
        if _BLOCK_START.search(line):
            start = i
            break
    if start is None:
        raise ValueError(f"{alert_engine_path}: 未找到 WordingBlacklist.patterns")
    entries = []
    unparsed: list[str] = []
    for lineno, line in enumerate(lines[start + 1 :], start=start + 2):
        if line.strip().startswith("]"):
            break
        match = _PATTERN_LINE.match(line)
        if match:
            entries.append({"pattern": match.group(1), "label": match.group(2)})
        elif re.search(r'\("', line) or re.search(r'",\s*"', line):
            # 形似词条行却解析失败(多行字符串/插值/标签元组等漂移形态):
            # 数量闸(<8)只防整体缩水,防不住「个别条目静默丢失」——逐行登记。
            unparsed.append(f"{lineno}: {line.strip()[:80]}")
    if len(entries) < 8:
        raise ValueError(f"WordingBlacklist 条目异常缩减({len(entries)} < 8)——解析漂移,fail-closed")
    if unparsed:
        raise ValueError(f"WordingBlacklist 存在未解析的形似词条行(fail-closed,防单条静默丢失): "
                         + " | ".join(unparsed[:3]))
    return {"source": str(alert_engine_path), "entries": entries}


class WordingGuard:
    """Python 侧执行器:与 Swift NSRegularExpression 语义对齐的 Python 转译。

    注:Swift NSRegularExpression 与 Python re 的 Unicode 语义有细微差异;
    评测用途(生成文本筛查)接受此差异,任何分歧以 App 运行时 Swift 执行
    为准——本闸门只做训练侧前置筛查,不是 App 侧执法。
    """

    def __init__(self, entries: list[dict]):
        compiled = []
        for e in entries:
            try:
                compiled.append((re.compile(e["pattern"]), e["label"], e["pattern"]))
            except re.error as exc:
                raise ValueError(f"BR-006 词表编译失败({e.get('label')}): {exc}——fail-closed") from exc
        self._compiled = compiled
        self._patterns = [(e["pattern"], e["label"]) for e in entries]

    def violation(self, text: str) -> str | None:
        for regex, label, pattern in self._compiled:
            if regex.search(text):
                return f"{label}:{pattern}"
        return None

    def to_json(self, source: str) -> dict:
        return {"source": source, "entries": [{"pattern": p, "label": l} for p, l in self._patterns]}
