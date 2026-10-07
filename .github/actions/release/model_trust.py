"""Public Ed25519 resource-metadata verification; this module never reads private keys."""
import base64
from datetime import datetime, timedelta, timezone
import hashlib
import re
from urllib.parse import urlparse

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

from asr_package import MAX_EXPANDED, decode_json, json_bytes, slug, validate_index

HOSTS = {"github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"}
# CNB 资源仓基址+传输主机(2026-10-03 cutover 定案):assetBaseURL 只接受下面两个
# 已知基址形态之一(精确枚举,不接受任意值);allowedHosts 随基址主机选对应集合。
CNB_HOSTS = {"cnb.cool", "asset.cnb.cool"}
ASSET_HOSTS_BY_NETLOC = {"github.com": HOSTS, "cnb.cool": CNB_HOSTS}


def utc_date(value):
    if not isinstance(value, str) or not re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z", value):
        raise ValueError("Invalid metadata timestamp")
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def payload_bytes(envelope):
    if not isinstance(envelope.get("payload"), str) or len(envelope["payload"]) > 1024**2:
        raise ValueError("Invalid signed payload")
    return base64.b64decode(envelope["payload"], validate=True)


def payload(envelope):
    return decode_json(payload_bytes(envelope))


def check_scope(value, role, asset_kind="asr"):
    if value.get("schemaVersion") != 1 or value.get("role") != role or value.get("app") != "vitaliber" or value.get("assetKind") != asset_kind:
        raise ValueError("Signed metadata scope/version mismatch")


def positive(value):
    return type(value) is int and 0 < value < 2**63


def validate_root(root, asset_kind="asr"):
    check_scope(root, "root", asset_kind)
    if not positive(root.get("version")):
        raise ValueError("Invalid root version")
    utc_date(root["expiresAt"])
    keys = root.get("keys", [])
    if not 1 <= len(keys) <= 16:
        raise ValueError("Invalid root key count")
    identities = set()
    for key in keys:
        raw = base64.b64decode(key["publicKey"], validate=True)
        if len(raw) != 32 or hashlib.sha256(raw).hexdigest() != key["id"] or key["id"] in identities:
            raise ValueError("Invalid/duplicate public key identity")
        identities.add(key["id"])
    for role in ("root", "catalog"):
        allowed = root[role + "KeyIDs"]
        threshold = root[role + "Threshold"]
        if not positive(threshold) or len(set(allowed)) != len(allowed) or not threshold <= len(allowed) <= 16 or not set(allowed) <= identities:
            raise ValueError("Invalid signing threshold/key set")
    if set(root["rootKeyIDs"]) & set(root["catalogKeyIDs"]):
        raise ValueError("Root and catalog keys must be separate")
    url = urlparse(root["assetBaseURL"])
    # CNB 下载路径比 GitHub 多一个 `/-/` 段(/owner/repo/-/releases/download/…),
    # 按 netloc 分路径形态(两者都是精确枚举,不接受其它变体)。
    if asset_kind == "asr":
        path_shapes = {  # netloc -> 路径正则
            "github.com": r"/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/releases/download/asr-models",
            "cnb.cool": r"/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/-/releases/download/asr-models",
        }
    else:
        path_shapes = {
            "github.com": r"/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/releases/download/[A-Za-z0-9_.-]+",
            "cnb.cool": r"/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/-/releases/download/[A-Za-z0-9_.-]+",
        }
    if (url.scheme != "https" or url.query or url.fragment
            or url.netloc not in path_shapes
            or not re.fullmatch(path_shapes[url.netloc], url.path)):
        raise ValueError(f"{asset_kind} assets must use an authorized Release base")
    if not root["allowedHosts"] or not set(root["allowedHosts"]) <= ASSET_HOSTS_BY_NETLOC[url.netloc]:
        raise ValueError("Unexpected resource host policy")


def verify_envelope(envelope, root, role, asset_kind="asr"):
    validate_root(root, asset_kind)
    data = payload_bytes(envelope)
    signatures = envelope.get("signatures", [])
    if not 1 <= len(signatures) <= 16:
        raise ValueError("Invalid signature count")
    public = {key["id"]: key["publicKey"] for key in root["keys"]}
    allowed = set(root[role + "KeyIDs"])
    seen, verified = set(), set()
    for signature in signatures:
        identity = signature["keyId"]
        if identity in seen:
            raise ValueError("Duplicate signature keyId")
        seen.add(identity)
        if identity not in allowed:
            continue
        raw_signature = base64.b64decode(signature["signature"], validate=True)
        if len(raw_signature) != 64:
            raise ValueError("Invalid Ed25519 signature length")
        try:
            Ed25519PublicKey.from_public_bytes(base64.b64decode(public[identity], validate=True)).verify(raw_signature, data)
            verified.add(identity)
        except InvalidSignature:
            continue
    if len(verified) < root[role + "Threshold"]:
        raise ValueError("Signature threshold not satisfied")
    result = decode_json(data)
    check_scope(result, role, asset_kind)
    return result


def trusted_root(envelope, *, now=None, previous=None, asset_kind="asr"):
    root = payload(envelope)
    validate_root(root, asset_kind)
    if previous is not None:
        old = payload(previous)
        validate_root(old, asset_kind)
        if root["version"] != old["version"] + 1:
            raise ValueError("Root updates must be consecutive")
        verify_envelope(envelope, old, "root", asset_kind)
    verify_envelope(envelope, root, "root", asset_kind)
    if now is not None and utc_date(root["expiresAt"]) <= now:
        raise ValueError("Root metadata expired")
    return root


def verify_catalog(root_envelope, catalog_envelope, *, previous=None, now=None, asset_kind="asr"):
    now = now or datetime.now(timezone.utc)
    root = trusted_root(root_envelope, now=now, asset_kind=asset_kind)
    catalog = verify_envelope(catalog_envelope, root, "catalog", asset_kind)
    if catalog.get("rootVersion") != root["version"] or not positive(catalog.get("catalogVersion")):
        raise ValueError("Catalog/root version mismatch")
    issued, expires = utc_date(catalog["issuedAt"]), utc_date(catalog["expiresAt"])
    if expires <= now or issued > now + timedelta(minutes=5) or expires <= issued or expires - issued > timedelta(days=31):
        raise ValueError("Catalog expired or outside validity window")
    if previous is not None:
        # 先读旧目录载荷再决定是否比对(2026-10-05 扫尾审查):旧实现先对
        # **当前根**验旧目录——跨根轮换的 previous 用旧 catalogKeyIDs 签名,
        # 在新根下必然「Signature threshold not satisfied」,rootVersion 守卫
        # 永远不可达。跨根单调性由发布侧 check_remote_catalog_chain 承担,
        # 本函数只做同根回滚/同版本异文拒绝。
        old_payload = payload(previous)
        if old_payload.get("rootVersion") == root["version"]:
            old = verify_envelope(previous, root, "catalog", asset_kind)
            if catalog["catalogVersion"] < old["catalogVersion"]:
                raise ValueError("Catalog rollback rejected")
            if catalog["catalogVersion"] == old["catalogVersion"] and payload_bytes(catalog_envelope) != payload_bytes(previous):
                raise ValueError("Catalog same-version equivocation rejected")
    if asset_kind != "asr":
        if not re.fullmatch(r"[0-9a-f]{64}", catalog.get("contentSha256", "")):
            raise ValueError("Medical catalog contentSha256 is invalid")
        return catalog
    index = catalog["index"]
    validate_index(index)
    if index["baseUrl"] != root["assetBaseURL"]:
        raise ValueError("Catalog asset base does not match its trust root")
    for model in index["models"]:
        if model.get("packaging") != "zip" or type(model.get("expandedBytes")) is not int or not 0 < model["expandedBytes"] <= MAX_EXPANDED:
            raise ValueError("Invalid signed package format/expanded budget")
        # 加密信封方案白名单(2026-10-05 R1):与 validate_index 同闸;未知方案
        # 拒绝(App 无法解密),缺省 = 明文 zip(历史目录冻结面)。
        if model.get("encryption") not in (None, "aes256gcm-v1"):
            raise ValueError("Unknown signed package encryption scheme")
        if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", model.get("minAppVersion", "")):
            raise ValueError("Signed minimum App version is required")
        slug(model["runtime"])
    # 包级签名验证(2026-10-06 业主指令:zip 文件也需要签名验证)——逐条目
    # Ed25519 对包 sha256 摘要的多重签名(域分离前缀 + 32 字节摘要),签名
    # 密钥与目录信封同源(catalogKeyIDs/catalogThreshold)。App 下载后重算
    # sha256 先验此签名再比对摘要——与目录信封构成双链。
    package_keys = {k["id"]: base64.b64decode(k["publicKey"])
                    for k in root.get("keys", []) if k["id"] in set(root.get("catalogKeyIDs", []))}
    package_threshold = root.get("catalogThreshold", 2)
    for model in index["models"]:
        signature = model.get("packageSignature")
        # 有则验真(新目录逐包必带,由签名器附加);无则容忍(旧目录/过渡面,
        # 仅目录 sha256 绑定——App 侧 Swift 收单同款语义)。
        if signature is None:
            continue
        if not isinstance(signature, dict) or signature.get("scheme") != "ed25519-sha256-v1":
            raise ValueError("Package signature missing or unknown scheme: " + model["url"])
        message = b"vitaliber/asr/package-sha256/v1/" + bytes.fromhex(model["sha256"])
        seen, verified = set(), 0
        for entry in signature.get("signatures", []):
            identity = entry.get("keyId")
            if identity in seen or identity not in package_keys:
                continue
            seen.add(identity)
            raw_signature = base64.b64decode(entry.get("value", ""), validate=True)
            if len(raw_signature) != 64:
                continue
            try:
                Ed25519PublicKey.from_public_bytes(package_keys[identity]).verify(raw_signature, message)
                verified += 1
            except InvalidSignature:
                pass
        if verified < package_threshold:
            raise ValueError("Package signature threshold not satisfied: " + model["url"])
    revoked = catalog.get("revokedHashes", [])
    if len(revoked) > 128 or any(not re.fullmatch(r"[0-9a-f]{64}", h) for h in revoked):
        raise ValueError("Invalid revocation list")
    if any(m["sha256"] in revoked for m in index["models"]):
        raise ValueError("An active package is revoked")
    return catalog


def build_baseline(root_envelope, catalog_envelope):
    catalog = verify_catalog(root_envelope, catalog_envelope)
    baseline = {"schemaVersion": 1, "generatedAt": datetime.now(timezone.utc).date().isoformat(),
                "rootVersion": catalog["rootVersion"], "catalogVersion": catalog["catalogVersion"],
                "catalogSHA256": hashlib.sha256(payload_bytes(catalog_envelope)).hexdigest(),
                "sourceIndexSha256": hashlib.sha256(json_bytes(catalog["index"])).hexdigest(),
                # S-M2：基线随 App 签名嵌入，须携带签名目录已知的撤销摘要，
                # 使擦除本机信任状态后已安装的被撤销包仍被拒绝。
                "revokedHashes": sorted(catalog.get("revokedHashes", [])),
                "entries": catalog["index"]["models"]}
    # 2026-10-05 目录驱动：基线必须携带 families（家族文案+语言/方言覆盖）——
    # 离线/未拉取签名目录时 App 路由判定全部落在基线，缺 families 则离线路由退化。
    if catalog["index"].get("families") is not None:
        baseline["families"] = catalog["index"]["families"]
    return baseline
