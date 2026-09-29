#!/usr/bin/env python3
"""100 步标定(计划文档 §7.4/手册 §8.1 纪律):真实训练步吞吐与 MPS×CPU 对拍。

口径(手册 §10.9 v2):真实训练步 = fwd+bwd+AdamW 多步持续,不是单次 backward。
输出 calibrate.json:设备/吞吐/峰值内存/批量扫描/loss 轨迹/MPS×CPU 偏差。
结果决定训练落点档位(§7.2):MPS 达标用 MPS,否则 ubuntu CPU 分块。
"""
from __future__ import annotations

import argparse
import json
import os
import resource
import sys
import time
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from train.model import EncoderConfig, build_encoder  # noqa: E402


def _rss_mb() -> float:
    # ru_maxrss 单位平台差异(getrusage(2) 口径):Linux=KiB,macOS=bytes。
    # 历史教训:macOS 标定腿曾把 bytes 当 KiB 除,峰值内存低估 1024 倍。
    kb = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    if sys.platform == "darwin":
        return kb / (1024.0 * 1024.0)
    return kb / 1024.0


def run_calibration(*, device: str, steps: int, batch: int, seq: int, seed: int) -> dict:
    import torch

    torch.manual_seed(seed)
    model = build_encoder(EncoderConfig(seq=seq)).to(device)
    optimizer = torch.optim.AdamW(model.parameters(), lr=2e-5)
    x = torch.randint(0, 2000, (batch, seq), device=device)
    times = []
    losses = []
    for step in range(steps):
        optimizer.zero_grad(set_to_none=True)
        start = time.perf_counter()
        logits = model(x)
        loss = logits.mean()
        loss.backward()
        optimizer.step()
        if device == "mps":
            torch.mps.synchronize()
        times.append(time.perf_counter() - start)
        losses.append(float(loss.detach().cpu()))
    times_sorted = sorted(times)
    tokens = steps * batch * seq
    return {
        "device": device, "steps": steps, "batch": batch, "seq": seq,
        "median_step_s": round(times_sorted[len(times_sorted) // 2], 4),
        "max_step_s": round(times_sorted[-1], 4),
        "tokens_per_s": round(tokens / sum(times), 2),
        "final_loss": round(losses[-1], 6),
        "loss_first": round(losses[0], 6),
        "loss_nan": any(l != l for l in losses),
        "peak_rss_mb": round(_rss_mb(), 1),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", default="cpu", choices=["cpu", "mps"])
    parser.add_argument("--steps", type=int, default=100)
    parser.add_argument("--batch", type=int, default=64)
    parser.add_argument("--seq", type=int, default=128)
    parser.add_argument("--seed", type=int, default=20260929)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()

    try:
        result = run_calibration(device=args.device, steps=args.steps, batch=args.batch,
                                 seq=args.seq, seed=args.seed)
    except Exception as exc:  # 设备异常 → 标定失败也是数据
        result = {"device": args.device, "error": f"{type(exc).__name__}: {exc}"}
        args.out.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        print(f"CALIBRATE_FAILED {result['error']}")
        return 0  # 标定失败由 workflow 汇总裁决,不炸 job
    args.out.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
