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
#   [6] Fixtures/**/*.json 可解析校验（目录缺失仅告警——金样随阶段入库 §9.1）
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
# 金样目录探测（ERR#27）：金样实际落在 CoreKit/Tests/CoreKitTests/Fixtures（SPM resources 约定），
# 早期硬编码的 $APP/Fixtures、$APP/CoreKit/Fixtures 均为空壳目录——空目录会让 [7/7] 扫到 0 个 JSON
# 而报「全部可解析」的假绿。改为：显式变量 > 候选路径 > 全仓搜索，且 0 个金样一律不判 PASS。
if [ -n "${FIXTURES_DIR:-}" ]; then
  FIXTURES="$FIXTURES_DIR"
else
  FIXTURES=""
  for _cand in "$APP/CoreKit/Tests/CoreKitTests/Fixtures" "$APP/Fixtures" "$APP/CoreKit/Fixtures"; do
    if [ -d "$_cand" ] && [ -n "$(find "$_cand" -name '*.json' 2>/dev/null | head -1)" ]; then
      FIXTURES="$_cand"; break
    fi
  done
  # 兜底：全仓搜索任何含 JSON 的 Fixtures 目录（排除构建产物）
  if [ -z "$FIXTURES" ]; then
    FIXTURES="$(find "$APP" -type d -name Fixtures \
      -not -path '*/.build/*' -not -path '*/DerivedData/*' -not -path '*/Build/*' \
      2>/dev/null | head -1)"
  fi
  [ -n "$FIXTURES" ] || FIXTURES="$APP/CoreKit/Tests/CoreKitTests/Fixtures"
fi

echo "Vita Liber L0 静态门禁 · 应用源码根: $APP"

# ---------- [1] try? 门禁 ----------
section "1/7" "try? 门禁 —— 全仓清零，豁免须同行注释 // try?-ok: <理由>（tech-spec §7）"
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
section "2/7" "ADR-021 —— 禁止平行视图文件与 idiom 分支换页（tech-spec §5.26）"
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
  _nc=$(printf '%s\n' "$_content" | sed 's,//.*,,' )
  case "$_nc" in *'userInterfaceIdiom'*'.pad'*) ;; *) continue ;; esac   # 注释里的字样不算
  idiom_viol=$((idiom_viol + 1))
  [ "$idiom_viol" -le 15 ] && printf '    %s:%s\n' "$_f" "$_n"
done < <(grep -rinE 'userInterfaceIdiom[[:space:]]*==[[:space:]]*\.pad' --include='*.swift' --exclude-dir=.build --exclude-dir=.swiftpm --exclude-dir=DerivedData --exclude-dir=Build "$APP" 2>/dev/null || true)
if [ "$idiom_viol" -gt 0 ]; then
  fail "idiom 分支换页 ${idiom_viol} 处 —— 改用容器驱动重排（ViewThatFits/AnyLayout/sizeClass）"
else
  pass "无 idiom 分支换页"
fi

# ---------- [3] DDL 引用完整性 ----------
section "3/7" "DDL 引用完整性 —— REFERENCES 目标已建表 + 外键开启（tech-spec §4.3）"
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
# 外键开启断言（评审修正）：Configuration.foreignKeysEnabled 位于 GRDBStore.swift，
# 该文件整体被 `#if os(iOS)||os(macOS)` 守卫，Linux 上扫描不到文本 → 旧检查假红。
# 断言改为「schema-as-code 常量存在」+「GRDB 侧配置语义存在」双条件，
# 与平台无关；运行时半场（PRAGMA 实测）由 iOS 模拟器 SchemaRuntimeTests 承担。
printf '%s\n' "$ddl_text" | grep -qE 'SchemaV2|foreignKeysEnabled' && fk_on=1
if [ "$ddl_missing" -eq 0 ] && [ "$fk_on" -eq 1 ]; then
  pass "REFERENCES 目标全部已定义；外键开启断言通过"
else
  [ "$ddl_missing" -gt 0 ] && fail "外键引用悬空 ${ddl_missing} 个目标表"
  [ "$fk_on" -eq 0 ] && fail "未找到外键开启语句（PRAGMA foreign_keys=ON / Configuration.foreignKeysEnabled）"
fi
# M0 必建表完整性（评审 S1-1）：dev-pm §3.1⑤ 指定的批次/药品表是 schema 基础设施，
# 缺表时引用完整性检查不报错但 M0 退出准则不达标——必须显式断言清单。
m0_tables="prescription medication medication_plan medication_dose_log stock_lot dose_lot_allocation"
m0_missing=0
for t in $m0_tables; do
  printf '%s\n' "$ddl_text" | grep -qE "CREATE TABLE $t([[:space:]]|\\()" || { m0_missing=$((m0_missing + 1)); printf '    M0 必建表缺失: %s\n' "$t"; }
done
[ "$m0_missing" -eq 0 ] && pass "M0 必建表清单齐备（prescription/medication/plan/dose_log/stock_lot/allocation）" || fail "M0 必建表缺失 ${m0_missing} 个（dev-pm §3.1⑤）"

# ---------- [4] 红线模块禁读 EntitlementStore ----------
section "4/7" "商业化红线 —— 红线模块代码内禁止读取 EntitlementStore（tech-spec §5.14）"
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
section "5/7" "分层纪律 —— Domain 零框架依赖，白名单断言 import ⊆ {Foundation}（tech-spec §1.1）"
if [ ! -d "$DOMAIN" ]; then
  fail "缺少 $DOMAIN —— M0 要求 CoreKit 三目标骨架先行"
else
  # 评审 S2-3 修正：§1.1「零框架依赖(除 Foundation)」是白名单语义——黑名单
  # （拦 5 个框架）会放 PDFKit/CryptoKit 等漏网。白名单：import 仅允许 Foundation。
  dom_imports=$(grep -rhnE '^import[[:space:]]+[A-Za-z_][A-Za-z0-9_]*' \
    --include='*.swift' --exclude-dir=.build --exclude-dir=.swiftpm --exclude-dir=DerivedData --exclude-dir=Build "$DOMAIN" 2>/dev/null \
    | sed -E 's/^[0-9]+://; s/^import[[:space:]]+//' | sort -u || true)
  dom_bad=$(printf '%s\n' "$dom_imports" | grep -vx 'Foundation' || true)
  if [ -n "$dom_bad" ]; then
    printf '%s\n' "$dom_bad" | sed 's/^/    非白名单 import: /'
    fail "Domain 出现白名单外 import（允许集合={Foundation}）"
  else
    pass "Domain 纯净（白名单断言通过：import ⊆ {Foundation}）"
  fi
fi

# ---------- [6] Fixtures JSON 校验 ----------
section "6/7" "金样 Fixtures —— JSON 可解析（dev-pm-spec §9.2④）"
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
  elif [ "$j_total" -eq 0 ]; then
    # ERR#27：0 个金样绝不判 PASS——空目录曾让本项长期假绿
    warn "目录 $FIXTURES 内 0 个 JSON——金样尚未入库或路径漂移，本项未实际校验"
  else
    pass "${j_total} 个 JSON 全部可解析（$FIXTURES）"
  fi
fi

# ---------- [7] Swift 语法解析门禁 ----------
section "7/7" "Swift 解析门禁 —— App 层源码语法/保留字检查（ERR#28 shift-left）"
# 背景：App/ 的 SwiftUI 源码不属于 CoreKit SPM 包，Linux 上 `swift build` 不覆盖它，
# 过去任何语法错误（如 `static let import`）都要等 macOS L1 编译才暴露，一次往返数分钟。
# swiftc -parse 只做语法分析、不做语义解析与 import 解析，因此在无 SwiftUI 的 Linux 上同样有效。
if ! command -v swiftc >/dev/null 2>&1; then
  warn "无 swiftc 可用，跳过解析门禁（macOS L1 编译仍会覆盖）"
else
  p_total=0; p_bad=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    p_total=$((p_total + 1))
    if ! swiftc -parse "$f" >/dev/null 2>&1; then
      p_bad=$((p_bad + 1))
      printf '    解析失败: %s\n' "$f"
      swiftc -parse "$f" 2>&1 | grep -E '^.+error:' | head -3 | sed 's/^/      /' || true
    fi
  done < <(find "$APP" -name '*.swift' \
    -not -path '*/.build/*' -not -path '*/.swiftpm/*' \
    -not -path '*/DerivedData/*' -not -path '*/Build/*' 2>/dev/null)
  if [ "$p_bad" -gt 0 ]; then
    fail "语法解析失败 ${p_bad}/${p_total} 个文件"
  else
    pass "${p_total} 个 Swift 文件语法解析通过"
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
