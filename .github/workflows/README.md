# .github/workflows 目录规则

> 本目录只存放 **GitHub Actions 工作流定义(`*.yml`)**。GitHub 仅扫描此层目录——
> 子目录里的 YAML 会被静默忽略,因此工作流文件禁止放入任何子目录,也不得移走。
> (2026-09-24 重组:辅助脚本已全部迁出,按功能域分簇至 `scripts/<域>/`。)

## 辅助脚本在哪里

```
scripts/
├── gates/          # 域:L0 静态门禁(19 节)+ 其数据文件
├── release/        # 域:发布/签名信任链/模型物化(共用 asr_package / model_trust 库)
├── distill/        # 域:实体链接/蒸馏训练簇(entlink 确定性召回+语料构建+评测闸+训练循环;
│                   #   设计依据 refactor/2026-09-29-medical-llm-training-scenarios-ci-plan.md §7;
│                   #   零 PHI 数据纪律、MPS 探测段先行、checkpoint 断点续训,详见簇 README)
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
  4. 验证:`bash scripts/gates/l0-static-gate.sh`(19 节全绿；2026-10-07 本工作树实测绿，旧 ERR#27 状态注已失效)+
     跑受影响的 `test-*.py`;最后更新 `refactor/memory/` 知识库。

## 工作流一览

| 文件 | 触发 | 职责 | 调用簇 |
|---|---|---|---|
| `build-testflight.yml` | push master / dispatch | **单纯编译+上传 TestFlight（2026-10-07 瘦身 P2）**：gates（ubuntu 并行 L0,schema；挡 upload 的机械冻结）→ build（版本内联→签名材料→archive→export→IPA 校验→artifact）→ upload（altool→buildUploads 秒级证据+≤90s 列表确认）。测试全量在 ci-tests.yml 并行跑；v* tag 触发已删（无版本语义） | gates / requirements |
| `release-asr-models.yml` | workflow_call / dispatch | ASR 包构建、签名、发布至 **CNB 资源仓 Release**（2026-10-03 cutover 后非 GitHub Releases；发布成功触发资源仓 README 同步） | release / requirements |
| `ci-tests.yml` | push master / PR / dispatch | **测试与静态门禁（2026-10-06 拆分批 P1）**：L0 十九节（ubuntu，含 swiftc 断言）→ CoreKit swift test ∥ 编译门禁+型检预算+L1 单元/UI（macOS）；与发布链完全并行（测试不再阻塞上传；批次验收 = 两工作流全绿；`cancel-in-progress: true` 与发布链排队语义相反） | gates / requirements |
| `distill-llm.yml` | workflow_dispatch | tests(53 例单测+语法)→语料冻结(prepare)→标定(calibrate,MPS 探测段)→smoke 训练回归→评测闸(eval,verdict=fail 阻断 publish)→发布;语料内容寻址存 Release(checkpoint Release 化随 P2 train job) | distill / requirements |
| `build-llama-xcframework.yml` | dispatch / 自身路径变更 | 自建 llama.cpp XCFramework 并发布 | (外部上游脚本) |
| `maintenance.yml` | 每日 16:00 UTC（清理）/ 周日 23:17 UTC（签名到期）/ dispatch（三 job 全跑） | 维护三合一（2026-09-29）：执行记录清理（规则A/B）+ 签名材料到期周检 + ASC build 状态查询（原 `cleanup-runs.yml` / `signing-expiry-check.yml` / `asc-build-status.yml`） | release / requirements |

**Release/sqlite 契约**:公开仓无 `medical-data` Release 时 Publish 步骤自动 `gh release create`;`medical-catalog.sqlite`(schema v4+FTS)每轮全量重建、age 加密后以 `medical-data.bin` 上传同标签(内容哈希未变则跳过)。

发布操作文档:`.github/ASR_RELEASE.md`；医疗数据 Release 契约已迁入私有仓 `tasks/vita-liber/medical-data/docs/MEDICAL_DATA_RELEASE.md`（[仅授权成员可访问](https://github.com/robinhoo1973/robinhoo-pipelines/blob/main/tasks/vita-liber/medical-data/docs/MEDICAL_DATA_RELEASE.md)）。
