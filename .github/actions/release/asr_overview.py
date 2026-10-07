#!/usr/bin/env python3
"""ASR 发布面「数据概览」生成器（2026-10-07 委员会：恢复人读面能力）。

业主报告「manifest.json 无可读的逐模型信息、无 overview.json」的裁决落点
（发布席字段考古：机器面零缺失——index 18 键为历史超集；真丢失的是 cutover
时被删的**人读面**：明文 index.json/逐包回执曾在 GitHub 时代发布）。本模块
按**医疗 v3 同构**为 ASR 增设固定名 `overview.json`：

- 定位 = **非权威展示件**（医疗 names.go 同纪律）：禁用于安装/安全判定；
  权威性一律来自签名 envelope（manifest.json）。
- 内容 = 纯函数（签名 payload + payload 字节摘要）→ **可重跑同字节**；
  零墙钟（issuedAt 取自 payload）。
- 发布 = 与 manifest.json 同批、固定名覆盖（overwrite）；生成/自验失败按
  「展示面不阻塞发布」降级 ::warning::（同医疗）。
- 不入签名索引、不入 manifest（后续可升版再议）；App 不消费（医疗侧同）。
"""
import argparse
import base64
import hashlib
import sys
from pathlib import Path

from asr_change_set import change_set, tier_key
from asr_package import decode_json, json_bytes

OVERVIEW_NAME = "overview.json"
OVERVIEW_KIND = "asr-overview"
SCHEMA_VERSION = 1

_TEXT_FIELDS = ("id", "variant", "tierName", "tierHint", "version", "artifactRevision",
                "bytes", "expandedBytes", "license", "url")


def build(payload_bytes, previous_payload=None):
    """由**签名 payload 的规范化字节**生成 overview（纯函数）。

    previous_payload（上一版签名载荷，或 None）= changes 块的唯一额外输入：
    给定 (payload, previous) 重生成必须逐字节相等；changes 生成条件=单源
    `asr_change_set.change_set`（previous 缺失或同版本/回退 → 整块 null）。"""
    payload = decode_json(payload_bytes)
    index = payload.get("index") or {}
    families = index.get("families") or []
    models = index.get("models") or []
    tiers = []
    for model in models:
        entry = {k: model[k] for k in _TEXT_FIELDS if k in model}
        if "packaging" in model:
            entry["packaging"] = model["packaging"]
        if "changeNote" in model:
            entry["changeNote"] = model["changeNote"]
        tiers.append(entry)
    families_out = []
    for family in families:
        families_out.append({k: family[k] for k in
                             ("id", "name", "hint", "strengths", "limitations",
                              "languages", "dialects") if k in family})
    totals = {
        "families": len(families_out),
        "tiers": len(tiers),
        "bytes": sum(int(m.get("bytes") or 0) for m in models),
        "expandedBytes": sum(int(m.get("expandedBytes") or 0) for m in models),
    }
    document = {
        "schemaVersion": SCHEMA_VERSION,
        "kind": OVERVIEW_KIND,
        "app": payload.get("app"),
        "assetKind": payload.get("assetKind"),
        "catalogVersion": payload.get("catalogVersion"),
        "rootVersion": payload.get("rootVersion"),
        "issuedAt": payload.get("issuedAt"),
        # 指纹：本概览严格由该 payload 字节导出（自验/对账用；非安全断言）。
        "payloadSha256": hashlib.sha256(json_bytes(payload)).hexdigest(),
        "changes": _changes_block(payload, previous_payload),
        "families": families_out,
        "tiers": tiers,
        "totals": totals,
    }
    return json_bytes(document)


def _changes_block(payload, previous_payload):
    """本版相对上一版的确定性增量（非权威展示面；不列文件名/URL/哈希）。

    生成规则=单源 change_set（previous 缺失/同版本/回退 → 整块 null）。"""
    result = change_set(previous_payload, payload)
    if result is None:
        return None
    added, updated, removed = result
    previous_models = ((previous_payload or {}).get("index") or {}).get("models") or []
    previous_by_key = {tier_key(model): model for model in previous_models}

    def compact(model):
        return {"id": model.get("id"), "variant": model.get("variant")}

    return {
        "fromCatalogVersion": int(previous_payload.get("catalogVersion") or 0),
        "added": [compact(m) for m in added],
        "updated": [dict(compact(m),
                         fromVersion=(previous_by_key.get(tier_key(m)) or {}).get("version"),
                         toVersion=m.get("version")) for m in updated],
        "removed": [compact(m) for m in removed],
    }


def verify(overview_bytes, payload_bytes, previous_payload=None):
    """自验：overview 必须与 (payload, previous) 严格互导（重生成逐字节相等）。"""
    expected = build(payload_bytes, previous_payload)
    if overview_bytes != expected:
        raise ValueError("overview.json 与签名载荷不一致（重生成非逐字节相等）")


def _payload_from_envelope(path):
    raw = decode_json(Path(path).read_bytes())
    if isinstance(raw, dict) and "payload" in raw and "signatures" in raw:
        # 返回 payload 原始字节（canonical 化在 build() 内完成；json_bytes 是
        # 「对象→JSON」编码器，喂 bytes 会抛 TypeError——2026-10-07 自测实证）。
        return base64.b64decode(raw["payload"])
    return Path(path).read_bytes()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--catalog", type=Path, required=True,
                        help="签名信封 manifest.json（或裸 payload，供夹具）")
    parser.add_argument("--previous", type=Path,
                        help="上一版签名信封（或裸 payload）——changes 块输入（可选）")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        payload_bytes = _payload_from_envelope(args.catalog)
        previous_payload = (decode_json(_payload_from_envelope(args.previous))
                            if args.previous is not None else None)
        data = build(payload_bytes, previous_payload)
        verify(data, payload_bytes, previous_payload)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_bytes(data)
        document = decode_json(data)
        print("overview.json 已生成：catalogVersion=%s families=%d tiers=%d bytes=%d"
              % (document["catalogVersion"], document["totals"]["families"],
                 document["totals"]["tiers"], document["totals"]["bytes"]), flush=True)
        return 0
    except (OSError, ValueError, KeyError, TypeError) as error:
        print("ASR-OVERVIEW-ERROR: " + str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
