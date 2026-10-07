#!/usr/bin/env python3
"""L0 [18] 依赖能力矩阵判定器（2026-09-27 委员会 P1）。

断言两个钉面与矩阵一致：
  1) CoreKit/Package.resolved：tag 钉 ≤ 矩阵上限（语义版本比较，降级放行）；
     rev 钉必须与矩阵 rev 等值（rev 无版本语义，任何漂移即未验证状态）。
  2) project.yml packages：exactVersion 必须与矩阵等值；majorVersion 区间钉
     是唯一可静默漂移面——矩阵要求 exact（GRDB 6.29.3）。
任一钉无矩阵行 → FAIL（未登记 = 未验证）。"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
while ROOT != ROOT.parent and not (ROOT / "CoreKit" / "Package.swift").is_file():
    ROOT = ROOT.parent

RESOLVED = ROOT / "CoreKit" / "Package.resolved"
PROJECT = ROOT / "project.yml"
MATRIX = ROOT / ".github" / "config" / "gates" / "dependency-capability-matrix.tsv"


def load_matrix():
    rows = {}
    for line in MATRIX.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) < 5:
            continue
        rows[parts[0]] = {"xcode26": parts[1], "xcodebuild": parts[2], "linux": parts[3], "form": parts[4], "path": parts[5]}
    return rows


def semver(v):
    nums = re.findall(r"\d+", v)
    return tuple(int(n) for n in nums[:4])


def main():
    matrix = load_matrix()
    fails = []
    scanned = 0

    # 1) Package.resolved
    resolved = json.loads(RESOLVED.read_text(encoding="utf-8"))
    pins = resolved.get("pins", [])
    for pin in pins:
        identity = pin["identity"]
        scanned += 1
        state = pin.get("state", {})
        if identity not in matrix:
            fails.append(f"{identity}: 无矩阵行——未登记即未验证（委员会 P1）")
            continue
        row = matrix[identity]
        if "version" in state and state["version"]:
            for face in ("xcode26", "xcodebuild", "linux"):
                if semver(state["version"]) > semver(row[face]):
                    fails.append(
                        f"{identity}: pin {state['version']} > {face} 上限 {row[face]}"
                        f" —— 该版本未经对应工具链验证（swift-collections 1.7.0 Builtin 族，CI 36253140508）")
        else:
            rev = state.get("revision", "")
            if row["form"] != "rev" or not rev.startswith(row["xcode26"]):
                fails.append(f"{identity}: rev 钉 {rev} ≠ 矩阵 {row['xcode26']}（rev 无版本语义，漂移即未验证）")

    # 2) project.yml exactVersion 面
    proj = PROJECT.read_text(encoding="utf-8")
    for pkg, row in matrix.items():
        if row["form"] != "exact":
            continue
        m = re.search(re.escape(pkg) + r':\s*\n(?:\s*url:.*\n)?\s*exactVersion:\s*([0-9.]+)', proj)
        if not m:
            fails.append(f"{pkg}: project.yml 无 exactVersion 钉（区间钉是可静默漂移面）")
        elif semver(m.group(1)) != semver(row["xcode26"]):
            fails.append(f"{pkg}: project.yml exact {m.group(1)} ≠ 矩阵 {row['xcode26']}")

    # 3) GRDB majorVersion 区间钉 → 必须 exact（唯一可静默漂移面）
    if re.search(r'GRDB\.swift:\s*\n(?:\s*url:.*\n)?\s*majorVersion:', proj):
        fails.append("GRDB.swift: project.yml 仍是 majorVersion 区间钉——改 exactVersion 6.29.3（唯一可静默漂移面，委员会 P1）")

    print(f"__SCANNED__ matrix_pins={scanned} matrix_rows={len(matrix)}")
    for f in fails:
        print("FAIL:", f)
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
