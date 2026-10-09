#!/usr/bin/env python3
"""L0 [20] 本机 LLM 模型单源门禁 —— 「模型不入包」的结构性断言（2026-10-09 换型+下载化批）。

背景（错误族）：2026-09-20 首启下载上线当日回滚——根因不是能力而是**并存**：
模型文件仍在 bundle（本地构建有、CI 没有），`isModelReady()` 在本地恒真使下载路径
短路（refactor/memory/owner-requests.md:15）。这类「约定式单一来源」在两侧环境
分叉时必须靠结构与机械断言兑现，不能靠纪律。本节的四查：

  a. 源码零随包分支：`CoreKit/Sources/Infrastructure/Llama*.swift` 内
     `Bundle.main.url(forResource:` 只允许出现在**目录资源**（catalog）读取行上；
     任何指向 .gguf 的 Bundle 查询 = 随包分支复活 → 红。
  b. 工程面无入包路径：project.yml 不得含 `- path: Resources/LLMModels` 文件夹引用；
     必须含 `- path: Resources/LLMCatalog`（type: folder）且 Resources group 的
     excludes 覆盖 LLMCatalog（防同款「group 条目 + 文件夹引用」双拷，2026-09-19 实证）。
  c. CI 无取模步：workflows/actions 内不得出现 `materialize-llama`（构建期把 GGUF
     灌进 bundle 的旧通道；脚本已随本批删除）。
  d. 目录契约自洽：Resources/LLMCatalog/catalog.json 可解析为 v2 且逐条字段合法
     （id slug / fileName .gguf / bytes>0 / sha256 64hex / url https+主机白名单 /
     role 合法 / preference ⊆ ids）。

镜像声明：字段规则的事实源是 Swift `LLMModelCatalog.parse` + `ModelResourcePolicy`
（Domain）；本判定器是离线镜像（照 l0-dependency-matrix 先例）——两处规则同批演化，
改一处必须同改另一处（评审硬约束）。

退出码：0 = 全过；1 = 任一红（打印逐条原因）。
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
while ROOT != ROOT.parent and not (ROOT / "CoreKit" / "Sources" / "Domain").is_dir():
    ROOT = ROOT.parent

FAILURES: list[str] = []


def fail(message: str) -> None:
    FAILURES.append(message)
    print(f"  FAIL {message}")


def ok(message: str) -> None:
    print(f"  PASS {message}")


# ---------- a. 源码零随包分支 ----------
llama_files = sorted((ROOT / "CoreKit" / "Sources" / "Infrastructure").glob("Llama*.swift"))
if not llama_files:
    fail("扫描根漂移：CoreKit/Sources/Infrastructure/Llama*.swift 一个文件都没扫到（ERR#27 同族）")
for path in llama_files:
    for lineno, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        stripped = line.lstrip()
        if stripped.startswith("//"):
            continue   # 注释提及不算实现面（本判定器 docstring 自身就引用该字面量）
        if "Bundle.main.url(forResource:" in line and "catalogFileName" not in line:
            fail(f"{path.relative_to(ROOT)}:{lineno} 出现非目录资源的 Bundle 查询（随包分支复活族）：{line.strip()[:120]}")
if not FAILURES:
    ok(f"源码零随包分支（{len(llama_files)} 个 Llama*.swift，Bundle 查询仅目录资源）")

# ---------- b. 工程面无入包路径 ----------
project = (ROOT / "project.yml").read_text(encoding="utf-8")
if re.search(r"^\s*- path: Resources/LLMModels\b", project, re.M):
    fail("project.yml 仍含 Resources/LLMModels 文件夹引用（模型会重新进包）")
else:
    ok("project.yml 无 Resources/LLMModels 文件夹引用")
if not re.search(r"^\s*- path: Resources/LLMCatalog\b", project, re.M):
    fail("project.yml 缺 Resources/LLMCatalog 文件夹引用（信任锚目录不进包）")
else:
    ok("project.yml 含 Resources/LLMCatalog 文件夹引用")
if '"LLMCatalog"' not in project or '"LLMCatalog/**"' not in project:
    fail("Resources group excludes 未覆盖 LLMCatalog（双拷贝族：group 条目 + 文件夹引用同时入包）")
else:
    ok("Resources group excludes 覆盖 LLMCatalog")

# ---------- c. CI 无取模步 ----------
hits = []
for base in (ROOT / ".github").rglob("*"):
    if base.is_file() and base.suffix in {".yml", ".yaml"}:
        if "materialize-llama" in base.read_text(encoding="utf-8", errors="ignore"):
            hits.append(base.relative_to(ROOT))
if hits:
    fail(f"workflows/actions 仍引用 materialize-llama（构建期入包旧通道）：{', '.join(map(str, hits))}")
else:
    ok("CI 面零 materialize-llama 引用")

# ---------- d. 目录契约自洽 ----------
catalog_path = ROOT / "Resources" / "LLMCatalog" / "catalog.json"
ALLOWED_HOSTS = {"cnb.cool", "asset.cnb.cool", "github.com",
                 "release-assets.githubusercontent.com", "objects.githubusercontent.com"}
if not catalog_path.is_file():
    fail("Resources/LLMCatalog/catalog.json 不存在")
else:
    try:
        catalog = json.loads(catalog_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as error:
        fail(f"catalog.json 非合法 JSON：{error}")
        catalog = None
    if catalog is not None:
        if catalog.get("formatVersion") != 2:
            fail(f"catalog formatVersion != 2（实为 {catalog.get('formatVersion')!r}）——v1 已随本批退役")
        models = catalog.get("models")
        if not isinstance(models, list) or not models:
            fail("catalog models 为空——下载面永远无货")
        else:
            ids = set()
            for index, model in enumerate(models):
                label = f"models[{index}]"
                if not isinstance(model, dict):
                    fail(f"{label} 非对象")
                    continue
                entry_id = model.get("id")
                if not isinstance(entry_id, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}", entry_id):
                    fail(f"{label} id 非 slug：{entry_id!r}")
                    continue
                ids.add(entry_id)
                if model.get("role") not in {"default", "medical"}:
                    fail(f"{label} role 非法：{model.get('role')!r}")
                if not isinstance(model.get("fileName"), str) or not model["fileName"].endswith(".gguf"):
                    fail(f"{label} fileName 非 .gguf：{model.get('fileName')!r}")
                if not isinstance(model.get("bytes"), int) or model["bytes"] <= 0:
                    fail(f"{label} bytes 未钉版：{model.get('bytes')!r}")
                sha = model.get("sha256")
                if not isinstance(sha, str) or not re.fullmatch(r"[0-9a-fA-F]{64}", sha):
                    fail(f"{label} sha256 非 64hex：{str(sha)[:20]!r}…")
                url = model.get("url")
                match = re.fullmatch(r"https://([^/:]+)(?::(\d+))?/[^\s]+", url or "")
                if not match or (match.group(2) not in (None, "443")) or match.group(1).lower() not in ALLOWED_HOSTS:
                    fail(f"{label} url 非法（须 https+主机白名单+非 443 端口）：{url!r}")
                version = model.get("version")
                if not isinstance(version, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}", version or ""):
                    fail(f"{label} version 非 slug：{version!r}")
            preference = catalog.get("preference")
            if not isinstance(preference, list) or any(p not in ids for p in preference):
                fail(f"preference 悬空或非数组：{preference!r}（ids={sorted(ids)}）")
            if not FAILURES:
                ok(f"catalog v2 自洽（{len(models)} 条目，preference {len(preference or [])} 项）")

if FAILURES:
    print(f"LLM 单源门禁：{len(FAILURES)} 项失败")
    sys.exit(1)
print("LLM 单源门禁：全过")
