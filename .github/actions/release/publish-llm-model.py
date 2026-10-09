#!/usr/bin/env python3
"""T2 本机 LLM 模型发布器（2026-10-09 换型+下载化批；发布接口/信任纪律照 asr 先例）。

职责（一个动作：把**已钉版**的目录条目对应的上游字节发到 CNB 分发面）：
  1. 读 `Resources/LLMCatalog/catalog.json` 的指定条目（id/sha256/bytes/url 已在
     仓库内被评审与 L0 [20] 固化——本脚本不发明版本，只搬运已钉版的内容）；
  2. 从上游 `--source` 下载字节流（https，主机白名单），流式 sha256 + 字节双校验；
     不符即硬失败（绝不发布未校验字节）；
  3. 资产名 = `<id>-<sha256 前 16 位>.gguf`（**内容寻址**：同名异内容不可能、
     重发幂等、回滚零操作）；断言 catalog 的 url 与该资产名推导出的 CNB 直链**逐字一致**
     （目录与分发面漂移 = 静默错货，宁可拒发）；
  4. 调 `cnb_release.py upload`（不可变上传 + 回读核对在其内建纪律里）。

用法（人工 dispatch 由 llm-model.yml 调用；也可本地 dry-run）：
  python3 publish-llm-model.py --id <catalog id> --source <上游 https 直链> [--dry-run]

环境：CNB_TOKEN（发布必需；dry-run 免）；CNB_RESOURCE_REPOSITORY 可选覆盖。
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parent
while ROOT != ROOT.parent and not (ROOT / "CoreKit" / "Sources" / "Domain").is_dir():
    ROOT = ROOT.parent

CATALOG = ROOT / "Resources" / "LLMCatalog" / "catalog.json"
DEFAULT_REPOSITORY = "robinhoo1973/Resources"
RELEASE_TAG = "llama-models"
CNB_DOWNLOAD_BASE = "https://cnb.cool/{repo}/-/releases/download/{tag}/{name}"
# 上游来源白名单（仅此脚本在**发布时刻**使用；App 端信任锚是目录条目本身，与此无关）。
SOURCE_ALLOWED_HOST_SUFFIXES = ("huggingface.co", "hf.co", "github.com",
                                "githubusercontent.com")
MAX_MODEL_BYTES = 2_147_483_647   # 镜像 ModelResourcePolicy.packageBytes（2GiB-1）
CHUNK = 1 << 20


def fail(message: str) -> "None":
    print(f"FAIL: {message}", file=sys.stderr)
    raise SystemExit(1)


def load_entry(model_id: str) -> dict:
    if not CATALOG.is_file():
        fail(f"catalog 缺失：{CATALOG}")
    catalog = json.loads(CATALOG.read_text(encoding="utf-8"))
    for model in catalog.get("models", []):
        if model.get("id") == model_id:
            return model
    fail(f"catalog 无此 id：{model_id}")


def asset_name_for(entry: dict) -> str:
    """内容寻址资产名（与 cnb-release-notes/llama-xcframework.md 的文法同族）。"""
    sha = entry["sha256"]
    return f"{entry['id']}-{sha[:16]}.gguf"


def expected_cnb_url(entry: dict, repository: str) -> str:
    return CNB_DOWNLOAD_BASE.format(repo=repository, tag=RELEASE_TAG,
                                    name=asset_name_for(entry))


def source_allowed(url: str) -> bool:
    from urllib.parse import urlparse
    parsed = urlparse(url)
    if parsed.scheme != "https" or parsed.username or parsed.password:
        return False
    host = (parsed.hostname or "").lower()
    if parsed.port not in (None, 443):
        return False
    return any(host == suffix or host.endswith("." + suffix)
               for suffix in SOURCE_ALLOWED_HOST_SUFFIXES)


def download_and_verify(url: str, expected_sha: str, expected_bytes: int, destination: Path) -> None:
    digest = hashlib.sha256()
    received = 0
    request = urllib.request.Request(url, headers={"User-Agent": "vitaliber-publish-llm-model"})
    with urllib.request.urlopen(request, timeout=120) as response, open(destination, "wb") as out:
        while True:
            chunk = response.read(CHUNK)
            if not chunk:
                break
            received += len(chunk)
            if received > MAX_MODEL_BYTES:
                fail(f"上游字节超上限（{MAX_MODEL_BYTES}）")
            digest.update(chunk)
            out.write(chunk)
    if received != expected_bytes:
        fail(f"字节数不符：上游 {received} ≠ 目录钉版 {expected_bytes}")
    if digest.hexdigest() != expected_sha:
        fail("sha256 不符：上游字节 ≠ 目录钉版（拒绝发布未校验字节）")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--id", required=True, help="catalog 条目 id")
    parser.add_argument("--source", required=True, help="上游 https 直链（HF resolve 等）")
    parser.add_argument("--repository", default=os.environ.get("CNB_RESOURCE_REPOSITORY", DEFAULT_REPOSITORY))
    parser.add_argument("--dry-run", action="store_true", help="只下载校验并打印，不上传")
    args = parser.parse_args()

    entry = load_entry(args.id)
    if not source_allowed(args.source):
        fail(f"来源主机不在白名单：{args.source}")
    name = asset_name_for(entry)
    expected_url = expected_cnb_url(entry, args.repository)
    if entry.get("url") != expected_url:
        fail("目录 url 与内容寻址推导不一致（目录/分发面漂移——先修目录再发布）\n"
             f"  目录 : {entry.get('url')}\n  推导 : {expected_url}")

    with tempfile.TemporaryDirectory(prefix="llm-model-publish-") as workdir:
        local = Path(workdir) / entry["fileName"]
        print(f"[1/2] 下载并校验：{args.source}")
        download_and_verify(args.source, entry["sha256"], entry["bytes"], local)
        print(f"      校验通过：{name}（{entry['bytes']} B, sha256 {entry['sha256'][:16]}…）")

        if args.dry_run:
            print(f"[2/2] dry-run：跳过上传；目标资产名 {name}")
            print(f"      目标 URL {expected_url}")
            return

        token = os.environ.get("CNB_TOKEN", "")
        if not token:
            fail("CNB_TOKEN 未配置——发布需要令牌（dry-run 免）")
        print(f"[2/2] 上传 CNB：{args.repository} release {RELEASE_TAG}")
        command = [sys.executable, str(ROOT / ".github" / "actions" / "release" / "cnb_release.py"),
                   "upload", "--tag", RELEASE_TAG, "--path", str(local),
                   "--name", name, "--sha256", entry["sha256"], "--repository", args.repository]
        completed = subprocess.run(command, check=False)
        if completed.returncode != 0:
            fail(f"cnb_release upload 失败（exit {completed.returncode}）——不可变上传+回读核对在其内建纪律里")
        print(f"发布完成：{expected_url}")


if __name__ == "__main__":
    main()
