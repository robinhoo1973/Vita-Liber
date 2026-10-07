#!/usr/bin/env python3
"""Project the plaintext ASR catalog copy source onto the built index (before signing).

2026-10-08 委员会终裁（明文 copy 源 + 签名前投影）：
- `.github/config/asr/catalog-copy.json` 是文案**唯一手工维护面**（可 diff/可评审）；
- 本工具在 build 之后、sign 之前把文案覆盖进 `$RUNNER_TEMP/asr-packages/index.json`
  （保序：families 顺序 = auto 链优先序，绝不重排；行为字段 languages/dialects/
  availability/家族顺序与全部身份字段绝不触碰）；
- fail-closed（前缀 ASR-COPY-ERROR，rc=1）：copy 缺家族/缺档位、三语不齐、空串、
  超长、负清单词、未知 (id,variant) 一律硬错——**不沿模板旧值**（防静默参差）；
- `changeNote` 按 `(id, variant, upstreamRevision)` 键控：revision 不符**自动不发射**
  （陈旧说明不可能变成谎言）；发射则三语必须齐备；
- 覆盖后自检一次（validate_index）——R3 闸（sign 点）是第二道防线。

负清单（绝对化/推荐语义/医疗结论——呈现语义=数据语义纪律）：
zh 最高/最强/最准/最快/最好/最佳/第一/唯一/保证/顶级/极致/首选/优选/无敌/100%；
zh-Hant 对应繁体；en highest/best/guaranteed/100%。（「高精度」「最小内存占用」等
族内相对描述放行。）
"""
import argparse
import json
import re
import sys
from pathlib import Path

from asr_package import json_bytes, validate_index

REPO_ROOT = Path(__file__).resolve().parent
while REPO_ROOT != REPO_ROOT.parent and not (REPO_ROOT / "CoreKit" / "Sources" / "Domain").is_dir():
    REPO_ROOT = REPO_ROOT.parent
COPY_DEFAULT = REPO_ROOT / ".github" / "config" / "asr" / "catalog-copy.json"

LOCALES = ("zh-Hans", "zh-Hant", "en")
MAX_TEXT = 4096
MAX_NEW_TEXT = 1024
FAMILY_FIELDS = ("name", "hint", "strengths", "limitations")
FAMILY_NEW_FIELDS = ("strengths", "limitations")
TIER_FIELDS = ("tierName", "tierHint")
BANNED = ("最高", "最強", "最强", "最准", "最準", "最快", "最好", "最佳", "第一", "唯一",
          "保证", "保證", "顶级", "頂級", "极致", "極致", "首选", "首選", "优选", "優選",
          "无敌", "無敵", "100%", "highest", "best", "guaranteed",
          "诊断", "治疗", "处方", "用药", "診斷", "治療", "處方", "用藥")
_BANNED_RE = re.compile("|".join(re.escape(word) for word in BANNED), re.IGNORECASE)


def _check_localized(value, where, limit=MAX_TEXT):
    if not isinstance(value, dict) or set(value.keys()) != set(LOCALES):
        raise ValueError("%s 必须恰好包含三语键 %s" % (where, list(LOCALES)))
    for locale in LOCALES:
        text = value[locale]
        if not isinstance(text, str) or not text.strip():
            raise ValueError("%s 的 %s 必须为非空字符串" % (where, locale))
        if len(text.encode("utf-8")) > limit:
            raise ValueError("%s 的 %s 超过 %d 字节" % (where, locale, limit))
        match = _BANNED_RE.search(text)
        if match:
            raise ValueError("%s 的 %s 含负清单词「%s」" % (where, locale, match.group(0)))


def validate_copy(copy, index):
    """完备性 + 形状 + 覆盖 + 负清单；任何不符即 raise（fail-closed）。"""
    if not isinstance(copy, dict) or copy.get("formatVersion") != 1:
        raise ValueError("copy 源须为 formatVersion=1 的对象")
    families = copy.get("families")
    tiers = copy.get("tiers")
    if not isinstance(families, list) or not isinstance(tiers, list):
        raise ValueError("copy 源须含 families 与 tiers 数组")
    index_families = {f["id"] for f in index.get("families") or []}
    index_tiers = {(m["id"], m.get("variant")) for m in index.get("models") or []}
    seen_families, seen_tiers = set(), set()
    for entry in families:
        where = "family/" + str(entry.get("id"))
        if not isinstance(entry, dict) or entry.get("id") not in index_families:
            raise ValueError("copy 含未知家族: " + where)
        if entry["id"] in seen_families:
            raise ValueError("copy 家族重复: " + where)
        seen_families.add(entry["id"])
        for field in FAMILY_FIELDS:
            limit = MAX_NEW_TEXT if field in FAMILY_NEW_FIELDS else MAX_TEXT
            _check_localized(entry.get(field), where + "/" + field, limit)
    for entry in tiers:
        where = "tier/%s.%s" % (entry.get("id"), entry.get("variant"))
        key = (entry.get("id"), entry.get("variant"))
        if not isinstance(entry, dict) or key not in index_tiers:
            raise ValueError("copy 含未知档位: " + where)
        if key in seen_tiers:
            raise ValueError("copy 档位重复: " + where)
        seen_tiers.add(key)
        for field in TIER_FIELDS:
            _check_localized(entry.get(field), where + "/" + field)
        note = entry.get("changeNote")
        if note is not None:
            if not isinstance(note, dict) or not isinstance(note.get("revision"), str) \
                    or not note["revision"].strip():
                raise ValueError(where + "/changeNote 须含非空 revision")
            _check_localized(note.get("text"), where + "/changeNote/text", MAX_NEW_TEXT)
    missing_families = index_families - seen_families
    missing_tiers = index_tiers - seen_tiers
    if missing_families:
        raise ValueError("copy 未覆盖家族: " + ", ".join(sorted(missing_families)))
    if missing_tiers:
        raise ValueError("copy 未覆盖档位: " + ", ".join(
            sorted("%s.%s" % (i, v) for i, v in missing_tiers)))


def overlay(index, copy):
    """文案投影：返回新索引（深拷贝）；行为字段与身份字段零触碰。"""
    import copy as _copy
    merged = _copy.deepcopy(index)
    by_family = {f["id"]: f for f in copy["families"]}
    by_tier = {(t["id"], t["variant"]): t for t in copy["tiers"]}
    for family in merged.get("families") or []:
        source = by_family[family["id"]]
        for field in FAMILY_FIELDS:
            family[field] = _copy.deepcopy(source[field])
    for model in merged.get("models") or []:
        source = by_tier[(model["id"], model.get("variant"))]
        model["tierName"] = _copy.deepcopy(source["tierName"])
        model["tierHint"] = _copy.deepcopy(source["tierHint"])
        note = source.get("changeNote")
        if note is not None and model.get("upstreamRevision") == note["revision"]:
            model["changeNote"] = _copy.deepcopy(note["text"])
        else:
            model.pop("changeNote", None)
    return merged


def project(index_bytes, copy_bytes):
    """纯函数：索引字节 + copy 字节 → 投影后的索引字节（失败抛 ValueError）。"""
    index = json.loads(index_bytes)
    copy = json.loads(copy_bytes)
    validate_copy(copy, index)
    merged = overlay(index, copy)
    validate_index(merged, complete=False)
    return json_bytes(merged)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--index", type=Path, required=True)
    parser.add_argument("--copy", type=Path, default=COPY_DEFAULT)
    parser.add_argument("--check", type=Path,
                        help="比对模式：投影结果须与给定文件逐字节相等，否则 rc=1")
    args = parser.parse_args()
    try:
        data = project(args.index.read_bytes(), args.copy.read_bytes())
        if args.check is not None:
            if args.check.read_bytes() != data:
                raise ValueError("投影结果与 %s 不一致" % args.check)
            print("projection matches " + str(args.check), flush=True)
            return 0
        temporary = args.index.with_suffix(".json.tmp")
        temporary.write_bytes(data)
        temporary.replace(args.index)
        print("catalog copy projected: families=%d tiers=%d bytes=%d"
              % (len(json.loads(data).get("families") or []),
                 len(json.loads(data).get("models") or []), len(data)), flush=True)
        return 0
    except (OSError, ValueError, KeyError, TypeError) as error:
        print("ASR-COPY-ERROR: " + str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
