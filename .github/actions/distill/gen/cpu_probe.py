#!/usr/bin/env python3
"""CPU 能力探测(2026-10-09 研究席 A1;stdlib,可离线单测)。

GitHub runner CPU 为 Intel/AMD 混池且不可 pin(vLLM #36898):任何 ISA 相关加速
(bf16/AMX) 必须运行时探测 + 可回退 + 留 A/B 记录。本模块只做"读事实":
  - /proc/cpuinfo flags 交集(avx2/avx512*/amx_bf16 等)
  - bf16_ok = avx512_bf16 或 amx_bf16(硬件 bf16;缺则 oneDNN bf16 慢 3-4×)
"""
from __future__ import annotations

import platform
import re
from pathlib import Path

WANT = ("avx2", "avx512f", "avx512_bf16", "amx_bf16", "amx_tile", "f16c", "fma")


def cpu_flags(cpuinfo: Path | None = None) -> dict:
    """返回 {feature: bool};读不到(非 Linux/无文件)→ 全 False + readable=False。"""
    path = cpuinfo or Path("/proc/cpuinfo")
    flags: set[str] = set()
    readable = False
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
        readable = True
        for line in text.splitlines():
            if line.lower().startswith("flags") or line.lower().startswith("features"):
                flags.update(line.split(":", 1)[1].split())
                break
    except OSError:
        pass
    # amx_bf16 在某些内核上报为 amx_bf16,个别为 amx-bf16
    norm = {f.replace("-", "_").lower() for f in flags}
    out = {feat: (feat in norm) for feat in WANT}
    out["readable"] = readable
    out["arch"] = platform.machine()
    return out


def bf16_hardware_ok(flags: dict) -> bool:
    return bool(flags.get("avx512_bf16") or flags.get("amx_bf16"))


def summary(flags: dict) -> str:
    feats = ",".join(k for k in WANT if flags.get(k)) or "none"
    return (f"arch={flags.get('arch')} feats=[{feats}] "
            f"bf16_hardware={'yes' if bf16_hardware_ok(flags) else 'no'}")


if __name__ == "__main__":
    print(summary(cpu_flags()))
