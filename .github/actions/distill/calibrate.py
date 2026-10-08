#!/usr/bin/env python3
"""100 步标定(计划文档 §7.4/手册 §8.1 纪律):真实训练步吞吐基准。

口径(手册 §10.9 v2):真实训练步 = fwd+bwd+AdamW 多步持续,不是单次 backward。
输出 calibrate.json:设备/吞吐/峰值内存/loss 轨迹。结果供训练分块预算(§7.4 第 8 条)。
**MPS 腿已退役**(2026-10-08 业主裁定):CI 只跑 --device cpu;--device mps 保留
供 M4 本地执行面手动仪器(probe 5/5 通过但 100 步标定从未完成→托管 MPS 吞吐
无可用证据,详见 llm.yml 头注)。
观测性(S2 红队 2026-10-08):每 10 步 print+落盘 partial、SIGTERM/SIGINT 部分
落盘——中断也留"跑到第 N 步、前 N 步中位 X s"的硬数据(历史:5 次取消零产出)。
"""
from __future__ import annotations

import argparse
import json
import os
import resource
import signal
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


def run_calibration(*, device: str, steps: int, batch: int, seq: int, seed: int,
                    on_progress=None) -> dict:
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
        if on_progress is not None:
            on_progress(step + 1, times)
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


def _write_out(path: Path, payload: dict) -> None:
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", default="cpu", choices=["cpu", "mps"])
    parser.add_argument("--steps", type=int, default=100)
    parser.add_argument("--batch", type=int, default=64)
    parser.add_argument("--seq", type=int, default=128)
    parser.add_argument("--seed", type=int, default=20260929)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()

    progress: dict = {"times": [], "steps_done": 0}

    def _partial(final: bool) -> None:
        ts = sorted(progress["times"])
        if not ts:
            return
        payload = {"device": args.device, "partial": not final,
                   "steps_done": progress["steps_done"], "total_steps": args.steps,
                   "median_step_s": round(ts[len(ts) // 2], 4),
                   "max_step_s": round(ts[-1], 4), "peak_rss_mb": round(_rss_mb(), 1)}
        _write_out(args.out, payload)

    def _on_signal(signum, _frame):  # 取消/超时(SIGTERM)也留部分数据
        _partial(final=False)
        print(f"CALIBRATE_INTERRUPTED signal={signum} steps_done={progress['steps_done']}",
              flush=True)
        sys.exit(0)

    signal.signal(signal.SIGTERM, _on_signal)
    signal.signal(signal.SIGINT, _on_signal)

    def _on_progress(steps_done: int, times: list) -> None:
        progress["times"], progress["steps_done"] = times, steps_done
        ts = sorted(times)
        print(f"[calibrate] step {steps_done}/{args.steps} "
              f"median={ts[len(ts) // 2]:.3f}s max={ts[-1]:.3f}s", flush=True)
        # 每步落盘(2026-10-08 对拍实证:平台取消不给 SIGTERM 宽限=硬杀,
        # 每 10 步才落盘会在第 9 步被杀时零产出)
        _partial(final=False)

    try:
        result = run_calibration(device=args.device, steps=args.steps, batch=args.batch,
                                 seq=args.seq, seed=args.seed, on_progress=_on_progress)
    except Exception as exc:  # 设备异常 → 标定失败也是数据
        result = {"device": args.device, "error": f"{type(exc).__name__}: {exc}"}
        _write_out(args.out, result)
        print(f"CALIBRATE_FAILED {result['error']}")
        return 0  # 标定失败由 workflow 汇总裁决,不炸 job
    _write_out(args.out, result)
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
