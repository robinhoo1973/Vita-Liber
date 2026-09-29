"""SU-M15-ENTLINK 评测闸(计划文档 §10 执行体):数据基线对照臂 + 模型五层闸。

输出:
- 逐带×域指标报告(JSON):recall@1 / recall@10 / top3_hit / 硬负例泄漏 /
  接受数 / 拒识数;基线臂另写 baselines/<dataVersion>.json 永久基线。
- verdict JSON:pass/fail + 逐层判定;exit 0=绿, 2=红(阻断 publish), 1=运行错误。

纪律(评测席四轮评审):
- 拒识率只观测不设及格线(防召回倒逼误链);
- 防假绿 tripwire:每带×域接受数 < 下限 → 红;全拒识 → 红;
- 硬零类:错链(rank1 非金标)/非词表(候选不在目录)/硬负例建行/BR-006 违规 = 0;
- 模型指标只在部署件语义上成立:P1 基线臂无模型,五层闸跳过并标注 n/a。
"""
from __future__ import annotations

import json
from collections import defaultdict
from dataclasses import dataclass, field
from pathlib import Path

from entlink.catalog import Catalog
from entlink.recall import RecallEngine


@dataclass
class GateConfig:
    recall_at1_min: float = 0.85
    precision_min: float = 0.98
    top3_hit_min: float = 0.90
    min_accepts: int = 50          # 每带×域接受数下限(tripwire;小集评测用 --min-accepts 调低)
    top_k: int = 10
    baseline_only: bool = True     # P1: 仅基线臂;模型候选出现时才跑五层


@dataclass
class BandMetrics:
    samples: int = 0
    recall_at1: int = 0
    recall_at10: int = 0
    top3_hit: int = 0
    hard_neg_leak: int = 0         # 任一硬负例进入 top-k 的样本数
    wrong_link: int = 0            # rank1 存在且非金标(错链)
    off_catalog: int = 0           # rank1 候选不在目录(非词表替换)
    br006_violations: int = 0      # 候选词条命中措辞负清单
    rejects: int = 0               # 零候选(拒识,只观测)
    rank1_exists: int = 0

    def to_dict(self) -> dict:
        total = max(self.samples, 1)
        return {
            "samples": self.samples,
            "recall_at1": round(self.recall_at1 / total, 4),
            "recall_at10": round(self.recall_at10 / total, 4),
            "top3_hit": round(self.top3_hit / total, 4),
            "hard_neg_leak": self.hard_neg_leak,
            "wrong_link": self.wrong_link,
            "off_catalog": self.off_catalog,
            "br006_violations": self.br006_violations,
            "rejects": self.rejects,
            "accepts": self.recall_at1,  # 基线臂:rank1 命中即接受(供 tripwire)
        }


@dataclass
class GateResult:
    verdict: str = "pass"
    metrics: dict = field(default_factory=dict)
    layers: dict = field(default_factory=dict)
    index_report: dict = field(default_factory=dict)
    failures: list[str] = field(default_factory=list)


def _run_baseline_arm(engine: RecallEngine, eval_lines: list[dict], config: GateConfig,
                      wording_guard=None) -> dict[str, dict[str, BandMetrics]]:
    """数据-only 基线臂:确定性召回在冻结评测集上的逐带×域指标。"""
    per: dict[str, dict[str, BandMetrics]] = defaultdict(lambda: defaultdict(BandMetrics))
    for line in eval_lines:
        domain, band = line["domain"], line["band"]
        hits = engine.search(line["query"], domain=domain, top_k=config.top_k)
        gold = line["gold"]["entity_id"]
        negative_ids = {n["entity_id"] for n in line.get("negatives", [])}
        m = per[domain][band]
        m.samples += 1
        ranked_ids = [h.entity_id for h in hits]
        if not ranked_ids:
            m.rejects += 1
            continue
        m.rank1_exists += 1
        if ranked_ids[0] == gold:
            m.recall_at1 += 1
        else:
            m.wrong_link += 1
        if gold in ranked_ids:
            m.recall_at10 += 1
        if gold in ranked_ids[:3]:
            m.top3_hit += 1
        if negative_ids & set(ranked_ids):
            m.hard_neg_leak += 1
        # §10 硬零类「BR-006 违规=0」在基线臂同样执法:目录新数据带进措辞
        # 违禁词条(如别名含「确诊」)时 rank1 命中即计数并判红——此前只在
        # 模型五层闸筛查,基线臂的 br006_violations 恒 0(历史教训)。
        if wording_guard is not None and hits[0].matched_term and \
                wording_guard.violation(hits[0].matched_term):
            m.br006_violations += 1
    return {d: {b: v for b, v in bands.items()} for d, bands in per.items()}


def run_gate(*, engine: RecallEngine, eval_lines: list[dict], config: GateConfig,
             wording_guard=None, model_candidates: dict[str, list[dict]] | None = None,
             known_entity_ids: set[str] | None = None) -> GateResult:
    result = GateResult()
    result.index_report = engine.describe()
    metrics = _run_baseline_arm(engine, eval_lines, config, wording_guard=wording_guard)
    result.metrics = {d: {b: v.to_dict() for b, v in bands.items()} for d, bands in metrics.items()}

    # 基线臂判定:接受数 tripwire + 全拒识 tripwire(防假绿;召回不作为 P1 硬闸)
    for domain, bands in sorted(metrics.items()):
        for band, m in sorted(bands.items()):
            key = f"{domain}:{band}"
            if m.samples == 0:
                result.failures.append(f"{key} 零样本——评测集构造缺陷")
                continue
            if m.recall_at1 < config.min_accepts:
                result.failures.append(
                    f"{key} 接受数 {m.recall_at1} < 下限 {config.min_accepts}(tripwire:每带×域接受数下限)")
            if m.rejects == m.samples and m.recall_at1 == 0:
                result.failures.append(f"{key} 全拒识(拒识率 100% 且 R@1=0)——判红")
            if m.br006_violations > 0:
                result.failures.append(f"{key} 基线 rank1 措辞违禁 {m.br006_violations} 例(§10 硬零类 BR-006 违规=0)")

    # 模型五层闸(部署件候选;P1 无模型 → 跳过并标注)
    if model_candidates is not None:
        _run_model_layers(result, eval_lines, model_candidates, config, wording_guard,
                          known_entity_ids=known_entity_ids)
    else:
        result.layers["model"] = "n/a(基线臂:无模型候选,五层闸随 P3 部署件启用)"

    result.verdict = "fail" if result.failures else "pass"
    return result


def _run_model_layers(result: GateResult, eval_lines: list[dict], candidates: dict[str, list[dict]],
                      config: GateConfig, wording_guard, known_entity_ids: set[str] | None = None) -> None:
    """模型候选五层闸:硬零类 / 接受精度 / 噪声带分层召回 / 提示质量 / 校准。

    candidates: sample_id -> [{entity_id, score, matched_term}](按 rank 排序)。
    校准层(P5)依赖置信带约定,当前标注 n/a。
    """
    hard_violations = []
    per_band: dict[str, BandMetrics] = defaultdict(BandMetrics)
    for line in eval_lines:
        band = line["band"]
        cands = candidates.get(line["id"], [])
        m = per_band[band]
        m.samples += 1
        if not cands:
            m.rejects += 1
            continue
        m.rank1_exists += 1
        top = cands[0]
        gold = line["gold"]["entity_id"]
        if top["entity_id"] == gold:
            m.recall_at1 += 1
        else:
            m.wrong_link += 1
            hard_violations.append(f"{line['id']} 错链: rank1={top['entity_id']} gold={gold}")
        # §10 硬零类补全:非词表替换(候选不在目录)与硬负例建行同样一票否决——
        # 旧实现只有错链/BR-006 进硬零类,这两类漏计数(off_catalog 曾是死字段)。
        if known_entity_ids is not None and top["entity_id"] not in known_entity_ids:
            m.off_catalog += 1
            hard_violations.append(f"{line['id']} 非词表替换: rank1={top['entity_id']}")
        negative_ids = {n["entity_id"] for n in line.get("negatives", [])}
        if top["entity_id"] in negative_ids:
            m.hard_neg_leak += 1
            hard_violations.append(f"{line['id']} 硬负例建行: rank1={top['entity_id']}")
        if wording_guard is not None and top.get("matched_term"):
            if wording_guard.violation(top["matched_term"]):
                m.br006_violations += 1
                hard_violations.append(f"{line['id']} BR-006 违规词条: {top['matched_term']}")
        ranked = [c["entity_id"] for c in cands]
        if gold in ranked:
            m.recall_at10 += 1
        if gold in ranked[:3]:
            m.top3_hit += 1
    total = sum(m.samples for m in per_band.values()) or 1
    precision = sum(m.recall_at1 for m in per_band.values()) / max(sum(m.rank1_exists for m in per_band.values()), 1)
    layers = {
        "L1_hard_zero": "fail" if hard_violations else "pass",
        "L2_acceptance_precision": f"{precision:.4f} (≥{config.precision_min})",
        "L3_recall_at1_per_band": {},
        "L4_top3_hit": f"{sum(m.top3_hit for m in per_band.values()) / total:.4f} (≥{config.top3_hit_min})",
        "L5_calibration": "n/a(置信带约定随 P5)",
    }
    for band, m in sorted(per_band.items()):
        rate = m.recall_at1 / max(m.samples, 1)
        layers["L3_recall_at1_per_band"][band] = f"{rate:.4f} (≥{config.recall_at1_min})"
        if rate < config.recall_at1_min:
            result.failures.append(f"L3 {band} 带 recall@1 {rate:.4f} < {config.recall_at1_min}")
    if hard_violations:
        result.failures.append(f"L1 硬零类 {len(hard_violations)} 例(前 3): {hard_violations[:3]}")
    if precision < config.precision_min:
        result.failures.append(f"L2 接受精度 {precision:.4f} < {config.precision_min}")
    result.layers["model"] = layers


def write_verdict(path: Path, result: GateResult, data_version: str) -> None:
    payload = {"dataVersion": data_version, "verdict": result.verdict,
               "failures": result.failures, "layers": result.layers,
               "metrics": result.metrics, "index_report": result.index_report}
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def write_baseline(path: Path, result: GateResult, data_version: str) -> None:
    """P1 对照臂落盘:每 dataVersion 一行 JSON(计划文档 §10)。"""
    payload = {"dataVersion": data_version, "baseline_metrics": result.metrics,
               "index_report": result.index_report}
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
