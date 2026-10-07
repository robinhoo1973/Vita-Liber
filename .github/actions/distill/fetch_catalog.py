#!/usr/bin/env python3
"""医疗目录资产获取器:CNB Release → 验签指针 → 下载密文 → 信封解密 → 目录 SQLite。

数据纪律(2026-10-07 三域对齐裁决 + 计划文档 §7.6):
- 医疗数据**唯一发布位置** = CNB `robinhoo1973/Resources` release tag `medical-data`
  (本地生产者是唯一写者;源站 WAF 拒云上出口 IP,CI 永不直连源站)。
- 匿名通道:tag 页 SSR(`__NEXT_DATA__`)做资产发现,`/-/releases/download/` 做下载。
  两条通道与 App 侧解析器同源(scripts/release/prepare-asr-source.py,路径加载,零复刻)。
- 包为 AES-256-GCM 分块信封(与 ASR 同构,scripts/release/asr_envelope.py 正本)。
  identity = 验签指针里的 sqliteSha256(也是包名第一段);master = App 内嵌公开常量
  (ASRPackageCrypto.masterKeyHex,CoreKit/Sources/Infrastructure/ASRPackageCrypto.swift)。
  **非秘密**——该钥匙随 App 二进制公开;此处不经任何 secret 注入。
- 全部校验 fail-closed:指针签名载荷→资产哈希→密文 SHA-256→信封 GCM tag→
  内层 SQLite SHA-256,任一层不符即拒绝产出(绝不落半成品)。

用法:
  python3 scripts/distill/fetch_catalog.py --out-dir corpus-assets
  python3 scripts/distill/fetch_catalog.py --local-sqlite /path/catalog.sqlite --out-dir corpus-assets  # 开发旁路
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import importlib.util
import json
import re
import shutil
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent
while REPO_ROOT != REPO_ROOT.parent and not (REPO_ROOT / "CoreKit" / "Sources" / "Domain").is_dir():
    REPO_ROOT = REPO_ROOT.parent
RELEASE_DIR = REPO_ROOT / "scripts" / "release"

# scripts/release 的解析器/信封实现按需加载(与 probe_cnb_resources.py 同一路径加载法):
# 模块顶层保持 stdlib——零依赖测试闸可直接 import 本模块;信封路径(需 cryptography)
# 只在真正下载/解密时加载,缺依赖时报错信息落在使用点上。
_PREPARE_MODULE = None


def _prepare_asr_source():
    global _PREPARE_MODULE
    if _PREPARE_MODULE is None:
        if str(RELEASE_DIR) not in sys.path:
            sys.path.insert(0, str(RELEASE_DIR))
        # 连字符文件名不可 import → 路径加载;其依赖(cnb_release/asr_package)已在 sys.path 可见
        spec = importlib.util.spec_from_file_location("prepare_asr_source", RELEASE_DIR / "prepare-asr-source.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        _PREPARE_MODULE = module
    return _PREPARE_MODULE


DEFAULT_REPOSITORY = "robinhoo1973/Resources"
DEFAULT_TAG = "medical-data"
UA = "vitaliber-distill-catalog/1"
MAX_PAGE_BYTES = 8 << 20           # 与 release 侧解析器同界(SSR 页上限)
MAX_ASSET_BYTES = 1 << 30          # 单资产上限 1 GiB(包 287MB 量级;防失控资产打爆 runner 盘)
DOWNLOAD_ATTEMPTS = 3

# App 内嵌公开包钥(与 CoreKit/Sources/Infrastructure/ASRPackageCrypto.swift:33 同值;
# test_fetch_catalog.py 逐字对齐断言——两处漂移即测试红)。公开、非秘密。
MEDICAL_PACKAGE_KEY_HEX = "2303fac4e6aaacc328f6ac612f77fa91c32594f9c627aab2178b19486ebe7e82"

_CATALOG_NAME = re.compile(r"^medical-data-catalog-progress-(\d+)-(\d{8}T\d{6}Z)\.json$")
_PACKAGE_NAME = re.compile(r"^medical-data-package-sqlite-([0-9a-f]{64})-cipher-([0-9a-f]{64})\.bin$")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _urlopen(url: str, timeout: int):
    request = urllib.request.Request(url, headers={"User-Agent": UA})
    return urllib.request.urlopen(request, timeout=timeout)


def fetch_tag_page(repository: str, tag: str) -> bytes:
    url = f"https://cnb.cool/{repository}/-/releases/tag/{tag}"
    last: Exception | None = None
    for attempt in range(1, DOWNLOAD_ATTEMPTS + 1):
        try:
            with _urlopen(url, timeout=120) as resp:
                if resp.status != 200:
                    raise OSError(f"HTTP {resp.status}")
                return resp.read(MAX_PAGE_BYTES + 1)
        except (OSError, urllib.error.URLError) as exc:
            last = exc
            if attempt < DOWNLOAD_ATTEMPTS:
                time.sleep(attempt * 3)
    raise OSError(f"CNB tag 页拉取失败: {url}: {last}")


def _public_download_url(repository: str, tag: str, name: str) -> str:
    if str(RELEASE_DIR) not in sys.path:
        sys.path.insert(0, str(RELEASE_DIR))
    from cnb_release import public_download_url  # 延迟加载:顶层保持 stdlib
    return public_download_url(repository, tag, name)


def download_asset(repository: str, tag: str, asset: dict, dest: Path) -> None:
    """流式下载 + 单趟哈希(**先校验后消费**;坏下载绝不落终名)。"""
    url = _public_download_url(repository, tag, asset["name"])
    expected_sha = asset["hashValue"]
    expected_size = asset["sizeInByte"]
    if expected_size > MAX_ASSET_BYTES:
        raise ValueError(f"资产超出上限({expected_size} > {MAX_ASSET_BYTES}): {asset['name']}")
    temporary = dest.with_suffix(dest.suffix + ".downloading")
    last: Exception | None = None
    for attempt in range(1, DOWNLOAD_ATTEMPTS + 1):
        digest = hashlib.sha256()
        received = 0
        try:
            with _urlopen(url, timeout=600) as resp, open(temporary, "wb") as fh:
                while True:
                    chunk = resp.read(1 << 20)
                    if not chunk:
                        break
                    received += len(chunk)
                    if received > expected_size:
                        raise ValueError(f"下载超出声明大小: {asset['name']}")
                    digest.update(chunk)
                    fh.write(chunk)
            if received != expected_size:
                raise ValueError(f"大小不符: {asset['name']}(声明 {expected_size},实收 {received})")
            if digest.hexdigest() != expected_sha:
                raise ValueError(f"哈希不符: {asset['name']}(声明 {expected_sha},实测 {digest.hexdigest()})")
            temporary.replace(dest)
            return
        except (OSError, urllib.error.URLError, ValueError) as exc:
            temporary.unlink(missing_ok=True)
            last = exc
            if attempt < DOWNLOAD_ATTEMPTS:
                print(f"下载失败(第 {attempt}/{DOWNLOAD_ATTEMPTS} 次): {asset['name']}: {exc}——"
                      f"退避 {attempt * 5}s 后重试", file=sys.stderr)
                time.sleep(attempt * 5)
    raise OSError(f"资产下载失败: {asset['name']}: {last}")


# ---------------------------------------------------------------- 指针解析

def parse_catalog_pointer(raw: bytes) -> dict:
    """`medical-data-catalog-progress-*.json` → 验签指针载荷(base64 内嵌 JSON)。

    形状校验 fail-closed:缺任一关键字段即拒(指针是后续一切校验的锚)。
    """
    try:
        envelope = json.loads(raw)
        payload = json.loads(base64.b64decode(envelope["payload"]))
    except (ValueError, KeyError, TypeError) as exc:
        raise ValueError(f"指针文件形状非法: {exc}") from exc
    if not isinstance(payload, dict):
        raise ValueError("指针载荷不是 JSON 对象")
    for key in ("packageAssetName", "packageSha256", "sqliteSha256", "dataVersion",
                "contentSha256", "manifestSha256"):
        if not isinstance(payload.get(key), str) or not payload[key]:
            raise ValueError(f"指针载荷缺字段: {key}")
    # 包名内嵌两个 64hex:sqlite 明文 SHA 与密文 SHA——与载荷逐字交叉,先于任何下载暴露漂移。
    match = _PACKAGE_NAME.match(payload["packageAssetName"])
    if match is None:
        raise ValueError(f"包资产名不符文法: {payload['packageAssetName']}")
    if match.group(1) != payload["sqliteSha256"]:
        raise ValueError(f"包名内嵌 sqlite SHA 与载荷不符: {match.group(1)} != {payload['sqliteSha256']}")
    if match.group(2) != payload["packageSha256"]:
        raise ValueError(f"包名内嵌密文 SHA 与载荷不符: {match.group(2)} != {payload['packageSha256']}")
    return payload


def select_latest_catalog_asset(assets: list[dict]) -> dict:
    candidates = []
    for asset in assets:
        match = _CATALOG_NAME.match(asset["name"])
        if match:
            candidates.append((int(match.group(1)), match.group(2), asset))
    if not candidates:
        names = ", ".join(a["name"] for a in assets[:10])
        raise ValueError(f"tag 页无 medical-data-catalog-progress 资产(前 10:{names})")
    candidates.sort(key=lambda item: (item[0], item[1]))
    return candidates[-1][2]


# ---------------------------------------------------------------- 解密 + 解包

def decrypt_and_extract(cipher: Path, zip_path: Path, sqlite_out: Path, identity: str) -> None:
    """信封 → ZIP → 内层 SQLite。identity = 指针 sqliteSha256(信封 key/nonce 派生锚)。"""
    if str(RELEASE_DIR) not in sys.path:
        sys.path.insert(0, str(RELEASE_DIR))
    from asr_envelope import decrypt_package, is_envelope_file  # 延迟加载(需 cryptography)
    if not is_envelope_file(cipher):
        raise ValueError(f"密文前缀不是 VLASR 信封: {cipher}")
    master = bytes.fromhex(MEDICAL_PACKAGE_KEY_HEX)
    decrypt_package(master, identity, cipher, zip_path)
    import zipfile
    with zipfile.ZipFile(zip_path) as archive:
        names = [n for n in archive.namelist() if n.endswith(".sqlite")]
        if len(names) != 1:
            raise ValueError(f"包内 SQLite 条目不唯一: {archive.namelist()}")
        digest = hashlib.sha256()
        with archive.open(names[0]) as src, open(sqlite_out, "wb") as dst:
            while True:
                chunk = src.read(1 << 20)
                if not chunk:
                    break
                digest.update(chunk)
                dst.write(chunk)
    actual = digest.hexdigest()
    if actual != identity:
        sqlite_out.unlink(missing_ok=True)
        raise ValueError(f"内层 SQLite SHA-256 与指针不符:{actual} != {identity}(信封解密或包内容被篡改)")
    print(f"[ok] 内层 SQLite 校验通过: {names[0]} sha256={actual[:16]}…")


def _find_asset_by_embedded_sha(assets: list[dict], prefix: str, sha: str) -> dict | None:
    for asset in assets:
        if asset["name"].startswith(prefix) and sha in asset["name"]:
            return asset
    return None


# ---------------------------------------------------------------- 主流程

def run_remote(repository: str, tag: str, out_dir: Path, keep_intermediates: bool) -> dict:
    print(f"[fetch] tag 页: {repository} / {tag}")
    page = fetch_tag_page(repository, tag)
    assets = _prepare_asr_source().parse_cnb_tag_page(page, repository, tag)
    print(f"[fetch] 资产 {len(assets)} 件")

    pointer_asset = select_latest_catalog_asset(assets)
    work = out_dir / ".fetch-work"
    work.mkdir(parents=True, exist_ok=True)
    pointer_path = work / pointer_asset["name"]
    download_asset(repository, tag, pointer_asset, pointer_path)
    pointer = parse_catalog_pointer(pointer_path.read_bytes())
    print(f"[fetch] 指针:catalogVersion={pointer.get('catalogVersion')} dataVersion={pointer['dataVersion'][:16]}… "
          f"installable={pointer.get('installable')}")

    # 资产层与指针载荷的交叉校验(缺一件即拒):包 + 清单(+ 概览,可选)。
    by_name = {a["name"]: a for a in assets}
    package_asset = by_name.get(pointer["packageAssetName"])
    if package_asset is None:
        raise ValueError(f"tag 页缺少指针所指包资产: {pointer['packageAssetName']}")
    if package_asset["hashValue"] != pointer["packageSha256"]:
        raise ValueError("包资产页内哈希与指针不符")

    manifest_asset = _find_asset_by_embedded_sha(assets, "medical-data-manifest-", pointer["manifestSha256"])
    if manifest_asset is None:
        raise ValueError(f"tag 页缺少清单资产(sha={pointer['manifestSha256']})")

    overview_asset = None
    overviews = [a for a in assets if a["name"].startswith("medical-data-overview-")]
    if overviews:
        overviews.sort(key=lambda a: a["name"])
        overview_asset = overviews[-1]

    cipher = work / package_asset["name"]
    print(f"[fetch] 下载包 {package_asset['sizeInByte'] / 1048576:.0f} MiB …")
    download_asset(repository, tag, package_asset, cipher)

    zip_path = work / "package.zip"
    sqlite_out = out_dir / "catalog.sqlite"
    decrypt_and_extract(cipher, zip_path, sqlite_out, pointer["sqliteSha256"])

    if manifest_asset is not None:
        download_asset(repository, tag, manifest_asset, out_dir / "medical-data-manifest.json")
    if overview_asset is not None:
        download_asset(repository, tag, overview_asset, out_dir / "medical-data-overview.json")

    if not keep_intermediates:
        shutil.rmtree(work, ignore_errors=True)

    return {
        "mode": "cnb-release",
        "repository": repository,
        "tag": tag,
        "catalogVersion": pointer.get("catalogVersion"),
        "dataVersion": pointer["dataVersion"],
        "contentSha256": pointer["contentSha256"],
        "sqliteSha256": pointer["sqliteSha256"],
        "packageAssetName": pointer["packageAssetName"],
        "packageSha256": pointer["packageSha256"],
        "manifestSha256": pointer.get("manifestSha256"),
        "installable": pointer.get("installable"),
        "sqlitePath": str(sqlite_out),
        "licenses": {
            "TFDA": "藥品許可證資料集(OGDL v1 顯名聲明,三語)",
            "NHSA": "医保药品目录批次数据(官方接口频控纪律,见 lexicon-data-sources.md §2)",
            "HK": "data.gov.hk / HA 公開數據",
            "CN-REF": "国家卫健委/医保局公开目录",
        },
    }


def run_local(sqlite: Path, out_dir: Path) -> dict:
    target = out_dir / "catalog.sqlite"
    if sqlite.resolve() != target.resolve():
        shutil.copy2(sqlite, target)
    return {
        "mode": "local-sqlite",
        "note": "开发旁路:直接使用本机已解密目录(生产语料一律走 CNB Release,fetch_catalog.py 远端模式)",
        "sqlitePath": str(target),
        "sqliteSha256": sha256_file(target),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", default=DEFAULT_REPOSITORY)
    parser.add_argument("--tag", default=DEFAULT_TAG)
    parser.add_argument("--out-dir", type=Path, required=True)
    parser.add_argument("--local-sqlite", type=Path, default=None,
                        help="开发旁路:跳过网络,直接用本机目录 SQLite(仅本地原型期)")
    parser.add_argument("--keep-intermediates", action="store_true",
                        help="保留 .fetch-work/(密文+ZIP,供失败诊断;默认成功后清理)")
    args = parser.parse_args()

    args.out_dir.mkdir(parents=True, exist_ok=True)
    try:
        if args.local_sqlite is not None:
            descriptor = run_local(args.local_sqlite, args.out_dir)
        else:
            descriptor = run_remote(args.repository, args.tag, args.out_dir, args.keep_intermediates)
    except (OSError, ValueError, urllib.error.URLError) as exc:
        print(f"FAILED: {exc}", file=sys.stderr)
        return 1
    (args.out_dir / "source.json").write_text(
        json.dumps(descriptor, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(descriptor, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
