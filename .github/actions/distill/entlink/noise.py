"""三层合成噪声(OCR/ASR 仿真,定种子可复现)。

对应计划文档 §6 S1 与 directory-data-acquisition §5 的增广规格:
  L1 形近字替换(OCR 字形混淆)
  L2 同音字替换(ASR 拼音混淆;依赖 pinyin 层,不可用时该层跳过并计入报告)
  L3 繁简/区域变体替换(靈/灵、臺/台)
另加结构噪声:全半角抖动、标点漂移、粘连(删空格/删字)、重度丢字。

纪律:
- 噪声器版本与逐带种子必须写入评测 manifest(可复现);
- span verbatim 纪律(手册 §10.2)不属于本模块——本模块只产出 query 文本,
  金标准实体 id 由构建器在原词条上记录,加噪不改变 id 对应关系。
"""
from __future__ import annotations

import random
from dataclasses import dataclass, field

from . import pinyin

NOISE_VERSION = "1.0"

# 形近字对(OCR 高频混淆;元组方向对称应用)。来源:目录获取文档 §5 混淆对
# 增补 + 医疗词表实测;扩充须升 NOISE_VERSION 并在评测 manifest 记录。
LOOKALIKE: dict[str, str] = {
    "自": "白", "白": "自", "灵": "林", "林": "灵", "已": "己", "己": "已",
    "大": "太", "太": "大", "日": "目", "目": "日", "人": "入", "入": "人",
    "千": "干", "干": "千", "王": "主", "主": "王", "未": "末", "末": "未",
    "土": "士", "士": "土", "胺": "铵", "铵": "胺", "素": "索", "索": "素",
    "栓": "拴", "拴": "栓", "颗": "棵", "棵": "颗", "片": "斤", "斤": "片",
    "酸": "醋", "醋": "酸", "辛": "幸", "幸": "辛", "苯": "笨", "笨": "苯",
    "胃": "胄", "胄": "胃", "膀": "傍", "傍": "膀",
    "間": "閒", "閒": "間", "鐘": "鍾", "鍾": "鐘",
}

# 繁简/区域变体对(双向)。只列高频医疗词表字符;全量转换不属噪声器职责。
VARIANT: dict[str, str] = {
    "機": "机", "机": "機", "醫": "医", "医": "醫", "藥": "药", "药": "藥",
    "檢": "检", "检": "檢", "驗": "验", "验": "驗", "學": "学", "学": "學",
    "門": "门", "门": "門", "區": "区", "区": "區", "廣": "广", "广": "廣",
    "內": "内", "内": "內", "臺": "台", "台": "臺", "專": "专", "专": "專",
    "號": "号", "号": "號", "銀": "银", "银": "銀", "時": "时", "时": "時",
    "華": "华", "华": "華", "婦": "妇", "妇": "婦", "兒": "儿", "儿": "兒",
    "腦": "脑", "脑": "腦", "腸": "肠", "肠": "腸", "腫": "肿", "肿": "腫",
    "複": "复", "复": "複", "癒": "愈", "愈": "癒", "風": "风", "风": "風",
}

# 全半角抖动用标点(OCR 文本里随机出现的宽度形态)。
_PUNCT_POOL = "，。、;；:：,．·-"


def _band_ops(band: str) -> int:
    """噪声带 → 最少操作数。评测带语义(计划文档 §10)以 ops 数分层。"""
    return {"light": 1, "medium": 2, "heavy": 3, "extreme": 4}[band]


@dataclass
class NoiseReport:
    band: str
    ops_applied: int = 0
    layers_used: list[str] = field(default_factory=list)


class NoiseSimulator:
    """定种子三层噪声。same seed + same text + same band → same output。

    有效混淆表 = 人工种子(LOOKALIKE/VARIANT/同音池)+ 目录数据动态挖掘
    (confusion_miner.MinedConfusions)——挖掘部分随语料 manifest 整体登记,
    评测逐字节复现。形近表无合法数据源(零 PHI 纪律),保持种子表。
    """

    def __init__(self, seed: int, version: str = NOISE_VERSION,
                 mined_variants: dict[str, str] | None = None,
                 mined_homophones: dict[str, tuple[str, ...]] | None = None):
        self.seed = seed
        self.version = version
        self._rng = random.Random(seed)
        self._variant = dict(VARIANT)
        self._homophone = dict(_HOMOPHONE_POOL)
        if mined_variants:
            self._variant.update(mined_variants)
        if mined_homophones:
            for py, chars in mined_homophones.items():
                merged = list(self._homophone.get(py, ()))
                merged.extend(chars)
                self._homophone[py] = tuple(dict.fromkeys(merged))

    def effective_tables(self) -> dict:
        """有效噪声模型(供 manifest 登记;lookalike/variant/homophone 三表)。"""
        return {
            "noise_version": self.version,
            "lookalike": dict(LOOKALIKE),
            "variant": dict(self._variant),
            "homophone": {k: list(v) for k, v in sorted(self._homophone.items())},
        }

    def _replaceable_positions(self, text: str) -> list[int]:
        out = []
        for i, ch in enumerate(text):
            if ch in LOOKALIKE or ch in self._variant:
                out.append(i)
        return out

    def _homophone_positions(self, text: str) -> list[int]:
        if not pinyin.available():
            return []
        out = []
        for i, ch in enumerate(text):
            if "一" <= ch <= "鿿":
                out.append(i)
        return out

    def apply(self, text: str, band: str, *, rng: random.Random | None = None) -> tuple[str, NoiseReport]:
        """对文本施加 band 级噪声。返回 (加噪文本, 报告)。

        rng 参数供语料构建器逐样本派生(主 seed 由构建器统一管理);
        不传则用本实例内部 rng。
        """
        if band not in ("light", "medium", "heavy", "extreme"):
            raise ValueError(f"unknown band: {band}")
        # 每次调用重置实例 RNG:契约「same seed + same text + same band →
        # same output」是逐调用语义;旧实现复用实例流,同一实例连调两次输出
        # 必异(历史教训:与契约/测试矛盾)。显式 rng(语料构建器逐样本派生)
        # 优先,不受重置影响。
        self._rng = random.Random(self.seed)
        r = rng or self._rng
        report = NoiseReport(band=band)
        chars = list(text)
        target_ops = _band_ops(band)
        # 防御性迭代上限(正常路径由「op 必可施加/词串耗尽」终止):
        # 重选语义下 attempts 只计已施加 op,须另设硬上限防病态文本。
        iterations = 0
        hard_cap = target_ops * 32
        while report.ops_applied < target_ops and iterations < hard_cap:
            iterations += 1
            if not chars:
                break
            op = r.randint(0, 3)
            pos = r.randrange(len(chars))
            if op == 0:  # 形近替换(种子表,无合法数据源)
                if chars[pos] in LOOKALIKE:
                    chars[pos] = LOOKALIKE[chars[pos]]
                    report.ops_applied += 1
                    report.layers_used.append("lookalike")
            elif op == 1:  # 同音替换(ASR;种子池+目录挖掘池)
                hom = self._homophone_positions("".join(chars))
                if hom:
                    idx = r.choice(hom)
                    py = pinyin.to_pinyin(chars[idx])
                    if py:
                        replacement = _homophone_swap(chars[idx], py, r, self._homophone)
                        if replacement != chars[idx]:
                            chars[idx] = replacement
                            report.ops_applied += 1
                            report.layers_used.append("homophone")
            elif op == 2:  # 繁简/区域变体(种子表+目录挖掘对)
                if chars[pos] in self._variant:
                    chars[pos] = self._variant[chars[pos]]
                    report.ops_applied += 1
                    report.layers_used.append("variant")
            else:  # 结构:全半角/标点抖动/粘连删字
                choice = r.randint(0, 2)
                if choice == 0:
                    jittered = _width_jitter(chars[pos])
                    # 无效抖动不得计 op 也不耗尝试:CJK 字无全半角形态,换前
                    # 换后同字——旧实现把无操作计作已施加,「带级噪声」实际
                    # 零变异、带级分层失真(与同音层同纪律);不适用即重选。
                    if jittered != chars[pos]:
                        chars[pos] = jittered
                        report.ops_applied += 1
                        report.layers_used.append("width")
                elif choice == 1:
                    chars.insert(pos, r.choice(_PUNCT_POOL))
                    report.ops_applied += 1
                    report.layers_used.append("punct")
                else:
                    del chars[pos]
                    report.ops_applied += 1
                    report.layers_used.append("deletion")
        return "".join(chars), report


def _width_jitter(ch: str) -> str:
    """ASCII 字符与全角形态互转(半角↔全角)。"""
    code = ord(ch)
    if 0x21 <= code <= 0x7E:
        return chr(code + 0xFEE0)
    if 0xFF01 <= code <= 0xFF5E:
        return chr(code - 0xFEE0)
    return ch


def _homophone_swap(char: str, pinyin_str: str, rng: random.Random, pool_map: dict[str, tuple[str, ...]] | None = None) -> str:
    """同音字替换:按同拼音检索替换候选(种子池+目录挖掘池合并表)。

    候选池缺省为模块内置常用同音混淆表(医疗语境精选),由 NoiseSimulator
    注入合并表;若命中则随机选一。
    """
    pool = (pool_map or _HOMOPHONE_POOL).get(pinyin_str, ())
    if not pool:
        return char
    candidates = [c for c in pool if c != char]
    return rng.choice(candidates) if candidates else char


# 常用同音混淆表(按无调全拼索引;ASR 医疗语境高频:
# 磺/黄(huang)、咳/刻/客(ke)、素/速(su)、炎/盐/严(yan)、辛/心(xin)…)
_HOMOPHONE_POOL: dict[str, tuple[str, ...]] = {
    "huang": ("磺", "黄", "簧"),
    "ke": ("科", "咳", "颗", "刻", "客", "克"),
    "su": ("素", "速", "宿"),
    "yan": ("炎", "盐", "严", "眼"),
    "xin": ("辛", "心", "新", "芯"),
    "gan": ("肝", "甘", "干"),
    "shen": ("肾", "神", "慎"),
    "wei": ("胃", "未", "位"),
    "fei": ("肺", "费", "非"),
    "tang": ("糖", "汤", "堂"),
    "yao": ("药", "要", "腰"),
    "zhi": ("脂", "止", "纸"),
    "an": ("安", "氨", "鞍"),
    "lin": ("林", "淋", "临"),
    "nei": ("内", "馁"),
    "min": ("敏", "民", "悯"),
    "bu": ("补", "不", "布"),
    "li": ("粒", "利", "力", "例"),
    "pian": ("片", "偏", "篇"),
    "jiao": ("胶", "交", "焦"),
    "nai": ("钠", "纳", "奈"),
}
