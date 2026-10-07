#!/usr/bin/env bash
# check-signing-expiry.sh 的 Linux 单测（无 macOS 依赖；openssl 自签证书做 fixture）。
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/check-signing-expiry.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }

future=$(date -u -v+100d '+%b %d %H:%M:%S %Y %Z' 2>/dev/null) || future=$(date -u -d '+100 days' '+%b %d %H:%M:%S %Y %Z')
soon=$(date -u -v+5d '+%b %d %H:%M:%S %Y %Z' 2>/dev/null) || soon=$(date -u -d '+5 days' '+%b %d %H:%M:%S %Y %Z')
expired=$(date -u -v-10d '+%b %d %H:%M:%S %Y %Z' 2>/dev/null) || expired=$(date -u -d '-10 days' '+%b %d %H:%M:%S %Y %Z')

[ "$(check_days "$future")" -ge 90 ] || fail "未来 100 天应 ≥90 剩余"
[ "$(check_days "$soon")" -le 7 ] || fail "未来 5 天应 ≤7"
[ "$(check_days "$expired")" -lt 0 ] || fail "过去 10 天应为负数（已过期）"
[ "$(check_days "not a date")" = "PARSE_FAIL" ] || fail "非法日期应 PARSE_FAIL（哨兵与负天数分离）"

verdict "DEV" "$expired" >/dev/null && fail "已过期必须非零退出"
verdict "DEV" "$soon" >/dev/null && fail "≤7 天必须非零退出"
verdict "DEV" "$future" >/dev/null || fail ">30 天应零退出"
echo "PASS: check-signing-expiry.sh contract"
