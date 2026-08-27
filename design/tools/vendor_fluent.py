#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把映射到的官方 Fluent 字形 vendor 进仓库（design/icons/fluent/）。

用法：python3 design/tools/vendor_fluent.py <path/to/@fluentui/svg-icons/icons>
产物：design/icons/fluent/{our}.svg、{our}.filled.svg（仅 Tab 五枚）、NOTICE.md
之后 generate_assets.py 只依赖仓库内副本，不再依赖 npm。
"""

import re
import shutil
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from fluent_map import FLUENT

ROOT = Path(__file__).resolve().parents[2]
DEST = ROOT / "design/icons/fluent"
FILLED_ONLY = {  # 仅这些概念需要 filled 态（Tab 激活态）
    "ic-tab-home", "ic-tab-records", "ic-tab-reminders", "ic-tab-assistant", "ic-tab-me",
}

NOTICE = """# Third-Party Notice — Fluent UI System Icons

本目录 `{name}.svg` / `{name}.filled.svg` 字形文件直接取自
**Microsoft Fluent UI System Icons**（npm 包 `@fluentui/svg-icons`），
按 **MIT License** 授权使用与再分发：

```
MIT License

Copyright (c) Microsoft Corporation.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE
```

上游：https://github.com/microsoft/fluentui-system-icons
瓷砖底、渐变、高光等封装层与未列出的自绘字形为青囊书项目自有产物。
"""


def main() -> None:
    src_dir = Path(sys.argv[1]).expanduser().resolve()
    if not src_dir.is_dir():
        sys.exit(f"icons 目录不存在: {src_dir}")
    DEST.mkdir(parents=True, exist_ok=True)

    expected = set()
    for our, fluent in FLUENT.items():
        expected.add(f"{our}.svg")
        shutil.copyfile(src_dir / f"{fluent}_24_regular.svg", DEST / f"{our}.svg")
        if our in FILLED_ONLY:
            expected.add(f"{our}.filled.svg")
            shutil.copyfile(src_dir / f"{fluent}_24_filled.svg", DEST / f"{our}.filled.svg")

    # 清理已从映射表移除的残留字形（避免管线引用过期文件）
    stale = [f for f in DEST.glob("*.svg") if f.name not in expected]
    for f in stale:
        f.unlink()
    (DEST / "NOTICE.md").write_text(NOTICE, encoding="utf-8")
    print(f"[ok] vendored {len(expected)} glyph files, pruned {len(stale)} stale -> {DEST}")


if __name__ == "__main__":
    main()
