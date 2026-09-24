#!/usr/bin/env bash
set -euo pipefail
# 仓库根探测:逐级向上找 project.yml 锚点(禁止按固定层级假设——脚本随簇移动)
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
while [ ! -f "$ROOT/project.yml" ]; do
  PARENT="$(dirname "$ROOT")"
  [ "$PARENT" = "$ROOT" ] && { echo "ERROR: 未找到 project.yml 锚点" >&2; exit 1; }
  ROOT="$PARENT"
done
TOOLS="$ROOT/refactor/tools"
OUT="$ROOT/scripts/medical-data/medical-data-ci.sh"
TMP_ROOT="${TMPDIR:-$ROOT/refactor/tools/.tmp}"
WORK="$(mktemp -d "$TMP_ROOT/medical-data-ci-pack.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/src/tools"
for f in build_medical_data.sh fetch_drug_data.sh fetch_nmpa.sh fetch_ref_data.sh drugkit_build.sh merge_drug_data.sh parse_hk.awk parse_tw.awk; do
  cp "$TOOLS/$f" "$WORK/src/tools/$f"
done
for d in drugkit gonhsa gonmpa; do
  cp -R "$TOOLS/$d" "$WORK/src/tools/$d"
done
find "$WORK/src/tools" -type d \( -name node_modules -o -name __pycache__ -o -name .venv -o -name archive -o -name data \) -prune -exec rm -rf {} +
find "$WORK/src/tools" -type f \( -name '*.jsonl' -o -name '*.json' -o -name '*.xml' -o -name '*.pdf' -o -name '*.zip' \) -delete
find "$WORK/src/tools" -type f \( -name drugkit -o -name gonhsa -o -name gonmpa \) -delete
# Keep the payload deterministic so a source edit has one obvious payload hash.
tar --sort=name --mtime='UTC 1970-01-01' --owner=0 --group=0 --numeric-owner -C "$WORK/src" -czf "$WORK/payload.tgz" tools
sha=$(sha256sum "$WORK/payload.tgz" | awk '{print $1}')
base64 -w 76 "$WORK/payload.tgz" > "$WORK/payload.b64" 2>/dev/null || base64 "$WORK/payload.tgz" > "$WORK/payload.b64"
cat > "$WORK/prefix" <<'HEADER'
#!/usr/bin/env bash
# Self-contained GitHub-runner wrapper for the medical-data fetch/build pipeline.
set -euo pipefail
PAYLOAD_SHA256="__PAYLOAD_SHA256__"
ROOT="${RUNNER_TEMP:-${TMPDIR:-.}}/medical-data-tools/$PAYLOAD_SHA256"
if [[ ! -x "$ROOT/tools/build_medical_data.sh" ]]; then
  tmp="$ROOT.tmp.$$"
  rm -rf "$tmp"
  mkdir -p "$tmp"
  awk '/^__MEDICAL_DATA_TOOLS_PAYLOAD__$/ {p=1; next} p' "$0" | base64 -d | gzip -dc | tar -xf - -C "$tmp"
  chmod +x "$tmp/tools"/*.sh
  mkdir -p "$(dirname "$ROOT")"
  mv "$tmp" "$ROOT"
fi
exec "$ROOT/tools/build_medical_data.sh" "$@"
exit 0
__MEDICAL_DATA_TOOLS_PAYLOAD__
HEADER
sed "s/__PAYLOAD_SHA256__/$sha/" "$WORK/prefix" > "$WORK/out"
cat "$WORK/payload.b64" >> "$WORK/out"
chmod 755 "$WORK/out"
mv "$WORK/out" "$OUT"
echo "medical CI tools payload: sha256=$sha bytes=$(wc -c < "$WORK/payload.tgz")"
