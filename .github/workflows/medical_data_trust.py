#!/usr/bin/env python3
"""Create a medical-data Ed25519 catalog envelope using the shared trust format."""
import argparse
import base64
from datetime import datetime, timedelta, timezone
import json
from pathlib import Path
import sys

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

from model_trust import trusted_root


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


def sign_envelope(payload_value, signers):
    data = canonical(payload_value)
    return {
        "payload": base64.b64encode(data).decode(),
        "signatures": [
            {"keyId": key_id, "signature": base64.b64encode(key.sign(data)).decode()}
            for key_id, key in signers
        ],
    }


def iso_now():
    return datetime.now(timezone.utc).replace(microsecond=0)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("sign", choices=["sign"])
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--keys", type=Path, required=True,
                        help="JSON: {\"keys\":[{\"keyId\":hex,\"privateKey\":base64-32-byte-seed}]} ")
    parser.add_argument("--content-sha256", required=True)
    parser.add_argument("--manifest-sha256", required=True)
    parser.add_argument("--release-tag", required=True)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        root_envelope = json.loads(args.root.read_text())
        root = trusted_root(root_envelope, asset_kind="medical-data")
        key_doc = json.loads(args.keys.read_text())
        private_by_id = {}
        for item in key_doc["keys"]:
            raw = base64.b64decode(item["privateKey"], validate=True)
            if len(raw) != 32:
                raise ValueError("medical signing privateKey must be a 32-byte Ed25519 seed")
            private_by_id[item["keyId"]] = Ed25519PrivateKey.from_private_bytes(raw)
        signers = [(key_id, private_by_id[key_id]) for key_id in root["catalogKeyIDs"] if key_id in private_by_id]
        if len(signers) < root["catalogThreshold"]:
            raise ValueError("not enough medical catalog signing keys supplied")
        now = iso_now()
        payload_value = {
            "schemaVersion": 1,
            "role": "catalog",
            "app": "vitaliber",
            "assetKind": "medical-data",
            "rootVersion": root["version"],
            "catalogVersion": int(now.timestamp()),
            "issuedAt": now.isoformat().replace("+00:00", "Z"),
            "expiresAt": (now + timedelta(days=31)).isoformat().replace("+00:00", "Z"),
            "contentSha256": args.content_sha256,
            "manifestSha256": args.manifest_sha256,
            "releaseTag": args.release_tag,
            "repository": args.repository,
        }
        envelope = sign_envelope(payload_value, signers[:root["catalogThreshold"]])
        args.output.parent.mkdir(parents=True, exist_ok=True)
        tmp = args.output.with_suffix(".tmp")
        tmp.write_text(json.dumps(envelope, sort_keys=True, separators=(",", ":")) + "\n")
        tmp.replace(args.output)
        print(f"MEDICAL-DATA-TRUST-OK: root={root['version']} catalog={payload_value['catalogVersion']}")
        return 0
    except (OSError, ValueError, KeyError, TypeError, json.JSONDecodeError) as error:
        print(f"MEDICAL-DATA-TRUST-ERROR: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
