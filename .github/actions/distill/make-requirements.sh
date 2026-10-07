#!/usr/bin/env bash
# ============================================================================
# 生成训练依赖钉版清单(S-M6 哈希钉版纪律;换版流程的生成脚本,随簇入库)
#
# 两平台分开成文件:torch 版本串不同(linux=2.11.0+cpu 走 pytorch.org CPU 索引,
# macos=2.11.0 走 PyPI arm64 wheel 自带 MPS),单文件无法同时满足。
#
# 用法:
#   bash .github/actions/distill/make-requirements.sh <wheel-dir-linux> <wheel-dir-macos> <out-dir>
# 前置:两目录各含完整 wheel 集(linux 经
#   pip download --dest linux --only-binary=:all: --platform manylinux_2_28_x86_64 \
#     --python-version 313 --implementation cp \
#     --index-url https://download.pytorch.org/whl/cpu --extra-index-url https://pypi.org/simple \
#     torch==2.11.0 pypinyin==0.53.0
#   macos 的 torch/markupsafe wheel 经 PyPI JSON 直取(跨平台 pip 解析有
#   platform_system 标记陷阱,见脚本库注释),其余纯 wheel 与 linux 相同)。
# 换版 = 改版本 → 重跑本脚本 → 两清单哈希整体替换,禁止手改哈希。
# ============================================================================
set -euo pipefail

LINUX_DIR="${1:?linux wheel dir}"
MACOS_DIR="${2:?macos wheel dir}"
OUT_DIR="${3:?out dir}"
mkdir -p "$OUT_DIR"

hash_of() {
  # 输出 "包名==版本 --hash=sha256:..." 行(从 wheel 文件名解析包名与版本)
  local wheel="$1"
  local base
  base="$(basename "$wheel")"
  local hash
  hash="$(python3 -c "import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())" "$wheel")"
  local name version
  name="${base%%-*}"
  version="${base#*-}"
  version="${version%%-*}"
  printf '%s==%s \\\n    --hash=sha256:%s\n' "$name" "$version" "$hash"
}

emit() {
  local header="$1"; shift
  echo "$header"
  for wheel in "$@"; do
    hash_of "$wheel"
  done
  echo
}

{
  echo "# 蒸馏/训练依赖钉版清单(S-M6;由 .github/actions/distill/make-requirements.sh 生成,勿手改)"
  echo "# 平台:linux x86_64 cp313(ubuntu-24.04 runner;torch 走 pytorch.org CPU 索引,无 CUDA)"
  echo "# 生成日期:$(date -u +%Y-%m-%d)"
  emit "# -- linux --" "$LINUX_DIR"/*.whl
} > "$OUT_DIR/requirements-distill-train-linux.txt"

{
  echo "# 蒸馏/训练依赖钉版清单(S-M6;由 .github/actions/distill/make-requirements.sh 生成,勿手改)"
  echo "# 平台:macosx arm64 cp313(macos-15 runner;PyPI arm64 wheel 自带 MPS)"
  echo "# 生成日期:$(date -u +%Y-%m-%d)"
  emit "# -- macos --" "$MACOS_DIR"/*.whl
} > "$OUT_DIR/requirements-distill-train-macos.txt"

# eval job 只钉 pypinyin(纯 Python 零传递依赖,py3-none-any 双平台同一 wheel):
# 基线臂须与 prepare 构建语料时同拼音层可用性,且不拖入 torch 全量训练依赖。
{
  echo "# 蒸馏/评测闸依赖钉版清单(S-M6;由 .github/actions/distill/make-requirements.sh 生成,勿手改)"
  echo "# 平台:linux x86_64 cp313(ubuntu-24.04 runner)"
  echo "# 生成日期:$(date -u +%Y-%m-%d)"
  echo "#"
  echo "# 为什么 eval job 必须安装 pypinyin:prepare 构建冻结语料时带拼音层(同音噪声、"
  echo "# manifest.pinyin_available=true),eval 基线臂若不装,确定性召回 L2/L3 层静默缺位,"
  echo "# 评分与冻结语料假设不符(计划文档 §10 复现纪律)——此文件只钉 pypinyin"
  echo "# (纯 Python 零传递依赖),不拖入 torch 全量训练依赖。"
  echo "# -- eval --"
  for wheel in "$LINUX_DIR"/pypinyin-*.whl; do
    hash_of "$wheel"
  done
  echo
} > "$OUT_DIR/requirements-distill-eval-linux.txt"

echo "written: $OUT_DIR/requirements-distill-train-{linux,macos}.txt + requirements-distill-eval-linux.txt"
