#!/usr/bin/env bash
# ============================================================================
# 导出 App 端抽取提示词与卡种元数据(供 CI 语料构建器逐字复用——训练/推理同分布保证)
#
# 单一事实源:文本来自 CoreKit/Sources/Domain 的真实代码(ExtractionPromptBuilder /
# ExtractionSpecRegistry),不经任何复写层——Domain 侧 spec/提示词变更后重跑本脚本
# 即可让 CI 语料跟进(不需要任何手工同步)。
#
# 编译方式与 refactor/tools/training/shared/export-extraction-prompts.sh 同构:
# swiftc 直编「全部 Domain 源文件 + 导出器 main」——不依赖 SPM/Apple SDK,
# Linux(含 GitHub ubuntu runner 的 Swift 工具链)与 macOS 均可运行。
#
# 用法:
#   bash scripts/distill/extract/export_prompts.sh [out_dir]
#   默认 out_dir = scripts/distill/extract/prompts
# ============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE"
while [[ ! -d "$ROOT/CoreKit/Sources/Domain" && "$ROOT" != "$(dirname "$ROOT")" ]]; do
  ROOT="$(dirname "$ROOT")"
done
if [[ ! -d "$ROOT/CoreKit/Sources/Domain" ]]; then
  echo "仓库根探测失败:找不到 CoreKit/Sources/Domain(从 $HERE 向上)" >&2
  exit 2
fi
command -v swiftc >/dev/null || { echo "缺 swiftc(CI 需 Swift 工具链;ubuntu runner 预装,见 workflow preflight)" >&2; exit 2; }

OUT_DIR="${1:-$HERE/prompts}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

DOMAIN_SOURCES=()
while IFS= read -r file; do DOMAIN_SOURCES+=("$file"); done < <(find "$ROOT/CoreKit/Sources/Domain" -name '*.swift' | sort)

swiftc -swift-version 5 -parse-as-library -o "$TMP/exporter" \
  "${DOMAIN_SOURCES[@]}" \
  "$HERE/export_extraction_prompts/main.swift"

"$TMP/exporter" "$OUT_DIR"
