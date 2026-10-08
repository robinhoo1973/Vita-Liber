"""语料/评测 manifest:字段契约、生成与校验(计划文档 §7.6/§10 冻结纪律)。

字段契约(评测席四轮评审定稿):
- corpus_sha256      语料 JSONL 的 sha256(冻结凭证)
- catalog_data_version  目录 dataVersion(与 App 侧同字段口径)
- noise_model        有效噪声模型整体(version + 三表 + sha256)——评测逐字节复现
- pinyin_available   拼音层可用性(基线报告必须携带)
- split_rule         切分规则版本 + 主种子(按 canonical 实体切分)
- licenses           逐来源许可义务(TFDAO OGDL v1 顯名等;CI 语料 job 零上游抓取)
- counts             逐域×带样本数(评测集实体下限断言的数据源)
- manifest_sha256    本文件自哈希(写入顺序固定,见 _order_key)
"""
from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path

MANIFEST_VERSION = "1.0"


def licenses_from_policy(source_keys) -> dict:
    """从 policy.licenses 生成 manifest 许可块(单一事实源;H5 合规席 2026-10-08)。

    训练机平铺布局无 policy.json → 抛 FileNotFoundError,调用方兜底 legacy inline。
    """
    try:
        import policy as _policy
    except ImportError:  # 直跑(cwd=corpus/)的相对导入回落
        sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
        import policy as _policy
    pol = _policy.load()
    srcs = pol["licenses"]["sources"]
    out = {}
    for key in source_keys:
        entry = srcs.get(key)
        if not entry:
            raise ValueError(f"来源 {key} 未登记于 policy.licenses.sources——先登记再采")
        out[key] = {"class": entry["class"], "attribution": entry["attribution"]}
    return out


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def sha256_json(obj) -> str:
    return hashlib.sha256(json.dumps(obj, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")).hexdigest()


# 字段写入顺序(确定性,self-hash 之外按此序)
_FIELD_ORDER = (
    "manifest_version", "corpus_sha256", "catalog_data_version", "catalog_source",
    "noise_model", "pinyin_available", "pinyin_reason", "split_rule",
    "licenses", "counts", "generated_at",
)


def build_manifest(*, corpus_path: Path, catalog_data_version: str, catalog_source: str,
                   noise_model: dict, pinyin_available: bool, pinyin_reason: str | None,
                   split_rule: dict, licenses: dict, counts: dict) -> dict:
    manifest = {
        "manifest_version": MANIFEST_VERSION,
        "corpus_sha256": sha256_file(corpus_path),
        "catalog_data_version": catalog_data_version,
        "catalog_source": catalog_source,
        "noise_model": noise_model,
        "pinyin_available": pinyin_available,
        "pinyin_reason": pinyin_reason,
        "split_rule": split_rule,
        "licenses": licenses,
        "counts": counts,
    }
    # 自哈希必须基于固定字段序且不含自身
    payload = {k: manifest[k] for k in _FIELD_ORDER if k in manifest}
    manifest["manifest_sha256"] = sha256_json(payload)
    return manifest


def write_manifest(path: Path, manifest: dict) -> None:
    payload = {k: manifest[k] for k in _FIELD_ORDER if k in manifest}
    ordered = dict(payload)
    ordered["manifest_sha256"] = manifest["manifest_sha256"]
    path.write_text(json.dumps(ordered, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def verify_manifest(manifest_path: Path, corpus_path: Path) -> dict:
    """校验冻结语料:sha256 一致 + 自哈希一致 + 字段齐全。不符即抛(fail-closed)。"""
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    for required in _FIELD_ORDER:
        if required not in manifest and required not in ("generated_at",):
            raise ValueError(f"manifest 缺字段: {required}")
    if manifest.get("manifest_version") != MANIFEST_VERSION:
        raise ValueError(f"manifest_version 不匹配: {manifest.get('manifest_version')}")
    actual = sha256_file(corpus_path)
    if actual != manifest["corpus_sha256"]:
        raise ValueError(f"语料 sha256 不符: manifest={manifest['corpus_sha256']} actual={actual}")
    payload = {k: manifest[k] for k in _FIELD_ORDER if k in manifest}
    if sha256_json(payload) != manifest.get("manifest_sha256"):
        raise ValueError("manifest 自哈希校验失败(内容被篡改或字段序漂移)")
    licenses = manifest.get("licenses")
    if isinstance(licenses, dict) and "TFDA" in licenses and not licenses["TFDA"].get("attribution"):
        raise ValueError("含 TFDA 派生数据但缺顯名 attribution——OGDL v1 义务必须随 manifest")
    # 泛化(H5):凡带 class 的来源,beyond 免署名类,attribution 必填(fail-closed)
    if isinstance(licenses, dict):
        for src, entry in licenses.items():
            if not isinstance(entry, dict):
                continue
            cls = entry.get("class")
            if cls and cls not in ("cc0", "public-domain") and not entry.get("attribution"):
                raise ValueError(f"来源 {src}({cls}) 缺 attribution——许可义务必须随 manifest")
    return manifest
