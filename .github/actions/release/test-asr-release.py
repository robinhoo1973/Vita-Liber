#!/usr/bin/env python3
"""Offline publisher tests: the ASR release pipeline writes only to a CNB Release.

2026-10-03 plan Task 3: `publish(args, client)` accepts an injected CNB client;
the GitHub `gh` wrapper is gone entirely. No network access is performed.
"""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import runpy
import subprocess
import tempfile
import unittest
from types import SimpleNamespace

from cnb_release import CNBReleaseError

TOOL = Path(__file__).with_name("publish-asr-release.py")
CNB_BASE = "https://cnb.cool/robinhoo1973/Resources/-/releases/download/asr-models"
VARIANTS = {"qwen3": "medium", "zipformer": "large", "dolphin": "small", "whisper": "small",
            "sense-voice": "small", "fire-red": "large", "moonshine": "base"}


class FakeCNBReleaseClient:
    """Stateful fake: uploads are recorded only on real uploads, not on reuse."""

    def __init__(self, downloads=None):
        self.uploads = []
        self.assets = []
        self.downloads = downloads or {}
        self.readme_sync_calls = []
        self.release_body_updates = []
        # 冷启动语义（2026-10-07 CI 37619255618 实证）：真实 CNBReleaseClient
        # 在 Release 缺失时 list_assets 硬错；发布器首位幂等 ensure_release。
        # 既有用例默认「Release 已存在」；冷启动回归用例显式置 False。
        self.release_exists = True
        self.release_creations = []
        self.call_log = []

    def start_readme_sync(self, tag):
        self.readme_sync_calls.append(tag)
        return {"sn": "fixture-sn", "buildLogUrl": "https://cnb.cool/fixture-build"}

    def readme_sync_status(self, sn):
        self.readme_sync_status_calls = getattr(self, "readme_sync_status_calls", [])
        self.readme_sync_status_calls.append(sn)
        return {"sn": sn, "status": "success"}

    def update_release_body(self, tag, body):
        self.release_body_updates.append((tag, body))

    def ensure_release(self, tag, title, body):
        self.call_log.append("ensure_release")
        if self.release_exists:
            return {"id": "fixture-release", "tag_name": tag}
        self.release_exists = True
        self.release_creations.append((tag, title, body))
        return {"id": "fixture-release", "tag_name": tag}

    def list_assets(self, tag):
        if not self.release_exists:
            raise RuntimeError("CNB release does not exist: " + tag)
        self.call_log.append("list_assets")
        return [{"name": a["name"], "size": a["size"], "hash_algo": "sha256", "hash_value": a["sha256"],
                 "path": "/robinhoo1973/Resources/-/releases/download/" + tag + "/" + a["name"]}
                for a in self.assets]

    def upload_immutable(self, tag, path, asset_name, expected_sha256, overwrite=False):
        self.call_log.append("upload:" + asset_name)
        payload = Path(path).read_bytes()
        digest = hashlib.sha256(payload).hexdigest()
        if digest != expected_sha256:
            raise RuntimeError("digest mismatch for " + asset_name)
        for asset in self.assets:
            if asset["name"] == asset_name:
                if asset["sha256"] == digest and asset["size"] == len(payload):
                    return SimpleNamespace(name=asset_name, size=len(payload), sha256=digest)
                if not overwrite:
                    raise RuntimeError("collision for " + asset_name)
                # 2026-10-05 审查:发布路径以 overwrite=True 更新同名异内容
                # 模型资产(业主 R2:不同才更新上传)。
                asset["sha256"] = digest
                asset["size"] = len(payload)
                asset["content"] = payload
                self.uploads.append((asset_name, digest))
                return SimpleNamespace(name=asset_name, size=len(payload), sha256=digest)
        self.assets.append({"name": asset_name, "size": len(payload), "sha256": digest, "content": payload})
        self.uploads.append((asset_name, digest))
        return SimpleNamespace(name=asset_name, size=len(payload), sha256=digest)

    def download_asset(self, tag, asset_name, destination, max_bytes):
        if asset_name in self.downloads:
            data = self.downloads[asset_name]
        else:
            data = next((a["content"] for a in self.assets if a["name"] == asset_name), None)
        if data is None:
            raise RuntimeError("missing fixture download: " + asset_name)
        if len(data) > max_bytes:
            raise RuntimeError("fixture download exceeds bound: " + asset_name)
        Path(destination).write_bytes(data)
        return Path(destination)


def make_signed_asr_fixture(directory):
    """Signed root/catalog + verified packages, all pinned to the CNB resource base."""
    directory = Path(directory)
    packages_module = runpy.run_path(str(TOOL.with_name("test-asr-package-integrity.py")))
    trust_module = runpy.run_path(str(TOOL.with_name("test-model-trust.py")))
    packages = packages_module["PackageTests"]()
    packages.setUp()
    index = packages.built_index()
    index["baseUrl"] = CNB_BASE
    (packages.output / "index.json").write_text(json.dumps(index))
    trust = trust_module["TrustTests"]()
    trust.setUp()
    trust.root_payload["assetBaseURL"] = CNB_BASE
    trust.root_payload["allowedHosts"] = ["cnb.cool", "asset.cnb.cool"]
    trust.catalog_payload["index"] = index
    sign = trust_module["envelope"]
    root_file = trust.write("1.root.json", sign(trust.root_payload, trust.keys[:2]))
    catalog_file = trust.write("3.catalog.json", sign(trust.catalog_payload, trust.keys[3:5]))
    options = argparse.Namespace(index=packages.output / "index.json", directory=packages.output,
                                 root=root_file, catalog=catalog_file,
                                 repository="robinhoo1973/Resources")
    return packages, trust, trust_module, options


class PublicationTests(unittest.TestCase):
    def plan(self, assets):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            index = {"schemaVersion": 1, "app": "vitaliber", "assetKind": "asr",
                     "families": [{"id": m, "name": {"zh-Hans": m}, "hint": {"zh-Hans": "fixture hint"},
                                   "languages": ["zh"], "dialects": []} for m in VARIANTS],
                     "models": [
                {"id": m, "variant": VARIANTS[m], "version": "1.0.0", "url": m + ".zip",
                 "bytes": 123, "sha256": "a" * 64,
                 "license": {"whisper": "MIT", "sense-voice": "model-license", "moonshine": "MIT"}.get(m, "Apache-2.0"),
                 "tierName": {"zh-Hans": "档"}, "tierHint": {"zh-Hans": "fixture tier"}}
                for m in VARIANTS]}
            (root / "index.json").write_text(json.dumps(index))
            (root / "assets.json").write_text(json.dumps(assets))
            return subprocess.run(["python3", str(TOOL), "plan", "--index", str(root / "index.json"),
                                   "--assets", str(root / "assets.json")], text=True, capture_output=True)

    @staticmethod
    def cnb_asset(name, size, digest):
        return {"name": name, "size": size,
                "hash_algo": "sha256", "hash_value": digest} if digest else {"name": name, "size": size}

    def test_all_missing_packages_are_uploaded(self):
        result = self.plan([])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {"qwen3.zip": "upload", "zipformer.zip": "upload",
                                                     "dolphin.zip": "upload", "whisper.zip": "upload",
                                                     "sense-voice.zip": "upload", "fire-red.zip": "upload",
                                                     "moonshine.zip": "upload"})

    def test_same_content_is_reused(self):
        result = self.plan([self.cnb_asset("qwen3.zip", 123, "a" * 64)])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["qwen3.zip"], "reuse")

    def test_same_name_different_content_is_never_overwritten(self):
        for size, digest in ((124, "a" * 64), (123, "b" * 64)):
            with self.subTest(size=size):
                result = self.plan([self.cnb_asset("qwen3.zip", size, digest)])
                self.assertNotEqual(result.returncode, 0)

    def test_missing_server_digest_requires_download_verification(self):
        result = self.plan([self.cnb_asset("qwen3.zip", 123, None)])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["qwen3.zip"], "verify")

    def test_publish_uses_cnb_and_has_no_github_writer(self):
        module = runpy.run_path(str(TOOL))
        self.assertFalse(hasattr(module, "gh"))
        with tempfile.TemporaryDirectory() as directory:
            packages, trust, _, options = make_signed_asr_fixture(Path(directory))
            self.addCleanup(packages.doCleanups)
            self.addCleanup(trust.doCleanups)
            client = FakeCNBReleaseClient()
            module["publish"](options, client)
            names = {asset for asset, _ in client.uploads}
            models = json.loads(options.index.read_text())["models"]
            # 单一 JSON 架构(2026-10-06 业主裁定):资产面 = 模型包 + index.json;
            # 根/版本化目录/回执不再上传。
            self.assertTrue({m["url"] for m in models} | {"manifest.json"} <= names)
            # 人读概览（2026-10-07 恢复批）：固定名 overview.json 随发布上传。
            self.assertIn("overview.json", names)
            self.assertFalse(any(name.endswith(".root.json") or name.endswith(".catalog.json")
                                 or name.endswith("package-validation.json") for name in names))
            # 方案 B(2026-10-07):发布成功后触发 README 同步管线。
            self.assertEqual(client.readme_sync_calls, ["asr-models"])
            # 下游确认（触发≠成功）：轮询到 status=success 才静默。
            self.assertEqual(getattr(client, "readme_sync_status_calls", []), ["fixture-sn"])
            # 发布页正文(委员会 S3):永久头 + 动态段经 PATCH 刷新。
            self.assertEqual(len(client.release_body_updates), 1)
            body_tag, body = client.release_body_updates[0]
            self.assertEqual(body_tag, "asr-models")
            self.assertIn("## 本次更新 / 本次資料更新 / This update", body)
            self.assertIn("catalog version: v", body)

    def test_readme_sync_status_failure_does_not_block_publish(self):
        # 触发成功但下游状态查询异常 ⇒ 仅告警，发布结果不受影响（展示面纪律）。
        module = runpy.run_path(str(TOOL))
        with tempfile.TemporaryDirectory() as directory:
            packages, trust, _, options = make_signed_asr_fixture(Path(directory))
            self.addCleanup(packages.doCleanups)
            self.addCleanup(trust.doCleanups)
            client = FakeCNBReleaseClient()

            def failing_status(sn):
                raise RuntimeError("status query exploded")

            client.readme_sync_status = failing_status
            result = module["publish"](options, client)   # 不得抛
            self.assertTrue(result)
            self.assertEqual(client.readme_sync_calls, ["asr-models"])

    def test_readme_sync_trigger_failure_does_not_block_publish(self):
        # 通知通道纪律(2026-10-07):触发失败仅告警,发布结果不受影响;
        # README 同步管线幂等且可经 CNB 页面按钮手动重同步。
        module = runpy.run_path(str(TOOL))
        with tempfile.TemporaryDirectory() as directory:
            packages, trust, _, options = make_signed_asr_fixture(Path(directory))
            self.addCleanup(packages.doCleanups)
            self.addCleanup(trust.doCleanups)
            client = FakeCNBReleaseClient()

            def failing_trigger(tag):
                raise CNBReleaseError("trigger unavailable")

            client.start_readme_sync = failing_trigger
            url = module["publish"](options, client)
            self.assertIn("asr-models", url)
            self.assertTrue(client.uploads)

    def test_publish_overwrites_same_name_different_content_model(self):
        # 业主 R2(2026-10-05/06):同名异内容模型资产按 overwrite 更新上传——
        # 发布路径不再被 publication_plan 的硬错挡住(plan 子命令仍保
        # 规划期拒绝语义,见 plan 用例)。
        module = runpy.run_path(str(TOOL))
        with tempfile.TemporaryDirectory() as directory:
            packages, trust, _, options = make_signed_asr_fixture(Path(directory))
            self.addCleanup(packages.doCleanups)
            self.addCleanup(trust.doCleanups)
            client = FakeCNBReleaseClient()
            module["publish"](options, client)
            first_uploads = list(client.uploads)
            target = next(m["url"] for m in json.loads(options.index.read_text())["models"])
            tampered = next(a for a in client.assets if a["name"] == target)
            tampered["content"] = b"rebuilt-with-different-bytes"
            tampered["size"] = len(tampered["content"])
            tampered["sha256"] = hashlib.sha256(tampered["content"]).hexdigest()
            # 目录/根/回执同名同内容 → 跳过;模型同名异内容 → 走更新上传。
            module["publish"](options, client)
            second = [name for name, _ in client.uploads]
            self.assertEqual(len(second), len(first_uploads) + 1)
            self.assertIn(target, second)
            updated = next(a for a in client.assets if a["name"] == target)
            self.assertEqual(updated["sha256"], tampered["sha256"])

    def test_publish_rejects_tampered_remote_index_bytes(self):
        # 单一 JSON 架构(2026-10-06 业主裁定):远端 index.json 被篡改 = 验签
        # 硬错(同版本异字节等价歧义闸亦在链校验内),不静默覆写。
        module = runpy.run_path(str(TOOL))
        with tempfile.TemporaryDirectory() as directory:
            packages, trust, _, options = make_signed_asr_fixture(Path(directory))
            self.addCleanup(packages.doCleanups)
            self.addCleanup(trust.doCleanups)
            client = FakeCNBReleaseClient()
            module["publish"](options, client)
            tampered = next(a for a in client.assets if a["name"] == "manifest.json")
            tampered["content"] = b"tampered-index"
            tampered["size"] = len(tampered["content"])
            tampered["sha256"] = hashlib.sha256(tampered["content"]).hexdigest()
            with self.assertRaises((RuntimeError, ValueError)):
                module["publish"](options, client)

    def test_publish_tolerates_stale_index_signatures(self):
        # run 37871759240 实证:上游摘要滚动后,索引文件内携带**陈旧**
        # packageSignature（对当前 sha256 不成立）曾被裸 dict 比对误杀发布。
        # 权威=已验真的 catalog 载荷签名;裸索引剥离签名后结构一致即放行。
        module = runpy.run_path(str(TOOL))
        with tempfile.TemporaryDirectory() as directory:
            packages, trust, _, options = make_signed_asr_fixture(Path(directory))
            self.addCleanup(packages.doCleanups)
            self.addCleanup(trust.doCleanups)
            index = json.loads(options.index.read_text())
            # 形状合法（64-hex keyId + 64 字节签名）但密码学上对当前 sha256
            # 不成立 = 陈旧签名真实形态;validate_index 只查形状,与线上一致。
            stale_value = base64.b64encode(b"x" * 64).decode()
            for model in index["models"]:
                model["packageSignature"] = {
                    "scheme": "ed25519-sha256-v1",
                    "signatures": [{"keyId": "ab" * 32, "value": stale_value}]}
            options.index.write_text(json.dumps(index))
            module["publish"](options, FakeCNBReleaseClient())  # 不抛 = 放行

    def test_publish_rejects_real_index_content_drift(self):
        # 剥离口径不放松结构一致性:内容真漂移仍硬红。
        module = runpy.run_path(str(TOOL))
        with tempfile.TemporaryDirectory() as directory:
            packages, trust, _, options = make_signed_asr_fixture(Path(directory))
            self.addCleanup(packages.doCleanups)
            self.addCleanup(trust.doCleanups)
            index = json.loads(options.index.read_text())
            index["models"][0]["bytes"] = index["models"][0]["bytes"] + 1
            options.index.write_text(json.dumps(index))
            with self.assertRaisesRegex(ValueError,
                                        "differs from the signed authorization"):
                module["publish"](options, FakeCNBReleaseClient())

    def test_second_publish_is_idempotent_reuse(self):
        module = runpy.run_path(str(TOOL))
        with tempfile.TemporaryDirectory() as directory:
            packages, trust, _, options = make_signed_asr_fixture(Path(directory))
            self.addCleanup(packages.doCleanups)
            self.addCleanup(trust.doCleanups)
            client = FakeCNBReleaseClient()
            module["publish"](options, client)
            first_uploads = list(client.uploads)
            module["publish"](options, client)
            self.assertEqual(client.uploads, first_uploads)  # 复用路径不产生新上传

    def test_publish_bootstraps_missing_release_before_first_read(self):
        # 冷启动恢复（2026-10-07 CI 37619255618 实证）：CNB Release 被删除后
        # 首个 list_assets 即硬错，3 次重试确定性无效——发布器是 Release 的
        # 唯一创建者（业主 2026-10-07 问询落点），必须在任何远端读取前幂等
        # 创建；创建先于一切上传（创建惯例 = release_notes_for_tag 模板）。
        module = runpy.run_path(str(TOOL))
        with tempfile.TemporaryDirectory() as directory:
            packages, trust, _, options = make_signed_asr_fixture(Path(directory))
            self.addCleanup(packages.doCleanups)
            self.addCleanup(trust.doCleanups)
            client = FakeCNBReleaseClient()
            client.release_exists = False
            module["publish"](options, client)
            self.assertEqual([tag for tag, _, _ in client.release_creations], ["asr-models"])
            self.assertTrue(client.release_creations[0][1], "创建必须携带模板标题")
            self.assertTrue(client.release_creations[0][2], "创建必须携带模板正文")
            self.assertEqual(client.call_log[0], "ensure_release",
                             "幂等创建必须先于首个远端读取/上传")
            first_upload = next(i for i, call in enumerate(client.call_log)
                                if call.startswith("upload:"))
            self.assertGreater(first_upload, 0)
            self.assertTrue(client.uploads)  # 冷启动 = 全量上传

    def test_same_version_different_payload_equivocation_rejected(self):
        module = runpy.run_path(str(TOOL))
        with tempfile.TemporaryDirectory() as directory:
            packages, trust, trust_module, options = make_signed_asr_fixture(Path(directory))
            self.addCleanup(packages.doCleanups)
            tampered = dict(trust.catalog_payload)
            tampered["index"] = dict(trust.catalog_payload["index"])
            tampered["index"]["models"] = tampered["index"]["models"][:-1]
            equivocation = trust_module["envelope"](tampered, trust.keys[3:5])
            equivocation_bytes = json.dumps(equivocation).encode()
            client = FakeCNBReleaseClient(downloads={"manifest.json": equivocation_bytes})
            # 远程清单必须可见该目录资产,链校验才进入比对分支
            client.assets.append({"name": "manifest.json", "size": len(equivocation_bytes),
                                  "sha256": hashlib.sha256(equivocation_bytes).hexdigest(),
                                  "content": equivocation_bytes})
            with self.assertRaises(ValueError):
                module["publish"](options, client)

    def test_readme_sync_default_window_is_5x15(self):
        # 2026-10-08:窗口 3×10→5×15——当日两次发布 marginal 超窗(实测 success
        # 需 ~40s);断言默认参数防静默回退(3×10=30s<40s 必漏报)。
        import inspect
        module = runpy.run_path(str(TOOL))
        params = inspect.signature(module["_confirm_readme_sync"]).parameters
        self.assertEqual(params["attempts"].default, 5)
        self.assertEqual(params["interval"].default, 15)

    def test_readme_sync_pending_exhausts_then_warns(self):
        # 终态始终 pending:有界轮询耗尽后 ::warning::(不阻塞发布),
        # 且状态查询次数恰为 attempts(无多余请求)。
        import contextlib
        import io
        module = runpy.run_path(str(TOOL))
        calls = []

        class PendingClient:
            def readme_sync_status(self, sn):
                calls.append(sn)
                return {"sn": sn, "status": "pending"}

        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            module["_confirm_readme_sync"](PendingClient(), "fixture-sn", attempts=3, interval=0)
        self.assertEqual(calls, ["fixture-sn"] * 3)
        self.assertIn("::warning::readme-sync 未在 3 次查询内完成", stderr.getvalue())

    def test_publish_overview_readback_content_mismatch_warns_only(self):
        # T8（2026-10-08 委员会）：overview.json 上传后匿名回读的**实际字节**
        # 与本地 sha256 不一致 ⇒ 仅 ::warning::，发布不阻塞（展示面纪律；
        # 清单级回读由 upload_immutable 内部承担，此处是内容级补充腿）。
        import contextlib
        import io
        module = runpy.run_path(str(TOOL))
        with tempfile.TemporaryDirectory() as directory:
            packages, trust, _, options = make_signed_asr_fixture(Path(directory))
            self.addCleanup(packages.doCleanups)
            self.addCleanup(trust.doCleanups)
            client = FakeCNBReleaseClient(downloads={"overview.json": b"tampered-readback-bytes"})
            stderr = io.StringIO()
            with contextlib.redirect_stderr(stderr):
                result = module["publish"](options, client)   # 不得抛
            self.assertTrue(result)
            self.assertIn("::warning::overview.json 匿名回读字节不一致", stderr.getvalue())

    def test_publish_overview_readback_content_match_logs(self):
        # 一致路径：默认桩回读上传后的真实字节 ⇒ 打印对账一致（防回退：
        # 内容级回读腿整体缺失时该行消失即红）。
        import contextlib
        import io
        module = runpy.run_path(str(TOOL))
        with tempfile.TemporaryDirectory() as directory:
            packages, trust, _, options = make_signed_asr_fixture(Path(directory))
            self.addCleanup(packages.doCleanups)
            self.addCleanup(trust.doCleanups)
            client = FakeCNBReleaseClient()
            stdout = io.StringIO()
            with contextlib.redirect_stdout(stdout):
                module["publish"](options, client)
            self.assertIn("overview.json 匿名回读对账一致", stdout.getvalue())


if __name__ == "__main__":
    unittest.main()
