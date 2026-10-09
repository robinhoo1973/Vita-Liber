#!/usr/bin/env python3
"""policy.json 唯一读取器(2026-10-08 round5 决议;判据单一事实源)。

纪律(round3 §7.3 + round4 §6):
- 阈值/混比/开关冻结在 `.github/config/distill/policy.json`,运行期不可改;
  workflow 内禁止散抄常量,一律经本读取器(--get/--dump);
- 变更只经 PR(天然审计);每次 run 计算 policy_sha256 入产物(随批落接线);
- 缺字段 fail-closed(不猜默认值);`*_provisional=true` 的字段为首测后待确认值;
- `weights.modelId`(训练目标件)载入时断言 ∈ App `Resources/LLMCatalog/catalog.json`
  条目集——防「训 App 不消费的件」(E2;training-goals.md §3 一致性闸②)。

用法:
  python3 .../policy.py --get gates.extraction.tau
  python3 .../policy.py --dump
  python3 .../policy.py --sha256
"""
from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path

REQUIRED_TOP = ("schema_version", "policy_version", "corpus", "gates", "noise", "publish", "licenses", "training", "weights")


def policy_path() -> Path:
    """锚点上溯定位仓根下的 policy.json(与 fetch_catalog 同法,零硬编码层级)。"""
    here = Path(__file__).resolve().parent
    while here != here.parent:
        candidate = here / ".github" / "config" / "distill" / "policy.json"
        if candidate.is_file():
            return candidate
        here = here.parent
    raise FileNotFoundError("未找到 .github/config/distill/policy.json(锚点上溯失败)")


def catalog_path() -> Path:
    """锚点上溯定位仓根下的 App 部署目录(Resources/LLMCatalog/catalog.json)。

    与 policy_path 同法(E2 一致性闸的前置;缺文件 fail-closed,不静默跳过)。"""
    here = Path(__file__).resolve().parent
    while here != here.parent:
        candidate = here / "Resources" / "LLMCatalog" / "catalog.json"
        if candidate.is_file():
            return candidate
        here = here.parent
    raise FileNotFoundError("未找到 Resources/LLMCatalog/catalog.json(锚点上溯失败;E2 一致性闸前置)")


def load(path: Path | None = None) -> dict:
    path = path or policy_path()
    policy = json.loads(path.read_text(encoding="utf-8"))
    validate(policy)
    return policy


def validate(policy: dict) -> None:
    """fail-closed 校验:必需顶层段齐备;核心判据不得缺失。"""
    missing = [k for k in REQUIRED_TOP if k not in policy]
    if missing:
        raise ValueError(f"policy 缺顶层字段: {missing}")
    n = policy["noise"]
    for key in ("bandTargets", "spanDamageTargets", "trainMix", "version"):
        if key not in n:
            raise ValueError(f"policy.noise 缺 {key}")
    if abs(sum(n["trainMix"].values()) - 1.0) > 1e-6:
        raise ValueError(f"policy.noise.trainMix 占比和≠1: {sum(n['trainMix'].values())}")
    bands = set(n["bandTargets"])
    if bands != set(n["trainMix"]) or bands != set(n["spanDamageTargets"]):
        raise ValueError("bandTargets/spanDamageTargets/trainMix 的带位集合不一致")
    g = policy["gates"]
    if g["entlink"]["hardZero"]["overridable"] is not False:
        raise ValueError("gates.entlink.hardZero.overridable 必须为 false(红线不可运行期放宽)")
    if g["extraction"]["hardZero"]["overridable"] is not False:
        raise ValueError("gates.extraction.hardZero.overridable 必须为 false")
    if policy["weights"]["autoPromote"] is not False and policy["weights"].get("autoPromote") is not True:
        raise ValueError("weights.autoPromote 必须为布尔")
    # E2 一致性闸(2026-10-09):训练目标件必须 ∈ App 部署目录条目集——防
    # 「训一个 App 不消费的件」复发(64M 错位族;training-goals.md §3 闸②)。
    target = policy["weights"].get("modelId")
    if not isinstance(target, str) or not target:
        raise ValueError("weights.modelId 必须为非空字符串(训练目标件 id)")
    catalog = json.loads(catalog_path().read_text(encoding="utf-8"))
    entry_ids = sorted(m.get("id") for m in catalog.get("models", []) if isinstance(m, dict))
    if target not in entry_ids:
        raise ValueError(
            f"weights.modelId {target!r} 不在 App LLMCatalog 条目集 {entry_ids}"
            "(训练目标件必须=部署件;见 training-goals.md §3 一致性闸②)")
    if policy["publish"]["dialogue"]["publish"] and policy["publish"]["dialogue"].get("changeRequires") != "owner":
        raise ValueError("dialogue 发布开关变更须业主裁决(changeRequires=owner)")
    # 许可准入矩阵(H5 合规席):prohibited 类不得进 sources;attribution_required 的来源必带 attribution
    lic = policy["licenses"]
    admission = lic.get("admission") or {}
    if not admission:
        raise ValueError("licenses.admission 缺失/为空(新来源必须落矩阵)")
    for cls, rules in admission.items():
        if rules.get("redistribution") not in ("ok", "prohibited"):
            raise ValueError(f"licenses.admission[{cls}].redistribution 非 ok/prohibited")
        if not isinstance(rules.get("attribution_required"), bool):
            raise ValueError(f"licenses.admission[{cls}].attribution_required 非布尔")
    for src, entry in (lic.get("sources") or {}).items():
        cls = entry.get("class")
        if cls not in admission:
            raise ValueError(f"licenses.sources[{src}] 许可类 {cls} 不在准入矩阵——先登记再采")
        if admission[cls]["redistribution"] == "prohibited":
            raise ValueError(f"licenses.sources[{src}] 许可类 {cls} 禁再分发——不得进入语料面")
        if admission[cls]["attribution_required"] and not entry.get("attribution"):
            raise ValueError(f"licenses.sources[{src}] 缺 attribution(许可类 {cls} 要求顯名)")
    if lic.get("changeRequires") != "owner":
        raise ValueError("licenses 变更须业主裁决(changeRequires=owner)")
    # 训练链(2026-10-09):chunk 预算/maxChunks 形态 fail-closed
    if not isinstance(policy["training"].get("chunkMinutes"), int) or policy["training"]["chunkMinutes"] <= 0:
        raise ValueError("training.chunkMinutes 必须正整数")
    if not isinstance(policy["training"].get("maxChunks"), dict) or not policy["training"]["maxChunks"]:
        raise ValueError("training.maxChunks 必须非空 dict")
    if not isinstance(policy["training"].get("chainEnabled"), bool):
        raise ValueError("training.chainEnabled 必须布尔")


def get(policy: dict, dotted: str):
    node = policy
    for part in dotted.split("."):
        if not isinstance(node, dict) or part not in node:
            raise KeyError(f"policy 无此路径: {dotted}(在 {part} 处中断)")
        node = node[part]
    return node


def sha256_of(path: Path | None = None) -> str:
    path = path or policy_path()
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--get", metavar="DOTTED.KEY")
    parser.add_argument("--get-joined", metavar="DOTTED.KEY",
                        help="dict 值转 k=v,k=v 逗号串(供 workflow CLI 传参,如 entlinkMaxSamples)")
    parser.add_argument("--dump", action="store_true")
    parser.add_argument("--sha256", action="store_true")
    args = parser.parse_args()
    try:
        if args.sha256:
            print(sha256_of())
            return 0
        policy = load()
        if args.get_joined:
            value = get(policy, args.get_joined)
            if not isinstance(value, dict):
                raise ValueError(f"--get-joined 需 dict 值: {args.get_joined} 是 {type(value).__name__}")
            print(",".join(f"{k}={v}" for k, v in value.items()))
        elif args.get:
            value = get(policy, args.get)
            print(json.dumps(value, ensure_ascii=False) if not isinstance(value, (int, float, str, bool)) else value)
        elif args.dump:
            print(json.dumps(policy, ensure_ascii=False, indent=2, sort_keys=True))
        else:
            parser.print_help()
    except (FileNotFoundError, ValueError, KeyError) as exc:
        print(f"::error::policy 读取失败: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
