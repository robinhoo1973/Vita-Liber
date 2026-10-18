#!/usr/bin/env python3
"""BUILD_STATE 变量写回（业主 2026-10-17 裁决：release 变更 → build 归 1；
上传确认 → build+1——失败 run 不消耗 build 号）。

写回通道 = GitHub Actions repo 变量 BUILD_STATE（JSON：{"release": "...", "build": N}）。
默认 GITHUB_TOKEN 无 variables 写权限——调用方须以 BUILD_STATE_PAT（fine-grained，
Variables: write，仅 Vita-Liber）覆盖 GH_TOKEN；PAT 缺失 = 写回跳过并告警
（build 回落 run_number 语义，绝不因记账失败阻断发布）。
"""
import argparse
import json
import os
import subprocess
import sys

VARIABLE_NAME = "BUILD_STATE"


def read_version(path: str) -> str:
    return open(path, encoding="utf-8-sig").read().strip()


def resolve(version_file: str, build: int, commit_sha256: str, repo: str) -> int:
    """写入 {release: version, build: build, commitSHA256: …}；返回 gh variable set 退出码。
    commitSHA256 = 本次已发布提交——入口 source-unchanged 前置闸比对相同即
    退出整链（业主 2026-10-18 裁决：取代上传期二进制哈希比对）。"""
    body = json.dumps({"release": read_version(version_file), "build": build,
                       "commitSHA256": commit_sha256}, separators=(",", ":"))
    return subprocess.run(["gh", "variable", "set", VARIABLE_NAME, "-R", repo, "--body", body],
                          check=False).returncode


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version-file", default="version.txt")
    parser.add_argument("--build", type=int, required=True, help="本次已确认上传的 build 号（写回 build+1）")
    parser.add_argument("--reset", action="store_true", help="release 变更归 1 模式（写回 build=1，appSHA256 清空=强制上传）")
    parser.add_argument("--commit-sha", default="", help="本次已发布提交 SHA（bump 模式写回；reset 模式恒清空）")
    parser.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY", "robinhoo1973/Vita-Liber"))
    args = parser.parse_args()
    if os.environ.get("GH_TOKEN", "").strip():
        target = 1 if args.reset else args.build + 1
        commit = "" if args.reset else args.commit_sha
        rc = resolve(args.version_file, target, commit, args.repo)
        if rc != 0:
            print(f"::error::BUILD_STATE 写回失败（gh exit {rc}）——build 记账未推进，下次 run 将复用本号")
            return 1
        print(f"BUILD_STATE → {json.dumps({'release': read_version(args.version_file), 'build': target, 'commitSHA256': commit or ''})}")
        return 0
    print("::warning::GH_TOKEN 未注入 BUILD_STATE_PAT——build 记账跳过（回落 run_number 语义，不阻断发布）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
