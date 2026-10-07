# .github/workflows 目录规则

> 本目录只存放 **GitHub Actions 工作流定义(`*.yml`)**。GitHub 仅扫描此层目录——
> 子目录里的 YAML 会被静默忽略,因此工作流文件禁止放入任何子目录,也不得移走。
> (2026-09-24 重组:辅助脚本已全部迁出,按功能域分簇至 `scripts/<域>/`。)

## CI 代码布局（.github/{workflows,actions,config} —— 2026-10-07 业主指令落地）

```
.github/
├── workflows/      # 仅工作流定义（*.yml，含 workflow_call reusable——平台硬约束：
│                   #   GitHub 只在此层扫描；工作流禁止放入任何子目录）
├── actions/        # 被 workflows 调用的脚本 / 公用代码（按域归簇）
│   ├── l0-gate/    #   L0 门禁 composite action 执行体（workflows 四个的公用调用面）
│   ├── gates/      #   域:L0 静态门禁(19 节)判定器簇
│   ├── release/    #   域:发布/签名信任链/模型物化(共用 asr_package / model_trust 库)
│   └── distill/    #   域:实体链接/蒸馏训练簇(entlink 确定性召回+语料构建+评测闸+训练循环;
│                   #     零 PHI 数据纪律、MPS 探测段先行、checkpoint 断点续训,详见簇 README)
└── config/         # 可公开的配置（纯配置/清单按域入子目录）
    ├── gates/        #   gate-suites.tsv / l10n-legacy-allowlist.txt / 依赖能力矩阵
    ├── distill/      #   assets.json（Release 资产清单模板）
    └── requirements/ #   pip --require-hashes 钉版清单
```

**归簇原则:按功能域聚合,目录名即职责域。** 新增脚本先归簇,禁止直接放进
workflows/ 或 actions/ 顶层;辅助数据文件随所属簇存放(如
`config/gates/gate-suites.tsv`、`config/gates/l10n-legacy-allowlist.txt` 等
纯配置/清单（集群数据与判定器留 actions/ 簇内，纯配置与钉版清单入 config/<域>/）。各簇的具体职责
见下表「工作流一览」。（旧 `scripts/` 布局于 2026-10-07 整体迁入本结构；
`scripts/medical-data/` 早已迁至 workspace 级 `refactor/tools/medical-data/`。）

## 簇内耦合规则(移动文件前必读)

- `python3 script.py` 会把脚本所在目录加入 `sys.path`,所以**同簇脚本可以互相
  `from xxx import`**,而 `Path(__file__).with_name("yyy.py")` 与子进程调用同理——
  全部依赖「同目录」这一事实。
- **因此:共用库的脚本必须同簇,禁止跨簇 import / with_name 定位。** 实证示例:
  `release/` 簇里 `asr_package.py` 被 13 个脚本导入、`model_trust.py` 被 5 个消费
  (含 runpy 挂载形式;计数随簇演进,以 grep 实况为准)。
- 仓库根探测**禁止按固定层级 `parents[N]` 假设**:一律逐级向上找
  `CoreKit/Sources/Domain`(Python)或 `project.yml`(shell)锚点。
  教训见 `.github/actions/gates/l0-container-id-mask.py:20`(2026-09-12 假绿实证)。

## 其他规则

- **`requirements-*.txt` 必须 `--require-hashes` 钉版**(S-M6 供应链纪律),统一放
  `.github/config/requirements/`;换版须重取哈希(见各清单文件头注释的生成方式)。
- **`__pycache__/` 与 `*.pyc` 是 Python 运行时缓存**:由 `.gitignore` 忽略,永不提交,
  本地可随时删除(不会被重建进库)。
- 编排逻辑尽量留在 YAML `run:` 步骤;复杂逻辑下沉为簇内脚本,禁止在 YAML 内长内联。
- **移动/新增文件后的同步清单**(全部都要做):
  1. 所有引用该脚本的 YAML 调用路径、`project.yml` 构建阶段(`$SRCROOT/...`);
  2. `CLAUDE.md` / `AGENTS.md`;
  3. `refactor/` 规格链与 `code-function-mapping.md` 中的路径引用;
  4. 验证:`bash .github/actions/gates/l0-static-gate.sh`(19 节全绿；2026-10-07 本工作树实测绿，旧 ERR#27 状态注已失效)+
     跑受影响的 `test-*.py`;最后更新 `refactor/memory/` 知识库。

## 工作流一览

| 文件 | 触发 | 职责 | 调用簇 |
|---|---|---|---|
| `testflight.yml` | push master / PR / dispatch | **编译+上传 TestFlight + 测试面（2026-10-07 消解 ci-tests.yml 后）**：**gates（L0 单源 composite）∥ corekit（swift test）∥ l1（编译门禁+型检预算+L1 单元/UI）三并联——任一红即不进入 build**（业主 2026-10-07 裁决）→ build（版本内联→签名材料→archive→export→IPA 校验）→ upload（altool→buildUploads 秒级证据+≤90s 列表确认；四依赖门控，测试红不上传 TestFlight）。PR 上只跑三并联（build 有事件守卫）。 | gates / release / requirements |
| `asr.yml` | workflow_call / dispatch | ASR 包构建、签名、发布至 **CNB 资源仓 Release**（2026-10-03 cutover 后非 GitHub Releases；发布成功触发资源仓 README 同步） | release / requirements |
| `llm.yml` | workflow_dispatch（task 输入：llm-pipeline / llama-xcframework） | tests(53 例单测+语法)→语料冻结(prepare)→标定(calibrate,MPS 探测段)→smoke 训练回归→评测闸(eval,verdict=fail 阻断 publish)→发布;语料内容寻址存 Release。**llama XCFramework 构建自 build-llama-xcframework.yml 并入**（task=llama-xcframework；原自路径触发有意删除——合并后任何编辑都会触发 15-20min 重建+clobber，重建改手动） | distill / release / requirements |
| `maintenance.yml` | 每日 16:00 UTC（清理）/ 周日 23:17 UTC（签名到期）/ dispatch（三 job 全跑） | 维护三合一（2026-09-29）：执行记录清理（规则A/B）+ 签名材料到期周检 + ASC build 状态查询（原 `cleanup-runs.yml` / `signing-expiry-check.yml` / `asc-build-status.yml`；`seed-cnb-assets.yml` 已删——业主 2026-10-07：本地离线执行完成） | release / requirements |

**Release/sqlite 契约**:公开仓无 `medical-data` Release 时 Publish 步骤自动 `gh release create`;`medical-catalog.sqlite`(schema v4+FTS)每轮全量重建、age 加密后以 `medical-data.bin` 上传同标签(内容哈希未变则跳过)。

发布操作文档:`.github/ASR_RELEASE.md`；医疗数据 Release 契约已迁入私有仓 `tasks/vita-liber/medical-data/docs/MEDICAL_DATA_RELEASE.md`（[仅授权成员可访问](https://github.com/robinhoo1973/robinhoo-pipelines/blob/main/tasks/vita-liber/medical-data/docs/MEDICAL_DATA_RELEASE.md)）。
