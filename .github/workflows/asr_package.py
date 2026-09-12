"""Shared ASR package contract for build, publish and CI verification (no signing keys)."""
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import stat
import unicodedata
import zipfile

MODELS = {"qwen3", "zipformer", "dolphin", "whisper"}
ROLES = {
    "qwen3": {"frontend", "encoder", "decoder", "vocab", "merges", "tokenizerConfig"},
    "zipformer": {"encoder", "decoder", "joiner", "tokens", "bpe"},
    "dolphin": {"model", "tokens"},
    "whisper": {"encoder", "decoder", "tokens"},
}
MAX_PACKAGE = 2 * 1024**3 - 1
MAX_EXPANDED = 4 * 1024**3
MAX_MANIFEST = 1024**2
MAX_ENTRIES = 512
ROOT_FILES = {"manifest.json", "resolved-manifest.json", "LICENSE-APACHE-2.0.txt", "LICENSE-MIT.txt", "NOTICE.md"}


def json_bytes(value):
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2) + "\n").encode()


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("Duplicate JSON key: " + key)
        result[key] = value
    return result


def decode_json(data):
    if len(data) > MAX_MANIFEST:
        raise ValueError("Metadata exceeds 1 MiB")
    return json.loads(data, object_pairs_hook=unique_object)


def digest_file(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024**2), b""):
            digest.update(chunk)
    return digest.hexdigest()


def slug(value):
    if not isinstance(value, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}", value):
        raise ValueError("Invalid model/version identifier")
    return value


def safe_path(value):
    if (not isinstance(value, str) or not value or len(value.encode()) > 1024
            or value.startswith("/") or "\\" in value or ":" in value
            or any(ord(c) < 32 or ord(c) == 127 for c in value)):
        raise ValueError("Unsafe package path")
    trimmed = value.rstrip("/")
    parts = trimmed.split("/")
    if any(p in ("", ".", "..") for p in parts):
        raise ValueError("Unsafe package path: " + value)
    return str(PurePosixPath(trimmed))


def validate_index(index, *, complete=True):
    if index.get("schemaVersion") != 1 or index.get("app") != "vitaliber" or index.get("assetKind") != "asr":
        raise ValueError("Unexpected ASR index scope/version")
    models = index.get("models", [])
    if len(models) != 4 or {m["id"] for m in models} != MODELS:
        raise ValueError("All four adopted ASR models are required")
    for model in models:
        slug(model["version"])
        if model.get("license") != ("MIT" if model["id"] == "whisper" else "Apache-2.0"):
            raise ValueError("Unexpected model license")
        if complete:
            if type(model.get("bytes")) is not int or not 0 < model["bytes"] <= MAX_PACKAGE:
                raise ValueError("Invalid package byte count")
            if not re.fullmatch(r"[0-9a-f]{64}", model.get("sha256", "")):
                raise ValueError("A real package SHA-256 is required")
            if safe_path(model["url"]) != Path(model["url"]).name or not model["url"].endswith(".zip"):
                raise ValueError("Package URL must be a relative ZIP filename")


def manifest_files(manifest, model_id):
    if manifest.get("formatVersion") != 1:
        raise ValueError("Unsupported model manifest")
    matches = [m for m in manifest.get("models", []) if m["id"] == model_id]
    if len(matches) != 1:
        raise ValueError("Missing or duplicate model in manifest: " + model_id)
    model = matches[0]
    files = model.get("files", [])
    runtime = [f["role"] for f in files if f["role"] != "notice"]
    if set(runtime) != ROLES[model_id] or len(runtime) != len(set(runtime)):
        raise ValueError("Missing/duplicate/unexpected runtime role: " + model_id)
    shared = manifest.get("shared", []) if model_id != "zipformer" else []
    if model_id != "zipformer" and [f["role"] for f in shared if f["role"] != "notice"] != ["vad"]:
        raise ValueError("A complete VAD is required: " + model_id)
    if not any(f["role"] == "notice" for f in files):
        raise ValueError("Model notice/license is required")
    if model_id != "zipformer" and not any(f["role"] == "notice" for f in shared):
        raise ValueError("VAD license is required")
    selected = files + shared
    seen = set()
    for item in selected:
        name = safe_path(item["path"])
        identity = unicodedata.normalize("NFC", name).casefold()
        if identity in seen:
            raise ValueError("Duplicate model file path")
        seen.add(identity)
        if type(item["bytes"]) is not int or not 0 < item["bytes"] <= MAX_EXPANDED:
            raise ValueError("Invalid model file size")
        if not re.fullmatch(r"[a-f0-9]{64}", item["sha256"]):
            raise ValueError("Invalid model file hash")
    return selected


def verify_package(model, directory):
    path = Path(directory) / model["url"]
    if path.is_symlink() or not path.is_file() or path.stat().st_size != model["bytes"]:
        raise ValueError("Missing/truncated package: " + model["url"])
    if digest_file(path) != model["sha256"]:
        raise ValueError("Package checksum mismatch: " + model["url"])
    with zipfile.ZipFile(path) as archive:
        entries = archive.infolist()
        if not 0 < len(entries) <= MAX_ENTRIES:
            raise ValueError("Invalid ZIP member count")
        members, seen, total = {}, set(), 0
        for info in entries:
            name = safe_path(info.filename)
            identity = unicodedata.normalize("NFC", name).casefold()
            if identity in seen:
                raise ValueError("Duplicate normalized ZIP path")
            seen.add(identity)
            file_type = stat.S_IFMT(info.external_attr >> 16)
            if file_type not in (0, stat.S_IFREG, stat.S_IFDIR) or info.flag_bits & 1:
                raise ValueError("Links, special files and encrypted ZIPs are not permitted")
            if info.compress_type not in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED):
                raise ValueError("Unsupported ZIP compression")
            if info.is_dir():
                continue
            if info.file_size < 0 or info.file_size > MAX_EXPANDED - total:
                raise ValueError("ZIP expanded size exceeds budget")
            total += info.file_size
            members[name] = info
        if "manifest.json" not in members or members["manifest.json"].file_size > MAX_MANIFEST:
            raise ValueError("Missing or oversized package manifest")
        manifest = decode_json(archive.read(members["manifest.json"]))
        if len(manifest.get("models", [])) != 1 or manifest["models"][0].get("license") != model["license"]:
            raise ValueError("Package model identity/license mismatch")
        selected = manifest_files(manifest, model["id"])
        allowed = {item["path"] for item in selected} | ROOT_FILES
        if set(members) - allowed:
            raise ValueError("Undeclared ZIP payload")
        license_file = "LICENSE-MIT.txt" if model["license"] == "MIT" else "LICENSE-APACHE-2.0.txt"
        if license_file not in members:
            raise ValueError("Package license is missing")
        if model.get("expandedBytes") is not None and total != model["expandedBytes"]:
            raise ValueError("Expanded byte count mismatch")
        for item in selected:
            if item["path"] not in members or members[item["path"]].file_size != item["bytes"]:
                raise ValueError("Missing/wrong-size model member: " + item["path"])
            digest, count = hashlib.sha256(), 0
            with archive.open(members[item["path"]]) as stream:
                for chunk in iter(lambda: stream.read(1024**2), b""):
                    count += len(chunk)
                    if count > item["bytes"]:
                        raise ValueError("Model member exceeds signed size")
                    digest.update(chunk)
            if count != item["bytes"] or digest.hexdigest() != item["sha256"]:
                raise ValueError("Model member checksum mismatch: " + item["path"])
        # Also consume metadata so ZIP CRC errors outside inference files are observable.
        for name in set(members) - {f["path"] for f in selected}:
            if members[name].file_size > MAX_MANIFEST:
                raise ValueError("Oversized package metadata")
            archive.read(members[name])
        return {"id": model["id"], "version": model["version"], "url": model["url"],
                "bytes": model["bytes"], "sha256": model["sha256"], "expandedBytes": total,
                "files": [{k: f[k] for k in ("role", "path", "bytes", "sha256")} for f in selected]}


def verify_packages(index, directory):
    validate_index(index)
    return {"schemaVersion": 1, "models": [verify_package(m, directory) for m in index["models"]]}
