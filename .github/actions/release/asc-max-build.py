#!/usr/bin/env python3
"""ASC 已登记最大 build 查询（构建号权威下界）。

背景（2026-10-18 CI 39136445104 实证）：BUILD_STATE 写回走 fine-grained PAT
（细粒度 PAT，Variables: write）；secret 缺失时 build-state.py 只发 ::warning::
并跳过写回，计数器静默停摆——下一次 run 复用同一 build 号，上传期单调闸才红。
App Store Connect 是构建号的权威登记簿：build job 先查同一 marketing version
的已登记最大 build，取 +1 作为下界，本地计数器再陈旧也不会产生重复号。

输出：标准输出一个整数（已登记最大 build；无记录/无 App 记录 → -1）。
失败（网络/鉴权/API 错误）以非零退出——workflow 负责重试与降级决策。
"""
import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

BASE = "https://api.appstoreconnect.apple.com/v1"


def make_token(key_text: str, key_id: str, issuer: str) -> str:
    import jwt  # PyJWT + cryptography，requirements-asc-tools.txt 哈希钉版

    now = int(time.time())
    return jwt.encode(
        {"iss": issuer, "iat": now, "exp": now + 1200, "aud": "appstoreconnect-v1"},
        key_text, algorithm="ES256",
        headers={"alg": "ES256", "kid": key_id},
    )


def call(path: str, token: str) -> dict:
    request = urllib.request.Request(
        BASE + path,
        headers={"Authorization": f"Bearer {token}", "Accept": "application/json"},
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.loads(response.read() or b"{}")
    except urllib.error.HTTPError as error:
        raise SystemExit(f"ASC API {error.code}: {error.read()[:200]!r}")


def max_registered(builds) -> int:
    """同一 marketing version 的已登记 build 最大值；忽略非数字记录。"""
    values = []
    for build in builds or []:
        raw = str((build.get("attributes") or {}).get("version", ""))
        if raw.isdigit():
            values.append(int(raw))
    return max(values, default=-1)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle-id", default="com.vitaliber.app")
    parser.add_argument("--version", required=True,
                        help="marketing version（version.txt），按 filter[preReleaseVersion.version] 过滤——"
                             "release 变更归 1 的语义因此保持成立")
    parser.add_argument("--key-file", default=os.environ.get("KEYFILE", ""))
    parser.add_argument("--key-id", default=os.environ.get("KEYID", ""))
    parser.add_argument("--issuer", default=os.environ.get("ISS", ""))
    args = parser.parse_args()
    if not (args.key_file and args.key_id and args.issuer):
        print("::error::asc-max-build: KEYFILE/KEYID/ISS 缺失", file=sys.stderr)
        return 2
    with open(args.key_file, encoding="utf-8") as handle:
        token = make_token(handle.read(), args.key_id, args.issuer)
    bundle = urllib.parse.quote(args.bundle_id, safe="")
    apps = call(f"/apps?filter[bundleId]={bundle}", token).get("data", [])
    if not apps:
        print(-1)
        return 0
    version = urllib.parse.quote(args.version, safe="")
    builds = call(
        f"/builds?sort=-version&limit=200&filter[app]={apps[0]['id']}"
        f"&filter[preReleaseVersion.version]={version}",
        token,
    ).get("data", [])
    result = max_registered(builds)
    print(f"ASC max build for {args.version}: {result}", file=sys.stderr)
    print(result)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
