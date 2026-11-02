#!/usr/bin/env python3
"""L0 [23] mock parity 契约检查（owner rule 2026-10-31）。

检查三面（每个契约文件独立执行，2026-11-01 扩展为多契约）：
1. 契约 JSON 行数/必需测试名/必需 L10n 键存在且被 App 引用（t("<key>")）。
2. Swift parity 测试文件包含每个必需测试名。
3. workspace 存在 refactor/mock 时，mock 源内含契约钉死的状态机片段；
   CI 无私仓 mock 时该面显式 SKIP（不伪绿）。
"""
import json
import pathlib
import re
import sys

repo = pathlib.Path(sys.argv[1]).resolve()
contract_dir = repo / ".github/config/gates/mock-parity"
contract_paths = sorted(contract_dir.glob("*.json"))
errors = []

if not contract_paths:
    print(f"  FAIL 契约目录为空：{contract_dir}")
    sys.exit(1)

app_text = "\n".join(
    p.read_text(encoding="utf-8", errors="ignore")
    for p in (repo / "App").rglob("*.swift")
    if p.name != "RegisteredKeys.swift"
)

total_rows = 0
total_tests = 0
mock_states = []

for contract_path in contract_paths:
    label = contract_path.name
    try:
        contract = json.loads(contract_path.read_text(encoding="utf-8"))
    except Exception as exc:  # noqa: BLE001
        errors.append(f"{label}: 契约不可读/不可解析：{exc}")
        continue

    rows = contract.get("rows") or []
    total_rows += len(rows)
    if len(rows) < 6:
        errors.append(f"{label}: 契约状态行不足（{len(rows)} < 6）")
    ids = [row.get("id") for row in rows]
    if len(ids) != len(set(ids)):
        errors.append(f"{label}: 契约状态 id 重复")

    names = contract.get("requiredTestNames") or []
    total_tests += len(names)
    test_path = repo / contract["swiftTest"]
    test_text = test_path.read_text(encoding="utf-8") if test_path.exists() else ""
    if not test_text:
        errors.append(f"{label}: Swift parity 测试缺失：{contract['swiftTest']}")
    for name in names:
        if name not in test_text:
            errors.append(f"{label}: Swift parity 测试缺行：{name}")

    ui_test_path = contract.get("uiTest")
    ui_test_name = contract.get("uiTestName")
    if ui_test_path and ui_test_name:
        ui_path = repo / ui_test_path
        ui_text = ui_path.read_text(encoding="utf-8") if ui_path.exists() else ""
        if not ui_text:
            errors.append(f"{label}: UI parity 测试缺失：{ui_test_path}")
        elif ui_test_name not in ui_text:
            errors.append(f"{label}: UI parity 测试缺行：{ui_test_name}")

    for key in contract.get("requiredKeys") or []:
        if f't("{key}")' not in app_text:
            errors.append(f"{label}: mock 契约键未被 App 消费：{key}")

    mock_path = None
    # repo.parent 是 worktree 的 .worktrees 目录；再上一层才是工作区根。
    for base in (repo, repo.parent, repo.parent.parent):
        candidate = base / contract["mockFile"]
        if candidate.exists():
            mock_path = candidate
            break
    if mock_path is not None:
        mock_text = mock_path.read_text(encoding="utf-8", errors="ignore")
        for snippet in contract.get("mockSnippets") or []:
            if snippet not in mock_text:
                errors.append(f"{label}: mock 源与契约片段不符：{snippet[:60]}")
        mock_states.append(f"{label}=checked")
    else:
        mock_states.append(f"{label}=SKIP")

# mock 专用命名空间死键扫描（owner rule：零引用即缺陷）。
strings_path = repo / "Resources/Localization/zh-Hans.lproj/Localizable.strings"
if strings_path.exists():
    strings_text = strings_path.read_text(encoding="utf-8", errors="ignore")
    for key in re.findall(r'"(startup\.catalog\.[^"]+)"\s*=', strings_text):
        if f't("{key}")' not in app_text:
            errors.append(f"mock 专用 L10n 键零引用：{key}")

if errors:
    for err in errors:
        print(f"  FAIL {err}")
    sys.exit(1)
print(f"  PASS mock parity 契约 {len(contract_paths)} 个 / {total_rows} 行 / "
      f"{total_tests} 测试 / mock={','.join(mock_states)}")
