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
import json
import os
import sys
from datetime import datetime, timedelta, timezone

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

from asr_package import decode_json
from asr_signing import key_id, sign_envelope
from model_trust import verify_catalog


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
        catalog_keys[key_id(public_raw)] = private

    issued = args.issued_at
    if issued:
        issued_dt = datetime.fromisoformat(issued.replace("Z", "+00:00"))
    else:
        issued_dt = datetime.now(timezone.utc).replace(microsecond=0)
    # 归一 UTC(2026-10-05 审查):带显式偏移的输入此前被丢弃偏移、按墙钟时间
    # 硬标 Z——+08:00 输入会签发一个「未来 8 小时」的目录,App 侧
    # issued <= now+300s 直接判过期,新目录对所有设备即时失效。
    if issued_dt.tzinfo is None:
        issued_dt = issued_dt.replace(tzinfo=timezone.utc)
    issued_dt = issued_dt.astimezone(timezone.utc)
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

    # R3 签名闸(2026-10-05 审查):新目录必须携带能力数据面——families 段
    # 覆盖全部模型家族、每条目带 tierName/tierHint(App 下载页文案的唯一数据源)。
    # 旧目录的放行只存在于 verify 侧(历史 v4 冻结面),签名点一律拒绝缺数据
    # 的新目录,防止 R3 数据随模板漂移静默消失。2026-10-06 放宽:families
    # 多于模型集的部分仅允许 upcoming 标记(后期家族预告,validate_index 同闸)。
    index = payload["index"]
    ids = {m["id"] for m in index.get("models", [])}
    families = index.get("families")
    family_ids = {f.get("id") for f in families} if families else set()
    upcoming_ids = {f["id"] for f in families or [] if f.get("availability") == "upcoming"}
    if not families or not ids <= family_ids or not family_ids - ids <= upcoming_ids:
        print("ERROR: 新签名目录必须携带覆盖全部家族的 families 段", file=sys.stderr)
        return 2
    for model in index.get("models", []):
        if model.get("tierName") is None or model.get("tierHint") is None:
            print(f"ERROR: 条目 {model['id']} 缺 tierName/tierHint(下载页文案数据源)", file=sys.stderr)
            return 2

    root_envelope = decode_json(open(args.root, "rb").read())
    root_payload = decode_json(base64.b64decode(root_envelope["payload"]))
    allowed = set(root_payload.get("catalogKeyIDs", []))
    signers = [(identity, key) for identity, key in catalog_keys.items() if identity in allowed]
    threshold = root_payload.get("catalogThreshold", 2)
    if len(signers) < threshold:
        print(f"ERROR: 注入密钥中命中 catalogKeyIDs 的不足阈值 {threshold}", file=sys.stderr)
        return 2
    envelope = sign_envelope(payload, signers[:threshold])

    # 包级签名(2026-10-06 业主指令:zip 文件也需要签名验证)——逐条目对包
    # sha256 摘要做域分离 Ed25519 多重签名,签名密钥与目录信封同源
    # (catalogKeyIDs,阈值同 catalogThreshold)。App 下载后重算 sha256,
    # 先验摘要签名(防伪造哈希绑定)再比对摘要——与目录信封构成双链。
    for model in payload["index"].get("models", []):
        digest = bytes.fromhex(model["sha256"])
        message = b"vitaliber/asr/package-sha256/v1/" + digest
        model["packageSignature"] = {
            "scheme": "ed25519-sha256-v1",
            "signatures": [
                {"keyId": identity, "value": b64(key.sign(message))}
                for identity, key in signers[:threshold]
            ],
        }

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
