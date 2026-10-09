#!/usr/bin/env python3
"""Offline tests for publish-local-artifact.py（2026-10-09 W11 训练→CNB 自动交换）。

Never performs network access: the write path runs on the scripted fake transport
(cnb_release.ScriptedCNBTransport) and the anonymous read-back is an injected fake
download — the test asserts exact call sequences (e.g. the idempotent path must
issue exactly one GET and zero PUTs), token-first hard failure, content-addressed
naming, the no-overwrite collision rule, and that the script never writes any
catalog/policy artifact.
"""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import sys
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

from cnb_read import download_cnb_asset  # noqa: F401  (模块自含导入面冒烟)
from cnb_release import CNBResponse, CNBReleaseError, ScriptedCNBTransport

spec = importlib.util.spec_from_file_location("publish_local_artifact", HERE / "publish-local-artifact.py")
assert spec and spec.loader
publisher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publisher)

RELEASE = "llama-models"
REPOSITORY = "owner/resources"


def asset_payload(name, payload, path=None):
    """cnb_release 清单条目形状（与 test-cnb-release.py 同款 fake 服务范式）。"""
    return {"name": name, "size": len(payload),
            "path": path or "/" + REPOSITORY + "/-/releases/download/" + RELEASE + "/" + name,
            "hash_algo": "sha256", "hash_value": hashlib.sha256(payload).hexdigest()}


def fresh_upload_transport(name, payload):
    """新建 release → grant → PUT → confirm → read-back 的固定应答序列。"""
    return ScriptedCNBTransport(
        api_responses=[
            CNBResponse(404, {}, b"{}"),
            CNBResponse(201, {}, json.dumps({"id": "r1", "tag_name": RELEASE,
                                             "draft": False, "assets": []}).encode()),
            CNBResponse(201, {}, json.dumps({"upload_url": "https://asset.cnb.cool/put/u1",
                                             "verify_url": "https://api.cnb.cool/confirm/u1",
                                             "expires_in_sec": 300}).encode()),
            CNBResponse(200, {}, b"{}"),
            CNBResponse(200, {}, json.dumps({"id": "r1", "tag_name": RELEASE, "draft": False,
                                             "assets": [asset_payload(name, payload)]}).encode()),
        ],
        put_responses=[CNBResponse(200, {}, b"")],
    )


class RecordingDownload:
    """匿名回读注入假件:记录调用参数;可编排"先失败 N 次"或"内容不符"。"""

    def __init__(self, fail_network=0, mismatch=False):
        self.calls = []
        self.fail_network = fail_network
        self.mismatch = mismatch

    def __call__(self, repository, tag, asset, destination, expected_sha256, expected_size):
        self.calls.append({"repository": repository, "tag": tag, "asset": dict(asset),
                           "destination": Path(destination), "sha256": expected_sha256,
                           "size": expected_size})
        if self.mismatch:
            raise ValueError("CNB cached package digest/size mismatch: " + asset["name"])
        if self.fail_network > 0:
            self.fail_network -= 1
            raise OSError("simulated transport failure")


class AssetNamingTests(unittest.TestCase):
    def test_name_is_prefix_digest16_basename(self):
        digest = hashlib.sha256(b"weights").hexdigest()
        self.assertEqual(publisher.asset_name("train-", digest, "model.bin"),
                         f"train-{digest[:16]}-model.bin")

    def test_unsafe_names_are_rejected(self):
        digest = "0" * 64
        for prefix, basename in (("train-", "weird name.bin"), ("train-", "café.bin"),
                                 ("train/", "model.bin"), ("train-", "a" * 255 + ".bin")):
            with self.subTest(basename=basename):
                with self.assertRaises(ValueError):
                    publisher.asset_name(prefix, digest, basename)


class PublishFlowTests(unittest.TestCase):
    def _write(self, tmp, payload, name="model.bin"):
        path = Path(tmp) / name
        path.write_bytes(payload)
        return path

    def test_fresh_publish_uploads_and_verifies_anonymously(self):
        payload = b"fresh-artifact"
        with tempfile.TemporaryDirectory() as tmp:
            path = self._write(tmp, payload)
            name = publisher.asset_name_for(path, "train-")
            transport = fresh_upload_transport(name, payload)
            download = RecordingDownload()
            from cnb_release import CNBReleaseClient
            client = CNBReleaseClient(REPOSITORY, "fixture-token", transport)
            result = publisher.publish_file(client, path, release=RELEASE, prefix="train-",
                                            download=download, backoff_seconds=0)
        self.assertEqual([call.method for call in transport.calls],
                         ["GET", "POST", "POST", "PUT", "POST", "GET"])
        self.assertEqual(len(download.calls), 1, "上传后必须恰好回读一次")
        call = download.calls[0]
        self.assertEqual(call["repository"], REPOSITORY)
        self.assertEqual(call["tag"], RELEASE)
        self.assertEqual(call["asset"]["name"], name)
        self.assertEqual(call["sha256"], hashlib.sha256(payload).hexdigest())
        self.assertEqual(call["size"], len(payload))
        self.assertEqual(result["name"], name)
        self.assertEqual(result["bytes"], len(payload))
        self.assertIn("/" + REPOSITORY + "/-/releases/download/" + RELEASE + "/" + name, result["url"])

    def test_idempotent_same_name_same_digest_skips_upload_but_still_verifies(self):
        payload = b"idempotent"
        with tempfile.TemporaryDirectory() as tmp:
            path = self._write(tmp, payload)
            name = publisher.asset_name_for(path, "train-")
            transport = ScriptedCNBTransport(
                api_responses=[CNBResponse(200, {}, json.dumps(
                    {"id": "r1", "tag_name": RELEASE, "assets": [asset_payload(name, payload)]}).encode())],
                put_responses=[])
            download = RecordingDownload()
            from cnb_release import CNBReleaseClient
            client = CNBReleaseClient(REPOSITORY, "fixture-token", transport)
            publisher.publish_file(client, path, release=RELEASE, prefix="train-",
                                   download=download, backoff_seconds=0)
        self.assertEqual([call.method for call in transport.calls], ["GET"], "同名同 sha 幂等:零 PUT")
        self.assertEqual(len(download.calls), 1, "幂等跳过也要匿名回读")

    def test_collision_same_name_different_digest_is_hard_error(self):
        payload = b"content-a"
        with tempfile.TemporaryDirectory() as tmp:
            path = self._write(tmp, payload)
            name = publisher.asset_name_for(path, "train-")
            collision = asset_payload(name, b"content-b")
            transport = ScriptedCNBTransport(
                api_responses=[CNBResponse(200, {}, json.dumps(
                    {"id": "r1", "tag_name": RELEASE, "assets": [collision]}).encode())],
                put_responses=[])
            download = RecordingDownload()
            from cnb_release import CNBReleaseClient
            client = CNBReleaseClient(REPOSITORY, "fixture-token", transport)
            with self.assertRaises(CNBReleaseError):
                publisher.publish_file(client, path, release=RELEASE, prefix="train-",
                                       download=download, backoff_seconds=0)
        self.assertEqual([call.method for call in transport.calls], ["GET"], "碰撞绝不 PUT/覆盖")
        self.assertEqual(download.calls, [], "碰撞后不得回读(未发布)")

    def test_readback_mismatch_fails_the_file(self):
        payload = b"tampered"
        with tempfile.TemporaryDirectory() as tmp:
            path = self._write(tmp, payload)
            transport = fresh_upload_transport(publisher.asset_name_for(path, "train-"), payload)
            download = RecordingDownload(mismatch=True)
            from cnb_release import CNBReleaseClient
            client = CNBReleaseClient(REPOSITORY, "fixture-token", transport)
            with self.assertRaises(ValueError):
                publisher.publish_file(client, path, release=RELEASE, prefix="train-",
                                       download=download, backoff_seconds=0)
        self.assertEqual(len(download.calls), 1, "内容不符不重试")


class ReadbackRetryTests(unittest.TestCase):
    def test_network_failures_are_retried_within_budget(self):
        download = RecordingDownload(fail_network=2)
        publisher.verify_anonymous_readback("r/r", RELEASE, "train-0-model.bin", "0" * 64, 3,
                                            download=download, attempts=3, backoff_seconds=0)
        self.assertEqual(len(download.calls), 3)

    def test_network_failure_exhaustion_raises(self):
        download = RecordingDownload(fail_network=5)
        with self.assertRaises(OSError):
            publisher.verify_anonymous_readback("r/r", RELEASE, "train-0-model.bin", "0" * 64, 3,
                                                download=download, attempts=2, backoff_seconds=0)
        self.assertEqual(len(download.calls), 2)

    def test_digest_mismatch_is_never_retried(self):
        download = RecordingDownload(mismatch=True)
        with self.assertRaises(ValueError):
            publisher.verify_anonymous_readback("r/r", RELEASE, "train-0-model.bin", "0" * 64, 3,
                                                download=download, attempts=3, backoff_seconds=0)
        self.assertEqual(len(download.calls), 1)


class MainEntryTests(unittest.TestCase):
    def test_missing_token_fails_before_any_io(self):
        payload = b"token-first"
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "model.bin"
            path.write_bytes(payload)
            transport = ScriptedCNBTransport(api_responses=[], put_responses=[])
            saved = os.environ.pop("CNB_TOKEN", None)
            try:
                code = publisher.main(["--file", str(path)], transport=transport,
                                      download=RecordingDownload(), backoff_seconds=0)
            finally:
                if saved is not None:
                    os.environ["CNB_TOKEN"] = saved
            self.assertEqual(code, 1)
        self.assertEqual(transport.calls, [], "token 缺失必须秒级硬红:零网络调用")

    def test_multi_file_batch_continues_and_reports_failures(self):
        ok = b"ok-artifact"
        with tempfile.TemporaryDirectory() as tmp:
            good = Path(tmp) / "good.bin"
            good.write_bytes(ok)
            name = publisher.asset_name_for(good, "train-")
            transport = fresh_upload_transport(name, ok)
            download = RecordingDownload()
            saved = os.environ.get("CNB_TOKEN")
            os.environ["CNB_TOKEN"] = "fixture-token"
            try:
                code = publisher.main(["--file", str(good), str(Path(tmp) / "missing.bin"),
                                       "--repository", REPOSITORY],
                                      transport=transport, download=download, backoff_seconds=0)
            finally:
                if saved is None:
                    os.environ.pop("CNB_TOKEN", None)
                else:
                    os.environ["CNB_TOKEN"] = saved
        self.assertEqual(code, 1, "缺件必须记失败")
        self.assertEqual(len(download.calls), 1, "其余文件照常处理(批语义)")


class NoMutationContractTests(unittest.TestCase):
    def test_script_never_writes_catalog_or_policy_files(self):
        source = (HERE / "publish-local-artifact.py").read_text(encoding="utf-8")
        self.assertNotIn("LLMCatalog", source)
        self.assertNotIn("catalog.json", source)
        for pattern in (r"json\.dump", r"write_text", r"write_bytes", r"open\([^)]*[\"']w"):
            with self.subTest(pattern=pattern):
                self.assertIsNone(re.search(pattern, source), "只上传:不得写任何 catalog/policy 文件")

    def test_uses_single_source_write_and_read_paths(self):
        source = (HERE / "publish-local-artifact.py").read_text(encoding="utf-8")
        self.assertIn("from cnb_release import", source)
        self.assertIn("from cnb_read import", source)


if __name__ == "__main__":
    unittest.main()
