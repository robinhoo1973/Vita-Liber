#!/usr/bin/env python3
"""扫描 SwiftUI 容器 .accessibilityIdentifier 掩蔽子元素标识的错误族。

规则（CI 34021989599 实证，见 OnboardingFlowView.swift 注释）：
容器上的 .accessibilityIdentifier 若不配 .accessibilityElement(children: .contain)，
SwiftUI 会把容器标识下放覆盖到每个子元素自身的标识，XCUITest 按子元素标识查询失败。

判定：修饰链的归属语句是容器创建（VStack/HStack/... + `{`），
且其花括号范围内存在更深的 .accessibilityIdentifier（子树里有带标识的控件），
且链中无 .accessibilityElement(children: .contain / .combine) → 掩蔽风险。

用法：python3 refactor/scan-container-id-mask.py [--ci]  （--ci：有候选即退出码 1，供门禁复用）
"""
import re
import sys
from pathlib import Path

APP = Path(__file__).resolve().parent.parent / "App"

CONTAINER_TYPES = (
    "VStack", "HStack", "ZStack", "Group", "ScrollView", "List", "Form",
    "LazyVStack", "LazyHStack", "LazyVGrid", "Grid", "GeometryReader",
    "AnyLayout", "ViewThatFits", "TabView", "Section", "Menu", "ControlGroup",
)
CREATOR_RE = re.compile(
    r"^\s*(\w+)\b.*\{\s*$"
)
ID_RE = re.compile(r"\.accessibilityIdentifier\(\s*\"([^\"]+)\"\s*\)")
ELEMENT_RE = re.compile(r"\.accessibilityElement\(\s*children:\s*\.(contain|combine)\s*\)")

ci_mode = "--ci" in sys.argv
findings = []


def matching_open(lines: list[str], close_idx: int) -> int | None:
    """从收尾 } 行向上找与之匹配的开 { 行；失衡返回 None。"""
    depth = 0
    for i in range(close_idx, -1, -1):
        depth += lines[i].count("}") - lines[i].count("{")
        if depth <= 0:
            return i
    return None


def brace_close(lines: list[str], open_idx: int) -> int | None:
    depth = 0
    for i in range(open_idx, len(lines)):
        depth += lines[i].count("{") - lines[i].count("}")
        if depth <= 0:
            return i
    return None


for swift in sorted(APP.rglob("*.swift")):
    lines = swift.read_text(encoding="utf-8").splitlines()
    for idx, line in enumerate(lines):
        m = ID_RE.search(line)
        if not m:
            continue
        ident = m.group(1)
        # 向上收集修饰链（连续 `.` 起始行）
        chain_start = idx
        while chain_start > 0 and lines[chain_start - 1].lstrip().startswith("."):
            chain_start -= 1
        chain = "\n".join(lines[chain_start:idx + 1])
        if ELEMENT_RE.search(chain):
            continue
        # 链归属语句：链上方第一行
        prev = lines[chain_start - 1].rstrip() if chain_start > 0 else ""
        creator_line_no = None
        if prev.endswith("{") or (prev.strip() and prev.strip().endswith("{")):
            # 直接以 `{` 收尾的创建行（单行闭包或 `VStack {`）
            creator_line_no = chain_start - 1
        elif prev.strip().endswith("}") or prev.strip() == "}":
            # 多行闭包收尾后挂修饰链 → 回溯匹配开 { 所在行
            creator_line_no = matching_open(lines, chain_start - 1)
        if creator_line_no is None:
            continue
        creator = lines[creator_line_no]
        cm = CREATOR_RE.match(creator)
        if not cm or cm.group(1) not in CONTAINER_TYPES:
            continue
        end = brace_close(lines, creator_line_no)
        if end is None:
            continue
        indent = len(creator) - len(creator.lstrip())
        # 容器范围内（含闭包内、链自身在 } 之后自然排除）存在更深的 identifier
        masked = [
            (j + 1, ID_RE.search(lines[j]).group(1))
            for j in range(creator_line_no + 1, end)
            if ID_RE.search(lines[j])
            and len(lines[j]) - len(lines[j].lstrip()) > indent
        ]
        if not masked:
            continue
        findings.append(
            f"{swift.relative_to(APP.parent)}:{idx + 1} 容器标识 {ident} 掩蔽子元素 "
            f"{', '.join(f'{name}(L{n})' for n, name in masked)}（缺 .accessibilityElement(children: .contain)）"
        )

if findings:
    print(f"发现 {len(findings)} 处容器标识掩蔽风险：")
    for f in findings:
        print(" -", f)
    sys.exit(1 if ci_mode else 0)
print("无容器标识掩蔽风险。")
sys.exit(0)
