#!/usr/bin/env python3
"""Bounded CNB Release API client for public model-resource publishing.

2026-10-03 plan (docs/superpowers/plans/2026-10-03-cnb-public-resource-publishers.md)
Task 1: authenticated CNB OpenAPI upload sequence, never forwards bearer auth to the
pre-signed upload host, verifies asset read-back, and is fully fakeable offline.
"""
import argparse
import hashlib
import json
import os
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path

TOOLS = Path(__file__).resolve().parent

ALLOWED_TAGS = {"asr-models", "llama-models", "llama-xcframework"}
API_BASE = "https://api.cnb.cool"
DOWNLOAD_BASE = "https://cnb.cool"
MAX_RESPONSE_BYTES = 8 << 20


class CNBReleaseError(RuntimeError):
    """Public operation failure type; token values must never appear in messages."""


class CNBResponse:
    def __init__(self, status, headers, body):
        self.status = int(status)
        self.headers = dict(headers or {})
        self.body = bytes(body) if body is not None else b""


class CNBTransport:
    def request(self, method, url, headers, body=None):
        raise NotImplementedError

    def put(self, url, headers, file_path, size):
        raise NotImplementedError


class NoRedirectHandler(urllib.request.HTTPRedirectHandler):
    """Fail closed on every redirect: the client validates each hop itself.

    urllib forwards custom headers (including Authorization) across redirects;
    a cross-host redirect would leak the bearer token, so redirects are refused
    at the transport layer and never replayed.
    """

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise CNBReleaseError("CNB API redirect refused")


class UrllibCNBTransport(CNBTransport):
    def request(self, method, url, headers, body=None):
        request = urllib.request.Request(url, data=body, headers=headers, method=method)
        opener = urllib.request.build_opener(NoRedirectHandler)
        try:
            with opener.open(request, timeout=120) as response:
                data = response.read(MAX_RESPONSE_BYTES + 1)
                if len(data) > MAX_RESPONSE_BYTES:
                    raise CNBReleaseError("CNB response exceeds size bound")
                return CNBResponse(response.status, dict(response.headers), data)
        except urllib.error.HTTPError as error:
            data = error.read(MAX_RESPONSE_BYTES + 1)
            if len(data) > MAX_RESPONSE_BYTES:
                raise CNBReleaseError("CNB response exceeds size bound")
            return CNBResponse(error.code, dict(error.headers), data)
        except urllib.error.URLError as error:
            raise CNBReleaseError("CNB request failed: " + str(error.reason)) from error

    def put(self, url, headers, file_path, size):
        opener = urllib.request.build_opener(NoRedirectHandler)
        request = urllib.request.Request(url, headers=headers, method="PUT")
        with open(file_path, "rb") as source:
            request.data = source
            try:
                with opener.open(request, timeout=600) as response:
                    data = response.read(MAX_RESPONSE_BYTES + 1)
                    if len(data) > MAX_RESPONSE_BYTES:
                        raise CNBReleaseError("CNB upload response exceeds size bound")
                    return CNBResponse(response.status, dict(response.headers), data)
            except urllib.error.HTTPError as error:
                data = error.read(MAX_RESPONSE_BYTES + 1)
                return CNBResponse(error.code, dict(error.headers), data)
            except urllib.error.URLError as error:
                raise CNBReleaseError("CNB upload failed: " + str(error.reason)) from error


class FakeCNBCall:
    def __init__(self, method, url, headers):
        self.method = method
        self.url = url
        self.headers = dict(headers)


class ScriptedCNBTransport(CNBTransport):
    """Offline test fake: dequeues canned responses, records calls in order.

    Raises AssertionError when the client makes a call beyond the script, so a
    sequence change can never silently pass.
    """

    def __init__(self, api_responses, put_responses):
        self.api_responses = list(api_responses)
        self.put_responses = list(put_responses)
        self.calls = []

    def request(self, method, url, headers, body=None):
        if not self.api_responses:
            raise AssertionError("Unexpected extra CNB API call: " + method + " " + url)
        self.calls.append(FakeCNBCall(method, url, headers))
        return self.api_responses.pop(0)

    def put(self, url, headers, file_path, size):
        if not self.put_responses:
            raise AssertionError("Unexpected extra CNB PUT call: " + url)
        self.calls.append(FakeCNBCall("PUT", url, headers))
        return self.put_responses.pop(0)


def release_notes_for_tag(tag):
    """Immutable title/body for an allowlisted resource tag; missing template blocks creation."""
    if tag not in ALLOWED_TAGS:
        raise CNBReleaseError("Unknown resource tag: " + tag)
    path = TOOLS / "cnb-release-notes" / (tag + ".md")
    if not path.is_file():
        raise CNBReleaseError("Missing CNB release-notes template for tag: " + tag)
    lines = path.read_text(encoding="utf-8").splitlines()
    title = lines[0].lstrip("#").strip() if lines else ""
    body = "\n".join(lines[1:]).strip()
    if not title or not body:
        raise CNBReleaseError("CNB release-notes template is empty: " + tag)
    return title, body


def validate_https_url(url, *, require_host=None, purpose):
    parsed = urllib.parse.urlsplit(url)
    if parsed.scheme != "https" or not parsed.hostname:
        raise CNBReleaseError("CNB " + purpose + " URL must be HTTPS with a host")
    if parsed.username or parsed.password or parsed.query or parsed.fragment:
        raise CNBReleaseError("CNB " + purpose + " URL must not carry credentials/query/fragment")
    if parsed.port not in (None, 443):
        raise CNBReleaseError("CNB " + purpose + " URL must use the default port")
    if require_host is not None and parsed.hostname != require_host:
        raise CNBReleaseError("CNB " + purpose + " URL host is not authorized")
    return parsed


def _json(response, purpose):
    try:
        value = json.loads(response.body.decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        raise CNBReleaseError("CNB " + purpose + " response is not JSON")
    if not isinstance(value, dict):
        raise CNBReleaseError("CNB " + purpose + " response has an unexpected shape")
    return value


def _asset_digest(asset):
    algo = asset.get("hash_algo") or asset.get("hashAlgo") or ""
    value = asset.get("hash_value") or asset.get("hashValue") or ""
    return (algo, value)


class CNBAssetReceipt:
    def __init__(self, name, size, sha256, path):
        self.name = name
        self.size = int(size)
        self.sha256 = sha256
        self.path = path


class CNBReleaseClient:
    """Authenticated CNB Release publisher.

    Bearer auth is sent only to `api.cnb.cool`; the pre-signed upload URL gets
    no Authorization header. upload_url is opaque (owner-probed prefix); its
    host is validated as HTTPS/no-credentials but not hardcoded.
    """

    def __init__(self, repository, token, transport, api_base=API_BASE):
        if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
            raise CNBReleaseError("Invalid CNB repository")
        self.repository = repository
        self.token = token
        self.transport = transport
        self.api_base = api_base.rstrip("/")

    def _api_headers(self):
        return {"Authorization": "Bearer " + self.token, "Accept": "application/json"}

    def _api(self, method, path, body=None):
        url = self.api_base + "/" + self.repository + path
        payload = json.dumps(body).encode() if body is not None else None
        headers = self._api_headers()
        if payload is not None:
            headers["Content-Type"] = "application/json"
        response = self.transport.request(method, url, headers, payload)
        if not 200 <= response.status < 300:
            raise CNBReleaseError("CNB API %s %s failed with HTTP %d" % (method, path, response.status))
        return response

    def get_release(self, tag):
        """Returns the release dict, or None when the tag does not exist."""
        url = self.api_base + "/" + self.repository + "/-/releases/tags/" + tag
        response = self.transport.request("GET", url, self._api_headers())
        if response.status == 404:
            return None
        if not 200 <= response.status < 300:
            raise CNBReleaseError("CNB release lookup failed with HTTP %d" % response.status)
        return _json(response, "release lookup")

    def ensure_release(self, tag, title, body):
        existing = self.get_release(tag)
        if existing is not None:
            if existing.get("tag_name") != tag:
                raise CNBReleaseError("CNB release tag mismatch")
            return existing
        if tag not in ALLOWED_TAGS:
            raise CNBReleaseError("Unknown resource tag: " + tag)
        response = self._api("POST", "/-/releases", {
            "tag_name": tag, "target_commitish": os.environ.get("CNB_RESOURCE_TARGET_COMMITISH", "main"),
            "name": title, "body": body, "draft": False, "prerelease": False})
        release = _json(response, "release creation")
        if not release.get("id"):
            raise CNBReleaseError("CNB release creation returned no id")
        return release

    def list_assets(self, tag):
        release = self.get_release(tag)
        if release is None:
            raise CNBReleaseError("CNB release does not exist: " + tag)
        return release.get("assets") or []

    def _asset_in(self, tag, asset_name):
        release = self.get_release(tag)
        if release is None:
            return None
        for asset in release.get("assets") or []:
            if asset.get("name") == asset_name:
                return asset
        return None

    def _verify_read_back(self, tag, asset_name, expected_size, expected_sha256):
        asset = self._asset_in(tag, asset_name)
        if asset is None:
            raise CNBReleaseError("CNB read-back: asset missing from inventory: " + asset_name)
        if int(asset.get("size") or -1) != expected_size:
            raise CNBReleaseError("CNB read-back: size mismatch for " + asset_name)
        algo, value = _asset_digest(asset)
        if algo != "sha256" or value != expected_sha256:
            raise CNBReleaseError("CNB read-back: digest mismatch for " + asset_name)
        path = asset.get("path") or ""
        expected_path = "/" + self.repository + "/-/releases/download/" + tag + "/" + asset_name
        if path != expected_path:
            raise CNBReleaseError("CNB read-back: asset path is out of scope for " + asset_name)
        return CNBAssetReceipt(asset_name, expected_size, expected_sha256, path)

    def _api_absolute(self, method, url, body=None):
        """POST/PUT-style call to an API-issued absolute URL (verify/confirm hop)."""
        validate_https_url(url, require_host=urllib.parse.urlsplit(self.api_base).hostname, purpose="API")
        payload = json.dumps(body).encode() if body is not None else None
        headers = self._api_headers()
        if payload is not None:
            headers["Content-Type"] = "application/json"
        response = self.transport.request(method, url, headers, payload)
        if not 200 <= response.status < 300:
            raise CNBReleaseError("CNB API %s failed with HTTP %d" % (method, response.status))
        return response

    def upload_immutable(self, tag, path, asset_name, expected_sha256):
        """Upload one asset; same name+digest reuses, same name+different digest is a hard collision.

        Call sequence for a fresh release: GET tag (404) → POST release → POST
        upload-url → PUT (no bearer) → POST confirmation → GET read-back.
        """
        if tag not in ALLOWED_TAGS:
            raise CNBReleaseError("Unknown resource tag: " + tag)
        path = Path(path)
        if not path.is_file() or path.is_symlink():
            raise CNBReleaseError("CNB upload source is not a regular file: " + str(path))
        size = path.stat().st_size
        if not re.fullmatch(r"[0-9a-f]{64}", expected_sha256):
            raise CNBReleaseError("CNB upload requires a SHA-256 digest")
        digest = hashlib.sha256()
        with open(path, "rb") as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(chunk)
        actual = digest.hexdigest()
        if actual != expected_sha256:
            raise CNBReleaseError("CNB upload refused: local digest mismatch for " + asset_name)

        release = self.get_release(tag)
        if release is not None:
            if release.get("tag_name") != tag:
                raise CNBReleaseError("CNB release tag mismatch")
            for asset in release.get("assets") or []:
                if asset.get("name") != asset_name:
                    continue
                algo, value = _asset_digest(asset)
                if algo == "sha256" and value == expected_sha256 and int(asset.get("size") or -1) == size:
                    return self._verify_read_back(tag, asset_name, size, expected_sha256)
                raise CNBReleaseError("CNB collision: " + asset_name + " exists with different content")
        else:
            title, body = release_notes_for_tag(tag)
            response = self._api("POST", "/-/releases", {
                "tag_name": tag, "target_commitish": os.environ.get("CNB_RESOURCE_TARGET_COMMITISH", "main"),
                "name": title, "body": body, "draft": False, "prerelease": False})
            release = _json(response, "release creation")
            if not release.get("id"):
                raise CNBReleaseError("CNB release creation returned no id")

        response = self._api("POST", "/-/releases/" + str(release["id"]) + "/asset-upload-url", {
            "asset_name": asset_name, "size": size, "overwrite": False, "ttl": 0})
        grant = _json(response, "upload-url grant")
        upload_url = grant.get("upload_url") or ""
        verify_url = grant.get("verify_url") or ""
        # 先验后传:两个 URL 都在 PUT 之前校验,坏 grant 不允许流出任何字节。
        validate_https_url(upload_url, purpose="upload")
        validate_https_url(verify_url, require_host=urllib.parse.urlsplit(self.api_base).hostname, purpose="verify")
        # 上传主机不硬编码(设计文档:upload_url 是不透明串,前缀由业主探针定);
        # 只保证 HTTPS/无凭据/默认端口,且绝不携带 bearer。
        self.transport.put(upload_url, {}, path, size)
        self._api_absolute("POST", verify_url)
        return self._verify_read_back(tag, asset_name, size, expected_sha256)

    def download_asset(self, tag, asset_name, destination, max_bytes):
        """Anonymous public download (no token): App-facing delivery path, bounded."""
        url = DOWNLOAD_BASE + "/" + self.repository + "/-/releases/download/" + tag + "/" + asset_name
        validate_https_url(url, purpose="download")
        destination = Path(destination)
        destination.parent.mkdir(parents=True, exist_ok=True)
        response = self.transport.request("GET", url, {})
        if not 200 <= response.status < 300:
            raise CNBReleaseError("CNB anonymous download failed with HTTP %d" % response.status)
        if len(response.body) > max_bytes:
            raise CNBReleaseError("CNB anonymous download exceeds size bound")
        destination.write_bytes(response.body)
        return destination


def _redact(text, secrets):
    for secret in secrets:
        if secret:
            text = text.replace(secret, "<redacted>")
    return text


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    upload = sub.add_parser("upload", help="Upload one immutable asset to a CNB Release")
    upload.add_argument("--tag", required=True)
    upload.add_argument("--path", type=Path, required=True)
    upload.add_argument("--name", required=True)
    upload.add_argument("--sha256", required=True)
    upload.add_argument("--repository")
    args = parser.parse_args()
    token = os.environ.get("CNB_TOKEN")
    repository = args.repository or os.environ.get("CNB_RESOURCE_REPOSITORY")
    try:
        if not token:
            raise CNBReleaseError("CNB_TOKEN is required for upload")
        if not repository:
            raise CNBReleaseError("CNB_RESOURCE_REPOSITORY is required for upload")
        client = CNBReleaseClient(repository, token, UrllibCNBTransport())
        if args.command == "upload":
            receipt = client.upload_immutable(args.tag, args.path, args.name, args.sha256)
            print(json.dumps({"name": receipt.name, "size": receipt.size,
                              "sha256": receipt.sha256, "path": receipt.path}))
        return 0
    except (CNBReleaseError, OSError, ValueError) as error:
        print("CNB-RELEASE-ERROR: " + _redact(str(error), [token]), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
