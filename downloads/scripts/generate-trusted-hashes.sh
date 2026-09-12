#!/usr/bin/env bash
# 构建期生成「下载文件哈希信任锚」：把仓库内发布的模型索引固化为 App 内置资源。
#
# 为什么：远端 index.json 可被 CDN/中间人替换；仅信任远端自报的 sha256 等于没有信任根。
# 做法：每次编译从仓库索引生成 Resources/TrustedModelHashes.json 并随包嵌入；
#       App 安装下载包时以该表为**唯一信任锚**，未登记/不匹配一律拒绝（fail closed）。
#
# 用法:
#   downloads/scripts/generate-trusted-hashes.sh [--index <路径>] [--out <路径>] [--check]
#
#   --check  : 只比对（不写文件）；条目漂移时退出码 1（供 CI 守卫「索引改了但忘记提交」）。
#
# 依赖: python3（macOS CI/本地均自带；不引入额外运行时）。
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
INDEX="$REPO_ROOT/downloads/vitaliber/asr/index.json"
OUT="$REPO_ROOT/Resources/TrustedModelHashes.json"
CHECK=""

while [ $# -gt 0 ]; do
  case "$1" in
    --index) INDEX="${2:?--index 需要参数}"; shift 2 ;;
    --out)   OUT="${2:?--out 需要参数}"; shift 2 ;;
    --check) CHECK="--check"; shift ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
done

[ -f "$INDEX" ] || { echo "索引不存在: $INDEX" >&2; exit 1; }

python3 - "$INDEX" "$OUT" "$CHECK" <<'PY'
import datetime, hashlib, json, os, sys

index_path, out_path, mode = sys.argv[1], sys.argv[2], sys.argv[3]
raw = open(index_path, "rb").read()
data = json.loads(raw)

entries = []
for model in data.get("models", []):
    sha = (model.get("sha256") or "").strip().lower()
    nbytes = int(model.get("bytes") or 0)
    # 未发布条目（空 sha / 零字节）不进入信任锚——App 对未登记版本一律拒绝安装。
    if not sha or nbytes <= 0:
        continue
    entries.append({
        "id": model["id"],
        "version": model["version"],
        "bytes": nbytes,
        "sha256": sha,
    })

document = {
    "schemaVersion": 1,
    "generatedAt": datetime.date.today().isoformat(),
    "sourceIndexSha256": hashlib.sha256(raw).hexdigest(),
    "entries": entries,
}

if mode == "--check":
    existing = {}
    if os.path.exists(out_path):
        existing = json.loads(open(out_path, encoding="utf-8").read() or "{}")
    # 只比对条目（generatedAt 每日变化，不参与漂移判定）。
    if existing.get("entries") == entries:
        print(f"TRUSTED-HASHES-OK ({len(entries)} entries)")
        sys.exit(0)
    print("TRUSTED-HASHES-DRIFT: Resources/TrustedModelHashes.json 与索引不一致", file=sys.stderr)
    sys.exit(1)

# 每次编译都跑（basedOnDependencyAnalysis: false）：条目未变化时跳过写入，
# 避免 generatedAt 每日变化把提交的资源文件天天弄脏（git 永远显示 diff）。
existing_entries = None
if os.path.exists(out_path):
    try:
        existing_entries = json.loads(open(out_path, encoding="utf-8").read()).get("entries")
    except (ValueError, AttributeError):
        existing_entries = None
if existing_entries == entries:
    print(f"TRUSTED-HASHES-OK ({len(entries)} entries, 无漂移不重写)")
    sys.exit(0)

os.makedirs(os.path.dirname(out_path), exist_ok=True)
with open(out_path, "w", encoding="utf-8") as handle:
    json.dump(document, handle, ensure_ascii=False, indent=2)
    handle.write("\n")
print(f"TRUSTED-HASHES-WRITTEN: {out_path} ({len(entries)} entries)")
PY
