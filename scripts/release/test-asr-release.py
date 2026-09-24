#!/usr/bin/env python3
import json
import os
from pathlib import Path
import runpy
import subprocess
import tempfile
import unittest

TOOL = Path(__file__).with_name("publish-asr-release.py")


class PublicationTests(unittest.TestCase):
    def plan(self, assets):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            index = {"schemaVersion": 1, "app": "vitaliber", "assetKind": "asr", "models": [
                {"id": m, "version": "1.0.0", "url": m + ".zip", "bytes": 123, "sha256": "a" * 64,
                 "license": "MIT" if m == "whisper" else "Apache-2.0"}
                for m in ["qwen3", "zipformer", "dolphin", "whisper"]]}
            (root / "index.json").write_text(json.dumps(index))
            (root / "assets.json").write_text(json.dumps(assets))
            return subprocess.run(["python3", str(TOOL), "plan", "--index", str(root / "index.json"),
                                   "--assets", str(root / "assets.json")], text=True, capture_output=True)

    def test_all_missing_packages_are_uploaded(self):
        result = self.plan([])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {"qwen3.zip": "upload", "zipformer.zip": "upload",
                                                   "dolphin.zip": "upload", "whisper.zip": "upload"})

    def test_same_content_is_reused(self):
        result = self.plan([{"name": "qwen3.zip", "size": 123, "digest": "sha256:" + "a" * 64}])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["qwen3.zip"], "reuse")

    def test_same_name_different_content_is_never_overwritten(self):
        for size, digest in ((124, "a" * 64), (123, "b" * 64)):
            with self.subTest(size=size):
                result = self.plan([{"name": "qwen3.zip", "size": size, "digest": "sha256:" + digest}])
                self.assertNotEqual(result.returncode, 0)

    def test_missing_server_digest_requires_download_verification(self):
        result = self.plan([{"name": "qwen3.zip", "size": 123, "digest": None}])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["qwen3.zip"], "verify")

    def test_first_draft_publication_and_retry(self):
        package_type = runpy.run_path(str(TOOL.with_name("test-asr-package-integrity.py")))["PackageTests"]
        trust_module = runpy.run_path(str(TOOL.with_name("test-model-trust.py")))
        packages = package_type()
        packages.setUp()
        self.addCleanup(packages.doCleanups)
        index = packages.built_index()
        trust = trust_module["TrustTests"]()
        trust.setUp()
        self.addCleanup(trust.doCleanups)
        trust.root_payload["assetBaseURL"] = index["baseUrl"]
        trust.catalog_payload["index"] = index
        sign = trust_module["envelope"]
        root_file = trust.write("1.root.json", sign(trust.root_payload, trust.keys[:2]))
        catalog_file = trust.write("catalog.json", sign(trust.catalog_payload, trust.keys[3:5]))
        binaries = trust.root / "bin"
        binaries.mkdir()
        remote = trust.root / "remote"
        remote.mkdir()
        state_file = trust.root / "state.json"
        state_file.write_text(json.dumps({"created": 0, "release": None, "assets": []}))
        fake = binaries / "gh"
        fake.write_text('''#!/usr/bin/env python3
import hashlib, json, os, pathlib, shutil, sys
a=sys.argv[1:]; state_path=pathlib.Path(os.environ["GH_FIXTURE_STATE"])
s=json.loads(state_path.read_text()); remote=pathlib.Path(os.environ["GH_FIXTURE_REMOTE"])
def save(): state_path.write_text(json.dumps(s))
def missing():
    print("gh: Not Found (HTTP 404)", file=sys.stderr); sys.exit(1)
if a[0] == "api":
    if "/releases/tags/" in a[1]:
        if not s["release"] or s["release"]["draft"]: missing()
        print(json.dumps(s["release"]))
    elif "/assets?" in a[1]: print(json.dumps([s["assets"]]))
    else: raise SystemExit("Unexpected API: " + str(a))
elif a[:2] == ["release", "view"]:
    if not s["release"]:
        print("release not found", file=sys.stderr); sys.exit(1)
    print(json.dumps({"databaseId":123,"isDraft":s["release"]["draft"],"url":"https://github.com/fixture/app/releases/tag/asr-models"}))
elif a[:2] == ["release", "create"]:
    if s["release"]: raise SystemExit("Duplicate creation")
    s["created"] += 1; s["release"]={"id":123,"draft":True}; save()
elif a[:2] == ["release", "upload"]:
    p=pathlib.Path(a[3]); data=p.read_bytes(); shutil.copyfile(p, remote/p.name)
    s["assets"]=[x for x in s["assets"] if x["name"] != p.name]
    s["assets"].append({"name":p.name,"size":len(data),"digest":"sha256:"+hashlib.sha256(data).hexdigest()}); save()
elif a[:2] == ["release", "download"]:
    name=a[a.index("--pattern")+1]; dest=pathlib.Path(a[a.index("--dir")+1]); shutil.copyfile(remote/name,dest/name)
elif a[:2] == ["release", "edit"]:
    s["release"]["draft"]=False; save()
else: raise SystemExit("Unexpected gh command: " + str(a))
''')
        fake.chmod(0o755)
        env = dict(os.environ, PATH=f"{binaries}:{os.environ['PATH']}", GH_FIXTURE_STATE=str(state_file), GH_FIXTURE_REMOTE=str(remote))
        args = ["python3", str(TOOL), "publish", "--index", str(packages.output / "index.json"),
                "--directory", str(packages.output), "--root", str(root_file), "--catalog", str(catalog_file),
                "--repository", "fixture/app", "--target", "a" * 40]
        for _ in range(2):
            result = subprocess.run(args, env=env, text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        state = json.loads(state_file.read_text())
        self.assertEqual(state["created"], 1)
        self.assertFalse(state["release"]["draft"])
        self.assertTrue({m["url"] for m in index["models"]}.issubset({a["name"] for a in state["assets"]}))


if __name__ == "__main__":
    unittest.main()
