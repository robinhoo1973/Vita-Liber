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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # 门禁清单等同目录资产的锚点（[8]）
ROOT="$SCRIPT_DIR"
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

# ---------- [1] 强制解包/try? 门禁 ----------
section "1/10" "强制解包门禁 —— try? / as! / try! 全仓清零，豁免须同行注释 // try?-ok: <理由>（tech-spec §7）"
try_viol=0; try_exempt=0
while IFS= read -r line; do
  [ -n "$line" ] || continue
  _f=${line%%:*}; _rest=${line#*:}; _n=${_rest%%:*}; _content=${_rest#*:}
  _nc=$(printf '%s\n' "$_content" | sed 's,//.*,,' | sed -E 's,[A-Za-z0-9_]try\?,,g' )
  case "$_nc" in *'try?'*) ;; *) continue ;; esac          # 注释与标识符内的 try? 不算（ERR#37）
  case "$_content" in *'try?-ok:'*) try_exempt=$((try_exempt + 1)); continue ;; esac
  try_viol=$((try_viol + 1))
  [ "$try_viol" -le 15 ] && printf '    %s:%s\n' "$_f" "$_n"
done < <(grep -rnE '(^|[^A-Za-z0-9_])try\?' --include='*.swift' --exclude-dir=.build --exclude-dir=.swiftpm --exclude-dir=DerivedData --exclude-dir=Build "$APP" 2>/dev/null || true)
if [ "$try_viol" -gt 0 ]; then
  fail "try? 违规 ${try_viol} 处（豁免 ${try_exempt} 处）——删除或按 §7 补豁免理由"
else
  pass "违规 0 处（豁免 ${try_exempt} 处）"
fi

# --- as! / try! 强制转换/强制 try（审查问题 1 回归防护）同纪律，豁免注释沿用 try?-ok ---
force_viol=0
for _pat in 'as! ' 'try! '; do
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in *'try?-ok:'*) continue ;; esac
    _r=${line#*:}; _r=${_r#*:}
    _nc=$(printf '%s\n' "$_r" | sed 's,//.*,,' )        # 剥离 // 注释（同 try? 扫描纪律）
    case "$_nc" in *"$_pat"*) force_viol=$((force_viol + 1)); [ "$force_viol" -le 12 ] && printf '    %s\n' "$line" ;; esac
  done < <(grep -rn --include='*.swift' --exclude-dir=.build --exclude-dir=.swiftpm --exclude-dir=DerivedData --exclude-dir=Build -F "$_pat" "$APP" 2>/dev/null || true)
done
if [ "$force_viol" -gt 0 ]; then
  fail "强制类型转换/强制 try（as!/try!）${force_viol} 处 —— 改 as?/do-catch 或补 // try?-ok: 豁免"
else
  pass "as!/try! 违规 0 处"
fi

# ---------- [2] ADR-021 无平行视图 ----------
section "2/10" "ADR-021 —— 禁止平行视图文件与 idiom 分支换页（tech-spec §5.26）"
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
section "3/10" "DDL 引用完整性 —— REFERENCES 目标已建表 + 外键开启（tech-spec §4.3）"
# 大文本管道防 SIGPIPE（ERR#34）：ddl_text 达数 MB 后，
# `printf | grep -qE` 在 grep 提前命中退出时把仍在写的 printf 打死
# （exit 141），pipefail 下整段报错——曾造成「外键开启语句缺失」假红。
# 一律落临时文件再 grep，杜绝管道早退。
_ddl_file=$(mktemp)
# 逐文件追加，不用 `xargs -0 cat`：参数表超过 ARG_MAX 时 xargs 会拆成多次 cat，
# 任一次失败都被 `2>/dev/null || true` 吞掉 → 语料被截断而门禁毫不知情。
# 截断的后果是双向的：既可能把「CREATE TABLE 落在丢失分片里」的表报成悬空引用（假红，
# 实测遇到过一次不可复现的 1 处悬空），也可能把真实违规读漏成 PASS（ERR#27 空扫判过）。
# 因此改为可数的读入 + 语料完整性自证。
_ddl_files=0
while IFS= read -r -d '' _f; do
  cat "$_f" >> "$_ddl_file" || { fail "DDL 语料读取失败: $_f"; break; }
  printf '\n' >> "$_ddl_file"
  _ddl_files=$((_ddl_files + 1))
done < <(find "$APP" \( -name .build -o -name .swiftpm -o -name DerivedData \) -prune -o \
         \( -name '*.swift' -o -name '*.sql' \) -print0 2>/dev/null)
created=$(tr -d '"' < "$_ddl_file" \
  | grep -ohE 'CREATE TABLE( IF NOT EXISTS)? [A-Za-z_]+' \
  | awk '{print $NF}' | sort -u || true)
refs=$(grep -ohE 'REFERENCES "?[A-Za-z_]+' "$_ddl_file" \
  | awk '{gsub(/"/,""); print $NF}' | sort -u || true)
# 语料完整性自证（ERR#27）：文件数为 0、或基线必有表读不到，说明这次扫的不是全量语料，
# 此时任何「引用完整性」结论都不成立——必须报「扫描不完整」，不得报内容判定。
_ddl_incomplete=0
if [ "$_ddl_files" -eq 0 ]; then
  _ddl_incomplete=1
else
  for _sentinel in patient_profile document_file; do
    printf '%s\n' "$created" | grep -qx "$_sentinel" || _ddl_incomplete=1
  done
fi
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
grep -qE 'SchemaV2|foreignKeysEnabled' "$_ddl_file" && fk_on=1
if [ "$_ddl_incomplete" -eq 1 ]; then
  fail "DDL 语料扫描不完整（读入 ${_ddl_files} 个文件，基线必有表缺失）—— 不得据此判定引用完整性"
elif [ "$ddl_missing" -eq 0 ] && [ "$fk_on" -eq 1 ]; then
  pass "REFERENCES 目标全部已定义；外键开启断言通过（语料 ${_ddl_files} 个文件）"
else
  [ "$ddl_missing" -gt 0 ] && fail "外键引用悬空 ${ddl_missing} 个目标表"
  [ "$fk_on" -eq 0 ] && fail "未找到外键开启语句（PRAGMA foreign_keys=ON / Configuration.foreignKeysEnabled）"
fi
# M0 必建表完整性（评审 S1-1）：dev-pm §3.1⑤ 指定的批次/药品表是 schema 基础设施，
# 缺表时引用完整性检查不报错但 M0 退出准则不达标——必须显式断言清单。
m0_tables="prescription medication medication_plan medication_dose_log stock_lot dose_lot_allocation"
m0_missing=0
for t in $m0_tables; do
  # 同样落文件 grep（ERR#34 同族：printf 管道遇 grep -q 早退会 SIGPIPE 假红）
  grep -qE "CREATE TABLE $t([[:space:]]|\\()" "$_ddl_file" || { m0_missing=$((m0_missing + 1)); printf '    M0 必建表缺失: %s\n' "$t"; }
done
[ "$m0_missing" -eq 0 ] && pass "M0 必建表清单齐备（prescription/medication/plan/dose_log/stock_lot/allocation）" || fail "M0 必建表缺失 ${m0_missing} 个（dev-pm §3.1⑤）"
rm -f "$_ddl_file"

# ---------- [4] 红线模块禁读 EntitlementStore ----------
section "4/10" "商业化红线 —— 红线模块代码内禁止读取 EntitlementStore（tech-spec §5.14）"
DEFAULT_REDLINE="$APP/App/M1a/OnboardingViews.swift:$APP/App/M1b/RemindersViews.swift:$APP/App/M1c/ObservationViews.swift:$APP/App/M1c/AssistantView.swift"
REDLINE_PATHS="${REDLINE_PATHS:-$DEFAULT_REDLINE}"
redline_matched=0; ent_viol=0
OLDIFS=$IFS; IFS=':'
for p in $REDLINE_PATHS; do
  [ -d "$p" ] || [ -f "$p" ] || continue   # 路径可为目录或具体文件（免费能力视图）
  redline_matched=$((redline_matched + 1))
  while IFS= read -r h; do
    [ -n "$h" ] || continue
    ent_viol=$((ent_viol + 1))
    [ "$ent_viol" -le 15 ] && printf '    %s\n' "$h"
  done < <(grep -rn -F 'EntitlementStore' --include='*.swift' --exclude-dir=.build --exclude-dir=.swiftpm --exclude-dir=DerivedData --exclude-dir=Build "$p" 2>/dev/null || true)
done
IFS=$OLDIFS
if [ "$redline_matched" -eq 0 ]; then
  # 评审修正：目录缺失 = 检查空转——空转的门禁与缺席同罪（ERR#27 同族），判红
  fail "REDLINE_PATHS 中没有任何已存在的目录——红线检查空转（路径与实际布局漂移？）"
else
  if [ "$ent_viol" -gt 0 ]; then
    fail "红线模块读取 EntitlementStore ${ent_viol} 处 —— 一票否决（验收红线）"
  else
    pass "红线模块（${redline_matched} 个目录）零 EntitlementStore 引用"
  fi
fi

# ---------- [5] Domain 零框架依赖 ----------
section "5/10" "分层纪律 —— Domain 零框架依赖，白名单断言 import ⊆ {Foundation}（tech-spec §1.1）"
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
section "6/10" "金样 Fixtures —— JSON 可解析（dev-pm-spec §9.2④）"
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
section "7/10" "Swift 解析门禁 —— App 层源码语法/保留字检查（ERR#28 shift-left）"
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

# ---------- [8] 阶段门禁套件存在性 ----------
section "8/10" "阶段门禁套件存在性 —— test-plan §3 必过套件必须真实存在（ERR#27 原则推广）"
# 根因族第三次复发的治本项：ERR#27=扫到 0 个对象判 PASS；ERR#30=job skipped 判 success；
# M1.5=套件从未创建、CI 无 job 绑定 → 无红可判 → 默认通过。三者同为「缺证据被当成有证据」。
# 本项把「某阶段必须存在哪些套件」变成可执行断言：清单里 required=yes 的套件
# 在测试源码/工作流中搜不到 token 即红。清单本身缺失也判红（不得因清单丢失而静默放行）。
SUITE_MANIFEST="${SUITE_MANIFEST:-$SCRIPT_DIR/gate-suites.tsv}"
if [ ! -f "$SUITE_MANIFEST" ]; then
  fail "套件清单缺失: $SUITE_MANIFEST —— 门禁清单本身不得缺席"
else
  s_req=0; s_missing=0
  # 测试源码搜索根：仅测试目标，避免把生产代码里的同名字符串当成套件存在的证据
  s_test_dirs=""
  for d in "$APP/Tests" "$APP/UITests" "$APP/CoreKit/Tests"; do
    [ -d "$d" ] && s_test_dirs="$s_test_dirs $d"
  done
  while IFS="$(printf '\t')" read -r m_stage m_suite m_req m_scope m_token; do
    case "$m_stage" in ''|'#'*|'stage') continue ;; esac
    [ "$m_req" = "yes" ] || continue
    [ -n "$m_token" ] || continue
    s_req=$((s_req + 1))
    case "$m_scope" in
      workflow)
        # shellcheck disable=SC2086
        if ! grep -rqF -- "$m_token" "$SCRIPT_DIR" 2>/dev/null; then
          s_missing=$((s_missing + 1))
          printf '    缺失套件: %s (%s) —— 未在 workflow 找到 token「%s」\n' \
            "$m_suite" "$m_stage" "$m_token"
        fi
        ;;
      *)
        # token 必须出现在**真实声明**里（@Suite 名 / 测试类名 / 测试方法名），
        # 而不是仅出现在注释中。理由：写完 [8] 几分钟内就自证了漏洞——
        # 给 SU-M2-STOCK 贴了一行 `// binds:` 注释，门禁即转绿，而该 SU 的
        # 一票否决用例（零确认存活）根本不存在。**贴标签不等于接线**，
        # 与 [9] 对确认入口的要求同一取向（标记存在还须真的调用模板）。
        s_hit=0
        if [ -n "$s_test_dirs" ]; then
          # shellcheck disable=SC2086
          if grep -rhF -- "$m_token" $s_test_dirs 2>/dev/null \
             | grep -qE '@Suite\(|final class|func test'; then
            s_hit=1
          fi
        fi
        if [ "$s_hit" -eq 0 ]; then
          s_missing=$((s_missing + 1))
          # shellcheck disable=SC2086
          if [ -n "$s_test_dirs" ] && grep -rqF -- "$m_token" $s_test_dirs 2>/dev/null; then
            printf '    仅有注释未接线: %s (%s) —— token「%s」只出现在注释里，\n' \
              "$m_suite" "$m_stage" "$m_token"
            printf '        须出现在 @Suite 名 / 测试类名 / 测试方法名中（贴标签≠接线）\n'
          else
            printf '    缺失套件: %s (%s) —— 未在 tests 找到 token「%s」\n' \
              "$m_suite" "$m_stage" "$m_token"
          fi
        fi
        ;;
    esac
  done < "$SUITE_MANIFEST"
  if [ "$s_req" -eq 0 ]; then
    fail "清单内 required=yes 的套件为 0 —— 空集不得判过（ERR#27）"
  elif [ "$s_missing" -gt 0 ]; then
    fail "必过套件缺失 ${s_missing}/${s_req} 个 —— 阶段门禁形同虚设，不得进入下一阶段"
  else
    pass "${s_req} 个必过套件全部存在（$SUITE_MANIFEST）"
  fi
fi

# ---------- [9] FR17.13 语音输入模板复用 ----------
section "9/10" "FR17.13 模板复用 —— 四处确认入口必须走同一模板，禁止自建确认逻辑（TC-M15-03）"
# function-spec FR17.13：语音指导每步(FR17.11)/语音速记(FR17.9)/语音提醒设定(FR17.10)/
# 观察语音速记(FR8.9) 一律调用标准模板，**禁止各功能自建独立确认逻辑**。
# 两条断言：
#   (a) 硬约束——OcrConfirmationSet 只允许在 Domain 的定义处与模板工厂里构造；
#       任何其它文件直接构造 = 自建确认逻辑，结构上即被挡死；
#   (b) 覆盖约束——四处入口各须一条 `// FR17.13-entry: <名>` 标记且同文件调用模板工厂；
#       少一处即红（入口没建 ≠ 门禁可以放行）。
t_bad=0
# 构造权只属 Domain（类型定义处 + 模板工厂）；其余层一律经工厂取得。
# 豁免沿用本脚本既有惯例（同 `// try?-ok:` / `// adr021-ok:`）：同行注释
# `// confirm-ok: <理由>`——用于 F6 OCR 提供者这类**非语音**确认集产出方。
t_hits=''
while IFS= read -r line; do
  [ -n "$line" ] || continue
  _f=${line%%:*}
  case "$_f" in "$APP/CoreKit/Sources/Domain/"*|./CoreKit/Sources/Domain/*) continue ;; esac
  case "$line" in *'confirm-ok:'*) continue ;; esac
  t_hits="$t_hits$line
"
done < <(grep -rn --include='*.swift' -E '(^|[^A-Za-z0-9_])OcrConfirmationSet\(' \
           "$APP/App" "$APP/CoreKit/Sources" 2>/dev/null || true)
if [ -n "$t_hits" ]; then
  t_bad=$((t_bad + 1))
  printf '    自建确认逻辑（Domain 外直接构造 OcrConfirmationSet，且无 // confirm-ok: 豁免）:\n'
  printf '%s' "$t_hits" | head -5 | sed 's/^/      /'
fi
t_entries_expected='语音速记 观察速记 提醒草稿 语音指导'
t_missing_entry=''
for t_e in $t_entries_expected; do
  t_files=$(grep -rl --include='*.swift' -F "FR17.13-entry: $t_e" "$APP/App" "$APP/CoreKit/Sources" 2>/dev/null || true)
  if [ -z "$t_files" ]; then
    t_missing_entry="$t_missing_entry $t_e"
    continue
  fi
  # 标记存在还不够——同文件必须真的调用模板工厂，杜绝「贴标签不接线」
  t_wired=0
  for t_f in $t_files; do
    if grep -qF 'VoiceInputTemplate.confirmationSet' "$t_f"; then t_wired=1; fi
  done
  [ "$t_wired" -eq 1 ] || t_missing_entry="$t_missing_entry ${t_e}(标记存在但未调用模板)"
done
if [ -n "$t_missing_entry" ]; then
  t_bad=$((t_bad + 1))
  printf '    未接入模板的确认入口:%s\n' "$t_missing_entry"
fi
if [ "$t_bad" -gt 0 ]; then
  fail "FR17.13 模板复用断言未通过（$t_bad 类问题）"
else
  pass "四处确认入口全部走 VoiceInputTemplate，模板外零构造"
fi

# ---------- [10] L10n 硬编码门禁（审查问题 E · 机制先于存量） ----------
section "10/10" "L10n 单出口 —— 视图层禁止新增中文字面量（三文件纪律；存量登记 .github/workflows/l10n-legacy-allowlist.txt）"
L10N_ALLOW="$SCRIPT_DIR/l10n-legacy-allowlist.txt"
[ -f "$L10N_ALLOW" ] || touch "$L10N_ALLOW"
# locale 必须「验证可用」而非「设了就算」：export 不校验合法性，无效 LC_ALL（如
# 某些发行版无 C.UTF-8）会让 grep 报 Invalid collation character（exit 2，被
# 2>/dev/null 吞掉）→ 扫描 0 行 → 空扫判 PASS（ERR#27 形态）。逐个候选实测，
# 全部失败即 fail 关闸，绝不放行未经扫描的门禁。
L10N_LOCALE=""
for _cand in C.UTF-8 C.utf8 en_US.UTF-8 en_US.utf8 zh_CN.UTF-8 zh_CN.utf8; do
  if LC_ALL="$_cand" grep -qE '[一-龥]' <<< '中文测试' 2>/dev/null; then
    L10N_LOCALE="$_cand"
    break
  fi
done
if [ -n "$L10N_LOCALE" ]; then
  export LC_ALL="$L10N_LOCALE"
else
  export LC_ALL=C
fi
l10n_bad=0
l10n_shown=0
l10n_scanned=0
while IFS= read -r line; do
  [ -n "$line" ] || continue
  l10n_scanned=$((l10n_scanned + 1))
  _rest=${line#*:}
  _rest=${_rest#*:}
  # 逐字面量判定，而非整行跳过。整行跳过（旧实现 case *systemImage*|*Image(*|//* ) continue）
  # 会让「与豁免调用同行」的用户文案整条蒙过门禁——`Label("记录观察", systemImage: "plus")`
  # 里的中文根本没被扫到，行尾补一句 `// 注释` 也能让整行消失（ERR#27：门禁在但不判）。
  # 因此改为先剥掉**确定非用户可见**的参数（注释、无障碍标识、图标名、日志、颜色资源名），
  # 再对剩余部分取字面量。注意 accessibilityLabel 是 VoiceOver 可见文案，绝不在剥离之列。
  _scan=$(printf '%s' "$_rest" | sed -E \
    -e 's#//.*$##' \
    -e 's/accessibilityIdentifier\([[:space:]]*"[^"]*"[[:space:]]*\)//g' \
    -e 's/systemImage:[[:space:]]*"[^"]*"//g' \
    -e 's/Image\([[:space:]]*"[^"]*"//g' \
    -e 's/Color\([[:space:]]*"[^"]*"//g' \
    -e 's/logger\.[a-zA-Z]+\("[^"]*"\)//g')
  _ok=1
  while IFS= read -r lit; do
    [ -n "$lit" ] || continue
    _v=${lit#\"}; _v=${_v%\"}
    # -x 整行精确匹配：子串匹配会让「提醒」被既有条目「您有一条健康提醒」放行，
    # 新增硬编码就能靠碰巧是某条存量的子串蒙过门禁（ERR#27 同族：门禁在但不判）
    grep -qxF "$_v" "$L10N_ALLOW" || _ok=0
  done <<< "$(printf '%s' "$_scan" | grep -oE '\"[^\"]*[一-龥][^\"]*\"' || true)"
  if [ "$_ok" -ne 1 ]; then
    l10n_bad=$((l10n_bad + 1))
    if [ "$l10n_shown" -lt 12 ]; then
      printf '    %s\n' "$line"
      l10n_shown=$((l10n_shown + 1))
    fi
  fi
done < <(grep -rn --include='*.swift' -E '\"[^\"]*[一-龥][^\"]*\"' "$APP/App" 2>/dev/null | grep -v '/L10n.swift:' || true)
if [ -z "$L10N_LOCALE" ]; then
  fail "本机无可验证的 UTF-8 locale —— L10n 扫描未执行，不得空扫判 PASS（ERR#27）"
elif [ "$l10n_scanned" -eq 0 ]; then
  fail "L10n 扫描命中 0 行 —— locale/正则失效或扫描范围为空，不得空扫判 PASS（ERR#27）"
elif [ "$l10n_bad" -gt 0 ]; then
  fail "视图层未登记中文字面量 $l10n_bad 处 —— 迁入 L10n.swift（三文件），或登记 $L10N_ALLOW"
else
  pass "视图层无未登记中文字面量（存量豁免清单 $L10N_ALLOW；扫描 $l10n_scanned 行）"
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
