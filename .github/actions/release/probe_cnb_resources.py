#!/usr/bin/env python3
"""CNB 资源面一次性探针(2026-10-03 cutover 定案 §7.6:先探针,后定 root 主机表)。

四个子命令全部 stdlib urllib、同一可追溯 UA、有界读取、fail-closed 输出:
  anonymous-page    公开 tag 页匿名拉取 + __NEXT_DATA__ 解析(探针=解析器首个真实数据)
  anonymous-api     匿名 GET api.cnb.cool 库存端点——一次性裁决「API vs SSR」形态分歧
  attachment-range  对指定资产发 HEAD/Range 探测(206/Content-Range/Accept-Ranges/逐跳宿主)
  upload-roundtrip  带 CNB_TOKEN 走完整上传序列(微资产 overwrite:false),输出观测到的
                    upload 宿主与路径前缀(业主据此设 CNB_RESOURCE_UPLOAD_PATH_PREFIX)

探针资产删除=独立破坏性动作,人工执行(定案 §7.6);本脚本绝不删除任何资产。
"""
import argparse
import hashlib
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

UA = "vitaliber-cnb-probe/1"
MAX_BYTES = 8 << 20

# 2026-10-07 模块化：SSR 解析器自 cnb_read 单源导入（此前 importlib 装载 prepare）。
import cnb_read


def _get(url, headers=None, timeout=60, method="GET"):
    request = urllib.request.Request(url, headers=dict(headers or {}), method=method)
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return response.status, dict(response.headers), response.read(MAX_BYTES + 1)


def anonymous_page(repository, tag):
    url = f"https://cnb.cool/{repository}/-/releases/tag/{tag}"
    status, headers, body = _get(url, {"User-Agent": UA})
    print(f"GET {url} -> HTTP {status} ({len(body)} bytes)")
    if status != 200:
        return 1
    try:
        assets = cnb_read.parse_cnb_tag_page(body, repository, tag)
    except ValueError as error:
        print("inventory parse failed (fail-closed): " + str(error), file=sys.stderr)
        return 1
    print(f"parsed {len(assets)} assets via __NEXT_DATA__ (fail-closed shape checks passed)")
    for asset in assets[:10]:
        print("  " + asset["name"])
    return 0


def anonymous_api(repository, tag):
    url = f"https://api.cnb.cool/{repository}/-/releases/tags/{tag}"
    try:
        status, _, body = _get(url, {"User-Agent": UA})
        print(f"GET {url} -> HTTP {status} ({len(body)} bytes)")
    except urllib.error.HTTPError as error:
        print(f"GET {url} -> HTTP {error.code} (anonymous)")
        return 0
    return 0


def attachment_range(repository, tag, name):
    url = f"https://cnb.cool/{repository}/-/releases/download/{tag}/{name}"
    # 逐跳观察:先看首跳,再发 HEAD/Range
    try:
        status, headers, body = _get(url, {"User-Agent": UA, "Range": "bytes=0-3"})
        print(f"GET {url} (Range 0-3) -> HTTP {status}")
        for key in ("content-range", "accept-ranges", "content-length", "location", "etag"):
            if key in headers:
                print(f"  {key}: {headers[key]}")
        print(f"  body: {body[:4]!r}")
    except urllib.error.HTTPError as error:
        print(f"GET {url} (Range 0-3) -> HTTP {error.code}")
        print("  response headers: " + json.dumps(dict(error.headers), default=str))
    try:
        request = urllib.request.Request(url, headers={"User-Agent": UA}, method="HEAD")
        with urllib.request.urlopen(request, timeout=60) as response:
            print(f"HEAD {url} -> HTTP {response.status}")
            for key in ("accept-ranges", "content-length", "content-type", "location"):
                if key in response.headers:
                    print(f"  {key}: {response.headers[key]}")
    except urllib.error.HTTPError as error:
        print(f"HEAD {url} -> HTTP {error.code}")
    return 0


def upload_roundtrip(repository, tag, token):
    from cnb_release import CNBReleaseClient, RecordingUploadTransport

    payload = b"vitaliber-cnb-probe-asset"
    name = "probe-" + hashlib.sha256(payload).hexdigest()[:12] + ".bin"
    import tempfile
    from pathlib import Path
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / name
        path.write_bytes(payload)
        transport = RecordingUploadTransport()
        client = CNBReleaseClient(repository, token, transport)
        try:
            receipt = client.upload_immutable(tag, path, name, hashlib.sha256(payload).hexdigest())
            print(json.dumps({"name": receipt.name, "size": receipt.size,
                              "sha256": receipt.sha256, "path": receipt.path}))
        except Exception as error:  # 探针面:任何失败都打印为可读诊断
            print("upload-roundtrip failed: " + str(error), file=sys.stderr)
            return 1
        if transport.upload_url:
            parsed = urllib.parse.urlsplit(transport.upload_url)
            segments = parsed.path.split("/")
            # 前缀候选 = scheme://host + 路径前两段(稳定目录面);余段按 token 面掩码。
            prefix_candidate = parsed.scheme + "://" + parsed.netloc + "/".join(
                [""] + segments[1:3])
            masked = "/".join(segments[:3]) + "/" + "/".join("<redacted>" for _ in segments[3:])
            print("observed upload_url:")
            print("  host: " + parsed.netloc)
            print("  masked path: " + masked + ("?" + parsed.query.split("&")[0].split("=")[0] + "=<redacted>" if parsed.query else ""))
            print("  UPLOAD_PATH_PREFIX candidate: " + prefix_candidate)
            print("  设置方式: gh variable set CNB_RESOURCE_UPLOAD_PATH_PREFIX -R robinhoo1973/Vita-Liber -b " + prefix_candidate)
    print("probe asset uploaded (删除=独立破坏性动作,人工执行;本脚本不删除)")
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    for command in ("anonymous-page", "anonymous-api"):
        entry = sub.add_parser(command)
        entry.add_argument("--repository", default=os.environ.get("CNB_RESOURCE_REPOSITORY"))
        entry.add_argument("--tag", default="asr-models")
    page = sub.add_parser("attachment-range")
    page.add_argument("--repository", default=os.environ.get("CNB_RESOURCE_REPOSITORY"))
    page.add_argument("--tag", default="asr-models")
    page.add_argument("--name", required=True)
    upload = sub.add_parser("upload-roundtrip")
    upload.add_argument("--repository", default=os.environ.get("CNB_RESOURCE_REPOSITORY"))
    upload.add_argument("--tag", default="asr-models")
    args = parser.parse_args()
    if not args.repository:
        print("--repository or CNB_RESOURCE_REPOSITORY is required", file=sys.stderr)
        return 1
    if args.command == "anonymous-page":
        return anonymous_page(args.repository, args.tag)
    if args.command == "anonymous-api":
        return anonymous_api(args.repository, args.tag)
    if args.command == "attachment-range":
        return attachment_range(args.repository, args.tag, args.name)
    token = os.environ.get("CNB_TOKEN")
    if not token:
        print("CNB_TOKEN is required for upload-roundtrip", file=sys.stderr)
        return 1
    return upload_roundtrip(args.repository, args.tag, token)


if __name__ == "__main__":
    raise SystemExit(main())
