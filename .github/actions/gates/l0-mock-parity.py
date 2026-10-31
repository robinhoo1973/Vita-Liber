#!/usr/bin/env python3
"""L0 [23] mock parity 契约检查（owner rule 2026-10-31）。

检查三面：
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
contract_path = repo / ".github/config/gates/mock-parity/startup-catalog.json"
errors = []

try:
    contract = json.loads(contract_path.read_text(encoding="utf-8"))
except Exception as exc:  # noqa: BLE001
    print(f"  FAIL 契约不可读/不可解析：{exc}")
    sys.exit(1)

rows = contract.get("rows") or []
if len(rows) < 6:
    errors.append(f"契约状态行不足（{len(rows)} < 6）")
ids = [row.get("id") for row in rows]
if len(ids) != len(set(ids)):
    errors.append("契约状态 id 重复")

test_path = repo / contract["swiftTest"]
test_text = test_path.read_text(encoding="utf-8") if test_path.exists() else ""
if not test_text:
    errors.append(f"Swift parity 测试缺失：{contract['swiftTest']}")
for name in contract.get("requiredTestNames") or []:
    if name not in test_text:
        errors.append(f"Swift parity 测试缺行：{name}")

app_text = "\n".join(
    p.read_text(encoding="utf-8", errors="ignore")
    for p in (repo / "App").rglob("*.swift")
    if p.name != "RegisteredKeys.swift"
)
for key in contract.get("requiredKeys") or []:
    if f't("{key}")' not in app_text:
        errors.append(f"mock 契约键未被 App 消费：{key}")

mock_path = None
for base in (repo, repo.parent, repo.parent.parent):
    candidate = base / contract["mockFile"]
    if candidate.exists():
        mock_path = candidate
        break
if mock_path is not None:
    mock_text = mock_path.read_text(encoding="utf-8", errors="ignore")
    for snippet in contract.get("mockSnippets") or []:
        if snippet not in mock_text:
            errors.append(f"mock 源与契约片段不符：{snippet[:60]}")
    mock_state = "checked"
else:
    mock_state = "SKIP（workspace 无 refactor/mock，CI 代码侧由 Swift parity 测试守）"

if errors:
    for err in errors:
        print(f"  FAIL {err}")
    sys.exit(1)
print(f"  PASS mock parity 契约 {len(rows)} 行 / {len(contract['requiredTestNames'])} 测试 / mock={mock_state}")
