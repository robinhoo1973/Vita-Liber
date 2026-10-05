#!/usr/bin/env python3
"""Offline fake-transport tests for the bounded CNB Release publisher (2026-10-03 plan Task 1).

Never performs network access: ScriptedCNBTransport dequeues canned responses and
asserts the client makes exactly the scripted calls.
"""
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from cnb_release import (CNBReleaseClient, CNBReleaseError, CNBResponse,
                         FakeCNBCall, ScriptedCNBTransport, release_notes_for_tag)


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
                    CNBResponse(200, {}, json.dumps({"id": "r1", "tag_name": "asr-models",
                                                     "assets": [asset_payload("model.zip", payload)]}).encode()),
                ],
                put_responses=[],
            )
            client = CNBReleaseClient("owner/resources", "fixture-token", transport)
            receipt = client.upload_immutable("asr-models", path, "model.zip", digest)
            self.assertEqual(receipt.sha256, digest)
        self.assertEqual([call.method for call in transport.calls], ["GET", "GET"])

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


if __name__ == "__main__":
    unittest.main()
