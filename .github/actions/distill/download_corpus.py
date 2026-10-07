#!/usr/bin/env python3
"""Release 资产下载 + 校验 + age 解密 + SQLite 闸 + 源适配层归一(计划文档 §7.6)。

- 正式路径:--assets-json(逐资产 {url, sha256})下载 → sha256 校验(fail-closed)
  → age 解密(--age-identity,--age-binary;缺任一即失败,绝不静默跳过)
  → load_sqlite_v4 schema 闸 → 输出归一描述 JSON。
- P1 原型路径:--local-jsonl(dev 侧实测件;仅 P1 金样原型期,正式语料一律 Release 化,
  见计划文档 §7.6 唯一来源纪律)。
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import urllib.request
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from corpus.manifest import sha256_file as _sha256  # noqa: E402 单一实现,禁止第三份拷贝
from entlink.catalog import load_sqlite_v4  # noqa: E402

_DOWNLOAD_ATTEMPTS = 3


def _download(url: str, dest: Path) -> None:
    """下载资产,带有限重试(网络抖动/临时代理 5xx 不判死刑)。

    重试归属 CLI 层而非 workflow 层:YAML 表达不了有界重试,且只有检测到
    竞态/抖动的这一层才持有上下文(历史教训:错误信息声称「重试由 workflow
    层负责」但 workflow 从未实现,一次抖动 = 整个 dispatch 红)。
    """
    import time

    last: Exception | None = None
    for attempt in range(1, _DOWNLOAD_ATTEMPTS + 1):
        try:
            with urllib.request.urlopen(url, timeout=300) as resp, open(dest, "wb") as fh:
                shutil.copyfileobj(resp, fh)
            return
        except OSError as exc:
            last = exc
            if attempt < _DOWNLOAD_ATTEMPTS:
                print(f"下载失败(第 {attempt}/{_DOWNLOAD_ATTEMPTS} 次): {url}: {exc}——"
                      f"退避 {attempt * 5}s 后重试", file=sys.stderr)
                time.sleep(attempt * 5)
    raise last  # type: ignore[misc]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--assets-json", type=Path, default=None,
                        help='JSON 列表:[{"url": ..., "sha256": ..., "encrypted": true, "kind": "catalog-sqlite"}]')
    parser.add_argument("--age-identity", type=Path, default=None)
    parser.add_argument("--age-binary", default="age")
    parser.add_argument("--out-dir", type=Path, required=True)
    parser.add_argument("--local-jsonl", default=None,
                        help="P1 原型期:domain=path 列表(正式语料一律 Release 化)")
    args = parser.parse_args()

    args.out_dir.mkdir(parents=True, exist_ok=True)
    if (args.assets_json is None) == (args.local_jsonl is None):
        parser.error("须且仅须提供 --assets-json 或 --local-jsonl 之一")

    if args.local_jsonl is not None:
        domains = {}
        for pair in args.local_jsonl.split(","):
            domain, path = pair.split("=", 1)
            domains[domain] = str(path)
        descriptor = {
            "mode": "local-jsonl-p1-prototype",
            "note": "仅 P1 金样原型期;正式语料一律 Release 化(计划文档 §7.6)",
            "domains": domains,
        }
        (args.out_dir / "source.json").write_text(json.dumps(descriptor, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        print(json.dumps(descriptor, ensure_ascii=False, indent=2))
        return 0

    raw = json.loads(args.assets_json.read_text(encoding="utf-8"))
    # 兼容两种形态:裸列表,或带 _comment 的对象 {"_comment": [...], "assets": [...]}
    # (仓内 .github/actions/distill/assets.json 即对象形态;历史教训:CLI 只认裸列表,
    # 模板文件填了真值也永远走不通)。
    if isinstance(raw, dict):
        raw = raw.get("assets")
    assets = raw
    if not isinstance(assets, list) or not assets:
        print("FAILED: --assets-json 必须是非空资产列表(仓内模板 assets.json "
              "为空是 P1 fail-closed 设计行为,填真实值后重跑)", file=sys.stderr)
        return 1
    descriptor = {"mode": "release", "assets": []}
    with tempfile.TemporaryDirectory() as tmp:
        tmp_path = Path(tmp)
        for idx, asset in enumerate(assets):
            url, expected = asset.get("url"), asset.get("sha256")
            if not url or not expected:
                print(f"FAILED: 资产 {idx} 缺 url/sha256", file=sys.stderr)
                return 1
            raw = tmp_path / f"asset-{idx}.bin"
            try:
                _download(url, raw)
            except OSError as exc:
                print(f"FAILED: 下载 {url}: {exc}", file=sys.stderr)
                return 1
            actual = _sha256(raw)
            if actual != expected:
                print(f"FAILED: sha256 不符 {url}\n  expected={expected}\n  actual  ={actual}\n  "
                      f"fail-closed:sha256 覆盖**下载到的密文**(先校验后解密);"
                      f"重传竞态(legacy --clobber)下改资产即红,由重跑 dispatch 恢复",
                      file=sys.stderr)
                return 1
            out_path = raw
            if asset.get("encrypted"):
                if args.age_identity is None or not Path(args.age_identity).exists():
                    print("FAILED: 加密资产缺 age identity(公开仓 release 环境注入,计划文档 §7.6 开口项①)",
                          file=sys.stderr)
                    return 1
                age_bin = shutil.which(args.age_binary)
                if age_bin is None:
                    print(f"FAILED: 未找到 age 二进制({args.age_binary})", file=sys.stderr)
                    return 1
                out_path = tmp_path / f"asset-{idx}.plain"
                try:
                    result = subprocess.run(
                        [age_bin, "-d", "-i", str(args.age_identity), "-o", str(out_path), str(raw)],
                        capture_output=True, text=True, timeout=1800)
                except subprocess.TimeoutExpired:
                    print("FAILED: age 解密超时(1800s)——挂死会拖满 job 级 6h 上限", file=sys.stderr)
                    return 1
                if result.returncode != 0:
                    print(f"FAILED: age 解密失败: {result.stderr.strip()}", file=sys.stderr)
                    return 1
            if asset.get("kind") == "catalog-sqlite":
                catalog = load_sqlite_v4(out_path)  # schema 闸 fail-closed
                shutil.copy2(out_path, args.out_dir / "catalog.sqlite")  # 解密产物落盘供下游
                descriptor["catalog"] = {
                    "path": str(args.out_dir / "catalog.sqlite"),
                    "data_version": catalog.data_version,
                    "stats": catalog.stats(),
                }
            descriptor["assets"].append({"index": idx, "url": url, "sha256": expected,
                                         "encrypted": bool(asset.get("encrypted")), "kind": asset.get("kind")})
    (args.out_dir / "source.json").write_text(json.dumps(descriptor, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(descriptor, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
