#!/usr/bin/env python3
"""L0 [19] 工作流结构门禁 —— .github/workflows 与 .github/actions 的静态形态断言。

四查 + 一附加（2026-10-07 委员会双轮定稿；错误族背景见 refactor/memory/ci-lessons
「工作流 run 块 shell 语法族」「注释内表达式 0 秒红」「协议遵从缺失族」）
+ e（2026-10-08 族防御，见下）：

  a. 可解析 + 触发器存在：.github/workflows/*.yml 必须 YAML 可解析且含 on: 键
     （PyYAML 把 `on` 解析为布尔 True——两形态都接受）；workflows/ 下出现
     *.yaml 等非 *.yml 的 YAML 一律判红（GitHub 接受 .yaml，而 L0 §6 的
     gate-token 扫描只认 *.yml ⇒ .yaml 工作流可同时逃过两处 = 静默盲区）；
     .github/actions/*/action.yml 存在时同样要求可解析。
  b. 注释内 ${{ 扫描（0 秒红族：2026-10-03 distill 注释双花括号整文件拒载，
     零 jobs 零日志）：quote-aware 定位 YAML 注释起点 #，其后的 ${{ 判红；
     同行带豁免标记 `gha-expr-ok:` 时放行（与 try?-ok: 同构）。action.yml 的
     description 字段同查（加载期解析同一表达式面）。
  c. 钉版纪律：非本仓（无 ./ 前缀）的 uses: 必须固定完整 40-hex SHA；
     action.yml 内部 uses 同查。浮动 tag（@v4 等）可在任何时刻被上游改指向。
  d. 本地引用闭包：`uses: ./.github/workflows/<f>.yml` 必须存在且声明
     workflow_call；`uses: ./.github/actions/<name>` 必须存在 action.yml 且
     runs.using == composite。（无效引用在 GitHub 侧是创建期 0 秒红——本地左移。）
  附加. maintenance.yml 的 REQUIRED_PATHS 每条路径必须存在（悬空哨兵 = 静默失效）。
  e. 测试电池依赖契约（2026-10-08，CI 37722650928 实证）：job 的 run 文本调用
     release 测试面（`.github/actions/release/test-*.py` 或 `model-trust.py`）
     时，同 job 必须出现 requirements-model-tools.txt 安装引用——本机 pip
     装齐掩盖 CI 裸 runner 缺依赖（yaml 消费测试 ModuleNotFoundError）；新
     job 抄测试清单漏抄安装步即撞此族（asr.yml verify job 首跑即实证）。

用法：python3 .github/actions/gates/l0-workflow-structure.py [--ci]
      （--ci：有发现即退出码 1，供 L0 门禁第 19 节复用；0 文件扫描退出码 2——
       ERR#27 纪律：空扫不得判 PASS）
"""
import re
import sys
from pathlib import Path

# 仓库根探测：逐级向上找 CoreKit/Sources/Domain 锚点（禁 parents[N] 固定层级）
ROOT = Path(__file__).resolve().parent
while ROOT != ROOT.parent and not (ROOT / "CoreKit" / "Sources" / "Domain").is_dir():
    ROOT = ROOT.parent
WF = ROOT / ".github" / "workflows"
ACTIONS = ROOT / ".github" / "actions"

if not WF.is_dir():
    print(f"ERROR: 未找到 .github/workflows（探测到仓库根 {ROOT}）——本判定器属于代码仓库。")
    sys.exit(2)

try:
    import yaml
except ImportError:
    print("ERROR: PyYAML 不可用——CI 需显式 setup-python + pip 提供；本地请 pip install pyyaml。")
    sys.exit(2)

ci_mode = "--ci" in sys.argv
findings: list[str] = []
scanned = 0


def flag(msg: str) -> None:
    findings.append(msg)


def comment_expr_hits(path: Path) -> list[int]:
    """quote-aware 找注释内的 ${{ 行号（单/双引号简判——YAML 引号语义子集）。"""
    hits = []
    for lineno, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if "gha-expr-ok" in line:
            continue
        if path.name == "action.yml" and re.match(r"\s*description:", line) and "${{" in line:
            hits.append(lineno)
            continue
        in_single = in_double = False
        cut = None
        for idx, ch in enumerate(line):
            if ch == "'" and not in_double:
                in_single = not in_single
            elif ch == '"' and not in_single:
                in_double = not in_double
            elif ch == "#" and not in_single and not in_double:
                cut = idx
                break
        if cut is not None and "${{" in line[cut:]:
            hits.append(lineno)
    return hits


USES_RE = re.compile(r"^\s*(?:-\s*)?uses:\s*(\S+)")
SHA_RE = re.compile(r"[0-9a-f]{40}$")


def scan_uses(path: Path) -> None:
    for lineno, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        m = USES_RE.match(line)
        if not m:
            continue
        ref = m.group(1).strip("\"'")
        if ref.startswith("./"):
            if ref.startswith("./.github/workflows/"):
                target = ROOT / ref[2:]
                if not target.is_file():
                    flag(f"{path.name}:{lineno}: 本地工作流引用不存在：{ref}")
                elif "workflow_call" not in target.read_text(encoding="utf-8"):
                    flag(f"{path.name}:{lineno}: 被引用的 {ref} 未声明 workflow_call（on: 下）")
            elif ref.startswith("./.github/actions/"):
                name = ref[len("./.github/actions/"):].split("/")[0]
                manifest = ACTIONS / name / "action.yml"
                if not manifest.is_file():
                    flag(f"{path.name}:{lineno}: 本地 action 不存在：{ref}（缺 {manifest.relative_to(ROOT)}）")
                else:
                    doc = yaml.safe_load(manifest.read_text(encoding="utf-8")) or {}
                    using = (doc.get("runs") or {}).get("using")
                    if using != "composite":
                        flag(f"{path.name}:{lineno}: {ref} 的 runs.using={using!r}，本仓只用 composite")
            # 其它 ./-相对引用：仓内路径存在性由上面两类覆盖，其余不追
            continue
        if "@" not in ref or not SHA_RE.search(ref.rsplit("@", 1)[1]):
            flag(f"{path.name}:{lineno}: uses 未钉 40-hex 完整 SHA：{ref}")


# ---------- a. 解析 + 触发器 + b/c 扫描 ----------
for f in sorted(WF.iterdir()):
    if f.is_dir():
        continue
    if f.suffix == ".yaml":
        flag(f"{f.name}: workflows/ 下的 .yaml 文件是双盲区（GitHub 认它、L0 §6 不扫它）——改名 .yml 或移出")
        continue
    if f.suffix != ".yml":
        continue
    scanned += 1
    try:
        doc = yaml.safe_load(f.read_text(encoding="utf-8"))
    except yaml.YAMLError as exc:
        flag(f"{f.name}: YAML 解析失败——{str(exc).splitlines()[0]}")
        continue
    if not isinstance(doc, dict):
        flag(f"{f.name}: 顶层不是映射")
        continue
    if "on" not in doc and True not in doc:
        flag(f"{f.name}: 缺 on: 触发器键")
    for jname, job in (doc.get("jobs") or {}).items():
        if not isinstance(job, dict):
            continue
        if "runs-on" not in job and not job.get("uses"):
            flag(f"{f.name}: job「{jname}」既无 runs-on 也无 uses（创建期 schema 红；composite 化后 caller job 必须自带 runs-on）")
        # e. 测试电池依赖契约（族防御，见文件头）
        runs_text = "\n".join(str(step.get("run", "")) for step in (job.get("steps") or [])
                              if isinstance(step, dict))
        if (".github/actions/release/test-" in runs_text
                or ".github/actions/release/model-trust.py" in runs_text):
            if "requirements-model-tools.txt" not in runs_text:
                flag(f"{f.name}: job「{jname}」调用 release 测试面但未装 requirements-model-tools.txt"
                     f"（CI 裸环境缺依赖族——本机装齐不构成证据）")
    for lineno in comment_expr_hits(f):
        flag(f"{f.name}:{lineno}: 注释内出现 ${{{{ ——0 秒红族（整文件拒载）；移除或同行加 gha-expr-ok: 豁免")
    scan_uses(f)

if ACTIONS.is_dir():
    for manifest in sorted(ACTIONS.glob("*/action.yml")):
        scanned += 1
        try:
            yaml.safe_load(manifest.read_text(encoding="utf-8"))
        except yaml.YAMLError as exc:
            flag(f"{manifest.relative_to(ROOT)}: YAML 解析失败——{str(exc).splitlines()[0]}")
            continue
        for lineno in comment_expr_hits(manifest):
            flag(f"{manifest.relative_to(ROOT)}:{lineno}: 注释/description 内出现 ${{{{ ——0 秒红族")
        scan_uses(manifest)

# ---------- 附加：REQUIRED_PATHS 悬空哨兵 ----------
maint = WF / "maintenance.yml"
if maint.is_file():
    m = re.search(r'REQUIRED_PATHS="([^"]*)"', maint.read_text(encoding="utf-8"))
    if not m:
        flag("maintenance.yml: 未找到 REQUIRED_PATHS 声明（悬空哨兵被移除？）")
    else:
        for p in m.group(1).split():
            if not (ROOT / p).exists():
                flag(f"maintenance.yml REQUIRED_PATHS 悬空：{p} 不存在")

# ---------- 汇总 ----------
if scanned == 0:
    print("ERROR: 0 文件扫描——空扫不得判 PASS（ERR#27 纪律），拒绝退出码 0。")
    sys.exit(2)
print(f"工作流结构门禁：扫描 {scanned} 个文件，发现 {len(findings)} 项")
for item in findings:
    print(f"  ✘ {item}")
if ci_mode and findings:
    sys.exit(1)
sys.exit(0)
