#!/usr/bin/env python3
"""MPS 探测(计划文档 §7.4 第 8 条):真分配 + matmul 对拍 + 架构检查。

不信任 torch.backends.mps.is_available();本探测用真实分配与数值对拍裁决。
**状态(2026-10-08)**:托管 macos-15-arm64 镜像上实测 5/5 通过(真可用;
2024 期 runner-images#9918 的"假阳性"结论在本镜像不复现)。但 CI MPS 腿已
退役(业主裁定):probe 通过≠吞吐可用——100 步标定 5 次全为人工取消、0 次
超时、最长 57m56s 未完,步均 ≥34.8s/step 下界 vs ubuntu CPU 实测 median
7.62s/step。本件登记为 **M4 本地执行面备用仪器(CI 零调用)**;
requirements-distill-train-macos.txt 同此登记。

输出:机器可读行 `MPS_USABLE=yes|no <reason>`(手动仪器使用)+ JSON。
退出码恒为 0(探测结果是数据,不是失败)。
"""
from __future__ import annotations

import argparse
import json
import os
import platform
import sys
import time
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))


def probe() -> dict:
    result = {
        "probe_version": "1.0",
        "machine": platform.machine(),
        "usable": False,
        "reason": "",
        "details": {},
    }
    if platform.machine() != "arm64":
        result["reason"] = f"非 arm64 平台({platform.machine()}),MPS 不适用"
        return result
    try:
        import torch
    except ImportError as exc:
        result["reason"] = f"torch 不可用: {exc}"
        return result
    result["details"]["torch"] = torch.__version__
    if not torch.backends.mps.is_available():
        result["reason"] = "is_available()=False"
        return result
    try:
        # ① 最小分配(#9918 崩溃签名:256B 分配即炸)
        tiny = torch.zeros(256, dtype=torch.uint8, device="mps")
        # ② 真实工作集分配(64MB 级)
        work = torch.randn(64, 4096, device="mps", dtype=torch.float32)
        # ③ matmul 对拍:结果必须与 CPU 一致(MPS 静默数值错的第一道闸)
        a = torch.randn(128, 128, device="mps", dtype=torch.float32)
        b = torch.randn(128, 128, device="mps", dtype=torch.float32)
        mps_out = (a @ b).cpu().float()
        cpu_out = a.cpu().float() @ b.cpu().float()
        max_diff = float((mps_out - cpu_out).abs().max())
        ok = max_diff < 1e-3
        # ④ 时序(100 次小 matmul 中位耗时,供标定参考)
        start = time.perf_counter()
        for _ in range(100):
            _ = a @ b
        torch.mps.synchronize()
        per_op_ms = (time.perf_counter() - start) / 100 * 1000
        del tiny, work, a, b
        if ok:
            result["usable"] = True
            result["reason"] = "真分配 + matmul 对拍通过"
        else:
            result["reason"] = f"matmul 对拍偏差 {max_diff:.6f} ≥ 1e-3(静默数值错)"
        result["details"]["matmul_max_diff"] = max_diff
        result["details"]["matmul_ms"] = round(per_op_ms, 3)
    except Exception as exc:  # 任何分配/算子异常 = 不可用(#9918 签名)
        result["reason"] = f"MPS 真分配失败: {type(exc).__name__}: {exc}"
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json", type=Path, default=None)
    args = parser.parse_args()
    result = probe()
    print(f"MPS_USABLE={'yes' if result['usable'] else 'no'} {result['reason']}")
    if args.json is not None:
        args.json.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
