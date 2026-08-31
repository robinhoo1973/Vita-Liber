"""Swift 标识符生成的**唯一实现**（design/tools 共用）。

为什么单独成模块：`generate_assets.py` 与 `sync_best_selection.py` 各自抄了一份
保留字表 + 驼峰转换。两份当前逐字相同（已实测：13 组样例输出一致、关键字集合相等），
所以这不是「已经漂移」，而是「迟早漂移」——往其中一份补一个保留字而漏掉另一份，
就会让某条管线产出未转义的属性名，重新引入 ERR#28（保留字作属性名 → 编译期 error）。

用法（两个脚本都在本目录，直接同名导入即可）：
    from swift_ident import swift_identifier
"""

# Swift 保留字：作为属性名声明时必须反引号转义，否则编译期 error（ERR#28）。
# 宁可多转义——反引号对非保留字是恒等语法，不改变 API 名。
SWIFT_KEYWORDS = {
    "associatedtype", "class", "deinit", "enum", "extension", "fileprivate", "func",
    "import", "init", "inout", "internal", "let", "open", "operator", "private",
    "precedencegroup", "protocol", "public", "rethrows", "static", "struct", "subscript",
    "typealias", "var", "break", "case", "catch", "continue", "default", "defer", "do",
    "else", "fallthrough", "for", "guard", "if", "in", "repeat", "return", "throw",
    "throws", "switch", "where", "while", "Any", "as", "await", "false", "is", "nil",
    "self", "Self", "super", "true", "try", "_",
}


def camel(stem: str) -> str:
    """`arrow-left` -> `arrowLeft`。空段（`a--b`、`b-`）不产生多余大写。"""
    parts = stem.split("-")
    return parts[0] + "".join(p[:1].upper() + p[1:] for p in parts[1:] if p)


def escape(identifier: str) -> str:
    """保留字转义。必须在拼出完整标识符之后调用（如 `xxxFilled`）。"""
    return f"`{identifier}`" if identifier in SWIFT_KEYWORDS else identifier


def swift_identifier(asset_name: str) -> str:
    """资产名（含 `ic-` 前缀）-> 可直接声明的 Swift 属性名。"""
    stem = asset_name[3:] if asset_name.startswith("ic-") else asset_name
    return escape(camel(stem))
