#!/usr/bin/env bash
# ============================================================================
# vphone 快速验证脚本（L2 自托管探针 + 建议命令冒烟）
# 位置：.github/workflows/vphone-quickcheck.sh —— 被 l2-vphone-quickcheck.yml 引用
# 用途：
#   1) --probe-only 环境探针：证明「GitHub 托管 runner = VM + SIP/AMFI 不可放松」，
#      从而解释为什么 vphone 只能在自托管物理 Apple Silicon 上跑；
#   2) full（默认）冒烟：在自托管 Mac 上验证 vphone 建议命令（--help / vm list）。
# 可本机直接执行：bash .github/workflows/vphone-quickcheck.sh
# 退出码：0=全绿；1=有未通过项（托管环境探针的 FAIL 属预期证据）
# ============================================================================

set -uo pipefail

REPORT="vphone-quickcheck-report.txt"
: > "$REPORT"
log()  { printf '%s\n' "$*" | tee -a "$REPORT"; }
pass() { log "  [PASS] $*"; }
warn() { log "  [WARN] $*"; }
fail() { log "  [FAIL] $*"; FAILS=$((FAILS + 1)); }
FAILS=0
MODE="${1:-full}"   # --probe-only = 仅环境探针（托管演示用）

log "================================================"
log "vphone 快速验证 · $(date '+%Y-%m-%d %H:%M:%S') · 模式=${MODE}"
log "================================================"

# ── 1. 架构（vphone 要求 Apple Silicon）──────────────────────────
ARCH=$(uname -m 2>/dev/null || echo "?")
log "1) 架构: ${ARCH}"
[ "$ARCH" = "arm64" ] && pass "Apple Silicon" || warn "非 arm64（Intel/模拟）——vphone 要求 Apple Silicon"

# ── 2. macOS 版本（要求 15+）────────────────────────────────────
OS=$(sw_vers -productVersion 2>/dev/null || echo "?")
log "2) macOS: ${OS}"
if [ "$OS" != "?" ]; then
  major=${OS%%.*}
  [ "$major" -ge 15 ] && pass "macOS >= 15" || warn "macOS < 15（需 Sequoia 15+）"
fi

# ── 3. 是否自身是虚拟机（kern.hv_vmm_present）────────────────────
HV=$(sysctl -n kern.hv_vmm_present 2>/dev/null || echo "?")
log "3) kern.hv_vmm_present: ${HV}   (1=本 macOS 运行在虚拟机内 → vphone 无法嵌套)"
if [ "${HV:-?}" = "0" ]; then
  pass "裸机（可嵌套虚拟化）"
elif [ "${HV:-?}" = "1" ]; then
  fail "当前是虚拟机——Apple Virtualization PV=3 guest 无法嵌套（vphone FAQ 实测确认）"
else
  warn "无法判定虚拟化状态"
fi

# ── 4. SIP / AMFI（vphone 前置）─────────────────────────────────
CSR=$(csrutil status 2>/dev/null || echo "unknown")
log "4) SIP: ${CSR//$'\n'/ }"
case "$CSR" in
  *disabled*)             pass "SIP 已关闭（vphone 前置满足）" ;;
  *unknown*|*"not available"*) warn "SIP 状态不可得——托管/受限环境（vphone 无法满足前置）" ;;
  *)                      warn "SIP 未关闭——需进 Recovery 执行 csrutil disable + allow-research-guests enable" ;;
esac

AMFI=$(nvram boot-args 2>/dev/null || echo "")
log "5) boot-args: ${AMFI:-（空/不可读）}"
case "$AMFI" in
  *amfi_get_out_of_my_way*) pass "AMFI 已放行" ;;
  *) warn "无 amfi_get_out_of_my_way=1（或 nvram 不可读——托管环境预期）" ;;
esac

# ── 探针模式：到此为止（托管环境预期 FAIL，即证明不可行）──────────
if [ "$MODE" = "--probe-only" ]; then
  log "------------------------------------------------"
  if [ "$FAILS" -gt 0 ]; then
    log "结论（探针）：${FAILS} 项未通过 —— 托管 runner 属预期失败（VM 不可嵌套 + SIP/AMFI 不可放松）"
  else
    log "结论（探针）：裸机 Apple Silicon + 前置满足 —— 可进入 vphone 冒烟"
  fi
  echo "report -> $REPORT"
  exit $(( FAILS > 0 ? 1 : 0 ))
fi

# ── 冒烟：vphone 建议命令 ────────────────────────────────────────
log "6) vphone-cli 冒烟："
if ! command -v vphone-cli >/dev/null 2>&1; then
  fail "未找到 vphone-cli —— brew install zqxwce/tap/vphone-cli"
else
  pass "vphone-cli 已安装"
  log "   -- vphone-cli --help --"
  vphone-cli --help 2>&1 | tee -a "$REPORT" | head -12
  log "   -- vphone-cli vm list --json --"
  vphone-cli vm list --json 2>&1 | tee -a "$REPORT" | head -12
  log "   -- vphone-cli vm info 探测（取首个 VM，无则跳过） --"
  FIRST=$(vphone-cli vm list --json 2>/dev/null | python3 -c 'import sys,json
try:
    d=json.load(sys.stdin); v=(d if isinstance(d,list) else d.get("vms",[]))
    print(v[0]["name"] if v and isinstance(v[0],dict) else (v[0] if v else ""))
except Exception: print("")' 2>/dev/null)
  if [ -n "$FIRST" ]; then
    vphone-cli vm info "$FIRST" 2>&1 | tee -a "$REPORT" | head -12
  else
    warn "无现有 VM —— 跳过 vm info（先跑 vm create 建机）"
  fi
fi

log "================================================"
if [ "$FAILS" -eq 0 ]; then
  log "结论：全绿 —— 自托管 vphone 环境就绪"
  echo "report -> $REPORT"
  exit 0
else
  log "结论：${FAILS} 项未通过（托管 runner 上的 FAIL 属预期证据）"
  echo "report -> $REPORT"
  exit 1
fi
