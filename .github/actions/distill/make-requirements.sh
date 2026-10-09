#!/usr/bin/env bash
# ============================================================================
# 生成训练依赖钉版清单(S-M6 哈希钉版纪律;换版流程的生成脚本,随簇入库)
#
# 三份清单两种用途:
#   train-linux   = 生成式 SFT 烟雾 + 编码器训练(torch + transformers 全量)
#   train-macos   = MPS 探测/标定(torch;smoke 只在 ubuntu 跑,不装 transformers)
#                   —— 2026-10-08 MPS 腿退役后 = M4 本地执行面备用件,CI 零调用
#   prepare-linux = prepare 数据面(cryptography 信封解密 + pypinyin 拼音层 +
#                   tokenizers 预算守卫——语料构建器与 eval 的轻量子集)
#
# 用法:
#   bash .github/actions/distill/make-requirements.sh <wheel-dir-linux> <wheel-dir-macos> <out-dir>
# 前置:linux 目录含全量 wheel(2026-10-07 起含 transformers 栈;生成命令见
#   requirements-distill-train-linux.txt 头部注记);macos 目录含 torch arm64
#   wheel(PyPI JSON 直取,跨平台 pip 解析有 platform_system 标记陷阱)。
# 换版 = 改版本 → 重跑本脚本 → 清单哈希整体替换,禁止手改哈希。
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

closure() {
  # 计算 LINUX_DIR 中给定顶层包的完整传递闭包(按 wheel METADATA 的 Requires-Dist
  # 名对名逐级展开;跳过 extras 标记,不做平台 marker 求值——目录本身已是
  # pip download 按目标平台解析的产物集)。2026-10-08 修复:此前 prepare 段用
  # 手选包名过滤,漏掉 tokenizers→huggingface-hub 传递链,首跑 CI 37707957974
  # 在 --require-hashes 下实证红(「all requirements must be pinned with ==」)。
  python3 - "$LINUX_DIR" "$@" <<'PY'
import sys, zipfile, re
from pathlib import Path
wheel_dir = Path(sys.argv[1])
tops = [n.lower().replace('-', '_') for n in sys.argv[2:]]
wheels = {}
for p in sorted(wheel_dir.glob('*.whl')):
    dist = p.name.split('-')[0].lower().replace('-', '_')
    wheels.setdefault(dist, p)
def requires(path):
    with zipfile.ZipFile(path) as z:
        meta = next(n for n in z.namelist() if n.endswith('.dist-info/METADATA'))
        for line in z.read(meta).decode('utf-8', 'replace').splitlines():
            if line.startswith('Requires-Dist:'):
                spec = line.split(':', 1)[1].strip()
                name, _, marker = spec.partition(';')
                if 'extra ==' in marker:
                    continue
                yield re.split(r'[<>=!~\[ (]', name.strip(), 1)[0].lower().replace('-', '_')
seen, order = set(), []
def visit(name):
    if name in seen or name not in wheels:
        return
    seen.add(name)
    order.append(wheels[name])
    for dep in requires(wheels[name]):
        visit(dep)
for t in tops:
    visit(t)
for p in sorted(order, key=lambda x: x.name.lower()):
    print(p)
PY
}

{
  echo "# 蒸馏/训练依赖钉版清单(S-M6;由 .github/actions/distill/make-requirements.sh 生成,勿手改)"
  echo "# 平台:linux x86_64 cp313(ubuntu-24.04 runner;torch 走 pytorch.org CPU 索引,无 CUDA)"
  echo "# 生成日期:$(date -u +%Y-%m-%d)"
  echo "# 内容(2026-10-07 起):torch CPU + pypinyin + transformers 栈(生成式 SFT 烟雾"
  echo "# train_sft_smoke.py 需 AutoTokenizer;语料构建器预算守卫需 tokenizers)。"
  emit "# -- linux --" "$LINUX_DIR"/*.whl
} > "$OUT_DIR/requirements-distill-train-linux.txt"

if compgen -G "$MACOS_DIR/*.whl" > /dev/null; then
  {
    echo "# 蒸馏/训练依赖钉版清单(S-M6;由 .github/actions/distill/make-requirements.sh 生成,勿手改)"
    echo "# 平台:macosx arm64 cp313(macos-15 runner;PyPI arm64 wheel 自带 MPS)"
    echo "# 生成日期:$(date -u +%Y-%m-%d)"
    emit "# -- macos --" "$MACOS_DIR"/*.whl
  } > "$OUT_DIR/requirements-distill-train-macos.txt"
else
  echo "skip: $MACOS_DIR 无 wheel——保留既有 requirements-distill-train-macos.txt(不产空文件)" >&2
fi

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

# prepare job 数据面依赖(2026-10-07 起):cryptography=CNB 信封解密(与 App 同构
# AES-256-GCM;公开包钥,非 secret)+ pypinyin(语料拼音层,与 eval 复现口径一致)
# + tokenizers(抽取构建器预算守卫必须与训练侧同一分词口径)。tests job 同装本
# 清单——解密往返等单测因此得以在 CI 实跑(缺依赖时测试自动 skip 而非假绿)。
{
  echo "# 蒸馏 prepare/测试依赖钉版清单(S-M6;由 .github/actions/distill/make-requirements.sh 生成,勿手改)"
  echo "# 平台:linux x86_64 cp313(ubuntu-24.04 runner)"
  echo "# 生成日期:$(date -u +%Y-%m-%d)"
  echo "# -- prepare --"
  # prepare 段闭包修正(2026-10-08):手选 5 包名曾漏 tokenizers→huggingface-hub 链,
  # 首跑 CI 实证红;现由 closure() 按 METADATA 展开完整传递闭包。
  # 注:清单以「pip download 对 prepare 顶层集合的独立解析」为准(如 hub 1.x 链),
  # 本闭包函数在并集 wheel 目录上为等价重建——两者都须经目标平台安装验证。
  for wheel in $(closure cryptography pypinyin tokenizers); do
    hash_of "$wheel"
  done
  echo
} > "$OUT_DIR/requirements-distill-prepare-linux.txt"

echo "written: $OUT_DIR/requirements-distill-train-{linux,macos}.txt + requirements-distill-{eval,prepare}-linux.txt"
