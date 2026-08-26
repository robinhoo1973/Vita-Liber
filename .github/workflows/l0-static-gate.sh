#!/usr/bin/env bash
# ============================================================================
# Vita Liber · 青囊书 — L0 静态门禁
# 位置：.github/workflows/l0-static-gate.sh —— 被 vita-liber-ios.yml 的
#       l0-static-gate job 引用，与工作流同目录托管；本地同样可直接执行。
# 依据：dev-pm-spec §9.2（五项固定检查，任一失败即红）/ §9.4（L0 不过不进 L1）
#
#   [1] try? grep 门禁 —— 全仓清零；豁免仅限同行注释 `// try?-ok: <理由>`（tech-spec §7）
#   [2] ADR-021 无平行视图 —— 禁止 *_iPad/*_iPhone 视图文件；
#       禁止 `userInterfaceIdiom == .pad` 分支换页（豁免同行注释 `// adr021-ok: <理由>`）（tech-spec §5.26）
#   [3] DDL 引用完整性 —— 每个 REFERENCES 目标表必须有对应 CREATE TABLE；
#       必须显式开启外键（foreign_keys / foreignKeysEnabled）（tech-spec §4.3，dev-pm §3.1 M0）
#   [4] 红线模块禁读 EntitlementStore（tech-spec §5.14，comercial-spec §1 永久免费红线）
#   [5] Domain 零框架依赖 —— Sources/Domain 不 import SwiftUI/UIKit/Vision/GRDB（tech-spec §1.1）
#   附 [6] Fixtures/**/*.json 可解析校验（目录缺失仅告警——金样随阶段入库 §9.1）
#
# 运行环境：bash 3.2+（兼容 macOS 自带 bash）/ python3 或 node 或 jq（仅 JSON 校验用）。
#           macOS/Linux 原生可跑；Windows 用 Git Bash 或等价 l0-static-gate.py。
# 退出码：0=全绿；1=门禁失败；2=环境错误（找不到应用源码——本脚本属于代码仓库）。
#
# 可调环境变量：
#   APP_ROOT        应用源码根（含 CoreKit/Sources/Domain 的目录）；默认自动探测 ./ 或 ./VitaLiber
#   FIXTURES_DIR    金样目录；默认 $APP_ROOT/Fixtures
#   REDLINE_PATHS   冒号分隔的红线模块目录列表；默认取 comercial-spec §2.1 对应的 Features/*
# ============================================================================
set -euo pipefail

# ---------- 输出 ----------
if [ -t 1 ]; then
  C_G=$'\033[32m'; C_R=$'\033[31m'; C_Y=$'\033[33m'; C_B=$'\033[1m'; C_0=$'\033[0m'
else
  C_G=''; C_R=''; C_Y=''; C_B=''; C_0=''
fi
FAILURES=0
pass() { printf '  %sPASS%s %s\n' "$C_G" "$C_0" "$1"; }
fail() { printf '  %sFAIL%s %s\n' "$C_R" "$C_0" "$1"; FAILURES=$((FAILURES + 1)); }
warn() { printf '  %sWARN%s %s\n' "$C_Y" "$C_0" "$1"; }
section() { printf '\n%s[%s]%s %s\n' "$C_B" "$1" "$C_0" "$2"; }

# ---------- 定位应用源码（找不到即环境错误，绝不静默通过）----------
# 从脚本所在目录逐级向上探测仓库根（脚本位于 .github/workflows/ 下，深度可变）
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
while [ "$ROOT" != "/" ] && [ ! -d "$ROOT/CoreKit/Sources/Domain" ] && [ ! -d "$ROOT/VitaLiber/CoreKit/Sources/Domain" ]; do
  ROOT="$(dirname "$ROOT")"
done
cd "$ROOT"

if [ -n "${APP_ROOT:-}" ]; then
  APP="$APP_ROOT"
elif [ -d "CoreKit/Sources/Domain" ]; then
  APP="."
elif [ -d "VitaLiber/CoreKit/Sources/Domain" ]; then
  APP="VitaLiber"
else
  printf '%sERROR%s 未找到应用源码（需要 CoreKit/Sources/Domain）。本门禁属于代码仓库（MedicalNotes/VitaLiber），当前目录无可检查对象。\n' "$C_R" "$C_0" >&2
  exit 2
fi
COREKIT="$APP/CoreKit"
DOMAIN="$COREKIT/Sources/Domain"
FIXTURES="${FIXTURES_DIR:-$APP/Fixtures}"; [ -d "$FIXTURES" ] || FIXTURES="$APP/CoreKit/Fixtures"

echo "Vita Liber L0 静态门禁 · 应用源码根: $APP"

# ---------- [1] try? 门禁 ----------
section "1/6" "try? 门禁 —— 全仓清零，豁免须同行注释 // try?-ok: <理由>（tech-spec §7）"
try_viol=0; try_exempt=0
while IFS= read -r line; do
  [ -n "$line" ] || continue
  _f=${line%%:*}; _rest=${line#*:}; _n=${_rest%%:*}; _content=${_rest#*:}
  _nc=$(printf '%s\n' "$_content" | sed 's,//.*,,' )
  case "$_nc" in *'try?'*) ;; *) continue ;; esac          # 注释后的 try? 不算
  case "$_content" in *'try?-ok:'*) try_exempt=$((try_exempt + 1)); continue ;; esac
  try_viol=$((try_viol + 1))
  [ "$try_viol" -le 15 ] && printf '    %s:%s\n' "$_f" "$_n"
done < <(grep -rn -F 'try?' --include='*.swift' --exclude-dir=.build --exclude-dir=.swiftpm --exclude-dir=DerivedData --exclude-dir=Build "$APP" 2>/dev/null || true)
if [ "$try_viol" -gt 0 ]; then
  fail "try? 违规 ${try_viol} 处（豁免 ${try_exempt} 处）——删除或按 §7 补豁免理由"
else
  pass "违规 0 处（豁免 ${try_exempt} 处）"
fi

# ---------- [2] ADR-021 无平行视图 ----------
section "2/6" "ADR-021 —— 禁止平行视图文件与 idiom 分支换页（tech-spec §5.26）"
ipad_files=$(find "$APP" \( -name .build -o -name .swiftpm -o -name DerivedData -o -name Build \) -prune -o \( -name '*_iPad*.swift' -o -name '*_iPhone*.swift' \) -print 2>/dev/null | grep -v '/CoreKit/' || true)
if [ -n "$ipad_files" ]; then
  printf '%s\n' "$ipad_files" | head -15 | sed 's/^/    /'
  fail "发现 *_iPad/*_iPhone 平行视图文件（每 SP 恰一个内容视图）"
else
  pass "无平行视图文件"
fi
idiom_viol=0
while IFS= read -r line; do
  [ -n "$line" ] || continue
  _f=${line%%:*}; _rest=${line#*:}; _n=${_rest%%:*}; _content=${_rest#*:}
  case "$_content" in *'adr021-ok:'*) continue ;; esac
  idiom_viol=$((idiom_viol + 1))
  [ "$idiom_viol" -le 15 ] && printf '    %s:%s\n' "$_f" "$_n"
done < <(grep -rinE '--exclude-dir=.build --exclude-dir=.swiftpm --exclude-dir=DerivedData --exclude-dir=Build' 'userInterfaceIdiom[[:space:]]*==[[:space:]]*\.pad' --include='*.swift' --exclude-dir=.build --exclude-dir=.swiftpm --exclude-dir=DerivedData --exclude-dir=Build "$APP" 2>/dev/null || true)
if [ "$idiom_viol" -gt 0 ]; then
  fail "idiom 分支换页 ${idiom_viol} 处 —— 改用容器驱动重排（ViewThatFits/AnyLayout/sizeClass）"
else
  pass "无 idiom 分支换页"
fi

# ---------- [3] DDL 引用完整性 ----------
section "3/6" "DDL 引用完整性 —— REFERENCES 目标已建表 + 外键开启（tech-spec §4.3）"
ddl_text=$(find "$APP" \( -name .build -o -name .swiftpm -o -name DerivedData \) -prune -o \( -name '*.swift' -o -name '*.sql' \) -print0 2>/dev/null | xargs -0 cat 2>/dev/null || true)
created=$(printf '%s\n' "$ddl_text" | tr -d '"' \
  | grep -ohE 'CREATE TABLE( IF NOT EXISTS)? [A-Za-z_]+' \
  | awk '{print $NF}' | sort -u || true)
refs=$(printf '%s\n' "$ddl_text" \
  | grep -ohE 'REFERENCES "?[A-Za-z_]+' \
  | awk '{gsub(/"/,""); print $NF}' | sort -u || true)
ddl_missing=0
while IFS= read -r t; do
  [ -n "$t" ] || continue
  if ! printf '%s\n' "$created" | grep -qx "$t"; then
    ddl_missing=$((ddl_missing + 1)); printf '    引用了未定义表: %s\n' "$t"
  fi
done <<EOF
$refs
EOF
fk_on=0
printf '%s\n' "$ddl_text" | grep -qE 'foreign_keys|foreignKeysEnabled|foreignKeys[[:space:]]*=' && fk_on=1
if [ "$ddl_missing" -eq 0 ] && [ "$fk_on" -eq 1 ]; then
  pass "REFERENCES 目标全部已定义；外键开启断言通过"
else
  [ "$ddl_missing" -gt 0 ] && fail "外键引用悬空 ${ddl_missing} 个目标表"
  [ "$fk_on" -eq 0 ] && fail "未找到外键开启语句（PRAGMA foreign_keys=ON / Configuration.foreignKeysEnabled）"
fi

# ---------- [4] 红线模块禁读 EntitlementStore ----------
section "4/6" "商业化红线 —— 红线模块代码内禁止读取 EntitlementStore（tech-spec §5.14）"
DEFAULT_REDLINE="$APP/Features/Documents:$APP/Features/Observations:$APP/Features/Medications:$APP/Features/Search:$APP/Features/Support"
REDLINE_PATHS="${REDLINE_PATHS:-$DEFAULT_REDLINE}"
redline_matched=0; ent_viol=0
OLDIFS=$IFS; IFS=':'
for p in $REDLINE_PATHS; do
  [ -d "$p" ] || continue
  redline_matched=$((redline_matched + 1))
  while IFS= read -r h; do
    [ -n "$h" ] || continue
    ent_viol=$((ent_viol + 1))
    [ "$ent_viol" -le 15 ] && printf '    %s\n' "$h"
  done < <(grep -rn -F 'EntitlementStore' --include='*.swift' --exclude-dir=.build --exclude-dir=.swiftpm --exclude-dir=DerivedData --exclude-dir=Build "$p" 2>/dev/null || true)
done
IFS=$OLDIFS
if [ "$redline_matched" -eq 0 ]; then
  warn "REDLINE_PATHS 中没有已存在的目录（M0 早期属正常）——检查空转，目录落地后请复核"
else
  if [ "$ent_viol" -gt 0 ]; then
    fail "红线模块读取 EntitlementStore ${ent_viol} 处 —— 一票否决（验收红线）"
  else
    pass "红线模块（${redline_matched} 个目录）零 EntitlementStore 引用"
  fi
fi

# ---------- [5] Domain 零框架依赖 ----------
section "5/6" "分层纪律 —— Domain 目标不 import SwiftUI/UIKit/Vision/GRDB（tech-spec §1.1）"
if [ ! -d "$DOMAIN" ]; then
  fail "缺少 $DOMAIN —— M0 要求 CoreKit 三目标骨架先行"
else
  dom_hits=$(grep -rnE '^import[[:space:]]+(SwiftUI|UIKit|Vision|GRDB|GRDBSQLite)([^A-Za-z0-9_]|$)' \
    --include='*.swift' --exclude-dir=.build --exclude-dir=.swiftpm --exclude-dir=DerivedData --exclude-dir=Build "$DOMAIN" 2>/dev/null | head -15 || true)
  if [ -n "$dom_hits" ]; then
    printf '%s\n' "$dom_hits" | sed 's/^/    /'
    fail "Domain 出现被禁 import"
  else
    pass "Domain 纯净（仅 Foundation 层依赖）"
  fi
fi

# ---------- [6] Fixtures JSON 校验 ----------
section "6/6" "金样 Fixtures —— JSON 可解析（dev-pm-spec §9.2④）"
validate_json() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import json,sys; json.load(open(sys.argv[1], encoding="utf-8"))' "$1" 2>/dev/null
  elif command -v node >/dev/null 2>&1; then
    node -e 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))' "$1" 2>/dev/null
  elif command -v jq >/dev/null 2>&1; then
    jq empty "$1" >/dev/null 2>&1
  else
    return 2
  fi
}
if [ ! -d "$FIXTURES" ]; then
  warn "Fixtures 目录缺失（金样随阶段入库，dev-pm-spec §9.1）——跳过"
else
  j_total=0; j_bad=0; j_no_tool=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    j_total=$((j_total + 1))
    # 注意：不能用裸调用——坏 JSON 返回 1 会触发 set -e 直接退出
    rc=0; validate_json "$f" || rc=$?
    if [ "$rc" -eq 1 ]; then
      j_bad=$((j_bad + 1)); printf '    JSON 解析失败: %s\n' "$f"
    elif [ "$rc" -eq 2 ]; then
      j_no_tool=1
    fi
  done < <(find "$FIXTURES" -name '*.json' 2>/dev/null)
  if [ "$j_no_tool" -eq 1 ]; then
    warn "无 python3/node/jq 可用，跳过 JSON 校验"
  elif [ "$j_bad" -gt 0 ]; then
    fail "损坏 JSON ${j_bad}/${j_total} 个"
  else
    pass "${j_total} 个 JSON 全部可解析"
  fi
fi

# ---------- 汇总 ----------
printf '\n========================================\n'
if [ "$FAILURES" -eq 0 ]; then
  printf '%s全绿 —— L0 通过，可进 L1 编译测试%s\n' "$C_G" "$C_0"
  exit 0
else
  printf '%s失败项：%s —— L0 不过不进 L1（dev-pm-spec §9.4）%s\n' "$C_R" "$FAILURES" "$C_0"
  exit 1
fi
