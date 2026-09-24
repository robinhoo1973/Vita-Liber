# .github/workflows 目录规则

> 本目录只存放 **GitHub Actions 工作流定义(`*.yml`)**。GitHub 仅扫描此层目录——
> 子目录里的 YAML 会被静默忽略,因此工作流文件禁止放入任何子目录,也不得移走。
> (2026-09-24 重组:辅助脚本已全部迁出,按功能域分簇至 `scripts/<域>/`。)

## 辅助脚本在哪里

```
scripts/
├── gates/          # 域:L0 静态门禁(17 节)+ 其数据文件
├── release/        # 域:发布/签名信任链/模型物化(共用 asr_package / model_trust 库)
├── medical-data/   # 域:医疗数据发布工具链
└── requirements/   # 辅助文件:pip --require-hashes 钉版清单
```

**归簇原则:按功能域聚合,目录名即职责域。** 新增脚本先归簇,禁止直接放进
workflows/ 或 scripts/ 顶层;辅助数据文件随所属簇存放(如
`gates/gate-suites.tsv`、`gates/l10n-legacy-allowlist.txt`)。各簇的具体职责
见下表「工作流一览」。

## 簇内耦合规则(移动文件前必读)

- `python3 script.py` 会把脚本所在目录加入 `sys.path`,所以**同簇脚本可以互相
  `from xxx import`**,而 `Path(__file__).with_name("yyy.py")` 与子进程调用同理——
  全部依赖「同目录」这一事实。
- **因此:共用库的脚本必须同簇,禁止跨簇 import / with_name 定位。** 实证示例:
  `release/` 簇里 `asr_package.py` 被 7 个脚本导入、`model_trust.py` 被 3 个导入、
  `medical_data_trust.py` 依赖 `model_trust.py`——拆到别的簇会静默断链。
- 仓库根探测**禁止按固定层级 `parents[N]` 假设**:一律逐级向上找
  `CoreKit/Sources/Domain`(Python)或 `project.yml`(shell)锚点。
  教训见 `scripts/gates/l0-container-id-mask.py:20`(2026-09-12 假绿实证)。

## 其他规则

- **`requirements-*.txt` 必须 `--require-hashes` 钉版**(S-M6 供应链纪律),统一放
  `scripts/requirements/`;换版须重取哈希(见各清单文件头注释的生成方式)。
- **`__pycache__/` 与 `*.pyc` 是 Python 运行时缓存**:由 `.gitignore` 忽略,永不提交,
  本地可随时删除(不会被重建进库)。
- 编排逻辑尽量留在 YAML `run:` 步骤;复杂逻辑下沉为簇内脚本,禁止在 YAML 内长内联。
- **移动/新增文件后的同步清单**(全部都要做):
  1. 所有引用该脚本的 YAML 调用路径、`project.yml` 构建阶段(`$SRCROOT/...`);
  2. `CLAUDE.md` / `AGENTS.md`;
  3. `refactor/` 规格链与 `code-function-mapping.md` 中的路径引用;
  4. 验证:`bash scripts/gates/l0-static-gate.sh`(17 节全绿)+
     跑受影响的 `test-*.py`;最后更新 `refactor/memory/` 知识库。

## 工作流一览

| 文件 | 触发 | 职责 | 调用簇 |
|---|---|---|---|
| `build-testflight.yml` | push master / `v*` tag / dispatch | 版本号→构建→L0 门禁→测试→打包→ASC 上传 | gates / release / requirements |
| `release-asr-models.yml` | workflow_call / dispatch | ASR 包构建、签名、发布至 GitHub Releases | release / requirements |
| `medical-data-release.yml` | dispatch | 医疗数据抓取、签名、发布 | medical-data / release |
| `build-llama-xcframework.yml` | dispatch / 自身路径变更 | 自建 llama.cpp XCFramework 并发布 | (外部上游脚本) |
| `asc-build-status.yml` | 定时/Webhook | ASC 构建状态复核 | requirements |
| `cleanup-runs.yml` | 定时 | 清理过期 workflow 运行记录 | — |

发布操作文档:`.github/ASR_RELEASE.md`、`.github/MEDICAL_DATA_RELEASE.md`。
