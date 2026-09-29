#!/usr/bin/env bash
set -euo pipefail
# workspace 根探测:逐级向上找 VitaLiber.code-workspace 锚点(2026-09-29 workspace 重组:
# 仓库根与 workspace 根分离,project.yml 随公仓迁至 repos/vita-liber,只作仓内锚点)
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
while [ ! -f "$ROOT/VitaLiber.code-workspace" ]; do
  PARENT="$(dirname "$ROOT")"
  [ "$PARENT" = "$ROOT" ] && { echo "ERROR: 未找到 VitaLiber.code-workspace 锚点" >&2; exit 1; }
  ROOT="$PARENT"
done
TOOLS="$ROOT/refactor/tools/medical-data"
# 2026-09-29 审查修复：OUT 可经环境变量覆盖——私仓侧生成自己的 payload 副本时
# 不再需要先写公仓。默认仍写公仓 scripts/medical-data/（发布工作流消费点）。
OUT="${MEDICAL_DATA_CI_OUT:-$ROOT/repos/vita-liber/scripts/medical-data/medical-data-ci.sh}"
# 2026-09-26 审查修复（altitude）：临时目录不再落进仓库树（此前默认
# $ROOT/refactor/tools/medical-data/.tmp——打包是临时工作区，与工具源码无关；
# 且 TMPDIR 指向不存在路径时旧修复仍会失败）。直接走系统临时目录。
WORK="$(mktemp -d "${TMPDIR:-/tmp}/medical-data-ci-pack.XXXXXX" 2>/dev/null || mktemp -d /tmp/medical-data-ci-pack.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
# medical-data/ 布局（2026-09-25 整理）：入口 build_medical_data.sh 在根，抓取脚本在 fetch/，合并/构建在 bundle/，
# Go 源 drugkit/gonhsa/gonmpa 在根；脚本互引按此相对结构写死，payload 里必须保持同样的目录形状。
mkdir -p "$WORK/src/tools"
for f in build_medical_data.sh fetch/fetch_drug_data.sh fetch/fetch_nmpa.sh fetch/fetch_ref_data.sh fetch/hk_private_source.sh fetch/lanes.sh fetch/fetch_lanes.py bundle/drugkit_build.sh bundle/merge_drug_data.sh bundle/sysmon.sh; do
  mkdir -p "$WORK/src/tools/$(dirname "$f")"
  cp "$TOOLS/$f" "$WORK/src/tools/$f"
done
# 三地并行抓取的面板/多路输出复用训练侧 trainlib.panel（stdlib only）；runner 无终端时只打前缀日志，CI 照样并行
mkdir -p "$WORK/src/tools/trainlib"
for f in __init__.py panel.py; do
  cp "$ROOT/refactor/tools/training/shared/trainlib/$f" "$WORK/src/tools/trainlib/$f"
done
for d in drugkit gonhsa gonmpa; do
  cp -R "$TOOLS/$d" "$WORK/src/tools/$d"
done
# 2026-09-29 审查修复：testdata 目录与 .ndjson/.csv/.stderr/.stdout 金样也是
# 真实抓取数据/测试夹具（conventions.md 硬规则 2「testdata 绝不入库」），必须同
# *.jsonl/*.json/*.xml/*.pdf/*.zip 一起剥离——否则它们会随 base64 载荷绕过
# .gitignore 的 testdata/ 钉定进入 CI 脚本。
find "$WORK/src/tools" -type d \( -name node_modules -o -name __pycache__ -o -name .venv -o -name archive -o -name data -o -name testdata \) -prune -exec rm -rf {} +
find "$WORK/src/tools" -type f \( -name '*.jsonl' -o -name '*.ndjson' -o -name '*.json' -o -name '*.xml' -o -name '*.pdf' -o -name '*.zip' -o -name '*.csv' -o -name '*.stderr' -o -name '*.stdout' -o -name '*_test.go' \) -delete
find "$WORK/src/tools" -type f \( -name drugkit -o -name gonhsa -o -name gonmpa \) -delete
# Keep the payload deterministic so a source edit has one obvious payload hash.
tar --sort=name --mtime='UTC 1970-01-01' --owner=0 --group=0 --numeric-owner -C "$WORK/src" -czf "$WORK/payload.tgz" tools
sha=$(sha256sum "$WORK/payload.tgz" | awk '{print $1}')
base64 -w 76 "$WORK/payload.tgz" > "$WORK/payload.b64" 2>/dev/null || base64 "$WORK/payload.tgz" > "$WORK/payload.b64"
cat > "$WORK/prefix" <<'HEADER'
#!/usr/bin/env bash
# Self-contained GitHub-runner wrapper for the medical-data fetch/build pipeline.
# 2026-09-26 加固（业主裁决 2）：不再信任 $RUNNER_TEMP 下可预测路径的既有目录——共享
# 宿主上预植同名脚本可携带 GITHUB_TOKEN 执行。现在每次解包到 mktemp 随机目录，
# 用完即删（trap EXIT）；解包成本 ~2s，换取无预植攻击面。
set -euo pipefail
base="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
mkdir -p "$base"
work="$(mktemp -d "$base/medical-data-tools.XXXXXX")"
trap 'rm -rf "$work"' EXIT
awk '/^__MEDICAL_DATA_TOOLS_PAYLOAD__$/ {p=1; next} p' "$0" | base64 -d | gzip -dc | tar -xf - -C "$work"
find "$work/tools" -name '*.sh' -exec chmod +x {} +
exec "$work/tools/build_medical_data.sh" "$@"
exit 0
# medical CI tools payload: sha256=__PAYLOAD_SHA256__ bytes=__PAYLOAD_BYTES__
__MEDICAL_DATA_TOOLS_PAYLOAD__
HEADER
sed -e "s/__PAYLOAD_SHA256__/$sha/" -e "s/__PAYLOAD_BYTES__/$(wc -c < "$WORK/payload.tgz")/" "$WORK/prefix" > "$WORK/out"
cat "$WORK/payload.b64" >> "$WORK/out"
chmod 755 "$WORK/out"
mv "$WORK/out" "$OUT"
echo "medical CI tools payload: sha256=$sha bytes=$(wc -c < "$WORK/payload.tgz")"
