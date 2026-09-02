#!/usr/bin/env bash
# ============================================================================
# 获取 ONNX Runtime Linux 动态库 —— OCR dev 轨（ADR-026）
#
# 背景：OcrCli（Linux 条件 target）经 COnnxRuntime 链接 libonnxruntime.so；
#       该 .so 为宿主端二进制，不入库（见 .gitignore 排除 CoreKit/Vendor/onnxruntime/lib/）。
#       本脚本从微软官方 GitHub release 下载解压，保证全新 Linux 检出可复现构建。
#
# 用法：bash fetch.sh [版本]      （默认 1.24.2）
# 说明：链接/运行时需 LD_LIBRARY_PATH=<本目录>/lib
# ============================================================================
set -euo pipefail

VER="${1:-1.24.2}"
ARCH="$(uname -m)"
case "$ARCH" in
  aarch64|arm64) TRIPLE="linux-aarch64" ;;
  x86_64|amd64)  TRIPLE="linux-x64" ;;
  *) echo "不支持架构: $ARCH（仅 linux-aarch64 / linux-x64）"; exit 1 ;;
esac

HERE="$(cd "$(dirname "$0")" && pwd)"
LIBDIR="$HERE/lib"
TARBALL="onnxruntime-$TRIPLE-$VER.tgz"
URL="https://github.com/microsoft/onnxruntime/releases/download/v$VER/$TARBALL"
WORK="$(mktemp -d)"

echo "==> 架构 ${ARCH} → ${TRIPLE}"
echo "==> 下载 $URL"
command -v curl >/dev/null 2>&1 || { echo "缺 curl"; exit 1; }
curl -fL -o "$WORK/$TARBALL" "$URL" || { echo "下载失败（版本/网络？）"; rm -rf "$WORK"; exit 1; }

mkdir -p "$LIBDIR"
tar -xzf "$WORK/$TARBALL" -C "$WORK"
cp -f "$WORK/onnxruntime-$TRIPLE-$VER"/lib/libonnxruntime.so* "$LIBDIR"/
rm -rf "$WORK"

echo "==> 就绪：$LIBDIR"
ls -la "$LIBDIR"
echo "==> 链接/运行时请设置：export LD_LIBRARY_PATH=$LIBDIR"
