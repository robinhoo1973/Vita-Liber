#!/usr/bin/env python3
"""结构转换登记表生成器（B1/B2，2026-10-29 转换登记表批）。

单一权威 = 代码（SchemaMigrations.swift steps + SchemaV2.swift baseline ddl）。
本脚本从代码**全量生成**两个派生产物（禁止手工补丁——旧 patch 脚本在
CI run 40778755694 因字节漂移红过，根因即「补丁式种子」）：

1. `CoreKit/Sources/Infrastructure/SchemaHistorySeed.swift` 的压缩分片
   （raw DEFLATE level 9 → base64 → 每行 100 字符）；
2. `.github/config/gates/schema-registry.json`（只读登记视图：kind 三值 /
   hasCode / executor / transactional / fk_check_table / irreversible /
   relocations；definition_sha256 在 B2 发布冻结后启用）。

用法：
  python3 -I scripts/gates/generate-schema-registry.py           # 校验模式（L0 门禁）：
      在内存生成并与已提交产物逐字节比对，漂移 exit 1。
  python3 -I scripts/gates/generate-schema-registry.py --write   # 开发者改迁移后重生成。

解析口径（与 Swift 编译器语义对齐）：
- 多行字面量 `\"\"\"` 的值 = 去掉闭合定界符所在行缩进后的行集合（Swift 规则），
  首行空行与闭合缩进行不进入值；
- SQL 文本入 INSERT 时单引号双写（SQL 字符串转义）；
- kind 三值派生同 Swift `Step.kind`：sql 空→code；hasCode→hybrid；否则 sql。
"""
import base64
import json
import pathlib
import re
import sys
import zlib

ROOT = pathlib.Path(__file__).resolve().parents[2]
MIGRATIONS = ROOT / "CoreKit/Sources/Infrastructure/SchemaMigrations.swift"
BASELINE = ROOT / "CoreKit/Sources/Infrastructure/SchemaV2.swift"
SEED = ROOT / "CoreKit/Sources/Infrastructure/SchemaHistorySeed.swift"
REGISTRY = ROOT / ".github/config/gates/schema-registry.json"

# 每条 Step(...) 调用：version / name / sql（三引号或空串）+ 尾部具名参数。
STEP_RE = re.compile(
    r'Step\(version: (\d+),\s*name: "([^"]+)",\s*sql:\s*(?:"""(.*?)"""|"")(.*?)\),',
    re.S)
TAIL_RE = re.compile(r'(\w+):\s*(?:"([^"]*)"|(true|false))')


def dedent_literal(body: str) -> str:
    """Swift 多行字面量 -> 值：去掉首行空段与闭合定界符缩进列。"""
    lines = body.split("\n")
    if lines and lines[0].strip() == "":
        lines = lines[1:]
    if not lines:
        return ""
    closing_indent = lines[-1]
    if closing_indent.strip() != "":
        # 闭合定界符与内容同行（本仓无此形态）——保守返回原样
        return body
    indent = len(closing_indent)
    value = []
    for line in lines[:-1]:
        if line.strip() == "":
            value.append("")
        elif line[:indent].strip() == "":
            value.append(line[indent:])
        else:
            raise SystemExit(f"FATAL: 字面量行缩进小于闭合缩进: {line!r}")
    return "\n".join(value)


def baseline_ddl() -> str:
    text = BASELINE.read_text(encoding="utf-8")
    m = re.search(r'static let ddl\s*=\s*"""(.*?)"""', text, re.S)
    if not m:
        raise SystemExit("FATAL: SchemaV2.ddl 字面量未找到")
    return dedent_literal(m.group(1))


def steps() -> list[dict]:
    text = MIGRATIONS.read_text(encoding="utf-8")
    rows = []
    for version, name, triple, tail in STEP_RE.findall(text):
        sql = "" if triple == "" else dedent_literal(triple)
        params = {}
        for key, quoted, boolean in TAIL_RE.findall(tail):
            if key in ("transactional", "hasCode", "irreversible"):
                params[key] = (boolean == "true")
            else:
                params[key] = quoted
        has_code = bool(params.get("hasCode", False))
        kind = "code" if sql == "" else ("hybrid" if has_code else "sql")
        rows.append({
            "version": int(version),
            "name": name,
            "sql": sql,
            "kind": kind,
            "transactional": bool(params.get("transactional", False)),
            "fk_check_table": params.get("fkCheckTable") or None,
            "has_code": has_code,
            "executor": params.get("executor") or None,
            "irreversible": bool(params.get("irreversible", False)),
        })
    if not rows:
        raise SystemExit("FATAL: 未解析到任何 Step（正则与源码形态漂移）")
    versions = [r["version"] for r in rows]
    if len(set(versions)) != len(versions):
        raise SystemExit("FATAL: 版本号重复")
    return rows


def sql_literal(text: str) -> str:
    return text.replace("'", "''")


def seed_raw(rows: list[dict]) -> str:
    ddl = baseline_ddl()
    lines = [
        "PRAGMA foreign_keys=OFF;",
        "CREATE TABLE schema_meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);",
        "CREATE TABLE schema_step(version INTEGER PRIMARY KEY, name TEXT NOT NULL, kind TEXT NOT NULL, sql TEXT NOT NULL, transactional INTEGER NOT NULL, fk_check_table TEXT);",
        "CREATE TABLE database_registry(name TEXT PRIMARY KEY, role TEXT NOT NULL, description TEXT NOT NULL);",
        "CREATE TABLE database_observation(name TEXT PRIMARY KEY, role TEXT NOT NULL, exists_flag INTEGER NOT NULL, size_bytes INTEGER NOT NULL, header_valid INTEGER NOT NULL, observed_version INTEGER, required_tables INTEGER NOT NULL, observed_at REAL NOT NULL);",
        "CREATE TABLE migration_attempt(id INTEGER PRIMARY KEY AUTOINCREMENT, database_name TEXT NOT NULL, source_version INTEGER, target_version INTEGER, outcome TEXT NOT NULL, detail TEXT, observed_at REAL NOT NULL);",
        "INSERT INTO schema_meta(key,value) VALUES('history_schema_version','1');",
        "INSERT INTO schema_meta(key,value) VALUES('catalog_generated_at','2026-10-29');",
        # 现存库自描述（B1 治理：条目即存在；medical-catalog-v4 死行已删——
        # v4 目录链随切片-only 退役，死行令 registeredDatabases 诊断失真）。
        "INSERT INTO database_registry(name,role,description) VALUES('app-local-user_data.sqlite','user-data','患者主库（73 表，本机唯一写入）');",
        "INSERT INTO database_registry(name,role,description) VALUES('app-local-schema-history.sqlite','schema-history','版本目录与启动观测（非权威投影）');",
        "INSERT INTO database_registry(name,role,description) VALUES('app-catalog-drug.sqlite','medical-catalog-v5','v5 药品目录包（f7 安装/选择）');",
        "INSERT INTO database_registry(name,role,description) VALUES('app-catalog-facility.sqlite','medical-catalog-v5','v5 机构目录包（f7 安装/选择）');",
        "INSERT INTO database_registry(name,role,description) VALUES('app-catalog-reference.sqlite','medical-catalog-v5','v5 参考目录包（f7 安装/选择）');",
    ]
    prefix = "INSERT INTO schema_step(version,name,kind,sql,transactional,fk_check_table) VALUES("
    lines.append(prefix + "1,'baseline','sql','" + sql_literal(ddl) + "',0,NULL);")
    for row in rows:
        fk = "NULL" if row["fk_check_table"] is None else f"'{sql_literal(row['fk_check_table'])}'"
        lines.append(
            prefix + f"{row['version']},'{row['name']}','{row['kind']}','"
            + sql_literal(row["sql"]) + f"',{1 if row['transactional'] else 0},{fk});")
    return "\n".join(lines)


def registry_json(rows: list[dict]) -> str:
    relocations = [{
        "old_name": "vitaliber.sqlite",
        "new_name": "app-local-user_data.sqlite",
        "executor": "DatabaseFileMigration.migrate",
    }]
    doc = {
        "generated_by": "scripts/gates/generate-schema-registry.py",
        "authority": "code: SchemaMigrations.swift + SchemaV2.swift（本文件为只读派生视图，不驱动任何决策）",
        "latest_version": max(r["version"] for r in rows),
        "steps": [{
            "version": r["version"],
            "name": r["name"],
            "kind": r["kind"],
            "has_code": r["has_code"],
            "executor": r["executor"],
            "transactional": r["transactional"],
            "fk_check_table": r["fk_check_table"],
            "irreversible": r["irreversible"],
            "definition_sha256": None,
        } for r in rows],
        "relocations": relocations,
    }
    return json.dumps(doc, ensure_ascii=False, indent=2, sort_keys=True) + "\n"


def packed_chunks(raw: str) -> list[str]:
    packed = zlib.compressobj(9, zlib.DEFLATED, -15)
    compressed = packed.compress(raw.encode("utf-8")) + packed.flush()
    b64 = base64.b64encode(compressed).decode("ascii")
    return [b64[i:i + 100] for i in range(0, len(b64), 100)]


def emit_seed(chunks: list[str]) -> str:
    text = SEED.read_text(encoding="utf-8")
    block = "\n".join(f'        "{c}",' for c in chunks)
    pattern = re.compile(r"(private static let chunks: \[String\] = \[\n)(.*?)(\n    \])", re.S)
    if not pattern.search(text):
        raise SystemExit("FATAL: SchemaHistorySeed chunks 数组形态未匹配")
    return pattern.sub(lambda m: m.group(1) + block + m.group(3), text)


def committed_raw() -> str:
    text = SEED.read_text(encoding="utf-8")
    chunks = re.findall(r'^\s*"([A-Za-z0-9+/=]+)",$', text, re.M)
    if not chunks:
        raise SystemExit("FATAL: 已提交种子无 base64 分片")
    return zlib.decompress(base64.b64decode("".join(chunks)), -15).decode("utf-8")


def main() -> int:
    write = "--write" in sys.argv
    rows = steps()
    raw = seed_raw(rows)
    registry = registry_json(rows)
    if write:
        SEED.write_text(emit_seed(packed_chunks(raw)), encoding="utf-8")
        REGISTRY.parent.mkdir(parents=True, exist_ok=True)
        REGISTRY.write_text(registry, encoding="utf-8")
        print(f"wrote seed raw={len(raw)}B chunks={len(packed_chunks(raw))}; registry steps={len(rows)}")
        return 0
    problems = []
    if committed_raw() != raw:
        problems.append("SchemaHistorySeed 与代码定义漂移（运行 --write 重生成）")
    if not REGISTRY.exists() or REGISTRY.read_text(encoding="utf-8") != registry:
        problems.append("schema-registry.json 与代码定义漂移（运行 --write 重生成）")
    if problems:
        for problem in problems:
            print(f"DRIFT: {problem}", file=sys.stderr)
        return 1
    print(f"schema registry consistent: steps={len(rows)} latest=v{max(r['version'] for r in rows)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
