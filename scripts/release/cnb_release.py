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
import time
import urllib.error
import urllib.parse
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


class CNBRedirectHandler(urllib.request.HTTPRedirectHandler):
    """Redirect policy(2026-10-06 修订):匿名公开请求白名单跟随,带凭据请求一律拒跳。

    urllib 会把自定义头(含 Authorization)转发到重定向目标——跨主机跳转必须
    拒绝,否则泄漏 bearer token(原始语义,保持不变)。修订依据:CNB 下载端点
    cnb.cool/.../releases/download/... 对匿名 GET 一律 302 → asset.cnb.cool
    (每次请求不同临时 token,不可预计算;发布回读核对三连败 37343613767
    实证)。该 302 与 App 真机下载链同构(URLSession 默认跟随),跟随它让回读
    验证的正是 App 实际走的链路。约束:①原请求带 Authorization/X-Authorization/
    Cookie → 一律拒跳(fail-closed);②目标主机必须在 ALLOWED_REDIRECT_HOSTS;
    ③单请求最多 MAX_REDIRECT_HOPS 跳(handler 实例随 opener 每次请求新建,
    计数器天然按请求隔离,防白名单内循环)。
    """

    ALLOWED_REDIRECT_HOSTS = {"cnb.cool", "asset.cnb.cool", "cos.cnb.cool"}
    MAX_REDIRECT_HOPS = 3

    def __init__(self):
        super().__init__()
        self._hops = 0

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        # 可观测性(2026-10-06 发布三连败定位):错误携带被拒跳的源/目标
        # netloc+path(不含 query——预签名上传 URL 的 query 含签名参数,
        # 不得入日志);Authorization 只存在于 headers,本消息不触碰。
        from urllib.parse import urlsplit
        source = urlsplit(req.full_url)
        target = urlsplit(newurl)
        sensitive = any(h.lower() in ("authorization", "x-authorization", "cookie")
                        for h in (req.headers or {}))
        self._hops += 1
        if sensitive or target.netloc not in self.ALLOWED_REDIRECT_HOSTS \
                or self._hops > self.MAX_REDIRECT_HOPS:
            raise CNBReleaseError(
                "CNB API redirect refused: {} {} -> {} {}".format(
                    req.get_method(), source.netloc + source.path,
                    code, target.netloc + target.path))
        new_request = super().redirect_request(req, fp, code, msg, headers, newurl)
        # urllib 会把原请求头合并进新请求——防御性剥离全部敏感头后再放行。
        for header in list(getattr(new_request, "headers", {}) or {}):
            if header.lower() in ("authorization", "x-authorization", "cookie"):
                del new_request.headers[header]
        return new_request


class NoRedirectHandler(urllib.request.HTTPRedirectHandler):
    """预签名 PUT 专用:一律拒跳(签名在 URL query 里,跨主机重放即泄漏上传授权)。

    上传 URL 是 API 签发的不透明串,其签名参数不得出现在日志,更不得随跳转
    转发到未授权主机。CNB 观测到的 302 只发生在匿名 GET 下载端点(由
    CNBRedirectHandler 白名单跟随),PUT 保持 fail-closed。
    """

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        from urllib.parse import urlsplit
        source = urlsplit(req.full_url)
        target = urlsplit(newurl)
        raise CNBReleaseError(
            "CNB API redirect refused: {} {} -> {} {}".format(
                req.get_method(), source.netloc + source.path,
                code, target.netloc + target.path))


class UrllibCNBTransport(CNBTransport):
    def request(self, method, url, headers, body=None):
        request = urllib.request.Request(url, data=body, headers=headers, method=method)
        opener = urllib.request.build_opener(CNBRedirectHandler)
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
    def __init__(self, method, url, headers, body=None):
        self.method = method
        self.url = url
        self.headers = dict(headers)
        self.body = body


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
        self.calls.append(FakeCNBCall(method, url, headers, body))
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


def validate_https_url(url, *, require_host=None, purpose, allow_query=False):
    parsed = urllib.parse.urlsplit(url)
    if parsed.scheme != "https" or not parsed.hostname:
        raise CNBReleaseError("CNB " + purpose + " URL must be HTTPS with a host")
    if parsed.username or parsed.password or parsed.fragment:
        raise CNBReleaseError("CNB " + purpose + " URL must not carry credentials/fragment")
    if parsed.query and not allow_query:
        # 预签名上传/确认 URL 的 query 是能力令牌(实测 2026-10-05:verify_url 带
        # query 才可确认)——仅对这两类 grant URL 放行;自构造下载 URL 仍禁 query。
        raise CNBReleaseError("CNB " + purpose + " URL must not carry a query string")
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


class RecordingUploadTransport(UrllibCNBTransport):
    """记录 PUT 上传宿主/路径(掩码),发布末尾打印一次——UPLOAD_PATH_PREFIX 数据源
    (业主 2026-10-05 指令:根据 ASR 输出自行定义创建)。publish 与 probe 共用
    (2026-10-05 审查收敛:此前两份实现前缀推导已出现分叉)。"""

    def __init__(self):
        super().__init__()
        self.upload_url = None

    def put(self, url, headers, file_path, size):
        self.upload_url = url
        return super().put(url, headers, file_path, size)


def print_masked_upload_prefix(transport):
    if transport.upload_url is None:
        return
    parsed = urllib.parse.urlsplit(transport.upload_url)
    segments = [s for s in parsed.path.split("/") if s]
    prefix = parsed.scheme + "://" + parsed.netloc + "/" + "/".join(segments[:2])
    print("observed upload host: " + parsed.netloc, flush=True)
    print("UPLOAD_PATH_PREFIX candidate: " + prefix, flush=True)


def public_download_url(repository, tag, asset_name):
    """匿名公开下载 URL(CNB Release 资产交付路径的单一文法出口)。"""
    url = DOWNLOAD_BASE + "/" + repository + "/-/releases/download/" + tag + "/" + asset_name
    validate_https_url(url, purpose="download")
    return url


README_SYNC_EVENT = "api_trigger_readme_sync"


def start_readme_sync(repository, tag, token, transport, api_base=API_BASE,
                      branch="main", attempts=2):
    """Release 更新成功后触发 CNB README 同步管线(业主 2026-10-07 方案 B)。

    `POST {api_base}/{repository}/-/build/start`,事件 `api_trigger_readme_sync`,
    env README_SYNC_TAG=<tag>,sync="false"(异步;响应含 sn/buildLogUrl)。
    权限:令牌需 `repo-cnb-trigger:rw`(CNB_RESOURCE_TOKEN 实测已含)。
    重试:仅网络错误与 5xx;4xx(权限/参数)立即失败不重试。
    失败语义由调用方决定(发布链按「通知通道不阻塞发布」降级为 warning)。
    """
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
        raise CNBReleaseError("Invalid CNB repository")
    url = api_base.rstrip("/") + "/" + repository + "/-/build/start"
    validate_https_url(url, require_host=urllib.parse.urlsplit(api_base).hostname,
                       purpose="readme sync trigger")
    body = json.dumps({
        "branch": branch, "event": README_SYNC_EVENT, "env": {"README_SYNC_TAG": tag},
        "sync": "false", "title": "readme-sync: " + tag}).encode()
    headers = {"Authorization": "Bearer " + token, "Accept": "application/json",
               "Content-Type": "application/json"}
    last_error = "no attempt"
    for _ in range(attempts):
        try:
            response = transport.request("POST", url, headers, body)
        except CNBReleaseError as error:
            last_error = str(error)
            time.sleep(1)
            continue
        if 200 <= response.status < 300:
            result = _json(response, "readme sync trigger")
            if not result.get("sn"):
                raise CNBReleaseError("README sync trigger returned no sn")
            return result
        detail = response.body[:200].decode("utf-8", errors="replace") if response.body else ""
        if 400 <= response.status < 500:
            raise CNBReleaseError(
                "README sync trigger rejected with HTTP %d: %s" % (response.status, detail))
        last_error = "HTTP %d: %s" % (response.status, detail)
        time.sleep(1)
    raise CNBReleaseError("README sync trigger failed: " + last_error)


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
            detail = response.body[:200].decode("utf-8", errors="replace") if response.body else ""
            raise CNBReleaseError("CNB API %s %s failed with HTTP %d: %s" % (method, path, response.status, detail))
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
        return self._create_release(tag, title, body)

    def start_readme_sync(self, tag):
        """发布收尾:触发 README 同步管线(方案 B;失败由调用方决定降级)。"""
        return start_readme_sync(self.repository, tag, self.token, self.transport,
                                 api_base=self.api_base)

    def _create_release(self, tag, title, body):
        """Release 创建唯一出口(ensure_release 与 upload_immutable 共用)。"""
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

    def _verify_read_back(self, tag, asset_name, expected_size, expected_sha256, release=None):
        asset = self._asset_in(tag, asset_name) if release is None else next(
            (a for a in release.get("assets") or [] if a.get("name") == asset_name), None)
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
        validate_https_url(url, require_host=urllib.parse.urlsplit(self.api_base).hostname,
                           purpose="API", allow_query=True)
        payload = json.dumps(body).encode() if body is not None else None
        headers = self._api_headers()
        if payload is not None:
            headers["Content-Type"] = "application/json"
        response = self.transport.request(method, url, headers, payload)
        if not 200 <= response.status < 300:
            raise CNBReleaseError("CNB API %s failed with HTTP %d" % (method, response.status))
        return response

    def upload_immutable(self, tag, path, asset_name, expected_sha256, overwrite=False):
        """Upload one asset with hash-compare semantics.

        Same name + same digest → skip the upload entirely (read-back only).
        Same name + different digest: `overwrite=False` (seed/immutable contexts)
        raises a hard collision; `overwrite=True` (owner rule 2026-10-05, ASR
        publish path: 生成的下载文件与 CNB 已有最新文件 hash 比对,不同才更新
        上传、相同跳过) updates the asset in place.

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

        existing = self.get_release(tag)
        if existing is not None:
            if existing.get("tag_name") != tag:
                raise CNBReleaseError("CNB release tag mismatch")
            for asset in existing.get("assets") or []:
                if asset.get("name") != asset_name:
                    continue
                algo, value = _asset_digest(asset)
                if algo == "sha256" and value == expected_sha256 and int(asset.get("size") or -1) == size:
                    # 相同内容跳过上传(业主 R2):清单已含本资产,直接以本次
                    # 已取回的清单核对,省一次整清单 GET。
                    return self._verify_read_back(tag, asset_name, size, expected_sha256, release=existing)
                if algo != "sha256" or not value:
                    # 清单缺哈希的历史/种子资产:无法证明相同,按 overwrite 语义
                    # 上传覆盖(只增资产则硬错)——显式打点,避免静默重复上传
                    # 或静默放行(2026-10-05 审查)。
                    print("CNB inventory has no digest for " + asset_name +
                          "; hash-compare skip unavailable, uploading", flush=True)
                if not overwrite:
                    raise CNBReleaseError("CNB collision: " + asset_name + " exists with different content")
        if existing is None:
            title, body = release_notes_for_tag(tag)
            release = self._create_release(tag, title, body)
        else:
            release = existing

        response = self._api("POST", "/-/releases/" + str(release["id"]) + "/asset-upload-url", {
            "asset_name": asset_name, "size": size, "overwrite": overwrite, "ttl": 0})
        grant = _json(response, "upload-url grant")
        upload_url = grant.get("upload_url") or ""
        verify_url = grant.get("verify_url") or ""
        # 先验后传:两个 URL 都在 PUT 之前校验,坏 grant 不允许流出任何字节。
        validate_https_url(upload_url, purpose="upload", allow_query=True)
        validate_https_url(verify_url, require_host=urllib.parse.urlsplit(self.api_base).hostname,
                           purpose="verify", allow_query=True)
        # 上传主机不硬编码(设计文档:upload_url 是不透明串,前缀由业主探针定);
        # 只保证 HTTPS/无凭据/默认端口,且绝不携带 bearer。
        put_response = self.transport.put(upload_url, {}, path, size)
        # PUT 非 2xx 即上传失败(过期 grant 403 / 超大 413 / 服务端 5xx)——
        # 此前丢弃该响应、继续 confirm 跳,错误只以误导性的「read-back 缺失」
        # 浮出且白跑一次变异的确认请求(2026-10-05 审查:先验后传的顺序不变)。
        if not 200 <= put_response.status < 300:
            raise CNBReleaseError("CNB upload PUT failed with HTTP %d" % put_response.status)
        self._api_absolute("POST", verify_url)
        return self._verify_read_back(tag, asset_name, size, expected_sha256)

    def download_asset(self, tag, asset_name, destination, max_bytes):
        """Anonymous public download (no token): App-facing delivery path, bounded."""
        url = public_download_url(self.repository, tag, asset_name)
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
