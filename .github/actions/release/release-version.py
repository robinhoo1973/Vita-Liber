#!/usr/bin/env python3
"""The App release version is owned by version.txt, independently of GitHub Releases."""
import argparse
import json
from pathlib import Path
import re
import sys


def read_version(path: Path) -> str:
    raw = path.read_bytes()
    if len(raw) > 128:
        raise ValueError("version.txt is too large")
    value = raw.decode("utf-8-sig").strip()
    if len(value) > 64 or not re.fullmatch(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)", value):
        raise ValueError("version.txt must contain one major.minor.patch version (for example 0.0.1)")
    return value


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version-file", type=Path, default=Path("version.txt"))
    parser.add_argument("--run-number", type=int, required=True)
    parser.add_argument("--code-hash", required=True)
    parser.add_argument("--build-state", default="",
                        help="GitHub 变量 BUILD_STATE 的 JSON（{release,build}）——业主 2026-10-17 裁决："
                             "release 与 version.txt 一致则沿用存储 build；不一致 → build=1 并输出 state_reset=true；"
                             "空/损坏 → 回落 run_number（旧行为，零回退风险）")
    parser.add_argument("--floor-build", type=int, default=None,
                        help="构建号硬下界（2026-10-18：build job 从 ASC 同一 marketing version 的已登记最大 "
                             "build+1 取得）。BUILD_STATE 写回需 BUILD_STATE_PAT，secret 缺失时计数器会静默"
                             "停摆（实证：build 751 重复上传被 ASC 拒收）。ASC 是权威登记簿，故下界优先于"
                             "本地计数器；缺失/查询失败时由 workflow 传 -1（不设下界）。")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        version = read_version(args.version_file)
        if args.run_number < 1:
            raise ValueError("build number must be positive")
        if not re.fullmatch(r"[0-9a-f]{8,40}", args.code_hash):
            raise ValueError("invalid commit hash")
        build: str
        state_reset = False
        try:
            state = json.loads(args.build_state) if args.build_state.strip() else None
            stored_release = (state or {}).get("release")
            stored_build = (state or {}).get("build")
        except ValueError:
            state, stored_release, stored_build = None, None, None
        if isinstance(stored_build, int) and stored_build >= 1 and stored_release == version:
            build = f"{stored_build:03d}"
        elif isinstance(stored_release, str):
            # release 变更 → build 归 1，由调用方（workflow）据此更新变量
            build = "001"
            state_reset = True
        else:
            build = f"{args.run_number:03d}"
        if args.floor_build is not None and args.floor_build > int(build):
            build = f"{args.floor_build:03d}"
        with args.output.open("a", encoding="utf-8") as output:
            output.write(f"version={version}\nbuild={build}\nhash={args.code_hash}\n")
            output.write(f"state_reset={'true' if state_reset else 'false'}\n")
        print(f"version.txt → Version {version} | Build {build} | Code Hash {args.code_hash}"
              f"{' | state_reset' if state_reset else ''}")
        return 0
    except (OSError, UnicodeError, ValueError) as error:
        print(f"::error::App version configuration: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
