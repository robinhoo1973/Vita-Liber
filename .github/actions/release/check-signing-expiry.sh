#!/usr/bin/env bash
# 签名材料到期检查（2026-09-27 委员会 P5：自 build-testflight.yml 析出，Linux 可测）。
# 用法：check-signing-expiry.sh <days-计算器> —— 或直接 source 本文件用 check_days。
# 语义：输出 "LABEL 剩余 N 天 ✓" / "LABEL 将在 N 天内到期（DATE）" / "LABEL 已过期 N 天（DATE）"；
#       解析失败输出 "LABEL 到期日解析失败：DATE"。退出码：已过期/解析失败=1，其余=0。
set -euo pipefail

# 纯函数：notAfter 日期串 → 剩余天数（负=已过期）；解析失败输出 PARSE_FAIL。
# Linux 可单测（openssl 自签证书做 fixture）。
check_days() {
  local enddate="$1" now_s end_s days
  now_s=$(date -u +%s)
  # macOS date -j；GNU date -d（Linux 单测与未来可能的 ubuntu 周检共用）
  if ! end_s=$(date -j -u -f '%b %d %H:%M:%S %Y %Z' "$enddate" +%s 2>/dev/null); then
    if ! end_s=$(date -u -d "$enddate" +%s 2>/dev/null); then
      echo "PARSE_FAIL"
      return 0
    fi
  fi
  days=$(( (end_s - now_s) / 86400 ))
  echo "$days"
}

verdict() {
  local label="$1" enddate="$2" days verdict
  days="$(check_days "$enddate")"
  if [ "$days" = "PARSE_FAIL" ]; then
    echo "$label 到期日解析失败：$enddate"
    return 1
  fi
  if [ "$days" -lt 0 ]; then
    echo "$label 已过期 $((-days)) 天（$enddate）"
    return 1
  fi
  if [ "$days" -le 7 ]; then
    echo "$label 将在 $days 天内到期（$enddate）"
    return 1
  fi
  if [ "$days" -le 30 ]; then
    echo "$label 将在 $days 天内到期（$enddate）"
    return 0
  fi
  echo "$label 剩余 $days 天 ✓"
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  "${@:-true}"
fi
