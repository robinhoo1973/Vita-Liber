#!/usr/bin/env bash
# ============================================================================
# distill 簇本地测试入口(Linux 可跑,零第三方依赖)
#
# 覆盖:entlink 核心包(fold/fuzzy/catalog/noise/recall/confusion_miner)+
#       corpus 构建/manifest + gate 评测闸(纯 stdlib 部分)。
# 不含:probe/calibrate/train(checkpoint 的 torch 部分)——torch 为 CI 期依赖,
#       本地仅 py_compile 语法验证(见下方 SYNTAX 段)。
# 用法:bash scripts/distill/run_tests.sh
# 退出码:0=全绿;1=测试失败;2=语法失败。
# ============================================================================
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR" || exit 2

fail=0
echo "== [1/2] stdlib 单元测试(python3 -m unittest discover -s tests -t .)"
if ! python3 -m unittest discover -s tests -t . 2>&1; then
  fail=1
fi

echo "== [2/2] 全簇语法验证(py_compile,含 torch 依赖模块)"
if ! python3 -m py_compile \
    build_corpus.py eval_entlink.py download_corpus.py probe_mps.py calibrate.py train_encoder.py \
    entlink/*.py corpus/*.py gate/*.py train/*.py tests/*.py 2>&1; then
  echo "SYNTAX FAILED" >&2
  exit 2
fi

if [ "$fail" -ne 0 ]; then
  echo "TEST FAILED" >&2
  exit 1
fi
echo "ALL GREEN"
