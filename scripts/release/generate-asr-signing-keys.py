#!/usr/bin/env python3
"""本地一次性 ASR 签名密钥生成（2026-10-05 业主指令）。

生成 root/catalog 两组 Ed25519 密钥，输出：
  --root-out   新信任根 envelope（自签，含全部公开密钥）——提交进仓库
               （Resources/ModelTrustRoot.json 与 ASRModelUpdates/N.root.json）
  --keys-out   私钥 JSON（注册为 GitHub Actions secret，如 ASR_SIGNING_KEYS_JSON）

私钥只落 --keys-out 一个文件；本脚本不打印、不落任何其它私钥副本。
信任链语义：根自签（rootThreshold 个 root 密钥），目录由 catalogThreshold 个
catalog 密钥签（sign-asr-catalog.py）。密钥轮换 = 新根（version+1）+ 新目录。
"""
import argparse
import base64
import json
import os
import sys
from datetime import datetime, timedelta, timezone

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

from asr_signing import b64, key_id, sign_envelope


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root-count", type=int, default=3)
    parser.add_argument("--catalog-count", type=int, default=3)
    parser.add_argument("--threshold", type=int, default=2)
    parser.add_argument("--root-version", type=int, required=True)
    parser.add_argument("--expires-at", default=None,
                        help="ISO UTC;缺省 = 当前时刻 + 730 天(2026-10-05 审查:旧硬编码默认"
                             "2028-09-11 过期后新根出生即失效,全目录被 App 拒绝)")
    parser.add_argument("--asset-base-url",
                        default="https://cnb.cool/robinhoo1973/Resources/-/releases/download/asr-models")
    parser.add_argument("--allowed-hosts", default="cnb.cool,asset.cnb.cool")
    parser.add_argument("--root-out", required=True)
    parser.add_argument("--keys-out", required=True)
    args = parser.parse_args()

    if args.threshold < 1 or args.threshold > min(args.root_count, args.catalog_count):
        parser.error("threshold must be 1..min(root-count, catalog-count)")

    expires_at = args.expires_at
    if expires_at is None:
        expires_at = (datetime.now(timezone.utc) + timedelta(days=730)).strftime("%Y-%m-%dT%H:%M:%SZ")
    if datetime.fromisoformat(expires_at.replace("Z", "+00:00")) <= datetime.now(timezone.utc):
        parser.error("--expires-at must be in the future (an already-expired root is rejected by every App)")

    root_keys = [Ed25519PrivateKey.generate() for _ in range(args.root_count)]
    catalog_keys = [Ed25519PrivateKey.generate() for _ in range(args.catalog_count)]
    keys_public = []
    for role, keys in (("root", root_keys), ("catalog", catalog_keys)):
        for key in keys:
            raw = key.public_key().public_bytes_raw()
            keys_public.append({"id": key_id(raw), "publicKey": b64(raw)})

    root_payload = {
        "schemaVersion": 1,
        "role": "root",
        "app": "vitaliber",
        "assetKind": "asr",
        "version": args.root_version,
        "expiresAt": expires_at,
        "keys": keys_public,
        "rootKeyIDs": [key_id(k.public_key().public_bytes_raw()) for k in root_keys],
        "rootThreshold": args.threshold,
        "catalogKeyIDs": [key_id(k.public_key().public_bytes_raw()) for k in catalog_keys],
        "catalogThreshold": args.threshold,
        "assetBaseURL": args.asset_base_url,
        "allowedHosts": args.allowed_hosts.split(","),
    }
    root_signers = [(key_id(k.public_key().public_bytes_raw()), k) for k in root_keys[: args.threshold]]
    root_envelope = sign_envelope(root_payload, root_signers)

    keys_out = {
        "root": [
            {"id": key_id(k.public_key().public_bytes_raw()),
             "privateKey": b64(k.private_bytes_raw())}
            for k in root_keys
        ],
        "catalog": [
            {"id": key_id(k.public_key().public_bytes_raw()),
             "privateKey": b64(k.private_bytes_raw())}
            for k in catalog_keys
        ],
    }

    root_path = args.root_out
    keys_path = args.keys_out
    with open(root_path, "w", encoding="utf-8") as f:
        json.dump(root_envelope, f, ensure_ascii=False, indent=1)
        f.write("\n")
    fd = os.open(keys_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(keys_out, f, ensure_ascii=False)
    print(f"root -> {root_path} (rootKeyIDs: {root_payload['rootKeyIDs'][:2]}…)")
    print(f"keys -> {keys_path} (chmod 600; register as GitHub secret, then shred local copy)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
