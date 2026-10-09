"""smoke 结果结构断言(R0 前批,2026-10-08 委员会裁定;零第三方依赖)。

为什么存在:smoke 此前"绿"只等于脚本退出 0——resume 可跑 0 新步仍绿、
NaN 可原样进 summary、checkpoint 与 sha 从未被对上。测试坏味目录称之为
Unknown Test(执行了代码但无断言=制造虚假安全感);首跑取证批委员会裁定
"smoke 必须以结构化 summary + 显式断言为唯一绿判据,exit code 不构成证据"。

五条结构不变量(拒绝纯步数/耗时断言——随 runner 波动,必然 flaky):
1. summary 必填字段齐备(机器可读消费契约);
2. 新增步数 > 0(steps > started_at_step——"0 新步也绿"即此条反杀);
3. stopped_by ∈ {max_steps, budget};
4. last_loss / grad_norm_max / first_loss 有限(非 NaN/Inf);
5. checkpoint 存在非空,且 {summary 记录, sha256 sidecar, 实测} 三方相等。

调用契约:train_sft_smoke.py 在写 summary 前调用;任一违反抛 ValueError。
负测: tests/test_smoke_assert.py(stdlib,CI tests job 无 torch 亦实跑)。
本文件为 CI 专用件,不在"与训练机逐字节同源"清单内。
"""
from __future__ import annotations

import hashlib
import math
from pathlib import Path

STOP_REASONS = ("max_steps", "budget")
REQUIRED_FIELDS = (
    "label", "steps", "started_at_step", "stopped_by", "last_loss",
    "checkpoint", "checkpoint_sha256", "corpus_sha256",
    "consumed_samples", "first_loss", "grad_norm_max",
)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def verify_smoke_summary(summary: dict, checkpoint: Path) -> None:
    """五条结构不变量逐条断言;违反即 ValueError(调用方转红,绝不静默)。"""
    missing = [k for k in REQUIRED_FIELDS if k not in summary]
    if missing:
        raise ValueError(f"summary 缺字段: {missing}")

    steps, started = int(summary["steps"]), int(summary["started_at_step"])
    if steps <= started:
        raise ValueError(
            f"无新增训练步: steps={steps} <= started_at_step={started}(空跑判绿即此形)")

    if summary["stopped_by"] not in STOP_REASONS:
        raise ValueError(f"stopped_by 非法: {summary['stopped_by']!r} 不在 {STOP_REASONS}")

    for key in ("last_loss", "grad_norm_max", "first_loss"):
        value = summary[key]
        if value is None or not math.isfinite(float(value)):
            raise ValueError(f"{key} 非有限值: {value!r}")

    ckpt = Path(checkpoint)
    if not ckpt.is_file():
        raise ValueError(f"checkpoint 不存在: {ckpt}")
    if ckpt.stat().st_size <= 0:
        raise ValueError(f"checkpoint 为空文件: {ckpt}")
    actual = sha256_file(ckpt)
    sidecar_file = ckpt.with_suffix(ckpt.suffix + ".sha256")
    if not sidecar_file.is_file():
        raise ValueError(f"checkpoint sha256 sidecar 缺失: {sidecar_file}")
    sidecar = sidecar_file.read_text(encoding="utf-8").strip().split()[0]
    recorded = str(summary["checkpoint_sha256"])
    if not (actual == sidecar == recorded):
        raise ValueError(
            f"checkpoint sha 三方不一致: 实测={actual} sidecar={sidecar} summary={recorded}")
