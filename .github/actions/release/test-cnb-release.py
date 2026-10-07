#!/usr/bin/env python3
"""Offline fake-transport tests for the bounded CNB Release publisher (2026-10-03 plan Task 1).

Never performs network access: ScriptedCNBTransport dequeues canned responses and
asserts the client makes exactly the scripted calls. Also anchors the fail-closed
CNB tag-page parser (design doc §3.1) with sanitized HTML fixtures.
"""
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from cnb_release import (CNBReleaseClient, CNBReleaseError, CNBResponse,
                         ScriptedCNBTransport, release_notes_for_tag,
                         start_readme_sync)

# 2026-10-07 模块化：SSR 解析器自 cnb_read 单源导入（此前 runpy-of-prepare 消费）
from cnb_read import download_assets, parse_cnb_tag_page
import time


def tag_page(release, tag="asr-models"):
    """Wrap a release dict into a minimal __NEXT_DATA__ SSR document."""
    data = {"props": {"pageProps": {"releaseDetailStatus": "success",
                                    "releasesDetailData": {"release": release}}}}
    return ('<html><body><script id="__NEXT_DATA__" type="application/json">'
            + json.dumps(data) + "</script></body></html>").encode()


class CNBTagPageParserTests(unittest.TestCase):
    def asset(self, name, path, digest=None, size=5):
        return {"name": name, "path": path, "hashAlgo": "sha256",
                "hashValue": digest or hashlib.sha256(name.encode()).hexdigest(),
                "sizeInByte": size}

    def test_valid_page_yields_assets_in_order(self):
        release = {"tagRef": "refs/tags/asr-models", "assets": [
            self.asset("a.zip", "/owner/resources/-/releases/download/asr-models/a.zip"),
            self.asset("b.zip", "/owner/resources/-/releases/download/asr-models/b.zip")]}
        parsed = parse_cnb_tag_page(tag_page(release), "owner/resources", "asr-models")
        self.assertEqual([a["name"] for a in parsed], ["a.zip", "b.zip"])

    def test_missing_next_data_is_rejected(self):
        with self.assertRaises(ValueError):
            parse_cnb_tag_page(b"<html><body>no data</body></html>", "owner/resources", "asr-models")

    def test_wrong_tag_or_state_is_rejected(self):
        with self.assertRaises(ValueError):
            parse_cnb_tag_page(tag_page({"tagRef": "refs/tags/other", "assets": []}), "owner/resources", "asr-models")
        with self.assertRaises(ValueError):
            data = {"props": {"pageProps": {"releaseDetailStatus": "missing"}}}
            parse_cnb_tag_page(('<script id="__NEXT_DATA__">' + json.dumps(data) + "</script>").encode(),
                               "owner/resources", "asr-models")

    def test_out_of_scope_path_or_bad_metadata_is_rejected(self):
        release = {"tagRef": "refs/tags/asr-models", "assets": [
            self.asset("a.zip", "/someone/else/-/releases/download/asr-models/a.zip")]}
        with self.assertRaises(ValueError):
            parse_cnb_tag_page(tag_page(release), "owner/resources", "asr-models")
        release = {"tagRef": "refs/tags/asr-models", "assets": [
            self.asset("a.zip", "/owner/resources/-/releases/download/asr-models/a.zip", digest="not-a-digest")]}
        with self.assertRaises(ValueError):
            parse_cnb_tag_page(tag_page(release), "owner/resources", "asr-models")

    def test_duplicate_names_are_rejected(self):
        release = {"tagRef": "refs/tags/asr-models", "assets": [
            self.asset("a.zip", "/owner/resources/-/releases/download/asr-models/a.zip"),
            self.asset("a.zip", "/owner/resources/-/releases/download/asr-models/a.zip")]}
        with self.assertRaises(ValueError):
            parse_cnb_tag_page(tag_page(release), "owner/resources", "asr-models")

    def test_pending_state_with_null_release_is_rejected(self):
        # 实测形态(2026-10-05 探针,robinhoo1973/Resources):Release 未创建时
        # releaseDetailStatus="pending" 且 releasesDetailData=null。
        data = {"props": {"pageProps": {"releaseDetailStatus": "pending",
                                        "releasesDetailData": None}}}
        html = ('<script id="__NEXT_DATA__">' + json.dumps(data) + "</script>").encode()
        with self.assertRaises(ValueError):
            parse_cnb_tag_page(html, "robinhoo1973/Resources", "asr-models")


def asset_payload(name, payload, path=None):
    return {"name": name, "size": len(payload),
            "path": path or "/owner/resources/-/releases/download/asr-models/" + name,
            "hash_algo": "sha256", "hash_value": hashlib.sha256(payload).hexdigest()}


class CNBReleaseTests(unittest.TestCase):
    def test_upload_uses_create_put_confirm_and_readback(self):
        with tempfile.TemporaryDirectory() as directory:
            payload = b"model"
            path = Path(directory) / "model.zip"
            path.write_bytes(payload)
            digest = hashlib.sha256(payload).hexdigest()
            transport = ScriptedCNBTransport(
                api_responses=[
                    CNBResponse(404, {}, b"{}"),
                    CNBResponse(201, {}, json.dumps({"id": "r1", "tag_name": "asr-models",
                                                     "draft": False, "assets": []}).encode()),
                    CNBResponse(201, {}, json.dumps({"upload_url": "https://asset.cnb.cool/put/u1",
                                                     "verify_url": "https://api.cnb.cool/confirm/u1",
                                                     "expires_in_sec": 300}).encode()),
                    CNBResponse(200, {}, b"{}"),
                    CNBResponse(200, {}, json.dumps({"id": "r1", "tag_name": "asr-models", "draft": False,
                                                     "assets": [asset_payload("model.zip", payload)]}).encode()),
                ],
                put_responses=[CNBResponse(200, {}, b"")],
            )
            client = CNBReleaseClient("owner/resources", "fixture-token", transport)
            receipt = client.upload_immutable("asr-models", path, "model.zip", digest)
        self.assertEqual(receipt.name, "model.zip")
        self.assertEqual(receipt.size, len(payload))
        self.assertEqual(receipt.sha256, digest)
        self.assertEqual([call.method for call in transport.calls],
                         ["GET", "POST", "POST", "PUT", "POST", "GET"])

    def test_bearer_token_goes_only_to_the_api_and_never_to_the_upload(self):
        with tempfile.TemporaryDirectory() as directory:
            payload = b"token-scope"
            path = Path(directory) / "model.zip"
            path.write_bytes(payload)
            digest = hashlib.sha256(payload).hexdigest()
            transport = ScriptedCNBTransport(
                api_responses=[
                    CNBResponse(404, {}, b"{}"),
                    CNBResponse(201, {}, json.dumps({"id": "r1", "tag_name": "asr-models", "assets": []}).encode()),
                    CNBResponse(201, {}, json.dumps({"upload_url": "https://asset.cnb.cool/put/u1",
                                                     "verify_url": "https://api.cnb.cool/confirm/u1"}).encode()),
                    CNBResponse(200, {}, b"{}"),
                    CNBResponse(200, {}, json.dumps({"id": "r1", "tag_name": "asr-models",
                                                     "assets": [asset_payload("model.zip", payload)]}).encode()),
                ],
                put_responses=[CNBResponse(200, {}, b"")],
            )
            client = CNBReleaseClient("owner/resources", "fixture-token", transport)
            client.upload_immutable("asr-models", path, "model.zip", digest)
        for call in transport.calls:
            if call.method == "PUT":
                self.assertNotIn("Authorization", call.headers)
                self.assertEqual(call.headers, {})
            else:
                self.assertEqual(call.headers.get("Authorization"), "Bearer fixture-token")

    def test_same_name_same_digest_is_reused(self):
        with tempfile.TemporaryDirectory() as directory:
            payload = b"reuse"
            path = Path(directory) / "model.zip"
            path.write_bytes(payload)
            digest = hashlib.sha256(payload).hexdigest()
            transport = ScriptedCNBTransport(
                api_responses=[
                    CNBResponse(200, {}, json.dumps({"id": "r1", "tag_name": "asr-models",
                                                     "assets": [asset_payload("model.zip", payload)]}).encode()),
                ],
                put_responses=[],
            )
            client = CNBReleaseClient("owner/resources", "fixture-token", transport)
            receipt = client.upload_immutable("asr-models", path, "model.zip", digest)
            self.assertEqual(receipt.sha256, digest)
        # 2026-10-05 审查:跳过路径复用已取回的清单核对,只 1 次 GET。
        self.assertEqual([call.method for call in transport.calls], ["GET"])

    def test_same_name_different_digest_is_a_hard_collision(self):
        with tempfile.TemporaryDirectory() as directory:
            payload = b"collision"
            path = Path(directory) / "model.zip"
            path.write_bytes(payload)
            digest = hashlib.sha256(payload).hexdigest()
            other = asset_payload("model.zip", b"different")
            transport = ScriptedCNBTransport(
                api_responses=[CNBResponse(200, {}, json.dumps(
                    {"id": "r1", "tag_name": "asr-models", "assets": [other]}).encode())],
                put_responses=[],
            )
            client = CNBReleaseClient("owner/resources", "fixture-token", transport)
            with self.assertRaises(CNBReleaseError):
                client.upload_immutable("asr-models", path, "model.zip", digest)
        self.assertEqual([call.method for call in transport.calls], ["GET"])

    def test_same_name_different_digest_updates_when_overwrite_allowed(self):
        # 业主规则(2026-10-05):hash 比对不同 → 更新上传;grant 请求带 overwrite:true。
        with tempfile.TemporaryDirectory() as directory:
            payload = b"updated-bytes"
            path = Path(directory) / "model.zip"
            path.write_bytes(payload)
            digest = hashlib.sha256(payload).hexdigest()
            existing = asset_payload("model.zip", b"old-bytes")
            transport = ScriptedCNBTransport(
                api_responses=[
                    CNBResponse(200, {}, json.dumps({"id": "r1", "tag_name": "asr-models",
                                                     "assets": [existing]}).encode()),
                    CNBResponse(201, {}, json.dumps({"upload_url": "https://asset.cnb.cool/put/u1",
                                                     "verify_url": "https://api.cnb.cool/confirm/u1"}).encode()),
                    CNBResponse(200, {}, b"{}"),
                    CNBResponse(200, {}, json.dumps({"id": "r1", "tag_name": "asr-models",
                                                     "assets": [asset_payload("model.zip", payload)]}).encode()),
                ],
                put_responses=[CNBResponse(200, {}, b"")],
            )
            client = CNBReleaseClient("owner/resources", "fixture-token", transport)
            receipt = client.upload_immutable("asr-models", path, "model.zip", digest, overwrite=True)
            self.assertEqual(receipt.sha256, digest)
        self.assertEqual([call.method for call in transport.calls],
                         ["GET", "POST", "PUT", "POST", "GET"])
        grant_call = transport.calls[1]
        grant_body = json.loads(grant_call.body)
        self.assertTrue(grant_body["overwrite"])

    def test_same_name_different_digest_skips_nothing_and_uploads(self):
        # 相同摘要 → 完全跳过上传(PUT 零次);不同摘要且 overwrite=True → 走上传。
        with tempfile.TemporaryDirectory() as directory:
            payload = b"same-bytes"
            path = Path(directory) / "model.zip"
            path.write_bytes(payload)
            digest = hashlib.sha256(payload).hexdigest()
            transport = ScriptedCNBTransport(
                api_responses=[
                    CNBResponse(200, {}, json.dumps({"id": "r1", "tag_name": "asr-models",
                                                     "assets": [asset_payload("model.zip", payload)]}).encode()),
                ],
                put_responses=[],
            )
            client = CNBReleaseClient("owner/resources", "fixture-token", transport)
            client.upload_immutable("asr-models", path, "model.zip", digest, overwrite=True)
        self.assertEqual([call.method for call in transport.calls], ["GET"])

    def test_insecure_or_credentialed_upload_url_is_rejected(self):
        for upload_url in ("http://asset.cnb.cool/put/u1",
                           "https://user:pass@asset.cnb.cool/put/u1",
                           "https://asset.cnb.cool:8080/put/u1"):
            with self.subTest(upload_url=upload_url):
                with tempfile.TemporaryDirectory() as directory:
                    payload = b"bad-url"
                    path = Path(directory) / "model.zip"
                    path.write_bytes(payload)
                    digest = hashlib.sha256(payload).hexdigest()
                    transport = ScriptedCNBTransport(
                        api_responses=[
                            CNBResponse(404, {}, b"{}"),
                            CNBResponse(201, {}, json.dumps({"id": "r1", "tag_name": "asr-models", "assets": []}).encode()),
                            CNBResponse(201, {}, json.dumps({"upload_url": upload_url,
                                                             "verify_url": "https://api.cnb.cool/confirm/u1"}).encode()),
                        ],
                        put_responses=[],
                    )
                    client = CNBReleaseClient("owner/resources", "fixture-token", transport)
                    with self.assertRaises(CNBReleaseError):
                        client.upload_immutable("asr-models", path, "model.zip", digest)

    def test_presigned_query_tokens_are_allowed_on_grant_urls(self):
        with tempfile.TemporaryDirectory() as directory:
            payload = b"presigned"
            path = Path(directory) / "model.zip"
            path.write_bytes(payload)
            digest = hashlib.sha256(payload).hexdigest()
            transport = ScriptedCNBTransport(
                api_responses=[
                    CNBResponse(404, {}, b"{}"),
                    CNBResponse(201, {}, json.dumps({"id": "r1", "tag_name": "asr-models", "assets": []}).encode()),
                    CNBResponse(201, {}, json.dumps({"upload_url": "https://asset.cnb.cool/put/u1?token=abc",
                                                     "verify_url": "https://api.cnb.cool/confirm/u1?token=abc"}).encode()),
                    CNBResponse(200, {}, b"{}"),
                    CNBResponse(200, {}, json.dumps({"id": "r1", "tag_name": "asr-models",
                                                     "assets": [asset_payload("model.zip", payload)]}).encode()),
                ],
                put_responses=[CNBResponse(200, {}, b"")],
            )
            client = CNBReleaseClient("owner/resources", "fixture-token", transport)
            receipt = client.upload_immutable("asr-models", path, "model.zip", digest)
            self.assertEqual(receipt.sha256, digest)

    def test_verify_url_outside_api_host_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            payload = b"bad-verify"
            path = Path(directory) / "model.zip"
            path.write_bytes(payload)
            digest = hashlib.sha256(payload).hexdigest()
            transport = ScriptedCNBTransport(
                api_responses=[
                    CNBResponse(404, {}, b"{}"),
                    CNBResponse(201, {}, json.dumps({"id": "r1", "tag_name": "asr-models", "assets": []}).encode()),
                    CNBResponse(201, {}, json.dumps({"upload_url": "https://asset.cnb.cool/put/u1",
                                                     "verify_url": "https://evil.example/confirm/u1"}).encode()),
                ],
                put_responses=[],
            )
            client = CNBReleaseClient("owner/resources", "fixture-token", transport)
            with self.assertRaises(CNBReleaseError):
                client.upload_immutable("asr-models", path, "model.zip", digest)

    def test_wrong_read_back_digest_fails_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            payload = b"wrong-readback"
            path = Path(directory) / "model.zip"
            path.write_bytes(payload)
            digest = hashlib.sha256(payload).hexdigest()
            tampered = asset_payload("model.zip", payload)
            tampered["hash_value"] = "0" * 64
            transport = ScriptedCNBTransport(
                api_responses=[
                    CNBResponse(404, {}, b"{}"),
                    CNBResponse(201, {}, json.dumps({"id": "r1", "tag_name": "asr-models", "assets": []}).encode()),
                    CNBResponse(201, {}, json.dumps({"upload_url": "https://asset.cnb.cool/put/u1",
                                                     "verify_url": "https://api.cnb.cool/confirm/u1"}).encode()),
                    CNBResponse(200, {}, b"{}"),
                    CNBResponse(200, {}, json.dumps({"id": "r1", "tag_name": "asr-models", "assets": [tampered]}).encode()),
                ],
                put_responses=[CNBResponse(200, {}, b"")],
            )
            client = CNBReleaseClient("owner/resources", "fixture-token", transport)
            with self.assertRaises(CNBReleaseError):
                client.upload_immutable("asr-models", path, "model.zip", digest)

    def test_unknown_tag_is_rejected_before_any_call(self):
        transport = ScriptedCNBTransport(api_responses=[], put_responses=[])
        client = CNBReleaseClient("owner/resources", "fixture-token", transport)
        with self.assertRaises(CNBReleaseError):
            client.upload_immutable("medical-data", Path("x.zip"), "x.zip", "a" * 64)
        self.assertEqual(transport.calls, [])

    def test_release_notes_templates_exist_for_allowed_tags(self):
        for tag in ("asr-models", "llama-models", "llama-xcframework"):
            title, body = release_notes_for_tag(tag)
            self.assertTrue(title)
            self.assertTrue(body)

    def test_anonymous_download_is_bounded(self):
        transport = ScriptedCNBTransport(
            api_responses=[CNBResponse(200, {}, b"asset-bytes"), CNBResponse(200, {}, b"asset-bytes")],
            put_responses=[],
        )
        client = CNBReleaseClient("owner/resources", "fixture-token", transport)
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / "out.bin"
            client.download_asset("asr-models", "out.bin", destination, max_bytes=11)
            self.assertEqual(destination.read_bytes(), b"asset-bytes")
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(CNBReleaseError):
                client.download_asset("asr-models", "out.bin", Path(directory) / "out.bin", max_bytes=5)
        self.assertEqual([call.headers.get("Authorization") for call in transport.calls], [None, None])


class StartReadmeSyncTests(unittest.TestCase):
    """方案 B(2026-10-07):发布器 → build/start 触发 README 同步管线的契约。"""

    @staticmethod
    def _trigger(responses, attempts=2):
        transport = ScriptedCNBTransport(api_responses=responses, put_responses=[])
        result = start_readme_sync("owner/resources", "asr-models", "fixture-token",
                                   transport, attempts=attempts)
        return result, transport

    def test_request_contract(self):
        result, transport = self._trigger(
            [CNBResponse(200, {}, json.dumps({"sn": "cnb-x", "buildLogUrl": "u"}).encode())])
        self.assertEqual(result["sn"], "cnb-x")
        self.assertEqual(len(transport.calls), 1)
        call = transport.calls[0]
        self.assertEqual(call.method, "POST")
        self.assertEqual(call.url, "https://api.cnb.cool/owner/resources/-/build/start")
        self.assertEqual(call.headers.get("Authorization"), "Bearer fixture-token")
        body = json.loads(call.body)
        self.assertEqual(body["event"], "api_trigger_readme_sync")
        self.assertEqual(body["env"], {"README_SYNC_TAG": "asr-models"})
        self.assertEqual(body["sync"], "false")  # swagger:dto.StartBuildReq.sync 为字符串
        self.assertEqual(body["branch"], "main")

    def test_4xx_fails_without_retry(self):
        transport = ScriptedCNBTransport(
            api_responses=[CNBResponse(403, {}, b'{"errmsg":"missing repo-cnb-trigger:rw"}')],
            put_responses=[])
        with self.assertRaises(CNBReleaseError):
            start_readme_sync("owner/resources", "asr-models", "fixture-token", transport)
        self.assertEqual(len(transport.calls), 1)

    def test_5xx_is_retried(self):
        result, transport = self._trigger([CNBResponse(500, {}, b"boom"),
                                           CNBResponse(200, {}, b'{"sn":"s2"}')])
        self.assertEqual(result["sn"], "s2")
        self.assertEqual(len(transport.calls), 2)

    def test_missing_sn_fails_closed(self):
        with self.assertRaises(CNBReleaseError):
            self._trigger([CNBResponse(200, {}, b"{}")])

    def test_invalid_repository_rejected_before_transport(self):
        transport = ScriptedCNBTransport(api_responses=[], put_responses=[])
        with self.assertRaises(CNBReleaseError):
            start_readme_sync("bad repo", "asr-models", "fixture-token", transport)
        self.assertEqual(transport.calls, [])


class UpdateReleaseBodyTests(unittest.TestCase):
    """委员会 S3（2026-10-07）：正文 PATCH 刷新——存在性门/空体门/回读比对（有界 3 次）。"""

    def test_patch_then_readback(self):
        transport = ScriptedCNBTransport(api_responses=[
            CNBResponse(200, {}, json.dumps({"id": "r7", "tag_name": "asr-models", "body": "old"}).encode()),
            CNBResponse(200, {}, b"{}"),
            CNBResponse(200, {}, json.dumps({"id": "r7", "tag_name": "asr-models", "body": "new body\n"}).encode()),
        ], put_responses=[])
        client = CNBReleaseClient("owner/resources", "fixture-token", transport)
        client.update_release_body("asr-models", "new body")
        self.assertEqual([call.method for call in transport.calls], ["GET", "PATCH", "GET"])
        patch = transport.calls[1]
        self.assertEqual(patch.url, "https://api.cnb.cool/owner/resources/-/releases/r7")
        self.assertEqual(json.loads(patch.body), {"body": "new body"})

    def test_missing_release_refuses_without_creating(self):
        transport = ScriptedCNBTransport(api_responses=[CNBResponse(404, {}, b"{}")], put_responses=[])
        client = CNBReleaseClient("owner/resources", "fixture-token", transport)
        with self.assertRaises(CNBReleaseError):
            client.update_release_body("asr-models", "body")
        self.assertEqual([call.method for call in transport.calls], ["GET"])

    def test_empty_body_rejected_before_any_call(self):
        transport = ScriptedCNBTransport(api_responses=[], put_responses=[])
        client = CNBReleaseClient("owner/resources", "fixture-token", transport)
        with self.assertRaises(CNBReleaseError):
            client.update_release_body("asr-models", "   ")
        self.assertEqual(transport.calls, [])

    def test_readback_mismatch_retries_three_times_then_fails(self):
        stale = json.dumps({"id": "r7", "tag_name": "asr-models", "body": "old"}).encode()
        transport = ScriptedCNBTransport(api_responses=[
            CNBResponse(200, {}, stale), CNBResponse(200, {}, b"{}"), CNBResponse(200, {}, stale),
            CNBResponse(200, {}, stale), CNBResponse(200, {}, b"{}"), CNBResponse(200, {}, stale),
            CNBResponse(200, {}, stale), CNBResponse(200, {}, b"{}"), CNBResponse(200, {}, stale),
        ], put_responses=[])
        client = CNBReleaseClient("owner/resources", "fixture-token", transport)
        with self.assertRaises(CNBReleaseError):
            client.update_release_body("asr-models", "new body")
        self.assertEqual([call.method for call in transport.calls].count("PATCH"), 3)


class ReadmeSyncStatusTests(unittest.TestCase):
    """下游确认契约（2026-10-07 平台席）：GET build/status/{sn} 只读查询。"""

    def test_request_contract(self):
        from cnb_release import readme_sync_status
        transport = ScriptedCNBTransport(
            api_responses=[CNBResponse(200, {}, json.dumps({"sn": "cnb-x", "status": "success"}).encode())],
            put_responses=[])
        result = readme_sync_status("owner/resources", "cnb-x", "fixture-token", transport)
        self.assertEqual(result["status"], "success")
        self.assertEqual(len(transport.calls), 1)
        call = transport.calls[0]
        self.assertEqual(call.method, "GET")
        self.assertEqual(call.url, "https://api.cnb.cool/owner/resources/-/build/status/cnb-x")
        self.assertEqual(call.headers.get("Authorization"), "Bearer fixture-token")

    def test_4xx_raises(self):
        from cnb_release import readme_sync_status
        transport = ScriptedCNBTransport(
            api_responses=[CNBResponse(404, {}, b'{"errmsg":"not found"}')], put_responses=[])
        with self.assertRaises(CNBReleaseError):
            readme_sync_status("owner/resources", "cnb-x", "fixture-token", transport)

    def test_invalid_sn_rejected(self):
        from cnb_release import readme_sync_status
        transport = ScriptedCNBTransport(api_responses=[], put_responses=[])
        with self.assertRaises(CNBReleaseError):
            readme_sync_status("owner/resources", "../escape", "fixture-token", transport)
        self.assertEqual(len(transport.calls), 0)


class CNBReadModuleTests(unittest.TestCase):
    """cnb_read 有界并行批下载（2026-10-07 平台席 A 方案）：并发路径与
    fail-fast 语义的离线钉（注入 download 缝，无网络）。"""

    def _models(self):
        return [{"url": "m1.zip", "sha256": "a" * 64, "bytes": 3},
                {"url": "m2.zip", "sha256": "b" * 64, "bytes": 3}]

    def test_bounded_parallel_downloads_all_assets(self):
        models = self._models()
        assets = {m["url"]: {"name": m["url"]} for m in models}
        calls = []

        def download(repo, asset, dest, sha, size):
            time.sleep(0.05)
            Path(dest).parent.mkdir(parents=True, exist_ok=True)
            Path(dest).write_bytes(b"abc")
            calls.append(asset["name"])

        with tempfile.TemporaryDirectory() as td:
            download_assets(models, assets, Path(td), "owner/resources",
                            tag="asr-models", parallel=2, download=download)
            self.assertEqual(sorted(calls), ["m1.zip", "m2.zip"])
            self.assertEqual(Path(td, "m1.zip").read_bytes(), b"abc")

    def test_fail_fast_on_any_asset_error(self):
        models = self._models()
        assets = {m["url"]: {"name": m["url"]} for m in models}

        def failing(repo, asset, dest, sha, size):
            if asset["name"] == "m2.zip":
                raise ValueError("boom")
            time.sleep(0.2)
            Path(dest).parent.mkdir(parents=True, exist_ok=True)
            Path(dest).write_bytes(b"abc")

        with tempfile.TemporaryDirectory() as td:
            with self.assertRaises(ValueError):
                download_assets(models, assets, Path(td), "owner/resources",
                                tag="asr-models", parallel=2, download=failing)


if __name__ == "__main__":
    unittest.main()
