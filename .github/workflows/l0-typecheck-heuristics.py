#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# ============================================================================
# L0 [15] 类型层启发式门禁 —— l0-typecheck-heuristics.py
# 背景：App/（SwiftUI）无法在 Linux 上编译，swiftc -parse 只查语法不查语义，
# 以下八族类型错误只有 macOS L1 编译门禁才能暴露（每族均有 CI 实证），
# 本脚本用静态启发式在 L0 左移拦截：
#   A. 跨层引用缺 import —— CI d0c1008：RootAdaptiveView 引用 Infrastructure
#      符号但未 import Infrastructure（parse 不解析符号，本地一直绿）
#   B. Date 与 Double/TimeInterval 混比较 —— CI 34032245120（8bc49b8）：
#      doc.createdAt(Date) > Date().timeIntervalSince1970 - 3*86400(Double)
#   C. iOS 专用 Apple 符号未套 #if os(iOS) —— CI 34018308312（f995ba3）：
#      AVAudioSession 在 macOS 上 canImport(AVFAudio) 为真即被编译、报
#      'unavailable in macOS'
#   D. #if os(Linux) 内声明的桩类型在非守卫区使用 —— CI 34018552283（b8384b1，
#      10 处）：macOS 上桩类型不存在、报 cannot find in scope
#   E. `any X?` 可选 any 拼写（须写作 `(any X)?`）—— CI ad1d767 实证：
#      swiftc -parse 静默放行（第五轮本地实测 6.3.1）、仅 macOS L1 类型检查
#      报 'optional any type must be written (any P)?'
#   F. nil 字面量传非可选 String 参数/成员 —— CI 34289498685 实证：
#      GlobalSearchView.swift:179 `snippet: nil`（SearchResultRow 成员
#      `let snippet: String`），parse 静默放行、仅 macOS L1 报
#      "'nil' is not compatible with expected argument type 'String'"。
#      判定：同文件 private/fileprivate struct 体（调用点必在同文件，跨文件
#      可选签名假红不可能）内声明非可选 `let/var x: String` 且调用点实参
#      `x: nil`；同名可选声明/参数存在则整名豁免（保守零误报）；字典字面量
#      `[x: nil]`（最近未闭合括号为 [）为合法值跳过。
#   G. 单语句 ≥6 段高阶链式调用 —— CI 34653854625 实证：
#      OCRCardStore.refreshDocumentProjection 的 flatMap→filter→filter→
#      map→compactMap→joined→joined 单链在 macOS Swift 6 类型检查预算
#      超时（"unable to type-check this expression in reasonable time"；
#      Linux 6.3.1 类型检查通过——该表达式正处预算边界）。判定：语句级
#      链段计数（跨行续链：行尾 `.`/开括号/&&/|| 续、行首 `.` 接），
#      ≥6 段即 FAIL；全仓当前零命中（阈值 ≥5 亦零）——修复即拆子表达式。
#   H. 文件级非隔离自由函数调用 @MainActor 类型成员 —— CI 34673049166 实证：
#      EncounterViews.swift 文件级 private func 调用 @MainActor DocumentsState
#      的静态 fieldValueDisplay，macOS 编译报 'call to main actor-isolated
#      static method in a synchronous nonisolated context'，parse 静默放行。
#      判定：@MainActor 类型名单 × 文件级 func（自身无 @MainActor）× 体内
#      `Name.member(` 调用；nonisolated 声明成员与 @MainActor in /
#      MainActor.assumeIsolated 逃逸口豁免。
# 判定与平台无关（python3 标准库）；ERR#27 纪律：扫 0 文件/无计数一律 FAIL。
# 豁免标记（与 try?-ok/adr021-ok 同惯例，仅同行注释）：`// tius-ok: <理由>`
# ——第五轮全仓审查修复：本标记此前只在文档声明、判定器从未读取（假豁免），
#   现各族判定点统一读取（exempted()）。
# ============================================================================
import re
import sys
from pathlib import Path

IOS_ONLY_SYMBOLS = ("AVAudioSession", "UIApplication", "UIScreen", "UIDevice")
# 家族 A 的过泛词排除（避免与 SwiftUI/通用名碰撞产生假红；当前零命中验证过）
EXCLUDE_A = {"Store", "View", "Row"}
SCAN_A_DIRS = ("App", "Tests", "UITests")
SCAN_CD_DIRS = ("CoreKit/Sources", "CoreKit/Tests")

DATEISH = r"\b[a-z_]\w*(?:Date|At)\b"
NUMEXPR = r"[0-9][0-9_.]*(?:\s*[*+-]\s*[0-9_.]+)*"
PATTERNS_B = {
    "Date() 与数字字面量直接比较": re.compile(r"\bDate\s*\(\)\s*[<>]=?\s*[0-9]"),
    "Date.now 与数字字面量直接比较": re.compile(r"\bDate\.now\s*[<>]=?\s*[0-9]"),
    "日期命名属性与数字表达式比较": re.compile(
        DATEISH + r"\s*[<>]=?\s*" + NUMEXPR + r"(?!\s*\(|\.\s*\w+\s*\()"),
    "数字表达式与日期命名属性比较(反向)": re.compile(
        NUMEXPR + r"\s*[<>]=?\s*" + DATEISH + r"(?!\s*\()"),
    "日期命名属性与秒值运算比较(tius族)": re.compile(
        DATEISH + r"\s*[<>]=?\s*Date\(\)\.timeIntervalSince1970\s*[-+*]"),
    "Date() 与数字直接加减": re.compile(r"\bDate\s*\(\)\s*[+-]\s*[0-9]"),
}
DECL_RE = re.compile(r"\b(?:struct|class|enum|actor|typealias|func)\s+([A-Za-z_]\w*)")
SYMBOL_RE = re.compile(
    r"^public (?:actor|struct|final class|class|enum|protocol|typealias)\s+([A-Za-z_]\w*)",
    re.M,
)
IMPORT_RE = re.compile(r"^(?:@testable )?import\s+(\w+)")
# 家族 E：`any X?`（可选 any 拼写）。`(any X)?` 的 any 前为左括号，lookbehind
# 排除；该拼写在任何 Swift 版本下都不合法（5.7+ 必须加括号），零假红。
PATTERN_E = re.compile(r"(?<![\w(])\bany\s+[A-Za-z_]\w*\s*\?")
# 家族 F：非可选 String 成员声明 / 同名可选声明（整名豁免）/ 调用点 nil 实参
NONOPT_STR = re.compile(r"\b(?:let|var)\s+(\w+)\s*:\s*String\b")
OPT_NAME = re.compile(r"\b(?:let|var)\s+(\w+)\s*:\s*[A-Za-z_]\w*\s*[?!]")
OPT_PARAM = re.compile(r"(\w+)\s*:\s*[A-Za-z_]\w*\s*[?!]\s*(?:=|,|\))")
ARG_NIL = re.compile(r"(\w+)\s*:\s*nil\b")


def exempted(raw_lines, lineno):
    """同行 `// tius-ok:` 豁免判定（与 try?-ok/adr021-ok 同惯例）。"""
    return "tius-ok" in raw_lines[lineno - 1]


def code_lines(text):
    """返回 [(1-based 行号, 剥离注释与字符串后的代码)], 跨行处理三引号字符串。"""
    out = []
    in_ml = False
    for lineno, raw in enumerate(text.splitlines(), 1):
        code = []
        i = 0
        n = len(raw)
        while i < n:
            if in_ml:
                if raw.startswith('"""', i):
                    in_ml = False
                    i += 3
                else:
                    i += 1
                continue
            if raw.startswith('"""', i):
                in_ml = True
                i += 3
                continue
            c = raw[i]
            if c == '"':
                i += 1
                while i < n:
                    if raw[i] == "\\":
                        i += 2
                    elif raw[i] == '"':
                        i += 1
                        break
                    else:
                        i += 1
                code.append(" ")
                continue
            if c == "/" and i + 1 < n and raw[i + 1] == "/":
                break
            code.append(c)
            i += 1
        out.append((lineno, "".join(code)))
    return out


def guard_stack(raw_lines):
    """按行推进 #if/#elseif/#else/#endif 栈，返回每个行号生效的守卫表达式栈。
    栈元素为当前块生效的表达式；#else 后表达式取反（按「非 iOS 专用」处理）。"""
    stack = []  # list of str (expr)
    else_flag = []  # 对应块是否处于 #else 分支
    mapping = {}
    for lineno, line in enumerate(raw_lines, 1):
        s = line.strip()
        if s.startswith("#if "):
            stack.append(s[4:].strip())
            else_flag.append(False)
        elif s.startswith("#elseif "):
            if stack:
                stack[-1] = s[8:].strip()
                else_flag[-1] = False
        elif s.startswith("#else"):
            # 第六轮全仓审查修复：用 startswith 而非全等比较——`#else // 注释`
            # 会失配导致栈永不弹出，后续行的守卫判定全部错位（D 族误放行/
            # C 族误报）
            if else_flag:
                else_flag[-1] = True
        elif s.startswith("#endif"):
            if stack:
                stack.pop()
                else_flag.pop()
        mapping[lineno] = list(stack), list(else_flag)
    return mapping


def ios_only_guard_ok(expr, in_else):
    """#if os(iOS)（可并 os(visionOS)）且不在 #else 分支 = macOS 上不编译该块。"""
    if in_else:
        return False
    if "canImport" in expr:
        return False
    tokens = re.findall(r"os\(\w+\)", expr)
    if not tokens:
        return False
    # 第七轮全仓审查修复：否定守卫 `#if !os(iOS)` 在 macOS 上**会被编译**——
    # 原判定只认 token 集合（findall 丢掉了 !），把否定守卫误判为 iOS 独占，
    # AVAudioSession/UIScreen 等引用在 macOS 编译失败却通过门禁
    return all(t in ("os(iOS)", "os(visionOS)") and not is_negated(expr, t)
               for t in tokens)


def is_negated(expr, token):
    """token 是否被紧跟其前的 `!` 否定（`#if !os(iOS)` / `!canImport(...)`）。"""
    idx = expr.find(token)
    return idx > 0 and expr[idx - 1] == "!"


def main():
    root = Path(sys.argv[1])
    fails = []
    scanned = {}

    # ---- 家族 A：跨层引用缺 import（App/Tests/UITests × Domain/Protocols/Infrastructure）
    mod_syms = {}
    for mod in ("Domain", "Protocols", "Infrastructure"):
        mod_dir = root / "CoreKit/Sources" / mod
        txt = "\n".join(
            p.read_text(encoding="utf-8")
            for p in sorted(mod_dir.rglob("*.swift")) if p.is_file()
        )
        mod_syms[mod] = set(SYMBOL_RE.findall(txt)) - EXCLUDE_A
    a_files = []
    for d in SCAN_A_DIRS:
        p = root / d
        if p.exists():
            a_files.extend(sorted(p.rglob("*.swift")))
    scanned["A"] = len(a_files)
    for f in a_files:
        try:
            txt = f.read_text(encoding="utf-8")
        except Exception:
            continue
        imports = set()
        raw_lines = txt.splitlines()
        for raw in raw_lines:
            m = IMPORT_RE.match(raw.strip())
            if m:
                imports.add(m.group(1))
        for mod, syms in mod_syms.items():
            if mod in imports:
                continue
            for lineno, code in code_lines(txt):
                if exempted(raw_lines, lineno):
                    continue
                for s in sorted(syms):
                    if re.search(r"\b" + re.escape(s) + r"\b", code):
                        fails.append(
                            f"{f.relative_to(root)}:{lineno}: 引用 {s}（CoreKit.{mod}）"
                            f"但未 import {mod} —— Linux parse 不查符号，仅 macOS 编译暴露"
                        )
                        break

    # ---- 家族 A（CoreKit 内部变体）：Infrastructure 引用 Domain/Protocols
    # 符号缺 import —— CI 34295670215 实证：PendingCardStore 整体被
    # #if os(iOS)||os(macOS) 守卫、Linux 上文件空编译，缺 import Domain
    # 本地 swift build/test 与 swiftc -parse 均不可见，仅 macOS swift test
    # 暴露（'cannot find type in scope'）。文本扫描与平台守卫无关，可左移。
    infra_dir = root / "CoreKit/Sources/Infrastructure"
    infra_files = sorted(infra_dir.rglob("*.swift")) if infra_dir.exists() else []
    scanned["A2"] = len(infra_files)
    for f in infra_files:
        try:
            txt = f.read_text(encoding="utf-8")
        except Exception:
            continue
        imports = set()
        raw_lines = txt.splitlines()
        for raw in raw_lines:
            m = IMPORT_RE.match(raw.strip())
            if m:
                imports.add(m.group(1))
        for mod in ("Domain", "Protocols"):
            if mod in imports:
                continue
            for lineno, code in code_lines(txt):
                if exempted(raw_lines, lineno):
                    continue
                for s in sorted(mod_syms[mod]):
                    if re.search(r"\b" + re.escape(s) + r"\b", code):
                        fails.append(
                            f"{f.relative_to(root)}:{lineno}: 引用 {s}（CoreKit.{mod}）"
                            f"但未 import {mod}——平台守卫文件在 Linux 空编译，"
                            f"仅 macOS 编译暴露（CI 34295670215 同族）"
                        )
                        break

    # ---- 家族 H：文件级非隔离自由函数调用 @MainActor 类型的成员 ----
    # CI 34673049166 实证：EncounterViews.swift 文件级 private func
    # encounterKindDisplayName（非隔离）调用 @MainActor DocumentsState 的
    # 静态 fieldValueDisplay → macOS 编译错误 'call to main actor-isolated
    # static method in a synchronous nonisolated context'；Linux parse 静默
    # 放行。判定：@MainActor 类型名单（App/）× 文件级 func（列 0 起、自身
    # 无 @MainActor）× 体内 `Name.member(` 调用；声明为 nonisolated 的成员
    # （含 10a23fa 六助手）天然豁免；体内出现 @MainActor in /
    # MainActor.assumeIsolated 的整函数豁免（MainActor 逃逸口）。
    MA_TYPE_RE = re.compile(r"^\s*(?:final\s+)?(?:class|enum|actor|protocol)\s+([A-Za-z_]\w*)")
    MA_SAMELINE_RE = re.compile(r"@MainActor\s+(?:final\s+)?(?:class|enum|actor|protocol)\s+([A-Za-z_]\w*)")
    NONISO_MEMBER_RE = re.compile(r"nonisolated\s+(?:static\s+)?func\s+(\w+)")
    FILEFUNC_RE = re.compile(r"^(?:private\s+)?func\s+([A-Za-z_]\w*)")
    mainactor_names = set()
    nonisolated_safe = set()   # (TypeName, member) —— 声明为 nonisolated 的成员
    h_files = []
    for d in ("App",):
        p = root / d
        if p.exists():
            h_files.extend(sorted(p.rglob("*.swift")))
    scanned["H"] = len(h_files)
    for f in h_files:
        try:
            raw_lines = f.read_text(encoding="utf-8").splitlines()
        except Exception:
            continue
        for i, line in enumerate(raw_lines):
            m = MA_SAMELINE_RE.search(line) or MA_TYPE_RE.match(line)
            if not m:
                continue
            window = "\n".join(raw_lines[max(0, i - 4):i + 1])
            if "@MainActor" not in window:
                continue
            name = m.group(1)
            mainactor_names.add(name)
            # 类型体范围内收集 nonisolated 成员（跨文件调用点据此豁免）
            depth = 0
            for j in range(i, len(raw_lines)):
                depth += raw_lines[j].count("{") - raw_lines[j].count("}")
                nm = NONISO_MEMBER_RE.search(raw_lines[j])
                if nm:
                    nonisolated_safe.add((name, nm.group(1)))
                if depth <= 0 and j > i:
                    break
    for f in a_files:
        try:
            raw_lines = f.read_text(encoding="utf-8").splitlines()
        except Exception:
            continue
        for i, line in enumerate(raw_lines):
            m = FILEFUNC_RE.match(line)
            if not m:
                continue
            if "@MainActor" in "\n".join(raw_lines[max(0, i - 3):i]):
                continue
            depth = 0
            body = []
            for j in range(i, len(raw_lines)):
                depth += raw_lines[j].count("{") - raw_lines[j].count("}")
                body.append(raw_lines[j])
                if depth <= 0 and j > i:
                    break
            if any("@MainActor in" in b or "MainActor.assumeIsolated" in b for b in body):
                continue
            for k, code in enumerate(body):
                if exempted(raw_lines, i + k):
                    continue
                for tname in sorted(mainactor_names):
                    for mm in re.finditer(r"\b" + re.escape(tname) + r"\.(\w+)\s*\(", code):
                        if (tname, mm.group(1)) in nonisolated_safe:
                            continue
                        fails.append(
                            f"{f.relative_to(root)}:{i + k + 1}: 文件级非隔离函数调用"
                            f" @MainActor {tname}.{mm.group(1)}——macOS 编译报"
                            f" 'call to main actor-isolated method in a synchronous"
                            f" nonisolated context'（CI 34673049166 同族，Linux parse"
                            f" 静默放行）——成员标 nonisolated（纯函数）或函数标"
                            f" @MainActor，或加 // tius-ok: 豁免"
                        )
                        break
                    else:
                        continue
                    break

    # ---- 家族 B：Date 与 Double/TimeInterval 混比较（App/Tests/UITests）
    b_files = list(a_files)
    scanned["B"] = len(b_files)
    for f in b_files:
        try:
            txt = f.read_text(encoding="utf-8")
        except Exception:
            continue
        raw_lines = txt.splitlines()
        for lineno, code in code_lines(txt):
            if not code.strip():
                continue
            if exempted(raw_lines, lineno):
                continue
            for name, pat in PATTERNS_B.items():
                if pat.search(code):
                    fails.append(
                        f"{f.relative_to(root)}:{lineno}: [{name}] 疑似 Date 与秒值/数字混比较"
                        f"（CI 34032245120 同族，仅 macOS 编译可查）——"
                        f"两端同为 Date（addingTimeInterval/DayArithmetic）或加 // tius-ok: 豁免"
                    )

    # ---- 家族 C：iOS 专用 Apple 符号未套 #if os(iOS)（CoreKit）
    c_files = []
    for d in SCAN_CD_DIRS:
        p = root / d
        if p.exists():
            c_files.extend(sorted(p.rglob("*.swift")))
    scanned["C"] = len(c_files)
    for f in c_files:
        try:
            txt = f.read_text(encoding="utf-8")
        except Exception:
            continue
        raw_lines = txt.splitlines()
        stack_map = guard_stack(raw_lines)
        for lineno, code in code_lines(txt):
            if lineno not in stack_map:
                continue
            if exempted(raw_lines, lineno):
                continue
            stack, else_flags = stack_map[lineno]
            for sym in IOS_ONLY_SYMBOLS:
                if re.search(r"\b" + sym + r"\b", code):
                    ok = False
                    if stack:
                        ok = ios_only_guard_ok(stack[-1], else_flags[-1])
                    if not ok:
                        fails.append(
                            f"{f.relative_to(root)}:{lineno}: {sym} 未套 #if os(iOS) 守卫"
                            f"（CI 34018308312 同族：macOS 编译报 'unavailable in macOS'）"
                        )

    # ---- 家族 D：#if os(Linux) 内声明的桩类型在非守卫区使用（CoreKit）
    scanned["D"] = len(c_files)
    for f in c_files:
        try:
            txt = f.read_text(encoding="utf-8")
        except Exception:
            continue
        raw_lines = txt.splitlines()
        stack_map = guard_stack(raw_lines)
        linux_names = {}
        for lineno, code in code_lines(txt):
            if exempted(raw_lines, lineno):
                continue
            stack, else_flags = stack_map.get(lineno, ([], []))
            # 第六轮全仓审查修复：Linux 独占 = 任一祖先守卫为 os(Linux) 且非
            # #else 分支（嵌套 #if canImport 等子守卫不改变外层平台排除）——
            # 原 all() 语义要求全栈均为 os(Linux)，嵌套子守卫（canImport 等）
            # 使 linux_only 恒假，Linux 专属文件内合法引用被误报
            # 第七轮修复：否定守卫 `#if !os(Linux)` 在 macOS 上会被编译——
            # 裸子串匹配把否定守卫误判为 Linux 独占（LocalAuthGateUnlocker 全文件
            # 即此形态），其声明被记为 Linux 桩、macOS 区域引用被误杀/漏杀
            linux_only = any(
                (re.search(r"os\(\s*[Ll]inux\s*\)", e) is not None
                 and not is_negated(e, re.search(r"os\(\s*[Ll]inux\s*\)", e).group(0)))
                and not fl
                for e, fl in zip(stack, else_flags)
            )
            if linux_only:
                m = DECL_RE.search(code)
                if m:
                    linux_names[m.group(1)] = lineno
            elif not linux_only:
                # 任何在 macOS 上会被编译的区域（无条件 / #if os(macOS) /
                # #else 分支）引用 Linux 桩名 = macOS 编译 cannot find in scope。
                # 第六轮全仓审查修复：原判定为 `not stack`（仅顶层），
                # #if os(macOS) 守卫区内的引用漏检（栈非空即放行）
                for name, decl_ln in list(linux_names.items()):
                    if re.search(r"\b" + re.escape(name) + r"\b", code):
                        fails.append(
                            f"{f.relative_to(root)}:{lineno}: 类型 {name}"
                            f"（声明于 {decl_ln} 行 #if os(Linux) 内）在非守卫区使用"
                            f"——macOS 编译 cannot find in scope（CI 34018552283 同族）"
                        )

    # ---- 家族 E：`any X?` 可选 any 拼写（App/Tests/UITests + CoreKit）——
    # CI ad1d767 实证 + 第五轮本地实测（swiftc 6.3.1 -parse 静默、-typecheck 报
    # 'optional any type must be written (any P)?'）。必须写作 `(any X)?`。
    e_files = list(a_files) + list(c_files)
    scanned["E"] = len(e_files)
    for f in e_files:
        try:
            txt = f.read_text(encoding="utf-8")
        except Exception:
            continue
        raw_lines = txt.splitlines()
        for lineno, code in code_lines(txt):
            if not code.strip():
                continue
            if exempted(raw_lines, lineno):
                continue
            if PATTERN_E.search(code):
                fails.append(
                    f"{f.relative_to(root)}:{lineno}: `any X?` 拼写非法——"
                    f"可选 any 必须写作 `(any X)?`（CI ad1d767 同族：swiftc -parse "
                    f"静默放行，仅 macOS L1 类型检查报 'optional any type must be "
                    f"written (any P)?'）"
                )

    # ---- 家族 F：nil 字面量传非可选 String 参数/成员（App/Tests/UITests）
    # 判定：同文件 private/fileprivate struct 体内的非可选 `let/var x: String`
    # 成员名集合；调用点实参 `x: nil` 命中即 FAIL（私有结构体调用点必在同
    # 文件，不存在跨文件可选签名假红）。同名可选声明/参数整名豁免；字典字面
    # 量 `[x: nil]`（最近未闭合括号为 [）跳过。
    f_files = list(a_files)
    scanned["F"] = len(f_files)
    priv_struct = re.compile(r"^\s*(?:private|fileprivate)\s+struct\s+")
    for f in f_files:
        try:
            txt = f.read_text(encoding="utf-8")
        except Exception:
            continue
        raw_lines = txt.splitlines()
        cl = code_lines(txt)
        opt = set()
        for _, code in cl:
            for m in OPT_NAME.finditer(code):
                opt.add(m.group(1))
            for m in OPT_PARAM.finditer(code):
                opt.add(m.group(1))
        nonopt = set()
        i = 0
        while i < len(cl):
            lineno, code = cl[i]
            if not priv_struct.match(code.strip()):
                i += 1
                continue
            depth = 0
            j = i
            while j < len(cl):
                depth += cl[j][1].count("{") - cl[j][1].count("}")
                j += 1
                if depth <= 0:
                    break
            for ln, body_code in cl[i + 1 : j - 1]:
                for m in NONOPT_STR.finditer(body_code):
                    nonopt.add(m.group(1))
            i = j
        if not nonopt:
            continue
        for lineno, code in cl:
            if not code.strip():
                continue
            if exempted(raw_lines, lineno):
                continue
            for m in ARG_NIL.finditer(code):
                name = m.group(1)
                if name in opt or name not in nonopt:
                    continue
                # 字典字面量 [x: nil] 合法——最近未闭合括号为 [ 则跳过
                stack = []
                for ch in code[: m.start()]:
                    if ch == "(":
                        stack.append("(")
                    elif ch == "[":
                        stack.append("[")
                    elif ch in ")]":
                        if stack:
                            stack.pop()
                if stack and stack[-1] == "[":
                    continue
                fails.append(
                    f"{f.relative_to(root)}:{lineno}: 实参 `{name}: nil` 与同文件 private/"
                    f"fileprivate struct 的非可选 `String` 成员冲突——（CI 34289498685 "
                    f"同族：仅 macOS L1 报 'nil' is not compatible with expected "
                    f"argument type 'String'）——传 \"\" 或改声明为可选，"
                    f"或加 // tius-ok: 豁免"
                )

    # ---- 家族 G：单语句 ≥6 段高阶链式调用（App/Tests/UITests + CoreKit）
    # CI 34653854625 实证：七段 flatMap→filter→filter→map→compactMap→
    # joined→joined 单链在 macOS Swift 6 类型检查超时（Linux 6.3.1 通过——
    # 预算边界）。语句级计数 + 跨行续链；阈值 ≥6 当前全仓零命中（≥5 亦零）。
    g_files = list(a_files) + list(c_files)
    scanned["G"] = len(g_files)
    chain_seg = re.compile(r"\.(map|filter|flatMap|compactMap|reduce|joined|sorted|prefix|suffix|allSatisfy|contains)\s*[\{\(]")
    # G-2：可选链直接接 typed-seed reduce——CI 34652541174 实证：
    # ASRModelAssets.byteCount 的 `?.files.reduce(Int64(0)) { $0 + $1.bytes }`
    # 仅 3 段即在 macOS 类型检查预算超时（可选链 + 泛型 reduce + 类型化
    # 种子的组合超出推理预算），≥6 段链长判定罩不住此类——独立窄模式，
    # 当前全仓零命中（修复即拆子表达式/let 承接）。
    chain_reduce = re.compile(r"\?\.[a-zA-Z_]*\s*\.reduce\([A-Za-z0-9_.]+\)\s*\{")
    for f in g_files:
        try:
            raw_lines = f.read_text(encoding="utf-8").splitlines()
        except Exception:
            continue
        chain = 0
        for idx, raw in enumerate(raw_lines):
            lineno = idx + 1
            stripped = raw.strip()
            if not stripped or stripped.startswith("//"):
                continue
            if chain_reduce.search(raw) and not exempted(raw_lines, lineno):
                fails.append(
                    f"{f.relative_to(root)}:{lineno}: 可选链直接接 typed-seed reduce"
                    f"超出 macOS Swift 6 类型检查预算（CI 34652541174 同族："
                    f"'unable to type-check this expression in reasonable time'）——"
                    f"拆子表达式（let 承接），或加 // tius-ok: 豁免"
                )
            n = len(chain_seg.findall(raw))
            if chain > 0 and stripped.startswith("."):
                chain += n
            else:
                chain = n
            if chain >= 6:
                if not exempted(raw_lines, lineno):
                    fails.append(
                        f"{f.relative_to(root)}:{lineno}: 单语句 {chain} 段高阶链式调用"
                        f"超出 macOS Swift 6 类型检查预算（CI 34653854625 同族："
                        f"'unable to type-check this expression in reasonable time'；"
                        f"Linux 类型检查可过——正处预算边界）——拆子表达式（let 承接），"
                        f"或加 // tius-ok: 豁免"
                    )
                chain = 0
            if not (stripped.endswith(".") or stripped.endswith(("(", "[", "{", "&&", "||"))):
                chain = 0

    print(f"__SCANNED__ A={scanned.get('A',0)} A2={scanned.get('A2',0)} "
          f"B={scanned.get('B',0)} C={scanned.get('C',0)} D={scanned.get('D',0)} "
          f"E={scanned.get('E',0)} F={scanned.get('F',0)} G={scanned.get('G',0)} "
          f"H={scanned.get('H',0)}")
    seen = set()
    for msg in fails:
        if msg in seen:
            continue
        seen.add(msg)
        print("FAIL:", msg)
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
