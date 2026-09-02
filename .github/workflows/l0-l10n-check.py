#!/usr/bin/env python3
# ============================================================================
# L0 [10/10] L10n 单出口门禁的判定器（独立文件，供 l0-static-gate.sh 调用）
#
# 为什么独立成文件（评审修正）：初版把判定逻辑内嵌为 bash `$(...)` 里的
# heredoc——bash 对「命令替换内嵌 heredoc」的解析在 3.2（macOS 自带）与 5.x
# 间行为不一致，实测报 "unterminated here-document" warning，且剥离正则未
# 生效。独立文件 = 可单测、无嵌套解析坑、与门禁脚本解耦。
#
# 为什么不用 grep 判定「是否中文」（ERR#5WHY）：`grep [一-龥]` 多字节字符区间
# 的解释随 grep/glibc/locale 漂移——CI 容器（jammy grep 3.7 + setlocale 失败
# 回退）与开发机对同一字节流给出不同判定，假红假绿双向发生。本判定器按
# Unicode 码点 U+4E00..U+9FA5（与原 `[一-龥]` 语义一致）显式匹配，与平台无关。
#
# 剥离语义与旧 sed 链逐条等价（注释/无障碍标识/图标名/日志/颜色资源名）；
# accessibilityLabel 是 VoiceOver 可见文案，绝不在剥离之列。
#
# 用法：l0-l10n-check.py <allowlist 路径> <扫描根目录>
# 输出：违规行逐条打印到 stdout（`path:line: 原文`），末尾一行 `__SCANNED__ N`
#       （N = 提取出含中文字面量的行数，供调用方做空扫保护）。
# 退出码恒为 0（判定结果经输出传递）—— 调用方负责 fail/pass 语义。
# ============================================================================
import os
import re
import sys

allow_path, scan_root = sys.argv[1], sys.argv[2]

with open(allow_path, encoding="utf-8") as f:
    allowed = set(line.rstrip("\n") for line in f)

# 汉字块：与原门禁 `[一-龥]` 一致（U+4E00..U+9FA5）
cjk = re.compile(r"[一-龥]")

# 与旧 sed -E 链等价的剥离（逐条对应）：
#   s#//.*$##
#   s/accessibilityIdentifier\([[:space:]]*"[^"]*"[[:space:]]*\)//g
#   s/systemImage:[[:space:]]*"[^"]*"//g
#   s/Image\([[:space:]]*"[^"]*"//g
#   s/Color\([[:space:]]*"[^"]*"//g
#   s/logger\.[a-zA-Z]+\("[^"]*"\)//g
strip_patterns = [
    re.compile(r"//.*$"),
    re.compile(r'accessibilityIdentifier\(\s*"[^"]*"\s*\)'),
    re.compile(r'systemImage:\s*"[^"]*"'),
    re.compile(r'Image\(\s*"[^"]*"'),
    re.compile(r'Color\(\s*"[^"]*"'),
    # 注意必须 `(` 后**立即** `"`（与 sed 同构）：宽松版 `\([^"]*"\)` 会把
    # 内层 `\(error` 之类当起点，剥不到整段 logger 调用
    re.compile(r'logger\.[a-zA-Z]+\(\"[^"]*\"\)'),
]
lit_re = re.compile(r'"[^"]*"')

violations = []
scanned = 0
for dirpath, dirnames, filenames in os.walk(scan_root):
    dirnames.sort()
    for name in sorted(filenames):
        if not name.endswith(".swift") or name == "L10n.swift":
            continue
        path = os.path.join(dirpath, name)
        rel = os.path.relpath(path)
        if not rel.startswith("."):
            rel = "./" + rel
        try:
            with open(path, encoding="utf-8", errors="replace") as f:
                lines = f.readlines()
        except OSError:
            continue
        for lineno, raw in enumerate(lines, 1):
            s = raw.rstrip("\n")
            for pat in strip_patterns:
                s = pat.sub("", s)
            literals = [m for m in lit_re.findall(s) if cjk.search(m)]
            if not literals:
                continue
            scanned += 1
            # 行内任一含汉字字面量不在豁免清单 → 整行违规
            # （精确整串匹配：子串命中会让新增硬编码靠碰巧是存量子串蒙过门禁）
            if not all(lit[1:-1] in allowed for lit in literals):
                violations.append("%s:%d: %s" % (rel, lineno, raw.rstrip("\n")))

for v in violations:
    print(v)
print("__SCANNED__", scanned)
