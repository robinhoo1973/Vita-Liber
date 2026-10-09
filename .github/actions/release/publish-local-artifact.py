#!/usr/bin/env python3
"""本地产物上传器（2026-10-09 W11 训练→CNB 自动交换）:训练机产物 → CNB Release。

职责（一个动作：把**本机文件**以内容寻址名发到 CNB 分发面）:
  1. 资产名 = `<prefix><sha256 前 16 位>-<basename>`（内容寻址:同名必同内容、
     重发幂等、绝不覆盖）;
  2. 不可变上传语义**单源复用** `cnb_release.CNBReleaseClient.upload_immutable
     (overwrite=False)`:同名同 sha+bytes → 幂等成功（跳过上传,仅清单核对）；
     同名异 sha → 硬错（绝不覆盖既有资产）;
  3. 上传/跳过之后做**匿名回读**核对:用匿名读路径（`cnb_read.download_cnb_asset`,
     无 token、App 同款 302 下载链）流式重下资产并核对 sha256+bytes——发布面
     真可见、字节真一致才判成功;内容不符立即硬错（不重试）;网络错误退避重试;
  4. token 只从 env `CNB_TOKEN` 读取（缺失 = 秒级硬错,未做任何网络/哈希动作）,
     永不落盘、永不入日志、不提供 `--token` 参数;
  5. **只上传,绝不改任何 catalog/policy**（本脚本不读不写 catalog/policy 文件）。

用法（训练机;`scripts/exchange/` 为 deploy-training.sh 投递的闭包）:
  CNB_TOKEN=<token> python3 scripts/exchange/publish-local-artifact.py \\
      --file out/pretrain_mps_768.pth out/full_sft_mps_768.pth \\
      [--release llama-models] [--name-prefix train-] [--repository owner/repo]

退出码:0 = 全部资产（含幂等跳过）通过匿名回读;1 = 任一失败（其余照常处理）。
"""
from __future__ import annotations

import argparse
import hashlib
import os
import re
import sys
import tempfile
import time
import urllib.error
from pathlib import Path

HERE = Path(__file__).resolve().parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

from cnb_release import CNBReleaseClient, CNBReleaseError, UrllibCNBTransport, public_download_url  # noqa: E402  (写路径单源)
from cnb_read import download_cnb_asset  # noqa: E402  (匿名读路径单源)

DEFAULT_REPOSITORY = "robinhoo1973/Resources"
DEFAULT_RELEASE = "llama-models"
DEFAULT_NAME_PREFIX = "train-"
# 资产名文法（URL path 一段;CNB 资产名白名单之外的字符一律拒绝,绝不静默改名）。
ASSET_NAME_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*")
MAX_ASSET_NAME_LENGTH = 255
READBACK_ATTEMPTS = 3
READBACK_BACKOFF_SECONDS = 5


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def asset_name(prefix: str, digest: str, basename: str) -> str:
    """内容寻址资产名:`<prefix><sha256 前 16 位>-<basename>`（文法不符即拒,绝不静默改名）。"""
    name = f"{prefix}{digest[:16]}-{basename}"
    if len(name) > MAX_ASSET_NAME_LENGTH or not ASSET_NAME_RE.fullmatch(name):
        raise ValueError(f"资产名不符文法（请重命名源文件为 [A-Za-z0-9._-]+）: {name!r}")
    return name


def asset_name_for(path: Path, prefix: str) -> str:
    """`asset_name` 的取文件便捷口（哈希后推导;测试与调用方同一推导）。"""
    return asset_name(prefix, sha256_file(path), Path(path).name)


def verify_anonymous_readback(repository: str, release: str, asset_name: str,
                              expected_sha256: str, expected_size: int, *,
                              download=None, attempts: int = READBACK_ATTEMPTS,
                              backoff_seconds: int = READBACK_BACKOFF_SECONDS) -> None:
    """匿名回读核对 sha256+bytes（无 token;校验不符 = 硬错不重试,网络错误 = 退避重试）。"""
    if download is None:
        download = download_cnb_asset
    last: Exception | None = None
    for attempt in range(1, attempts + 1):
        try:
            with tempfile.TemporaryDirectory(prefix="cnb-readback-") as tmp:
                download(repository, release, {"name": asset_name}, Path(tmp) / asset_name,
                         expected_sha256, expected_size)
            return
        except ValueError as exc:
            raise ValueError(
                f"匿名回读内容不符（绝不静默放行;已发布资产保持原样,人工处置）: {asset_name}: {exc}") from exc
        except (OSError, urllib.error.URLError) as exc:
            last = exc
            if attempt < attempts:
                print(f"匿名回读失败(第 {attempt}/{attempts} 次): {asset_name}: {exc}——"
                      f"{backoff_seconds * attempt}s 后重试", file=sys.stderr)
                time.sleep(backoff_seconds * attempt)
    raise OSError(f"匿名回读失败: {asset_name}: {last}")


def publish_file(client: CNBReleaseClient, path: Path, *, release: str, prefix: str,
                 download=None, attempts: int = READBACK_ATTEMPTS,
                 backoff_seconds: int = READBACK_BACKOFF_SECONDS) -> dict:
    """单文件:校验 → 内容寻址名 → 不可变上传（幂等/碰撞语义在 cnb_release 里）→ 匿名回读。"""
    path = Path(path)
    if not path.is_file() or path.is_symlink():
        raise CNBReleaseError(f"上传源不是常规文件: {path}")
    size = path.stat().st_size
    digest = sha256_file(path)
    name = asset_name(prefix, digest, path.name)
    print(f"[publish] {path.name}  bytes={size} sha256={digest[:16]}… → {name}", flush=True)
    # 不可变上传单源:同名同 sha 幂等跳过;同名异 sha 硬错;revision 复核走 cnb_release 内建纪律。
    receipt = client.upload_immutable(release, path, name, digest, overwrite=False)
    print(f"[publish] 上传面核对通过（{release}@{client.repository}）;进行匿名回读校验…", flush=True)
    verify_anonymous_readback(client.repository, release, name, digest, size,
                              download=download, attempts=attempts, backoff_seconds=backoff_seconds)
    print(f"[ok] 匿名回读核对通过: {name}（sha256={digest[:16]}…, bytes={size}）", flush=True)
    return {"name": receipt.name, "sha256": receipt.sha256, "bytes": receipt.size,
            "path": receipt.path, "file": str(path),
            "url": public_download_url(client.repository, release, name)}


def main(argv=None, *, transport=None, download=None, attempts: int = READBACK_ATTEMPTS,
         backoff_seconds: int = READBACK_BACKOFF_SECONDS) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--file", type=Path, action="append", nargs="+", required=True,
                        metavar="PATH", help="本地产物路径(可多件;可重复给出)")
    parser.add_argument("--release", default=DEFAULT_RELEASE,
                        help=f"CNB release tag(白名单在 cnb_release.ALLOWED_TAGS;默认 {DEFAULT_RELEASE})")
    parser.add_argument("--name-prefix", default=DEFAULT_NAME_PREFIX,
                        help=f"资产名前缀(默认 {DEFAULT_NAME_PREFIX})")
    parser.add_argument("--repository",
                        default=os.environ.get("CNB_RESOURCE_REPOSITORY", DEFAULT_REPOSITORY))
    args = parser.parse_args(argv)

    # 秒级硬红:token 先行,未配置时不读文件、不发任何请求（token 只走 env,永不落盘）。
    token = os.environ.get("CNB_TOKEN", "")
    if not token:
        print("FAIL: CNB_TOKEN 未配置——上传需要令牌（仅接受环境变量,不接受参数/文件）", file=sys.stderr)
        return 1

    files = [path for group in args.file for path in group]
    client = CNBReleaseClient(args.repository, token, transport or UrllibCNBTransport())
    failures = 0
    for path in files:
        try:
            publish_file(client, path, release=args.release, prefix=args.name_prefix,
                         download=download, attempts=attempts, backoff_seconds=backoff_seconds)
        except (CNBReleaseError, OSError, ValueError) as exc:
            failures += 1
            print(f"FAIL: {path}: {exc}", file=sys.stderr)
    if failures:
        print(f"[done] {len(files) - failures}/{len(files)} 件通过;{failures} 件失败", file=sys.stderr)
        return 1
    print(f"[done] {len(files)}/{len(files)} 件已发布并经匿名回读核对", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
