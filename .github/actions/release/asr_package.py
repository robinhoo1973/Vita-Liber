"""Shared ASR package contract for build, publish and CI verification (no signing keys)."""
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import stat
import tempfile
import unicodedata
import zipfile

from asr_constants import MODELS, VARIANTS  # 轻依赖常量（2026-10-08 拆出；本模块 re-export）
from asr_envelope import (ENCRYPTION_SCHEME, decrypt_package, env_package_key,
                          identity_string, is_envelope_file)

ROLES = {
    "qwen3": {"frontend", "encoder", "decoder", "vocab", "merges", "tokenizerConfig"},
    "zipformer": {"encoder", "decoder", "joiner", "tokens", "bpe"},
    "dolphin": {"model", "tokens"},
    "whisper": {"encoder", "decoder", "tokens"},
    "sense-voice": {"model", "tokens"},
    "fire-red": {"model", "tokens"},
    "moonshine": {"preprocessor", "encoder", "uncachedDecoder", "cachedDecoder", "tokens"},
}
MAX_TIERS_PER_MODEL = 5
# 各家族许可:非 Apache-2.0 家族逐名登记(2026-10-06 钉版实测:
# sense-voice 权重为 FunASR 模型开源许可协议 v1.1,fire-red 为 Apache-2.0
# 取默认;whisper MIT)。
LICENSES = {"whisper": "MIT", "sense-voice": "model-license", "moonshine": "MIT"}
# 目录聚合预算:下载目录所有包 zip 字节合计的上限。2026-10-05 iOS 适用性评估后
# 矩阵定为 7 族 13 档 ≈5.2GiB(4GiB 装不下),业主裁决「评估后可纳入」→ 提至 6GiB。
ASR_CATALOG_BUDGET_BYTES = 6 * 1024**3
MAX_PACKAGE = 2 * 1024**3 - 1
MAX_EXPANDED = 4 * 1024**3
# 源树预算(2026-10-05 审查):fetch-asr-models 旧 2GB 硬上限与 6GiB 矩阵矛盾,
# 多档数据面落地即红;单文件/归档成员 ≤ MAX_EXPANDED,全源树展开 ≤ 12GiB
# (13 档展开总量留裕量;CI 磁盘预算外另有清理策略)。
ASR_SOURCE_ENTRY_BUDGET_BYTES = MAX_EXPANDED
ASR_SOURCE_UNPACKED_BUDGET_BYTES = 12 * 1024**3
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


def decode_manifest_data_file(path):
    """数据文件两态读取(2026-10-06 业主单一 JSON 架构):Resources/ASRModelUpdates/
    manifest.json 是唯一数据文件——签名信封形态(payload+signatures)时返回
    payload["index"],裸索引形态(构建模板期/历史文件)原样返回。"""
    raw = decode_json(Path(path).read_bytes())
    if isinstance(raw, dict) and "payload" in raw and "signatures" in raw:
        import base64
        return decode_json(base64.b64decode(raw["payload"]))["index"]
    return raw


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


def _validate_localized(text):
    # 目录文案(2026-10-05 业主定:模型文字描述由 CI 目录 JSON 提供,App 只渲染)。
    if not isinstance(text, dict):
        raise ValueError("Localized text must be an object")
    for key, value in text.items():
        if key not in ("zh-Hans", "zh-Hant", "en"):
            raise ValueError("Unknown locale key: " + str(key))
        if not isinstance(value, str) or not value or len(value.encode()) > 4096:
            raise ValueError("Invalid localized text for locale " + key)


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


def validate_index(index, *, complete=True, expected_families=None):
    if index.get("schemaVersion") != 1 or index.get("app") != "vitaliber" or index.get("assetKind") != "asr":
        raise ValueError("Unexpected ASR index scope/version")
    models = index.get("models", [])
    # 家族集合同(2026-10-05 数据驱动):校验器不硬断言「全家族齐备」——
    # 实际家族集由数据文件(源清单/模板)声明,`expected_families` 给出时按
    # 该集合判齐备(新家族数据面落地时随 manifest 自然收紧);无该参数时只
    # 拒绝未知家族(历史 v4 目录验证路径兼容)。「每 id 一条」硬断言随多档
    # 数据面退役(身份键 = (id, version, artifactRevision, variant))。
    ids = {m["id"] for m in models}
    if not ids or not ids <= MODELS:
        raise ValueError("Unknown ASR model family in index")
    if expected_families is not None and ids != expected_families:
        raise ValueError("Index families do not match the declared data set")
    for model_id in ids:
        tiers = [m for m in models if m["id"] == model_id]
        if not 1 <= len(tiers) <= MAX_TIERS_PER_MODEL:
            raise ValueError("Model family tier count out of range: " + model_id)
    identities, urls = set(), set()
    for model in models:
        variant = model.get("variant")
        if variant not in VARIANTS:
            raise ValueError("Unknown model variant: " + model["id"] + "/" + str(variant))
        slug(model["version"])
        if model.get("license") != LICENSES.get(model["id"], "Apache-2.0"):
            raise ValueError("Unexpected model license")
        identity = (model["id"], model["version"], model.get("artifactRevision"), variant)
        if identity in identities:
            raise ValueError("Duplicate (id, version, artifactRevision, variant) entry")
        identities.add(identity)
        if model.get("url") is not None:
            # 打包文件名含 variant 段后同串碰撞不可再发生;此处把碰撞从「后写覆盖」
            # 升级为发布侧硬错(此前 validate_index 无跨条目 url 唯一性,静默互覆)。
            # 构建模板期(complete=False)允许缺 url——build-asr-packages 随后按公式赋名。
            if model["url"] in urls:
                raise ValueError("Duplicate package URL across entries: " + model["url"])
            urls.add(model["url"])
        for key in ("tierName", "tierHint"):
            if model.get(key) is not None:
                _validate_localized(model[key])
        # 文案链（2026-10-08 委员会）：changeNote 在**签名载荷**中已是三语文本
        # （投影器按 (id,variant,upstreamRevision) 键控后才发射）；此处形状校验
        # （形状-only，不设必填——必填闸在 R3 签名点）。
        if model.get("changeNote") is not None:
            _validate_localized(model["changeNote"])
        # R1 加密合同(2026-10-05):目录条目可声明加密信封方案;未知方案拒绝
        # (App 无法解密),缺省 = 明文 zip(历史目录)。发布侧(build)一律加密,
        # 明文条目只可能来自冻结的旧目录。
        if model.get("encryption") not in (None, ENCRYPTION_SCHEME):
            raise ValueError("Unknown package encryption scheme: " + str(model.get("encryption")))
        # 包级签名合同(2026-10-06 业主指令:zip 文件也需要签名验证)——有则验形
        # (签名只由签名器附加进签名目录载荷;built 索引与旧目录无此键合法),
        # 验真由 model_trust.verify_catalog / App 信任库收单处承担。
        signature = model.get("packageSignature")
        if signature is not None:
            if not isinstance(signature, dict) or signature.get("scheme") != "ed25519-sha256-v1" \
                    or not isinstance(signature.get("signatures"), list) or not signature["signatures"]:
                raise ValueError("Malformed ed25519-sha256-v1 packageSignature: " + model["url"])
            for entry in signature["signatures"]:
                if not re.fullmatch(r"[0-9a-f]{64}", str(entry.get("keyId", ""))) \
                        or not re.fullmatch(r"[A-Za-z0-9+/]{86,88}={0,2}", str(entry.get("value", ""))):
                    raise ValueError("Invalid package signature entry: " + model["url"])
        if complete:
            if type(model.get("bytes")) is not int or not 0 < model["bytes"] <= MAX_PACKAGE:
                raise ValueError("Invalid package byte count")
            if not re.fullmatch(r"[0-9a-f]{64}", model.get("sha256", "")):
                raise ValueError("A real package SHA-256 is required")
            if safe_path(model["url"]) != Path(model["url"]).name or not model["url"].endswith(".zip"):
                raise ValueError("Package URL must be a relative ZIP filename")
    families = index.get("families")
    if families is not None:
        seen_families = set()
        for family in families:
            if family.get("id") not in MODELS:
                raise ValueError("Unknown family id: " + str(family.get("id")))
            if family["id"] in seen_families:
                raise ValueError("Duplicate family entry: " + family["id"])
            seen_families.add(family["id"])
            availability = family.get("availability")
            if availability not in (None, "upcoming"):
                raise ValueError("Unknown family availability: " + str(availability))
            for key in ("name", "hint", "strengths", "limitations"):
                if family.get(key) is not None:
                    _validate_localized(family[key])
            # 语言/方言覆盖(2026-10-05 目录驱动):App 路由判定唯一数据源——
            # 语言码 ISO 639 小写形态,方言为 locale 标识。
            for code in family.get("languages") or []:
                if not isinstance(code, str) or not re.fullmatch(r"[a-z]{2,3}", code):
                    raise ValueError("Invalid language code: " + str(code))
            for locale in family.get("dialects") or []:
                if not isinstance(locale, str) or not re.fullmatch(r"[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})+", locale):
                    raise ValueError("Invalid dialect locale: " + str(locale))
        # families↔models 覆盖合同(2026-10-05 业主指令:后期家族随目录呈现,
        # 客户端接受闸镜像):每个模型 id 必须有家族描述(否则 descriptors 落空、
        # 装完仍 engineUnavailable);families 里多余 id 只允许 upcoming 标记
        # (零档位预告),常规家族缺档位 = 发布侧硬错。
        model_ids = {m["id"] for m in index.get("models", [])}
        upcoming_ids = {f["id"] for f in families if f.get("availability") == "upcoming"}
        if not model_ids <= seen_families:
            raise ValueError("Model id missing a family descriptor: " + ", ".join(sorted(model_ids - seen_families)))
        if not seen_families - model_ids <= upcoming_ids:
            raise ValueError("Family without tiers must be marked upcoming: "
                             + ", ".join(sorted(seen_families - model_ids - upcoming_ids)))
    if complete:
        # 文案/覆盖表合同(2026-10-05 目录驱动,self-consistent 口径):目录一旦携带
        # families 段即必须完整——覆盖全部家族、每条目必带 tierName/tierHint(App
        # 渲染的唯一数据源;App 侧容忍缺字段仅为旧目录兼容)。无 families 段的历史
        # 目录(v4 形态)放行——其数据面已冻结,新发布由数据文件落地自然携带。
        if families is not None:
            # 覆盖方向 = 模型 ⊆ 家族(每个模型必须有描述符);家族多于模型的
            # 部分仅允许 upcoming 标记(上方闸),预告家族无档位合法。
            if not ids <= {f["id"] for f in families}:
                raise ValueError("Published catalog families must cover every model id")
            for model in models:
                if model.get("tierName") is None or model.get("tierHint") is None:
                    raise ValueError("Published entries require tierName and tierHint: " + model["id"])
    if complete:
        total = sum(m["bytes"] for m in models)
        if total > ASR_CATALOG_BUDGET_BYTES:
            raise ValueError("Catalog aggregate exceeds the download budget")


def manifest_files(manifest, model_id, variant=None):
    if manifest.get("formatVersion") != 1:
        raise ValueError("Unsupported model manifest")
    matches = [m for m in manifest.get("models", [])
               if m["id"] == model_id and m.get("variant") == variant]
    if len(matches) != 1:
        raise ValueError("Missing or duplicate (model, variant) in manifest: " + model_id)
    model = matches[0]
    files = model.get("files", [])
    runtime = [f["role"] for f in files if f["role"] != "notice"]
    expected = set(ROLES[model_id])
    valid = set(runtime) == expected and len(runtime) == len(set(runtime))
    if model_id == "zipformer":
        # 2026-10-06 zipformer-14M 支持:bpe 为可选角色——双语档有 bpe.vocab
        # (全角色),14M 中文小模型上游无(恰缺 bpe 一种);两种形态均合法,
        # 其余缺/增/重复仍拒。运行时装配随资产存在性切换 cjkchar/bpe。
        valid = valid or (set(runtime) == expected - {"bpe"}
                         and len(runtime) == len(set(runtime)))
    if not valid:
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


def _package_source(model, directory, package_key):
    """包字节 → 可读 zip 源:加密信封解密到临时文件(校验后自清),明文直通。

    index sha256/bytes 始终覆盖**下载所得字节**(信封字节);信封声明与目录
    声明必须一致,否则拒绝——明文包带 encryption 声明或信封包缺声明都是
    数据面错误。
    """
    path = Path(directory) / model["url"]
    if path.is_symlink() or not path.is_file() or path.stat().st_size != model["bytes"]:
        raise ValueError("Missing/truncated package: " + model["url"])
    if digest_file(path) != model["sha256"]:
        raise ValueError("Package checksum mismatch: " + model["url"])
    declared = model.get("encryption")
    if is_envelope_file(path) != (declared == ENCRYPTION_SCHEME):
        raise ValueError("Package envelope/encryption declaration mismatch: " + model["url"])
    if declared == ENCRYPTION_SCHEME:
        key = package_key if package_key is not None else env_package_key()
        temporary = tempfile.NamedTemporaryFile(prefix="asr-verify-", suffix=".zip", delete=False)
        temporary_path = Path(temporary.name)
        try:
            decrypt_package(key, identity_string(model["id"], model.get("variant"), model["version"], model.get("artifactRevision")),
                            path, temporary_path)
        except Exception:
            temporary_path.unlink(missing_ok=True)
            raise
        return temporary_path
    return path


def verify_package(model, directory, *, legacy_inner_manifest_ok=False, package_key=None):
    path = Path(directory) / model["url"]
    source = _package_source(model, directory, package_key)
    decrypted = source != path
    try:
        return _verify_package_zip(model, source, legacy_inner_manifest_ok=legacy_inner_manifest_ok)
    finally:
        if decrypted:
            source.unlink(missing_ok=True)


def _verify_package_zip(model, path, *, legacy_inner_manifest_ok=False):
    # BadZipFile/LargeZipFile 直承 Exception,不在各 main() 的
    # (OSError, ValueError, …) 处理面内——统一转 ValueError,保住
    # ASR-*-ERROR 结构化错误合同(2026-10-05 扫尾审查)。
    try:
        archive = zipfile.ZipFile(path)
    except (zipfile.BadZipFile, zipfile.LargeZipFile) as error:
        raise ValueError("Invalid ZIP package: " + model["url"]) from error
    with archive:
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
        inner = manifest["models"][0]
        # World A(2026-10-05 委员会):单档家族的遗留包内清单无 variant 键——
        # 该家族目录只有一条条目,遗留包无歧义地属于唯一档;放行避免重打包
        # (zlib 不确定性会破坏已签名 sha 复用)。多档家族内清单必须带 variant。
        legacy_variant = legacy_inner_manifest_ok and inner.get("variant") is None
        if len(manifest.get("models", [])) != 1 or inner.get("license") != model["license"] \
                or (inner.get("variant") != model.get("variant") and not legacy_variant):
            raise ValueError("Package model identity/license/variant mismatch")
        selected = manifest_files(manifest, model["id"], None if legacy_variant else model.get("variant"))
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
        return {"id": model["id"], "version": model["version"], "variant": model["variant"],
                "url": model["url"],
                "bytes": model["bytes"], "sha256": model["sha256"], "expandedBytes": total,
                "files": [{k: f[k] for k in ("role", "path", "bytes", "sha256")} for f in selected]}


def verify_packages(index, directory, expected_families=None, package_key=None):
    validate_index(index, expected_families=expected_families)
    tier_counts = {}
    for model in index["models"]:
        tier_counts[model["id"]] = tier_counts.get(model["id"], 0) + 1
    return {"schemaVersion": 1, "models": [
        verify_package(m, directory, legacy_inner_manifest_ok=(tier_counts[m["id"]] == 1),
                       package_key=package_key)
        for m in index["models"]]}
