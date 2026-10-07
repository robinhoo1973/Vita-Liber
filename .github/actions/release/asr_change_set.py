#!/usr/bin/env python3
"""ASR 目录变化集 · 单源（发布页增量行 + overview changes 块共用）。

2026-10-08 委员会终裁：增量语义（added/updated/removed，键=(id, variant)，
updated 判据=sha256 不等）此前只在 asr_release_page 内联；本次抽为单源，
两个消费方共用同一实现——禁止同语义双实现漂移（仓内「families↔models
漏改闸」教训族）。

省略语义（沿用发布页既有约定，**整块省略、绝不解释原因**）：
previous 缺失、或 previous.catalogVersion >= current.catalogVersion（同版本
重跑 / 回退异常）→ 返回 None。
"""


def tier_key(model):
    return (model.get("id"), model.get("variant"))


def _models_of(payload):
    return ((payload or {}).get("index") or {}).get("models") or []


def change_set(previous_payload, payload):
    """返回 (added, updated, removed) 模型对象三元组；无可比基线时 None。"""
    if previous_payload is None or not isinstance(previous_payload, dict):
        return None
    try:
        previous_version = int(previous_payload.get("catalogVersion") or 0)
        current_version = int((payload or {}).get("catalogVersion") or 0)
    except (TypeError, ValueError):
        return None
    if previous_version >= current_version:
        return None
    old_by_key = {tier_key(model): model for model in _models_of(previous_payload)}
    new_models = _models_of(payload)
    new_keys = {tier_key(model) for model in new_models}
    added = [model for model in new_models if tier_key(model) not in old_by_key]
    updated = [model for model in new_models
               if tier_key(model) in old_by_key
               and old_by_key[tier_key(model)].get("sha256") != model.get("sha256")]
    removed = [model for model in _models_of(previous_payload)
               if tier_key(model) not in new_keys]
    return added, updated, removed
