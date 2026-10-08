"""混淆表装载(噪声 v2 主源;round5 仲裁席 α 终案:pycorrector 两表为主,stdlib 零依赖)。

设计:
- 表为**入仓静态件**(extract/tables/,Apache-2.0,见 PROVENANCE.md);
- `mirrors_for()` 每字符按层优先(形近 > 同音同调 > 同音异调)取 ≤hub_cap 个镜像,
  码点序确定性——防 hub 爆炸且跨机逐同;
- ASR 模糊音族为自维护常量:声母/韵母/声调替换类(供拼音侧等价键派生)。

纪律(round5 §2.2):表/常量任一变更=语料字节变更=独立 dataVersion 批。
"""
from __future__ import annotations

import hashlib
from pathlib import Path

TABLES_DIR = Path(__file__).resolve().parent / "tables"
DEFAULT_HUB_CAP = 3

# ASR 模糊音族(替换类;权重语义由噪声调度器按带预算决定)
ASR_FUZZY_FAMILIES: dict[str, tuple[tuple[str, ...], ...]] = {
    "initial": (
        ("zh", "z"), ("ch", "c"), ("sh", "s"), ("n", "l"), ("r", "l"),
        ("f", "h"), ("j", "z"), ("q", "c"), ("x", "s"),
    ),
    "final": (
        ("an", "ang"), ("en", "eng"), ("in", "ing"), ("ian", "iang"),
        ("uan", "uang"), ("uen", "ong"),
    ),
    "tone": (("2", "3"), ("1", "4"), ("0", "1"), ("0", "4")),
}


def _read_tsv(path: Path) -> list[list[str]]:
    rows = []
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        rows.append([cell for cell in line.split("\t") if cell])
    return rows


def load_same_stroke(path: Path | None = None) -> dict[str, set[str]]:
    """形近族:同组内两两互镜像(char → 其余成员集合)。"""
    path = path or TABLES_DIR / "same_stroke.txt"
    mirrors: dict[str, set[str]] = {}
    for group in _read_tsv(path):
        members = [ch for cell in group for ch in cell]
        for ch in members:
            mirrors.setdefault(ch, set()).update(m for m in members if m != ch)
    return mirrors


def load_same_pinyin(path: Path | None = None) -> dict[str, dict[str, set[str]]]:
    """同音族:列=首字符 + 同音同调组 + 同音异调组。"""
    path = path or TABLES_DIR / "same_pinyin.txt"
    out: dict[str, dict[str, set[str]]] = {}
    for row in _read_tsv(path):
        if not row:
            continue
        head = row[0][0] if row[0] else ""
        if not head:
            continue
        same_tone = {ch for ch in "".join(row[1:2]) if ch != head}
        diff_tone = {ch for ch in "".join(row[2:3]) if ch != head}
        entry = out.setdefault(head, {"same_tone": set(), "diff_tone": set()})
        entry["same_tone"].update(same_tone)
        entry["diff_tone"].update(diff_tone)
    # 对称化:同音是等价类,但表只按 head 逐行给出——补反向边,保置换双向可达
    # (镜像方向否则取决于该字符是否有自己的行;实测 丙∈甲行但 丙 无行)。
    for head, groups in list(out.items()):
        for tone in ("same_tone", "diff_tone"):
            for mirror in groups[tone]:
                back = out.setdefault(mirror, {"same_tone": set(), "diff_tone": set()})
                back[tone].add(head)
    return out


class ConfusionTables:
    """装载一次、多带复用;`mirrors_for` 确定性(码点序+层优先+hub_cap)。"""

    def __init__(self, stroke: dict[str, set[str]], pinyin: dict[str, dict[str, set[str]]],
                 hub_cap: int = DEFAULT_HUB_CAP):
        self._stroke = stroke
        self._pinyin = pinyin
        self.hub_cap = hub_cap

    @classmethod
    def load(cls, tables_dir: Path | None = None, hub_cap: int = DEFAULT_HUB_CAP) -> "ConfusionTables":
        base = tables_dir or TABLES_DIR
        return cls(load_same_stroke(base / "same_stroke.txt"),
                   load_same_pinyin(base / "same_pinyin.txt"), hub_cap=hub_cap)

    def mirrors_for(self, ch: str) -> tuple[tuple[str, str], ...]:
        """[(镜像字符, 族)];层优先 形近→同音同调→同音异调;每层内码点序;总数≤hub_cap。"""
        tiers: list[tuple[str, set[str]]] = [
            ("stroke", self._stroke.get(ch, set())),
            ("pinyin_same_tone", (self._pinyin.get(ch) or {}).get("same_tone", set())),
            ("pinyin_diff_tone", (self._pinyin.get(ch) or {}).get("diff_tone", set())),
        ]
        out: list[tuple[str, str]] = []
        for family, members in tiers:
            for mirror in sorted(members):
                if len(out) >= self.hub_cap:
                    return tuple(out)
                out.append((mirror, family))
        return tuple(out)

    def coverage(self, text: str) -> float:
        """可编辑覆盖率(含镜像字符位置占全部字符比;验收量之一)。"""
        if not text:
            return 0.0
        editable = sum(1 for ch in text if self.mirrors_for(ch))
        return editable / len(text)

    def tables_sha256(self) -> str:
        h = hashlib.sha256()
        for name in ("same_stroke.txt", "same_pinyin.txt"):
            h.update((TABLES_DIR / name).read_bytes())
        return h.hexdigest()


if __name__ == "__main__":
    tables = ConfusionTables.load()
    print({"stroke_chars": len(tables._stroke), "pinyin_chars": len(tables._pinyin),
           "tables_sha256": tables.tables_sha256()[:16],
           "mirrors_阿": tables.mirrors_for("阿"), "mirrors_莫": tables.mirrors_for("莫")})
