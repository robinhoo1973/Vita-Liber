"""拼音层(lazy 可选依赖):ASR 同音错(「内咳」/「内科」)的召回与负例构造。

pypinyin 是拼音转换的成熟实现(成熟实现优先),作为可选依赖;
不可用时本层**显式降级**(跳过拼音召回/同音负例),其余层不受影响。
基线评测报告必须携带拼音层可用性,评测集 manifest 记录其版本。

依赖钉版见 requirements-distill.txt(S-M6 哈希钉版纪律)。
"""
from __future__ import annotations

import unicodedata

_PY = None
_IMPORT_ERROR: str | None = None


def _lazy():
    global _PY, _IMPORT_ERROR
    if _PY is None and _IMPORT_ERROR is None:
        try:
            import pypinyin  # type: ignore

            _PY = pypinyin
        except ImportError as exc:  # pragma: no cover - 环境相关
            _IMPORT_ERROR = f"pypinyin 不可用,拼音层降级: {exc}"
    return _PY


def available() -> bool:
    return _lazy() is not None


def unavailable_reason() -> str | None:
    _lazy()
    return _IMPORT_ERROR


def to_pinyin(text: str) -> str | None:
    """全拼(去声调,空格分隔多音字候选取首);不可用时返回 None。"""
    py = _lazy()
    if py is None or not text:
        return None
    out = []
    for ch in text:
        if "一" <= ch <= "鿿":
            pron = py.pinyin(ch, style=py.Style.NORMAL, heteronym=False)
            out.append(pron[0][0] if pron else ch)
        elif ch.isascii() and ch.isalpha():
            out.append(ch.lower())
        else:
            out.append(ch)
    return "".join(out)


def to_initials(text: str) -> str | None:
    """首字母串;不可用时返回 None。"""
    py = _lazy()
    if py is None or not text:
        return None
    out = []
    for ch in text:
        if "一" <= ch <= "鿿":
            pron = py.pinyin(ch, style=py.Style.FIRST_LETTER, heteronym=False)
            out.append(pron[0][0] if pron else ch)
        elif ch.isascii() and ch.isalpha():
            out.append(ch.lower())
        else:
            out.append(ch)
    return "".join(out)


def norm_key(pinyin_or_text: str) -> str:
    """拼音/首字母串的折叠:NFKC 后剥离非字母数字。"""
    return "".join(c for c in unicodedata.normalize("NFKC", pinyin_or_text.lower()) if c.isalnum())
