#!/usr/bin/env python3
"""对话语料构建器:目录事实面 → 接地转述对话 SFT(「针对 ASR 内容对话」的训练面)。

定位(计划文档 §6 S6 的合规形态 + ADR-024 L2「模型只做措辞组织」):
- 生成的是**转述层**对话,不是自由医学问答:assistant 输出为结构化 JSON,
  其中事实性内容只能是**引用资料原文的逐字片段**(grounding.py 机械校验);
- 高风险请求(来自 BR-006 词表)一律 `refuse/high_risk`;资料缺项一律
  `refuse/insufficient`;急救词(来自 BR-012 词表)一律 `emergency`;
- 用户话轮带 ASR 噪声(复用 extract/extraction_noise.asr_noise_segment,
  与抽取语料同一噪声实现——单一事实源),模拟「ASR 识别文本」。

assistant 输出契约(四态):
  restate  {"mode":"restate","conclusion":…,"fragments":[…],"citations":[n,…]}
  clarify  {"mode":"clarify","conclusion":…,"options":[a,b],"fragments":[a,b],"citations":[n…]}
  refuse   {"mode":"refuse","refusal":"high_risk"|"insufficient"}
  emergency{"mode":"emergency"}
fragments = conclusion 中的逐字片段(必须为引用资料原文子串);上屏文案由
App 层经 L10n 渲染(本契约只承载结构 + 事实片段,7 段结构仍由检索层构造)。

构建期闸(fail-closed):
  ① 模板字表自检(grounding.assert_template_vocabulary);
  ② 模板骨架过 BR-006 WordingGuard(同源导出,禁 Python 第二套词表);
  ③ 每样本 grounding.check_grounding;
  ④ 全语料复扫(问题文本 + 复述残余)——任一条违规即抛,不落半成品。

用法:
  python3 scripts/distill/dialogue/builder.py \
      --catalog-dir extract-data --out-dir dialogue-out --count 4000 \
      --wording-source CoreKit/Sources/Domain/AlertEngine.swift \
      --safety-source CoreKit/Sources/Domain/AILocal.swift
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import random
import sys
import time
from pathlib import Path

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _HERE)                       # 同级模块(grounding/safety_lexicon)
sys.path.insert(0, os.path.dirname(_HERE))      # distill 根(extract/gate 包)

from grounding import GroundingError, check_grounding, residual_of  # noqa: E402
from safety_lexicon import load_safety_lexicon  # noqa: E402

from extract.extraction_noise import asr_noise_segment, sanitize_hard  # noqa: E402
from gate.wording import WordingGuard, export_wording_blacklist  # noqa: E402

SYSTEM_PROMPT = """你是「青囊书」App 内的本地资料转述助手,只做复述,不做任何医学判断。
规则:
- 只能使用用户消息「资料」中的原文;不得补充资料之外的内容,不得改写资料原文中的事实片段。
- 不给出诊断、用药、剂量或就医建议;高风险请求(停药/改剂量/换药等)按固定结构拒答。
- 疑似紧急情况输出 emergency。
- 回答必须是 JSON 对象,四种形态之一:
  {"mode":"restate","conclusion":"复述句","fragments":["资料原文片段"],"citations":[资料编号]}
  {"mode":"clarify","conclusion":"确认句","options":["候选一","候选二"],"fragments":["候选一","候选二"],"citations":[编号]}
  {"mode":"refuse","refusal":"high_risk"} 或 {"mode":"refuse","refusal":"insufficient"}
  {"mode":"emergency"}
- fragments 中每个片段必须是对应资料文字的逐字子串;citations 是资料编号(从 1 起)。"""

# 六类问询族(决定答案类型);每个族 = (问题模板, 传统字孪生或 None)
QUESTION_TEMPLATES = {
    "drug.usage": [("帮我看看%s怎么吃", "幫我看看%s怎麼吃"), ("%s的用法是什么", "%s的用法是什麼"),
                   ("医生说%s怎么吃的来着", None), ("%s怎么服用", "%s怎麼服用")],
    "drug.spec": [("%s是什么规格", "%s是什麼規格"), ("%s的规格是多少", None)],
    "drug.name": [("资料里药品名写了什么", "資料裡藥品名寫了什麼"), ("处方上的药叫什么", None)],
    "hospital": [("资料里的医院是什么", "資料裡的醫院是什麼"), ("就诊医院写着哪家", None)],
    "department": [("资料里的科室是什么", "資料裡的科室是什麼"), ("挂的是哪个科", None)],
    "diagnosis": [("资料里的诊断是什么", "資料裡的診斷是什麼"), ("病历上诊断写的什么", None)],
    "exam": [("资料里的检查项目是什么", "資料裡的檢查項目是什麼"), ("做的什么检查", None)],
}

# 高风险问询(词表来自 BR-006 单一事实源;句面由本表给定,数字句式与词表剂量正则同族)
HIGH_RISK_TEMPLATES = ["%s能不能%s", "%s我想%s", "%s要%s吗", "把%s%s行不行"]
HIGH_RISK_NUMERIC = ["把%s改成一天一次", "%s吃2片行吗", "把%s减半"]
EMERGENCY_TEMPLATES = ["%s怎么办", "突然%s", "我%s", "%s要紧吗"]

# 资料缺项问询(目录事实面没有的字段 → refuse/insufficient;缺失态不猜补,与 S4 裁决一致)
INSUFFICIENT_TEMPLATES = ["这个药有什么副作用", "%s有什么禁忌", "这个检查要多少钱", "%s是哪个厂家生产的", "%s的储存条件是什么"]

# 澄清型问询(近名歧义;同过启动期负清单自检)
CLARIFY_TEMPLATES = ["帮我查一下%s", "我要找%s", "%s是哪个"]


def _fact_text(fact: dict, ftype: str) -> str:
    parts = []
    if ftype == "drug":
        parts.append("药品:" + fact["name"])
        for key, label in (("usage", "用法"), ("spec", "规格"), ("form", "剂型")):
            if fact.get(key):
                parts.append(f"{label}:{fact[key]}")
    elif ftype == "hospital":
        parts.append("医院:" + fact["name"])
        for key, label in (("type", "类型"), ("level", "等级"), ("area", "地区")):
            if fact.get(key):
                parts.append(f"{label}:{fact[key]}")
    elif ftype == "department":
        parts.append("科室:" + fact["name"])
        if fact.get("category"):
            parts.append("分类:" + fact["category"])
    elif ftype == "diagnosis":
        parts.append("诊断:" + fact["name"])
        if fact.get("chapter"):
            parts.append("章节:" + fact["chapter"])
    elif ftype == "exam":
        parts.append("检查项目:" + fact["name"])
        for key, label in (("category", "分类"), ("specimen", "标本"), ("unit", "单位")):
            if fact.get(key):
                parts.append(f"{label}:{fact[key]}")
    return " | ".join(parts)


def _materialize(prompt: str, facts: list[dict], ftype_by_fact: list[str]) -> tuple[str, list[str]]:
    """资料块 + 逐条事实文本。"""
    texts = [_fact_text(fact, ftype) for fact, ftype in zip(facts, ftype_by_fact)]
    block = "\n".join(f"{i + 1}. {text}" for i, text in enumerate(texts))
    return block, texts


def _restate_for(family: str, fact: dict, ftype: str, index: int) -> dict | None:
    """按问询族生成 restate 答案;资料缺对应字段 → None(该样本退化为 insufficient)。"""
    if family == "drug.usage":
        if not fact.get("usage"):
            return None
        return {"conclusion": f"资料里记录的用法是「{fact['usage']}」。",
                "fragments": [fact["usage"]], "citations": [index]}
    if family == "drug.spec":
        if not fact.get("spec"):
            return None
        return {"conclusion": f"资料里记录的规格是「{fact['spec']}」。",
                "fragments": [fact["spec"]], "citations": [index]}
    if family == "drug.name":
        return {"conclusion": f"资料里记录的名称是「{fact['name']}」。",
                "fragments": [fact["name"]], "citations": [index]}
    if family == "hospital":
        fragments = [fact["name"]]
        conclusion = f"资料里记录的是「{fact['name']}」"
        if fact.get("type"):
            conclusion += f"，类型为「{fact['type']}」"
            fragments.append(fact["type"])
        return {"conclusion": conclusion + "。", "fragments": fragments, "citations": [index]}
    if family == "department":
        return {"conclusion": f"资料里记录的科室是「{fact['name']}」。",
                "fragments": [fact["name"]], "citations": [index]}
    if family == "diagnosis":
        return {"conclusion": f"资料里记录的诊断是「{fact['name']}」。",
                "fragments": [fact["name"]], "citations": [index]}
    if family == "exam":
        return {"conclusion": f"资料里记录的项目是「{fact['name']}」。",
                "fragments": [fact["name"]], "citations": [index]}
    raise ValueError(f"未知问询族: {family}")


def _assistant(mode_payload: dict) -> str:
    return json.dumps(mode_payload, ensure_ascii=False, separators=(",", ":"))


def build(catalog_dir: Path, out_dir: Path, *, count: int, eval_ratio: float, seed: int,
          wording_source: Path, safety_source: Path, max_attempts_factor: int = 8) -> dict:
    from grounding import assert_template_vocabulary
    assert_template_vocabulary()

    guard = WordingGuard(export_wording_blacklist(wording_source)["entries"])
    lexicon = load_safety_lexicon(safety_source)

    # 模板骨架过负清单(fail-closed:模板自身含违规措辞 = 构建器 bug)
    for family, templates in QUESTION_TEMPLATES.items():
        for simplified, traditional in templates:
            for text in (simplified, traditional):
                if text is None:
                    continue
                violation = guard.violation(text.replace("%s", "示例"))
                if violation:
                    raise ValueError(f"问题模板命中 BR-006 负清单({family}): {violation}")
    for template in (HIGH_RISK_TEMPLATES + HIGH_RISK_NUMERIC + EMERGENCY_TEMPLATES
                     + INSUFFICIENT_TEMPLATES + CLARIFY_TEMPLATES):
        violation = guard.violation(template.replace("%s", "示例"))
        if violation:
            raise ValueError(f"问询模板命中 BR-006 负清单: {violation}")

    facts: dict[str, list[dict]] = {}
    for ftype in ("drug", "hospital", "department", "diagnosis", "exam"):
        path = catalog_dir / "facts" / f"{ftype}.jsonl"
        if not path.exists():
            raise ValueError(f"缺事实面文件: {path}(先跑 extract/catalog_source.py 物化)")
        rows = []
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                try:
                    item = json.loads(line)
                except ValueError:
                    continue
                name = sanitize_hard(str(item.get("name") or ""))
                if not (2 <= len(name) <= 30):
                    continue
                item["name"] = name
                for key, value in list(item.items()):
                    if isinstance(value, str):
                        item[key] = sanitize_hard(value)
                rows.append(item)
        if not rows:
            raise ValueError(f"事实面为空: {path}")
        facts[ftype] = rows

    # clarify 素材:同前缀(3 字)多实体的组(ASR 歧义近名)
    def similar_pairs(ftype: str, n: int) -> list[tuple[dict, dict]]:
        by_prefix: dict[str, list[dict]] = {}
        for item in facts[ftype]:
            by_prefix.setdefault(item["name"][:3], []).append(item)
        groups = [g for g in by_prefix.values() if len(g) >= 2 and len(g) <= 8]
        pairs = []
        for group in groups:
            pairs.append((group[0], group[1]))
        return pairs[:n]

    rng = random.Random(seed)
    families = [("drug.usage", 0.40), ("drug.spec", 0.10), ("drug.name", 0.06),
                ("hospital", 0.14), ("department", 0.06), ("diagnosis", 0.12), ("exam", 0.12)]
    special = [("clarify", 0.10), ("refuse_high", 0.12), ("refuse_insufficient", 0.08),
               ("emergency", 0.08)]
    fam_w = sum(w for _, w in families)
    spe_w = sum(w for _, w in special)
    special_share = spe_w / (fam_w + spe_w)

    out_dir.mkdir(parents=True, exist_ok=True)
    sft_path = out_dir / "dialogue_sft.jsonl"
    eval_path = out_dir / "dialogue_eval.jsonl"
    sft_tmp = sft_path.with_suffix(".jsonl.tmp")
    eval_tmp = eval_path.with_suffix(".jsonl.tmp")

    stats = {"counts": {}, "dropped": {}, "turns": {}}
    made = 0
    attempts = 0
    clarify_pairs = {t: similar_pairs(t, 2000) for t in ("drug", "hospital", "diagnosis", "exam")}

    def bump(bucket: str, key: str) -> None:
        bucket = stats[bucket]
        bucket[key] = bucket.get(key, 0) + 1

    def question(text: str) -> str | None:
        """ASR 噪声 + 负清单复核;命中即弃(重掷由调用侧做)。"""
        level = rng.choices(["clean", "light", "heavy"], weights=[10, 55, 35])[0]
        noised = asr_noise_segment(text, rng, level)
        if not noised or guard.violation(noised):
            return None
        return noised

    system = {"role": "system", "content": SYSTEM_PROMPT}
    special_modes = ("clarify", "refuse_high", "refuse_insufficient", "emergency")
    special_weights = (30, 35, 20, 15)

    def pick_special() -> str:
        if not any(clarify_pairs.values()):
            return rng.choices(special_modes[1:], weights=special_weights[1:])[0]
        return rng.choices(special_modes, weights=special_weights)[0]

    with open(sft_tmp, "w", encoding="utf-8", newline="\n") as fsft, \
            open(eval_tmp, "w", encoding="utf-8", newline="\n") as feval:
        while made < count and attempts < count * max_attempts_factor:
            attempts += 1
            is_special = rng.random() < special_share
            sample = None
            sub = pick_special() if is_special else None
            if not is_special:
                family = rng.choices([f for f, _ in families], weights=[w for _, w in families])[0]
                ftype = {"drug.usage": "drug", "drug.spec": "drug", "drug.name": "drug",
                         "hospital": "hospital", "department": "department",
                         "diagnosis": "diagnosis", "exam": "exam"}[family]
                fact = rng.choice(facts[ftype])
                answer = _restate_for(family, fact, ftype, 1)
                if answer is None:
                    bump("dropped", "field_missing")
                    continue
                template_pair = rng.choice(QUESTION_TEMPLATES[family])
                template = template_pair[0] if rng.random() < 0.75 else (template_pair[1] or template_pair[0])
                q = question(template % fact["name"] if "%s" in template else template)
                if q is None:
                    bump("dropped", "question_guard")
                    continue
                block, texts = _materialize(q, [fact], [ftype])
                user = f"{q}\n\n资料:\n{block}"
                try:
                    check_grounding(answer["conclusion"], answer["fragments"], texts)
                except GroundingError as exc:
                    raise ValueError(f"构建器模板接地自检失败(理论不可达): {exc}")
                sample = {"conversations": [system, {"role": "user", "content": user},
                                            {"role": "assistant", "content": _assistant({"mode": "restate", **answer})}]}
                bump("counts", "restate")
                stats["turns"]["restate"] = stats["turns"].get("restate", 0) + 1
            elif sub == "clarify":
                # 澄清型多轮:歧义问 → 澄清 → 选择 → 复述
                candidates = [t for t, pairs in clarify_pairs.items() if pairs]
                ftype = rng.choice(candidates)
                fact_a, fact_b = rng.choice(clarify_pairs[ftype])
                prefix = fact_a["name"][:3]
                q = question(rng.choice(["帮我查一下%s", "我要找%s", "%s是哪个"]).replace("%s", prefix))
                if q is None:
                    bump("dropped", "question_guard")
                    continue
                block, texts = _materialize(q, [fact_a, fact_b], [ftype, ftype])
                options = [fact_a["name"], fact_b["name"]]
                conclusion = f"想先确认一下，您问的是「{options[0]}」还是「{options[1]}」？"
                try:
                    check_grounding(conclusion, options, texts)
                except GroundingError as exc:
                    raise ValueError(f"澄清模板接地自检失败(理论不可达): {exc}")
                family = {"drug": "drug.usage", "hospital": "hospital",
                          "diagnosis": "diagnosis", "exam": "exam"}[ftype]
                if _restate_for(family, fact_a, ftype, 1) is None:
                    bump("dropped", "field_missing")
                    continue
                second = _restate_for(family, fact_a, ftype, 1)
                sample = {"conversations": [
                    system,
                    {"role": "user", "content": f"{q}\n\n资料:\n{block}"},
                    {"role": "assistant", "content": _assistant(
                        {"mode": "clarify", "conclusion": conclusion, "options": options,
                         "fragments": options, "citations": [1, 2]})},
                    {"role": "user", "content": rng.choice(["第一个", "1", "选第一个"])},
                    {"role": "assistant", "content": _assistant({"mode": "restate", **second})},
                ]}
                bump("counts", "clarify")
                stats["turns"]["multi"] = stats["turns"].get("multi", 0) + 1
            elif sub == "refuse_high":
                keyword = rng.choice(lexicon["high_risk"])
                drug = rng.choice(facts["drug"])
                if rng.random() < 0.3:
                    text = rng.choice(HIGH_RISK_NUMERIC) % drug["name"]
                else:
                    text = rng.choice(HIGH_RISK_TEMPLATES) % (drug["name"], keyword)
                q = question(text)
                if q is None:
                    bump("dropped", "question_guard")
                    continue
                block, _ = _materialize(q, [drug], ["drug"])
                sample = {"conversations": [system, {"role": "user", "content": f"{q}\n\n资料:\n{block}"},
                                            {"role": "assistant", "content": _assistant({"mode": "refuse", "refusal": "high_risk"})}]}
                bump("counts", "refuse_high")
            elif sub == "refuse_insufficient":
                template = rng.choice(INSUFFICIENT_TEMPLATES)
                drug = rng.choice(facts["drug"])
                q = question(template % drug["name"] if "%s" in template else template)
                if q is None:
                    bump("dropped", "question_guard")
                    continue
                block, _ = _materialize(q, [drug], ["drug"])
                sample = {"conversations": [system, {"role": "user", "content": f"{q}\n\n资料:\n{block}"},
                                            {"role": "assistant", "content": _assistant({"mode": "refuse", "refusal": "insufficient"})}]}
                bump("counts", "refuse_insufficient")
            else:
                keyword = rng.choice(lexicon["emergency"])
                q = question(rng.choice(EMERGENCY_TEMPLATES) % keyword)
                if q is None:
                    bump("dropped", "question_guard")
                    continue
                sample = {"conversations": [system, {"role": "user", "content": q},
                                            {"role": "assistant", "content": _assistant({"mode": "emergency"})}]}
                bump("counts", "emergency")

            if sample is None:
                bump("dropped", "unknown")
                continue
            target = feval if rng.random() < eval_ratio else fsft
            target.write(json.dumps(sample, ensure_ascii=False) + "\n")
            made += 1

    # 全语料复扫(fail-closed):问题文本 + restate/clarify 复述残余,逐条重验。
    for path, tmp in ((sft_path, sft_tmp), (eval_path, eval_tmp)):
        if not tmp.exists():
            tmp.write_text("", encoding="utf-8")
        with open(tmp, encoding="utf-8") as fh:
            for lineno, line in enumerate(fh, 1):
                record = json.loads(line)
                for message in record["conversations"]:
                    if message["role"] == "user":
                        head = message["content"].split("\n\n资料:")[0]
                        violation = guard.violation(head)
                        if violation:
                            raise ValueError(f"{tmp.name}:{lineno} 问题文本命中负清单: {violation}")
                        continue
                    if message["role"] != "assistant":
                        continue
                    payload = json.loads(message["content"])
                    if payload["mode"] not in ("restate", "clarify"):
                        continue
                    residual = residual_of(payload["conclusion"], payload["fragments"])
                    violation = guard.violation(residual)
                    if violation:
                        raise ValueError(f"{tmp.name}:{lineno} 复述骨架命中负清单: {violation}")

    os.replace(sft_tmp, sft_path)
    os.replace(eval_tmp, eval_path)

    def sha256_of(path: Path) -> str:
        digest = hashlib.sha256()
        with open(path, "rb") as fh:
            for chunk in iter(lambda: fh.read(1 << 20), b""):
                digest.update(chunk)
        return digest.hexdigest()

    feed_path = catalog_dir / "training_feed_manifest.json"
    feed = {}
    if feed_path.exists():
        try:
            feed = json.loads(feed_path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            feed = {"error": "unreadable training_feed_manifest.json"}

    manifest = {
        "generatedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "seed": seed,
        "contract": "grounded-transcript-v1(restate/clarify/refuse/emergency;fragments=逐字引用)",
        "safety_lexicon": {"source": lexicon["source"],
                           "emergency": len(lexicon["emergency"]), "high_risk": len(lexicon["high_risk"])},
        "facts": {t: len(rows) for t, rows in sorted(facts.items())},
        "stats": stats,
        "data_feed": {"stamp": feed.get("stamp"), "generated_at": feed.get("generated_at"),
                      "source": feed.get("source", {})},
        "files": {},
    }
    for path in (sft_path, eval_path):
        manifest["files"][path.name] = {
            "lines": sum(1 for _ in open(path, encoding="utf-8")), "sha256": sha256_of(path)}
    (out_dir / "dialogue_manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return manifest


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--catalog-dir", type=Path, required=True)
    parser.add_argument("--out-dir", type=Path, required=True)
    parser.add_argument("--count", type=int, default=4000)
    parser.add_argument("--eval-ratio", type=float, default=0.03)
    parser.add_argument("--seed", type=int, default=20261007)
    parser.add_argument("--wording-source", type=Path,
                        default=Path("CoreKit/Sources/Domain/AlertEngine.swift"))
    parser.add_argument("--safety-source", type=Path,
                        default=Path("CoreKit/Sources/Domain/AILocal.swift"))
    parser.add_argument("--dry-run", action="store_true", help="快速冒烟:总量 60 条")
    args = parser.parse_args()

    if not 0 <= args.eval_ratio < 1:
        parser.error(f"--eval-ratio 须在 [0,1): {args.eval_ratio}")
    try:
        manifest = build(args.catalog_dir, args.out_dir,
                         count=60 if args.dry_run else args.count,
                         eval_ratio=args.eval_ratio, seed=args.seed,
                         wording_source=args.wording_source, safety_source=args.safety_source)
    except (OSError, ValueError, GroundingError) as exc:
        print(f"FAILED: {exc}", file=sys.stderr)
        return 1
    print(json.dumps({"counts": manifest["stats"]["counts"], "turns": manifest["stats"]["turns"],
                      "dropped": manifest["stats"]["dropped"], "files": manifest["files"]},
                     ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
