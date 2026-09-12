#!/usr/bin/env python3
"""Real Ed25519 fixtures test authorization, not a mocked signature verifier."""
import base64
from datetime import datetime, timedelta, timezone
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
import yaml

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey


TOOLS = Path(__file__).resolve().parent


def envelope(payload, signers):
    data = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()
    return {"payload": base64.b64encode(data).decode(), "signatures": [
        {"keyId": identity, "signature": base64.b64encode(key.sign(data)).decode()} for identity, key in signers
    ]}


class TrustTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.keys = []
        public = []
        for _ in range(6):
            key = Ed25519PrivateKey.generate()
            raw = key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
            identity = hashlib.sha256(raw).hexdigest()
            self.keys.append((identity, key))
            public.append({"id": identity, "publicKey": base64.b64encode(raw).decode()})
        now = datetime.now(timezone.utc).replace(microsecond=0)
        date = lambda value: value.isoformat().replace("+00:00", "Z")
        self.root_payload = {"schemaVersion": 1, "role": "root", "app": "vitaliber", "assetKind": "asr", "version": 1,
                             "expiresAt": date(now + timedelta(days=730)), "keys": public,
                             "rootKeyIDs": [k[0] for k in self.keys[:3]], "rootThreshold": 2,
                             "catalogKeyIDs": [k[0] for k in self.keys[3:]], "catalogThreshold": 2,
                             "assetBaseURL": "https://github.com/robinhoo1973/Vita-Liber/releases/download/asr-models",
                             "allowedHosts": ["github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"]}
        index = {"schemaVersion": 1, "app": "vitaliber", "assetKind": "asr", "baseUrl": self.root_payload["assetBaseURL"],
                 "models": [{"id": m, "version": "1.0.0", "url": m + ".zip", "bytes": 123, "sha256": "a" * 64,
                             "expandedBytes": 456, "packaging": "zip", "minAppVersion": "0.0.1", "runtime": "sherpa-onnx-1.13.4",
                             "license": "MIT" if m == "whisper" else "Apache-2.0"}
                            for m in ["qwen3", "zipformer", "dolphin", "whisper"]]}
        self.catalog_payload = {"schemaVersion": 1, "role": "catalog", "app": "vitaliber", "assetKind": "asr",
                                "rootVersion": 1, "catalogVersion": 3, "issuedAt": date(now - timedelta(minutes=1)),
                                "expiresAt": date(now + timedelta(days=29)), "index": index, "revokedHashes": []}
        self.write("root.json", envelope(self.root_payload, self.keys[:2]))

    def write(self, name, value):
        path = self.root / name
        path.write_text(json.dumps(value))
        return path

    def verify(self, value, *extra):
        catalog = self.write("catalog.json", value)
        return subprocess.run(["python3", str(TOOLS / "model-trust.py"), "verify", "--root", str(self.root / "root.json"),
                               "--catalog", str(catalog), *extra], text=True, capture_output=True)

    def test_two_distinct_authorized_signatures_accept(self):
        result = self.verify(envelope(self.catalog_payload, self.keys[3:5]))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_duplicate_signer_cannot_meet_threshold(self):
        result = self.verify(envelope(self.catalog_payload, [self.keys[3], self.keys[3]]))
        self.assertNotEqual(result.returncode, 0)

    def test_tampered_payload_is_rejected(self):
        signed = envelope(self.catalog_payload, self.keys[3:5])
        self.catalog_payload["index"]["models"][0]["sha256"] = "b" * 64
        signed["payload"] = base64.b64encode(json.dumps(self.catalog_payload).encode()).decode()
        self.assertNotEqual(self.verify(signed).returncode, 0)

    def test_root_keys_cannot_sign_catalog(self):
        self.assertNotEqual(self.verify(envelope(self.catalog_payload, self.keys[:2])).returncode, 0)

    def test_expired_or_wrong_scope_or_bad_budget_rejected(self):
        for field, value in (("expiresAt", "2000-01-01T00:00:00Z"), ("app", "another-app"), ("rootVersion", 2)):
            with self.subTest(field=field):
                changed = dict(self.catalog_payload, **{field: value})
                self.assertNotEqual(self.verify(envelope(changed, self.keys[3:5])).returncode, 0)
        self.catalog_payload["index"]["models"][0]["bytes"] = 10**15
        self.assertNotEqual(self.verify(envelope(self.catalog_payload, self.keys[3:5])).returncode, 0)

    def test_rollback_and_same_version_equivocation_rejected(self):
        prior = self.write("prior.json", envelope(self.catalog_payload, self.keys[3:5]))
        changed = dict(self.catalog_payload, catalogVersion=2)
        result = self.verify(envelope(changed, self.keys[3:5]), "--previous-catalog", str(prior))
        self.assertNotEqual(result.returncode, 0)
        changed = dict(self.catalog_payload, revokedHashes=["b" * 64])
        self.assertNotEqual(self.verify(envelope(changed, self.keys[3:5]), "--previous-catalog", str(prior)).returncode, 0)

    def test_build_baseline_contains_signed_compatibility(self):
        catalog = self.write("catalog.json", envelope(self.catalog_payload, self.keys[3:5]))
        output = self.root / "generated.json"
        result = subprocess.run(["python3", str(TOOLS / "model-trust.py"), "build", "--root", str(self.root / "root.json"),
                                 "--catalog", str(catalog), "--output", str(output)], text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        baseline = json.loads(output.read_text())
        self.assertEqual(len(baseline["entries"]), 4)
        self.assertEqual(baseline["entries"][0]["sha256"], "a" * 64)
        self.assertEqual(baseline["entries"][0]["minAppVersion"], "0.0.1")
        self.assertEqual(baseline["catalogVersion"], 3)

    def test_project_build_generates_and_embeds_the_baseline(self):
        resources = self.root / "Resources"
        resources.mkdir()
        shutil.copyfile(self.root / "root.json", resources / "ModelTrustRoot.json")
        downloads = resources / "ASRModelUpdates"
        downloads.mkdir(parents=True)
        (downloads / "catalog.json").write_text(json.dumps(envelope(self.catalog_payload, self.keys[3:5])))
        (downloads / "index.json").write_text(json.dumps(self.catalog_payload["index"]))
        helpers = self.root / ".github/workflows"
        helpers.mkdir(parents=True)
        for name in ("model-trust.py", "model_trust.py", "asr_package.py"):
            shutil.copyfile(TOOLS / name, helpers / name)
        derived = self.root / "derived"
        bundle = self.root / "build/Example.app"
        bundle.mkdir(parents=True)
        project = yaml.safe_load((TOOLS.parents[1] / "project.yml").read_text())
        target = project["targets"]["VitaLiber"]
        env = dict(os.environ, SRCROOT=str(self.root), DERIVED_FILE_DIR=str(derived),
                   TARGET_BUILD_DIR=str(bundle.parent), UNLOCALIZED_RESOURCES_FOLDER_PATH=bundle.name,
                   MODEL_PYTHON=sys.executable)
        result = subprocess.run(["bash", "-e"], input=target["preBuildScripts"][0]["script"],
                                text=True, capture_output=True, env=env)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        embed = next(s for s in target["postBuildScripts"] if s["name"] == "Embed generated model trust")
        copied = subprocess.run(["bash", "-e"], input=embed["script"], text=True, capture_output=True, env=env)
        self.assertEqual(copied.returncode, 0, copied.stdout + copied.stderr)
        data = json.loads((bundle / "TrustedModelHashes.json").read_text())
        self.assertEqual(data["catalogVersion"], 3)
        self.assertEqual(len(data["entries"]), 4)


if __name__ == "__main__":
    unittest.main()
