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


def check_scope(value, role):
    if value.get("schemaVersion") != 1 or value.get("role") != role or value.get("app") != "vitaliber" or value.get("assetKind") != "asr":
        raise ValueError("Signed metadata scope/version mismatch")


def positive(value):
    return type(value) is int and 0 < value < 2**63


def validate_root(root):
    check_scope(root, "root")
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
    if (url.scheme != "https" or url.netloc != "github.com" or url.query or url.fragment
            or not re.fullmatch(r"/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/releases/download/asr-models", url.path)):
        raise ValueError("ASR assets must use the authorized GitHub Release")
    if not root["allowedHosts"] or not set(root["allowedHosts"]) <= HOSTS:
        raise ValueError("Unexpected resource host policy")


def verify_envelope(envelope, root, role):
    validate_root(root)
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
    check_scope(result, role)
    return result


def trusted_root(envelope, *, now=None, previous=None):
    root = payload(envelope)
    validate_root(root)
    if previous is not None:
        old = payload(previous)
        validate_root(old)
        if root["version"] != old["version"] + 1:
            raise ValueError("Root updates must be consecutive")
        verify_envelope(envelope, old, "root")
    verify_envelope(envelope, root, "root")
    if now is not None and utc_date(root["expiresAt"]) <= now:
        raise ValueError("Root metadata expired")
    return root


def verify_catalog(root_envelope, catalog_envelope, *, previous=None, now=None):
    now = now or datetime.now(timezone.utc)
    root = trusted_root(root_envelope, now=now)
    catalog = verify_envelope(catalog_envelope, root, "catalog")
    if catalog.get("rootVersion") != root["version"] or not positive(catalog.get("catalogVersion")):
        raise ValueError("Catalog/root version mismatch")
    issued, expires = utc_date(catalog["issuedAt"]), utc_date(catalog["expiresAt"])
    if expires <= now or issued > now + timedelta(minutes=5) or expires <= issued or expires - issued > timedelta(days=31):
        raise ValueError("Catalog expired or outside validity window")
    if previous is not None:
        old = verify_envelope(previous, root, "catalog")
        if old.get("rootVersion") == root["version"]:
            if catalog["catalogVersion"] < old["catalogVersion"]:
                raise ValueError("Catalog rollback rejected")
            if catalog["catalogVersion"] == old["catalogVersion"] and payload_bytes(catalog_envelope) != payload_bytes(previous):
                raise ValueError("Catalog same-version equivocation rejected")
    index = catalog["index"]
    validate_index(index)
    if index["baseUrl"] != root["assetBaseURL"]:
        raise ValueError("Catalog asset base does not match its trust root")
    for model in index["models"]:
        if model.get("packaging") != "zip" or type(model.get("expandedBytes")) is not int or not 0 < model["expandedBytes"] <= MAX_EXPANDED:
            raise ValueError("Invalid signed package format/expanded budget")
        if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", model.get("minAppVersion", "")):
            raise ValueError("Signed minimum App version is required")
        slug(model["runtime"])
    revoked = catalog.get("revokedHashes", [])
    if len(revoked) > 128 or any(not re.fullmatch(r"[0-9a-f]{64}", h) for h in revoked):
        raise ValueError("Invalid revocation list")
    if any(m["sha256"] in revoked for m in index["models"]):
        raise ValueError("An active package is revoked")
    return catalog


def build_baseline(root_envelope, catalog_envelope):
    catalog = verify_catalog(root_envelope, catalog_envelope)
    return {"schemaVersion": 1, "generatedAt": datetime.now(timezone.utc).date().isoformat(),
            "rootVersion": catalog["rootVersion"], "catalogVersion": catalog["catalogVersion"],
            "catalogSHA256": hashlib.sha256(payload_bytes(catalog_envelope)).hexdigest(),
            "sourceIndexSha256": hashlib.sha256(json_bytes(catalog["index"])).hexdigest(),
            "entries": catalog["index"]["models"]}
