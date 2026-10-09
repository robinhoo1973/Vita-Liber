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
│   └── distill/    #   域:蒸馏训练簇(CNB 零密钥取数 fetch_catalog + entlink 确定性召回 +
│                   #     抽取/对话/实体链接三面语料构建 + 生成式 smoke 训练循环 + 双评测闸;
│                   #     零 PHI 数据纪律、ubuntu CPU 吞吐标定(MPS 腿 2026-10-08 退役)、checkpoint 断点续训,详见簇 README)
└── config/         # 可公开的配置（纯配置/清单按域入子目录）
    ├── gates/        #   gate-suites.tsv / l10n-legacy-allowlist.txt / 依赖能力矩阵
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
| `testflight.yml` | dispatch（唯一入口；push/PR 自动触发已删除，2026-10-08 业主指令）；输入 `build_xcframework=true`=仅重建 llama XCFramework | **编译+上传 TestFlight + 测试面（2026-10-07 消解 ci-tests.yml 后）**：**三阶段 DAG（业主 2026-10-07 终稿）：(L0 ∥ CoreKit) → (L1 ∥ build) → upload**——一级任一红不进二级；二级 l1（编译门禁+型检预算+L1 单元/UI）与 build（版本内联→签名材料→archive→export→IPA 校验）并联；upload（altool→buildUploads 秒级证据+≤90s 列表确认）**四依赖门控——测试红不上传 TestFlight**。PR 测试面已删——L1 单元/UI 仅手动 dispatch 执行（合流前 macOS 型检盲区已登记）。**llama XCFramework 重建**（2026-10-09 自 llm.yml 迁入——App 构建依赖，属发布面）：勾 `build_xcframework` 仅跑该 job（App 全链含上传整体跳过），发布 zip 至 release `llama-xcframework`。 | gates / release / requirements |
| `asr.yml` | workflow_call / dispatch | ASR 包构建、签名、发布至 **CNB 资源仓 Release**（2026-10-03 cutover 后非 GitHub Releases；发布成功触发资源仓 README 同步） | release / requirements |
| `llm.yml` | workflow_dispatch（task 输入：llm-pipeline / train-encoder） | **distill v2（2026-10-08：rebase 入四文件布局 + round4 设计批 + job 细分原子化批）：一 job 一任务，文件经 artifact 传递、控制/裁决经 needs+outputs 传递。tests/tests-torch/export-prompts(前置并联)→fetch-catalog(CNB 匿名 v3 零密钥取数+信封解密)→materialize-catalog(SQLite→data-dir 经 artifact 共享)→build-extraction/build-dialogue(消费 data-dir)/build-entlink(消费 SQLite)三个构建并联；calibrate(ubuntu CPU 吞吐基准,记录面——不进裁决器 needs)→smoke-encoder/smoke-extraction/smoke-dialogue(三个冒烟并联，含断点续训回归与五条结构断言)+eval-entlink/eval-corpora(双评测闸)→acceptance(唯一裁决器：13 必需 job 全绿且 entlink∧corpora verdict=pass 才 go；未达=run 判红)→publish-corpus(训练输入件冻结，draft→REST ?name= 上传→digest 复核→裁决器放行才翻转可见；不含模型；对话面发布暂缓至 D-1 裁决)**。**训练轨 task=train-encoder（2026-10-09）：CPU 分块训练链（状态机三重闸+自派发续链；状态/checkpoint 经 llama-models Release draft；启动=手动 dispatch——定时调度 job 已按业主指令删除）**。llama XCFramework 构建 2026-10-09 起迁 `testflight.yml`（task 选项已删）。 | distill / release / requirements |
| `maintenance.yml` | 每日 16:00 UTC（清理）/ 周日 23:17 UTC（签名到期）/ 周一 03:23 UTC（目录漂移）/ dispatch（四 job 全跑） | 维护四件套：执行记录清理（规则A/B）+ 签名材料到期周检 + ASC build 状态查询（原 `cleanup-runs.yml` / `signing-expiry-check.yml` / `asc-build-status.yml`；`seed-cnb-assets.yml` 已删——业主 2026-10-07：本地离线执行完成）+ ASR 目录漂移周检（2026-10-08）。训练窗口调度 job 已按业主指令删除（2026-10-09）。 | release / requirements |

**Release/sqlite 契约（2026-10-08 修订）**:医疗数据唯一发布位置已迁 **CNB `robinhoo1973/Resources` release `medical-data`**（v3 文法:固定名 `manifest.json` 签名指针 + `package-<catalogVersion>.bin` 信封包 + `overview.json`;本地 producer 为唯一写者,源站 WAF 拒云上出口 IP,CI 不直连源站——见 `refactor/discussions/2026-10-07-distill-ci-medical-data-v2.md` §3.5 与私有仓 MEDICAL_DATA_RELEASE.md）。`llm.yml` 的 `distill-corpus` Release 为**合成语料**冻结资产（内容寻址、append-only;对话面暂缓至 D-1 裁决）,与医疗数据 Release 无耦合;旧 age 加密 `medical-data.bin` 契约随 v2 数据面退役。

发布操作文档:`.github/ASR_RELEASE.md`；医疗数据 Release 契约已迁入私有仓 `tasks/vita-liber/medical-data/docs/MEDICAL_DATA_RELEASE.md`（[仅授权成员可访问](https://github.com/robinhoo1973/robinhoo-pipelines/blob/main/tasks/vita-liber/medical-data/docs/MEDICAL_DATA_RELEASE.md)）。
