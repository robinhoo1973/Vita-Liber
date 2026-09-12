#!/usr/bin/env bash
# 打包一个 ASR 模型发布包，并更新/追加索引条目。
#
# 用法:
#   downloads/scripts/package-asr-model.sh <模型目录> <id> <version> [选项]
#
# 选项:
#   --base-url <前缀>   写入 index.json 的 baseUrl（默认沿用现有值）
#   --index <路径>      索引路径（默认 <repo>/downloads/vitaliber/asr/index.json）
#   --out <目录>        输出目录（默认索引同目录）
#   --keep              若目标 zip 已存在则保留（默认覆盖）
#
# 依赖: zip, sha256sum, python3 （均为构建机常见工具；不引入额外语言运行时）
# 说明: 二进制（*.zip）不入 Git；本脚本只提交 index.json。
set -euo pipefail

usage() { sed -n '2,16p' "$0"; exit 1; }

[ $# -ge 3 ] || usage
SRC_DIR="$1"; MODEL_ID="$2"; VERSION="$3"; shift 3

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
INDEX="$REPO_ROOT/downloads/vitaliber/asr/index.json"
OUT_DIR="$(dirname "$INDEX")"
BASE_URL=""
KEEP=0

while [ $# -gt 0 ]; do
  case "$1" in
    --base-url) BASE_URL="${2:?--base-url 需要参数}"; shift 2 ;;
    --index)    INDEX="${2:?--index 需要参数}"; shift 2 ;;
    --out)      OUT_DIR="${2:?--out 需要参数}"; shift 2 ;;
    --keep)     KEEP=1; shift ;;
    *) echo "未知参数: $1" >&2; usage ;;
  esac
done

[ -d "$SRC_DIR" ] || { echo "模型目录不存在: $SRC_DIR" >&2; exit 1; }
[ -f "$SRC_DIR/manifest.json" ] || { echo "缺少 manifest.json（包根必须包含）: $SRC_DIR/manifest.json" >&2; exit 1; }

# App 端 ASRModelAssets.validate 要求 files 形态清单（逐文件 bytes+sha256 校验）。
# 仓库内 qwen3 等清单是 archive 分卷形态（files:[] + archive.parts）——打包前
# 原地转换为 files 形态（按 parts 逐文件统计字节/哈希，role/path 沿用），
# 否则下载的包恒被 invalidPackage 拒绝（发布流不可用）。shared 成员（VAD 等）
# 缺失直接失败并给出缺件路径——宁可打包失败，不产出运行时必拒的包。
python3 - "$SRC_DIR/manifest.json" "$SRC_DIR" <<'PY'
import hashlib, json, os, sys

manifest_path, src_dir = sys.argv[1], sys.argv[2]
with open(manifest_path, encoding="utf-8") as f:
    data = json.load(f)

def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()

converted = []
for model in data.get("models", []):
    if model.get("files"):
        continue
    parts = (model.get("archive") or {}).get("parts") or []
    if not parts:
        continue
    out = []
    for part in parts:
        p = os.path.join(src_dir, part["path"])
        if not os.path.isfile(p):
            print(f"错误: 分卷成员缺失（无法生成 files 形态清单）: {p}", file=sys.stderr)
            sys.exit(1)
        out.append({
            "role": part["role"], "path": part["path"],
            "bytes": os.path.getsize(p),
            "sha256": sha256_file(p),
            "url": "",
        })
    model["files"] = out
    converted.append(model.get("id"))

for f in data.get("shared", []):
    p = os.path.join(src_dir, f["path"])
    if not os.path.isfile(p):
        print(f"错误: shared 成员缺失（validate 逐文件校验必拒）: {p}", file=sys.stderr)
        sys.exit(1)

with open(manifest_path, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
    f.write("\n")
if converted:
    print(f"== 清单已转 files 形态: {', '.join(converted)}")
else:
    print("== 清单已为 files 形态，无需转换")
PY

BUILT_AT="$(date -u +%Y%m%d)"
PACKAGE_NAME="${MODEL_ID}-${VERSION}-${BUILT_AT}.zip"
mkdir -p "$OUT_DIR"
TARGET="$OUT_DIR/$PACKAGE_NAME"

if [ -f "$TARGET" ] && [ "$KEEP" -eq 1 ]; then
  echo "== 复用已存在包: $TARGET"
else
  echo "== 打包: $TARGET"
  # -X 去掉多余扩展属性（可复现性）；-9 最高压缩；模型权重本身已量化，压缩耗时可控。
  ( cd "$SRC_DIR" && zip -9 -X -r "$TARGET" . >/dev/null )
fi

BYTES="$(stat -c %s "$TARGET" 2>/dev/null || stat -f %z "$TARGET")"
SHA="$(sha256sum "$TARGET" | awk '{print $1}')"
echo "== 字节数: $BYTES"
echo "== SHA-256: $SHA"

python3 - "$INDEX" "$MODEL_ID" "$VERSION" "$BYTES" "$SHA" "$PACKAGE_NAME" "$BUILT_AT" "$BASE_URL" <<'PY'
import json, sys, datetime
index_path, model_id, version, nbytes, sha, package, built_at, base_url = sys.argv[1:9]
with open(index_path, encoding="utf-8") as f:
    data = json.load(f)
if base_url:
    data["baseUrl"] = base_url.rstrip("/")
data["updatedAt"] = datetime.date.today().isoformat()
entry = next((m for m in data["models"] if m.get("id") == model_id), None)
if entry is None:
    entry = {"id": model_id, "packaging": "zip", "minAppVersion": "1.0.0", "license": "UNKNOWN"}
    data["models"].append(entry)
entry.update({
    "version": version,
    "builtAt": built_at,
    "bytes": int(nbytes),
    "sha256": sha,
    "url": package,
})
with open(index_path, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
    f.write("\n")
print("== 已更新索引:", index_path)
PY

cat <<EOF

下一步:
  1) 上传资产:  gh release upload asr-models "$TARGET" --clobber
  2) 提交索引:  git add "$INDEX" && git commit -m "chore(downloads): asr $MODEL_ID $VERSION"
  3) 校验索引:  python3 -m json.tool "$INDEX" >/dev/null && echo OK
EOF
