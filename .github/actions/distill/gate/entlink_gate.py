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
    gate_version: str = "2"

    def to_params(self) -> dict:
        """判据落参(verdict.gate;D20——判据不自解释的缺口修复)。"""
        return {"gate_version": self.gate_version, "recall_at1_min": self.recall_at1_min,
                "precision_min": self.precision_min, "top3_hit_min": self.top3_hit_min,
                "min_accepts": self.min_accepts, "top_k": self.top_k}


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
    gate: dict = field(default_factory=dict)


def _emit_item(items: list | None, line: dict, *, arm: str, hit1: bool, rank1,
               in_top10: bool, in_top3: bool) -> None:
    """逐项结果行(McNemar/离线重算用;D20 同批——verdict 只落聚合数的缺口)。

    arm=baseline|model:同一 id 可在两臂各出现一行,离线配对(McNemar exact)。"""
    if items is None:
        return
    items.append({"id": line["id"], "arm": arm, "domain": line["domain"],
                  "band": line["band"], "gold": line["gold"]["entity_id"],
                  "rank1": rank1, "hit1": hit1, "in_top10": in_top10,
                  "in_top3": in_top3})


def _run_baseline_arm(engine: RecallEngine, eval_lines: list[dict], config: GateConfig,
                      wording_guard=None, items: list | None = None) -> dict[str, dict[str, BandMetrics]]:
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
            _emit_item(items, line, arm="baseline", hit1=False, rank1=None,
                       in_top10=False, in_top3=False)
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
        _emit_item(items, line, arm="baseline", hit1=ranked_ids[0] == gold,
                   rank1=ranked_ids[0], in_top10=gold in ranked_ids,
                   in_top3=gold in ranked_ids[:3])
    return {d: {b: v for b, v in bands.items()} for d, bands in per.items()}


def run_gate(*, engine: RecallEngine, eval_lines: list[dict], config: GateConfig,
             wording_guard=None, model_candidates: dict[str, list[dict]] | None = None,
             known_entity_ids: set[str] | None = None, collect_items: list | None = None,
             policy_sha256: str | None = None,
             manifest_sha256: str | None = None) -> GateResult:
    result = GateResult()
    result.index_report = engine.describe()
    result.gate = config.to_params()
    result.gate["policy_sha256"] = policy_sha256
    result.gate["manifest_sha256"] = manifest_sha256
    metrics = _run_baseline_arm(engine, eval_lines, config, wording_guard=wording_guard,
                                items=collect_items)
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
                          known_entity_ids=known_entity_ids, items=collect_items)
    else:
        result.layers["model"] = "n/a(基线臂:无模型候选,五层闸随 P3 部署件启用)"

    result.verdict = "fail" if result.failures else "pass"
    return result


def _run_model_layers(result: GateResult, eval_lines: list[dict], candidates: dict[str, list[dict]],
                      config: GateConfig, wording_guard, known_entity_ids: set[str] | None = None,
                      items: list | None = None) -> None:
    """模型候选五层闸:硬零类 / 接受精度 / 噪声带分层召回 / top3 / 校准。

    candidates: sample_id -> [{entity_id, score, matched_term}](按 rank 排序)。
    2026-10-08 修正(红队/验收席):L2 与 L4 原为**跨带求和聚合**,与「禁跨带
    平均」矛盾——现逐带判定;tripwire 补齐到模型臂(每带×域接受数下限+全拒识
    判红,此前只在基线臂有,防假绿闸恰在需要它的臂缺席)。校准层(P5)标注 n/a。
    """
    hard_violations = []
    per: dict[str, dict[str, BandMetrics]] = defaultdict(lambda: defaultdict(BandMetrics))
    for line in eval_lines:
        domain, band = line["domain"], line["band"]
        cands = candidates.get(line["id"], [])
        m = per[domain][band]
        m.samples += 1
        if not cands:
            m.rejects += 1
            _emit_item(items, line, arm="baseline", hit1=False, rank1=None,
                       in_top10=False, in_top3=False)
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
        _emit_item(items, line, arm="model", hit1=top["entity_id"] == gold,
                   rank1=top["entity_id"], in_top10=gold in ranked,
                   in_top3=gold in ranked[:3])

    # 逐带判定(禁跨带平均):L2 精度与 L4 top3 按带聚合,任一带不达即判红。
    band_acc: dict[str, dict] = defaultdict(
        lambda: {"hit": 0, "rank1_exists": 0, "samples": 0, "top3": 0, "rejects": 0})
    for bands in per.values():
        for band, m in bands.items():
            acc = band_acc[band]
            acc["hit"] += m.recall_at1
            acc["rank1_exists"] += m.rank1_exists
            acc["samples"] += m.samples
            acc["top3"] += m.top3_hit
            acc["rejects"] += m.rejects

    layers = {
        "L1_hard_zero": "fail" if hard_violations else "pass",
        "L2_acceptance_precision": {},
        "L3_recall_at1_per_band": {},
        "L4_top3_hit": {},
        "L5_calibration": "n/a(置信带约定随 P5)",
        "tripwire": {},
    }
    for band, acc in sorted(band_acc.items()):
        precision = acc["hit"] / max(acc["rank1_exists"], 1)
        top3 = acc["top3"] / max(acc["samples"], 1)
        layers["L2_acceptance_precision"][band] = f"{precision:.4f} (≥{config.precision_min})"
        layers["L4_top3_hit"][band] = f"{top3:.4f} (≥{config.top3_hit_min})"
        if precision < config.precision_min:
            result.failures.append(f"L2 {band} 带接受精度 {precision:.4f} < {config.precision_min}")
        if top3 < config.top3_hit_min:
            result.failures.append(f"L4 {band} 带 top3 {top3:.4f} < {config.top3_hit_min}")
    for domain, bands in sorted(per.items()):
        for band, m in sorted(bands.items()):
            key = f"{domain}:{band}"
            rate = m.recall_at1 / max(m.samples, 1)
            layers["L3_recall_at1_per_band"][key] = f"{rate:.4f} (≥{config.recall_at1_min})"
            layers["tripwire"][key] = {"accepts": m.recall_at1, "min": config.min_accepts}
            if rate < config.recall_at1_min:
                result.failures.append(f"L3 {key} 带 recall@1 {rate:.4f} < {config.recall_at1_min}")
            if m.recall_at1 < config.min_accepts:
                result.failures.append(
                    f"{key} 模型臂接受数 {m.recall_at1} < 下限 {config.min_accepts}(tripwire)")
            if m.rejects == m.samples and m.recall_at1 == 0:
                result.failures.append(f"{key} 模型臂全拒识(拒识率 100% 且 R@1=0)——判红")
    if hard_violations:
        result.failures.append(f"L1 硬零类 {len(hard_violations)} 例(前 3): {hard_violations[:3]}")
    result.layers["model"] = layers


def write_verdict(path: Path, result: GateResult, data_version: str) -> None:
    payload = {"dataVersion": data_version, "verdict": result.verdict,
               "failures": result.failures, "layers": result.layers,
               "metrics": result.metrics, "index_report": result.index_report,
               "gate": result.gate}
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def write_baseline(path: Path, result: GateResult, data_version: str) -> None:
    """P1 对照臂落盘:每 dataVersion 一行 JSON(计划文档 §10)。"""
    payload = {"dataVersion": data_version, "baseline_metrics": result.metrics,
               "index_report": result.index_report}
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
