#!/usr/bin/env python3
"""T2 本机 LLM 模型取模脚本（业主 2026-09-17 定：llama 模型随包内置）。

读取 `Resources/LLMModels/catalog.json`，缺失或哈希不符时从 source 下载
（HuggingFace resolve 直链），逐字节校验 sha256 与体积后落位
`Resources/LLMModels/<fileName>`。任何校验失败即非零退出——绝不把
未校验的模型文件放进 bundle（与 ASR 发布管线同纪律：哈希先行、失败响亮）。

用法：python3 materialize-llama-model.py [--force]
  --force  即使文件已存在且哈希一致也重新下载
CI 与本地同源：xcodebuild 前跑一次；GitHub Actions 可用 actions/cache
缓存 Resources/LLMModels 目录（键 = catalog.json 的 sha256）。
"""
import argparse
import hashlib
import json
import sys
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CATALOG = ROOT / "Resources" / "LLMModels" / "catalog.json"
CHUNK = 1024 * 1024


def fail(message: str) -> "NoReturn":
    print(f"FAIL: {message}", file=sys.stderr)
    sys.exit(1)


def sha256_of(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as fh:
        while chunk := fh.read(CHUNK):
            digest.update(chunk)
    return digest.hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args()

    if not CATALOG.exists():
        fail(f"catalog 缺失：{CATALOG}")

    try:
        catalog = json.loads(CATALOG.read_text())
    except json.JSONDecodeError as exc:
        fail(f"catalog 非法 JSON：{exc}")
    models = catalog.get("models") or []
    if not models:
        fail("catalog.models 为空——判定器失效，不得判 PASS")

    for entry in models:
        name = entry["fileName"]
        expected_sha = entry["sha256"]
        expected_bytes = int(entry["bytes"])
        target = ROOT / "Resources" / "LLMModels" / name

        if target.exists() and not args.force:
            actual = sha256_of(target)
            if actual == expected_sha and target.stat().st_size == expected_bytes:
                print(f"PASS: {name} 已就绪（sha256 一致，{expected_bytes} 字节）")
                continue
            fail(f"{name} 哈希不符：期望 {expected_sha}，实际 {actual}——删除后重跑")

        target.parent.mkdir(parents=True, exist_ok=True)
        tmp = target.with_suffix(target.suffix + ".download")
        print(f"下载 {entry['source']} → {target}（{expected_bytes} 字节）")
        try:
            urllib.request.urlretrieve(entry["source"], tmp)
        except Exception as exc:  # 网络层失败如实报错
            tmp.unlink(missing_ok=True)
            fail(f"下载失败：{exc}")

        if tmp.stat().st_size != expected_bytes:
            tmp.unlink(missing_ok=True)
            fail(f"体积不符：期望 {expected_bytes}，实际 {tmp.stat().st_size}")
        actual = sha256_of(tmp)
        if actual != expected_sha:
            tmp.unlink(missing_ok=True)
            fail(f"sha256 不符：期望 {expected_sha}，实际 {actual}")
        tmp.rename(target)
        print(f"PASS: {name} 已落位并校验通过")


if __name__ == "__main__":
    main()
