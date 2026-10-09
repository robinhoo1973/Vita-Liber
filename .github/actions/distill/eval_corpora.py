#!/usr/bin/env python3
"""抽取/对话语料评测闸:对**冻结产物**的独立复验(不是生成器内的自检重复)。

为什么要有这一闸(与构建期自检的分工):
- 构建期自检证明「生成本身」守约;本闸证明「落盘并上传的那份」守约——
  两处之间隔着序列化/传输/打包,历史上这一段出过问题(资产误配/截断)。
- 模型五层闸的挂点:未来接入部署件候选时,本闸的 verdict 结构直接承接
  (extraction: span 逐字+必填/覆盖;dialogue: 接地+拒绝行为+措辞)。

复验项(全部机械,零模型):
  extraction: ① manifest sha256 对账;② 每条样本 conversations 形状;
              ③ 每个 span.value 是所引行的逐字子串(check_verbatim 等价);
              ④ 训练/评测切分非空。
  dialogue:   ① manifest sha256 对账;② assistant JSON 四态合法;
              ③ restate/clarify:fragments ⊆ user「资料」行逐字、残余只含连接词
                (grounding.check_grounding 复验——从落盘文本反解,不信任内存);
              ④ 高风险/紧急词表覆盖存在(至少各 ≥1);⑤ 措辞负清单零违规
                (用户问题全文 + 复述残余;资料原文(引用)不扫——与 App 口径一致)。
退出码:0=pass;2=RED(verdict=fail,阻断 publish);1=运行错误。
用法:
  python3 .github/actions/distill/eval_corpora.py \
      --extraction-dir out/extraction --dialogue-dir out/dialogue \
      --wording-source CoreKit/Sources/Domain/AlertEngine.swift \
      --write-verdict verdict-corpora.json
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
from pathlib import Path

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _HERE)

from dialogue.grounding import GroundingError, check_grounding, residual_of  # noqa: E402
from gate.wording import WordingGuard, export_wording_blacklist  # noqa: E402


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _read_jsonl(path: Path):
    with open(path, encoding="utf-8") as fh:
        for lineno, line in enumerate(fh, 1):
            line = line.strip()
            if line:
                yield lineno, json.loads(line)


def check_licenses(manifest: dict, label: str, failures: list[str]) -> None:
    """许可对账(H5 矩阵;round2 质询席 E 裁决):manifest.licenses 非空、来源已登记、义务齐。

    eval-corpora job 有 checkout 可读 policy.json;训练机平铺布局 import 失败→跳过。
    """
    lic = manifest.get("licenses")
    if not isinstance(lic, dict) or not lic:
        failures.append(f"{label} manifest 缺 licenses 块(fail-closed;round2 E)")
        return
    try:
        import policy as _policy
        srcs = _policy.load()["licenses"]["sources"]
    except (ImportError, FileNotFoundError, ValueError):
        return
    for src, entry in lic.items():
        if src not in srcs:
            failures.append(f"{label} 许可来源 {src} 未登记于 policy.licenses.sources")
        elif not (entry.get("attribution") or entry.get("note")):
            failures.append(f"{label} 来源 {src} 缺 attribution/note")


def check_extraction(corpus_path: Path, manifest_path: Path, failures: list[str], stats: dict) -> None:
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    check_licenses(manifest, f"extraction {corpus_path.name}", failures)
    recorded = manifest.get("files", {}).get(corpus_path.name, {}).get("sha256")
    actual = sha256_file(corpus_path)
    if recorded != actual:
        failures.append(f"extraction {corpus_path.name} sha256 对账失败: manifest={recorded} actual={actual}")
    count = 0
    for lineno, record in _read_jsonl(corpus_path):
        count += 1
        messages = record.get("conversations")
        if not isinstance(messages, list) or [m.get("role") for m in messages] != ["system", "user", "assistant"]:
            failures.append(f"extraction {corpus_path.name}:{lineno} conversations 形状非法")
            continue
        try:
            assistant = json.loads(messages[2]["content"])
        except ValueError:
            failures.append(f"extraction {corpus_path.name}:{lineno} assistant 非 JSON")
            continue
        lines = [l.split("] ", 1)[1] if "] " in l else l for l in messages[1]["content"].split("\n")]
        for span in assistant.get("shared", []) + [s for row in assistant.get("rows", []) for s in row]:
            index = span.get("lineIndex")
            if not isinstance(index, int) or not (0 <= index < len(lines)) or span["value"] not in lines[index]:
                failures.append(f"extraction {corpus_path.name}:{lineno} span 逐字违约: {span}")
                break
    stats[corpus_path.name] = count


def _fact_lines_from_user(content: str) -> list[str]:
    if "\n资料:" not in content:
        return []
    block = content.split("\n资料:", 1)[1]
    lines = []
    for line in block.split("\n"):
        line = line.strip()
        if not line:
            continue
        if ". " in line:
            lines.append(line.split(". ", 1)[1])
        else:
            lines.append(line)
    return lines


def check_dialogue(corpus_path: Path, manifest_path: Path, guard: WordingGuard,
                   failures: list[str], stats: dict) -> None:
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    check_licenses(manifest, f"dialogue {corpus_path.name}", failures)
    recorded = manifest.get("files", {}).get(corpus_path.name, {}).get("sha256")
    actual = sha256_file(corpus_path)
    if recorded != actual:
        failures.append(f"dialogue {corpus_path.name} sha256 对账失败: manifest={recorded} actual={actual}")
    modes: dict[str, int] = {}
    count = 0
    for lineno, record in _read_jsonl(corpus_path):
        count += 1
        fact_cache: list[str] = []
        for message in record["conversations"]:
            if message["role"] == "user":
                head = message["content"].split("\n资料:")[0]
                violation = guard.violation(head)
                if violation:
                    failures.append(f"dialogue {corpus_path.name}:{lineno} 问题文本命中负清单: {violation}")
                facts = _fact_lines_from_user(message["content"])
                if facts:
                    fact_cache = facts
                continue
            if message["role"] != "assistant":
                continue
            payload = json.loads(message["content"])
            mode = payload.get("mode")
            modes[mode] = modes.get(mode, 0) + 1
            if mode in ("restate", "clarify"):
                try:
                    check_grounding(payload["conclusion"], payload["fragments"], fact_cache)
                except (GroundingError, KeyError) as exc:
                    failures.append(f"dialogue {corpus_path.name}:{lineno} 接地违约: {exc}")
                residual = residual_of(payload["conclusion"], payload["fragments"])
                violation = guard.violation(residual)
                if violation:
                    failures.append(f"dialogue {corpus_path.name}:{lineno} 复述残余命中负清单: {violation}")
            elif mode == "refuse":
                if payload.get("refusal") not in ("high_risk", "insufficient"):
                    failures.append(f"dialogue {corpus_path.name}:{lineno} refuse 形态非法: {payload}")
            elif mode != "emergency":
                failures.append(f"dialogue {corpus_path.name}:{lineno} 未知 mode: {mode}")
    # count 必须写入 stats[corpus_path.name](与 check_extraction 同形)——空切分判据
    # 查的正是该键;2026-10-08 修:此前只写 .modes 子键,判据恒真 → verdict 恒 fail
    # → publish 永被阻断(首跑 CI 37710699326 实证的「永红闸」)。
    stats[corpus_path.name] = count
    stats[f"{corpus_path.name}.modes"] = modes
    if modes.get("emergency", 0) < 1:
        failures.append(f"dialogue {corpus_path.name} 缺 emergency 样本(安全行为覆盖缺失)")
    if modes.get("refuse", 0) < 1:
        failures.append(f"dialogue {corpus_path.name} 缺 refuse 样本(安全行为覆盖缺失)")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--extraction-dir", type=Path, required=True)
    parser.add_argument("--dialogue-dir", type=Path, required=True)
    parser.add_argument("--wording-source", type=Path,
                        default=Path("CoreKit/Sources/Domain/AlertEngine.swift"))
    parser.add_argument("--write-verdict", type=Path, default=None)
    args = parser.parse_args()

    failures: list[str] = []
    stats: dict = {}
    try:
        guard = WordingGuard(export_wording_blacklist(args.wording_source)["entries"])
        for name in ("extraction_sft.jsonl", "extraction_eval.jsonl"):
            check_extraction(args.extraction_dir / name,
                             args.extraction_dir / "extraction_manifest.json", failures, stats)
        if stats.get("extraction_sft.jsonl", 0) < 1 or stats.get("extraction_eval.jsonl", 0) < 1:
            failures.append("extraction 语料缺少 SFT/评测切分之一(空语料判红)")
        for name in ("dialogue_sft.jsonl", "dialogue_eval.jsonl"):
            check_dialogue(args.dialogue_dir / name,
                           args.dialogue_dir / "dialogue_manifest.json", guard, failures, stats)
        if stats.get("dialogue_sft.jsonl", 0) < 1 or stats.get("dialogue_eval.jsonl", 0) < 1:
            failures.append("dialogue 语料缺少 SFT/评测切分之一(空语料判红)")
    except (OSError, ValueError, KeyError) as exc:
        print(f"FAILED 运行错误: {exc}", file=sys.stderr)
        return 1

    verdict = "fail" if failures else "pass"
    payload = {"verdict": verdict, "failures": failures, "stats": stats}
    if args.write_verdict is not None:
        args.write_verdict.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(payload, ensure_ascii=False, indent=2))
    if verdict == "fail":
        print("RED: 语料复验不通过,阻断 publish", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
