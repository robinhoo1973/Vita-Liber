#!/usr/bin/env python3
"""签名 ASR 目录 envelope（CI 或本地；密钥经 env ASR_SIGNING_KEYS_JSON 注入）。

输入 = 已构建索引（CI build-asr-packages 产物 index.json）；输出 = 签名目录
envelope。签完即用 model_trust.verify_catalog 公开路径自校验（fail 即非零退出），
保证「签名必可验」——与 model-trust.py verify 同闸。

用法：
  ASR_SIGNING_KEYS_JSON="$(cat keys.json)" python3 scripts/release/sign-asr-catalog.py \
      --root Resources/ModelTrustRoot.json \
      --index "$RUNNER_TEMP/asr-packages/index.json" \
      --root-version 2 --catalog-version 4 --output /tmp/catalog.json
"""
import argparse
import base64
import hashlib
import json
import os
import sys
from datetime import datetime, timedelta, timezone

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

from model_trust import decode_json, json_bytes, verify_catalog


def b64(data: bytes) -> str:
    return base64.b64encode(data).decode()


def sign_envelope(payload: dict, signers) -> dict:
    raw = json_bytes(payload)
    return {
        "payload": b64(raw),
        "signatures": [{"keyId": identity, "signature": b64(key.sign(raw))}
                       for identity, key in signers],
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", required=True)
    parser.add_argument("--index", required=True)
    parser.add_argument("--root-version", type=int, required=True)
    parser.add_argument("--catalog-version", type=int, required=True)
    parser.add_argument("--issued-at", default=None,
                        help="ISO UTC；缺省 = 当前时刻")
    parser.add_argument("--valid-days", type=int, default=30)
    parser.add_argument("--revoked", default="[]", help="JSON 字符串数组")
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    keys_json = os.environ.get("ASR_SIGNING_KEYS_JSON")
    if not keys_json:
        print("ERROR: ASR_SIGNING_KEYS_JSON 未注入", file=sys.stderr)
        return 2
    keys = json.loads(keys_json)
    catalog_keys = {}
    for entry in keys.get("catalog", []):
        raw = base64.b64decode(entry["privateKey"])
        private = Ed25519PrivateKey.from_private_bytes(raw)
        public_raw = private.public_key().public_bytes_raw()
        catalog_keys[hashlib.sha256(public_raw).hexdigest()] = private

    issued = args.issued_at
    if issued:
        issued_dt = datetime.fromisoformat(issued.replace("Z", "+00:00"))
    else:
        issued_dt = datetime.now(timezone.utc).replace(microsecond=0)
    payload = {
        "schemaVersion": 1,
        "role": "catalog",
        "app": "vitaliber",
        "assetKind": "asr",
        "catalogVersion": args.catalog_version,
        "issuedAt": issued_dt.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "expiresAt": (issued_dt + timedelta(days=args.valid_days)).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "rootVersion": args.root_version,
        "index": decode_json(open(args.index, "rb").read()),
        "revokedHashes": json.loads(args.revoked),
    }

    root_envelope = decode_json(open(args.root, "rb").read())
    root_payload = decode_json(base64.b64decode(root_envelope["payload"]))
    allowed = set(root_payload.get("catalogKeyIDs", []))
    signers = [(identity, key) for identity, key in catalog_keys.items() if identity in allowed]
    threshold = root_payload.get("catalogThreshold", 2)
    if len(signers) < threshold:
        print(f"ERROR: 注入密钥中命中 catalogKeyIDs 的不足阈值 {threshold}", file=sys.stderr)
        return 2
    envelope = sign_envelope(payload, signers[:threshold])

    with open(args.output, "w", encoding="utf-8") as f:
        json.dump(envelope, f, ensure_ascii=False, indent=1)
        f.write("\n")
    # 自校验：与 CI verify 同一公开闸
    verify_catalog(root_envelope, envelope, previous=None, asset_kind="asr")
    print(f"catalog signed: version={payload['catalogVersion']} "
          f"rootVersion={payload['rootVersion']} entries={len(payload['index'].get('models', []))}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
