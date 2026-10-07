# ASR 下载文件与 TestFlight 工作流

> 版本：V1.4（2026-10-07）

## 版本与资产来源

- **App release 版本**：根目录 `version.txt`，一行 `major.minor.patch`，当前 `0.0.1`。GitHub Release/tag 不决定 App 版本。
- **TestFlight build 号**：`run_number.run_attempt`；代码标识取当前提交 hash。
- **ASR 模型版本**：`Resources/ASRModels/manifest.json` 的批准上游来源，以及 `Resources/ASRModelUpdates/index.json` 的发布版本/制作日期/打包修订。
- **分发**：仅 GitHub Releases，资源 Release 为 `asr-models`。ZIP 文件名不可变；App 动态目录为该 Release 的 `catalog.json`。
- 模型下载、生成与校验都在 runner 的 `RUNNER_TEMP` 完成；仓库无 `downloads/` 目录，也不提交模型二进制。

## 模型家族与档位（2026-10-05 目录驱动，业主裁定）

模型信息（家族集、档位、名称/简介/语言覆盖/方言覆盖、许可、版本、字节与内存参数）**全部**由 CI 生成的签名目录 JSON 提供，App 零内置模型数据表：

- **`index.families[]`**：家族级条目——`id`（与 App `VoiceEngineChoice.rawValue` 对齐：`qwen3`/`zipformer`/`dolphin`/`whisper`/`sense-voice`/`fire-red`/`moonshine`）、本地化名称 `name`、简介 `hint`、语言覆盖 `languages`、方言覆盖 `dialects`。声明序 = auto 链优先序（下载卡行序同源）。
- **`index.models[]`**：发布条目——同 `id` 可多档（`variant`: tiny/base/small/medium/turbo/large，按体积升序加权）；每档携带 `tierName`（档位短标签）与 `tierHint`（参数/性能说明）本地化文案。App 下载信息卡按 `families[]` 生成行、按 `models[]` 生成档位选择器与下载/更新/换档按钮。
- **App 侧兜底**：旧目录缺 families/tierName/tierHint 时，UI 回落到 L10n 通用文案（不内置任何型号名称/性能声称）。`asr_package.py validate_index` 强制 families 覆盖全部模型 id（客户端 `ModelCatalogTrustStore` 收单处同检，fail-closed）。
- **预告家族（2026-10-05 业主指令）**：`index.families[]` 条目可携带 `availability: "upcoming"`——零档位预告（后期评估入列的家族随目录呈现，下载卡显示「即将上线」并隐藏下载控件）。发布侧闸：families 多于模型集的 id 必须全部标记 upcoming，常规家族缺档位 = 硬错；客户端接受闸镜像同一规则（App 不内置任何家族清单，标记语义完全来自目录）。
- **当期矩阵（2026-10-06 v7 全档钉版）**：whisper tiny/base/small/medium/turbo（5 档）+ dolphin base/small（2 档）+ zipformer small（14M 中文）/large（2 档）+ qwen3 medium + sense-voice small + fire-red large（v2 CTC）+ moonshine tiny = **7 家族 13 档**。zipformer 小档为 14M 中文模型（上游无 bpe.vocab）——运行时装配随资产存在性切换 `cjkchar`/`cjkchar+bpe`（`ASRModelAssets.Validated.optionalPath`），构建角色契约同语义（bpe 可选）。fire-red 用 v2 CTC 单文件布局（`fire_red_asr_ctc.model`）；sense-voice 权重许可为 FunASR 模型开源许可协议（`model-license`）。权重钉版纪律：HF resolve 直链 + revision 哈希 + 实测 sha256/bytes；Xet CAS 是块级哈希≠文件 sha256，不得用作钉版哈希；续传产物必须整文件哈希校验（字节数对齐≠内容完整）。
- **单一 JSON 架构（2026-10-06 业主裁定）**：CNB 只承载**模型包 + 固定名 `manifest.json`**（签名信封，TUF fixed-name 形态——单调 `catalogVersion` 在签名载荷内，回滚防护 = 载荷单调闸 + 客户端持久化回滚守卫；根资产与版本化目录/回执不再上传）。仓库 `Resources/ASRModelUpdates/manifest.json` 是唯一数据文件（家族 + 全档位 + 能力描述；旧 `index.json`/`N.catalog.json` 已退役）。`publish` 开关已删除——workflow 一气呵成：构建 → 现场签名（`ASR_SIGNING_KEYS_JSON`，无密钥=硬错）→ 验证 → 发布 CNB（幂等 upsert + 回读核对）。包命名去重段：`<id>-<variant>-<上游版本>-<builtAt>-r<N>.zip`（version 不再内嵌档位名）。App 侧发现链：tag 页确认 `manifest.json` 存在 → 固定名下载 → 验签（目录 + 逐包 `packageSignature`）。
- **zip 包级签名（2026-10-06 业主指令）**：签名器对每包 sha256 摘要做域分离（`vitaliber/asr/package-sha256/v1/` + 32 字节摘要）Ed25519 多重签名，密钥面 = 目录同源 `catalogKeyIDs`（2-of-3），随载荷内 `packageSignature` 分发；App 下载后重算 sha256 先验摘要签名再比对摘要（`ModelCatalogTrustStore.verifyPackageSignature`），验不过 = 硬错不可使用。
- 引擎支持集合（`VoiceEngineChoice` 枚举）只是渲染上限：目录新增家族需先发 App 版本加入枚举；未知 id 被旧 App 静默跳过。

## 工作流

### TestFlight

`.github/workflows/build-testflight.yml`：

```
version.txt 校验 → L0 → macOS CoreKit 测试 → iOS 编译/单元/UI
  → 签名归档 → IPA 校验（框架 minOS/路径安全）→ 上传 TestFlight
```

2026-10-06 业主指令：ASR/LLAMA 构建步骤已自 TestFlight 链删除——模型构建与发布由本工作流（release-asr-models.yml）独立承担（CNB 发布面 + 目录驱动矩阵），App 随包模型改为运行时按签名目录自 CNB 下载，IPA 不再内置基线模型；ASR 数据校验（test-asr-assets.py / fetch-asr-models.py --manifest-only）随之收口到本工作流的「校验构建、签名及版本规则」步。

### 独立或可调用的 ASR 构建

`.github/workflows/release-asr-models.yml` 同时声明 `workflow_call` 和 `workflow_dispatch`。

手动构建并发布：

```bash
gh workflow run release-asr-models.yml --repo robinhoo1973/Vita-Liber -f publish=true
```

其他 workflow 调用：

```yaml
jobs:
  asr-models:
    uses: ./.github/workflows/release-asr-models.yml
    permissions:
      contents: write
    with:
      publish: true
```

它会：

1. 运行版本、包、签名与发布规则回归。
2. 优先复用已发布且哈希匹配的模型包作为构建缓存，并核对上游清单；缓存不可用时获取已钉版权重。
3. 按源清单 families 生成完整 ZIP（2026-10-05 目录驱动：家族集与档位随清单，如 whisper 三档 base/small/medium、zipformer 两档 small/large、dolphin 两档 base/small、qwen3 单档 0.6B——各按上游可得性）。每包 `url` 含 id-variant-version-builtAt-revision 段；顺序/时间戳固定；缓存下载地址不影响包内容。
4. 逐包校验整体 SHA/字节、每个声明文件的 SHA/字节、ZIP CRC、路径/成员类型/展开上限，以及完整推理角色与许可。
5. 生成 App 的离线基线 bundle（按源清单 `bundledModels` 声明的家族/档位）。
6. `publish=true` 时，生成索引必须与仓库已签名目录完全一致，才发布到 `asr-models`。模型资产按业主 R2 哈希比对：与 CNB 已有同名文件相同则跳过上传，不同则更新上传（overwrite）；信任资产（N.root.json / N.catalog.json / 校验回执）只增不改——同版本异字节 = 硬错，内容变化必须升版本（2026-10-05 审查）。自 2026-10-05 起下载包整体进 aes256gcm-v1 加密信封（R1：加密+压缩；主密钥 = CI secret `ASR_PACKAGE_KEY`，与 App 内嵌 `ASRPackageCrypto.masterKeyHex` 同值），index sha256/bytes 覆盖信封字节。
7. 通过支持 draft 的 GitHub CLI 查询恢复发布过程，全部资源就绪后发布，且不标成 App 的 latest Release。

输出 artifact：`bundle_artifact`（App 离线基线，被 build-testflight 消费）；`packages_artifact`（全部加密模型 ZIP、索引与校验回执）与 `metadata_artifact`（轻量索引与校验回执，供发布者离线签名，无需下载模型到本地）仍上传、从 run 页人工取用，不再作为 workflow 输出面（2026-10-05 审查）。

## 更新模型与签名（方案 B）

App 内置公钥根和每次编译生成的已知哈希基线。目录使用 Ed25519 签名；根/目录角色各为独立 2-of-3，支持连续根轮换、有效期、单调版本和撤销。未来模型经签名目录授权，不能只依据网络自报 SHA。

源码中的公开配置：

```
Resources/ModelTrustRoot.json              App 启动信任根
Resources/TrustedModelHashes.json         当前公开基线（构建时重新生成）
Resources/ASRModelUpdates/index.json       模型发布描述
Resources/ASRModelUpdates/catalog.json     已签名动态目录
Resources/ASRModelUpdates/N.root.json      版本化公开根
```

修改权重或打包配方时，先构建候选：

```bash
gh workflow run release-asr-models.yml --repo robinhoo1973/Vita-Liber -f publish=false
```

从该次运行下载轻量 `asr-metadata-<run-id>-<attempt>` artifact：CI 已注入 `ASR_SIGNING_KEYS_JSON` 时含签名候选目录 `candidate-catalog.json`（缺该 secret 时此步自跳过——目录不变无需轮换）。核对源提交/模型/许可、回执与候选目录载荷后，把 `candidate-catalog.json` 提交为 `Resources/ASRModelUpdates/catalog.json` 与版本化副本。签名密钥由 `generate-asr-signing-keys.py` 本地生成：私钥 JSON 注册为 `ASR_SIGNING_KEYS_JSON` secret（不进仓库），新根 envelope 人工提交入仓；目录续签与根轮换均经此流程。

把新的公开配置提交并部署后，再运行 `publish=true`。生成字节与签名不一致会失败，不能通过更新远端自报哈希规避。

## README 同步（CNB 资源仓，2026-10-07 业主定案「方案 B」）

CNB 资源仓 `robinhoo1973/Resources` 的 README 由该仓内 `tools/readme-sync` 模块（CNB 流水线执行）自动维护，三部分：**永久介绍段**（`README-header.md`，逐发布字节稳定；显式修订走 git 历史）+ **人类分节**（标题链接下载页、仅列最新文件；ASR 按家族分块，描述文案在 `sections.json`）+ **尾部 `VL-INDEX v1` 加密索引**（payload JSON → 单 entry ZIP → aes256gcm-v1 信封，identity=`update-payload-<sha256(明文)>`，密钥 = App 内嵌公开常量；载荷是提示索引、**非信任源**，App 以签名目录/信任根为准；载荷含每 release 的 latest/history/unclassified 与名称/URL/大小/sha256）。

**触发链（方案 B）**：发布步骤成功收尾后，`publish-asr-release.py` 调 `CNBReleaseClient.start_readme_sync("asr-models")`（`POST {repo}/-/build/start`，事件 `api_trigger_readme_sync`，env `README_SYNC_TAG`，`sync="false"` 异步；令牌需 `repo-cnb-trigger:rw`，`CNB_RESOURCE_TOKEN` 实测已含）。触发失败 = `::warning::` 不阻塞发布（通知通道纪律）；同步管线幂等（无变化零推送），可经 CNB 页面「同步 README」按钮（`web_trigger_readme_sync`，可输入 tag）手动重同步。

**同步管线纪律**：资源仓不声明 push 事件（README 回写不再次触发流水线，防回环）；流水线锁 `readme-sync` 串行（单写者）；非 force push（≤3 次 fetch+rebase 重算）；git + blob（SSR）双读回；README 尾块存在但畸形 = **硬错**（不静默重建、不销毁历史）；依赖 `cryptography==49.0.0`（`--require-hashes`，与 `requirements-model-tools.txt` 同源）。

## 密钥引导与轮换（ASR_PACKAGE_KEY）

下载包加密主密钥与 App 内嵌 `ASRPackageCrypto.masterKeyHex` 同值；`test-asr-package-integrity.py` 断言三处一致（CI secret / App 内嵌 / 测试常量），漏改任何一侧 CI 即红。

**引导（本地脚本，一次性）**：`gh auth login` 后执行 `python3 scripts/release/init_asr_secrets.py --repo robinhoo1973/Vita-Liber`——自动生成 32 字节密钥、注册 `ASR_PACKAGE_KEY` secret、改写 App 内嵌常量与测试常量；随后提交推送两处改写。CI 不参与生成与注册，只在「包加密密钥前置校验」步判断有值（缺失/为空 = 带日志硬错）。

**轮换语义**：删除 secret 后重跑脚本 = 新密钥。旧密钥加密的已发布包对新 App 全部不可解，必须随后全量重发布（新目录版本 + 全部包重加密）；因此除非密钥泄露，否则不轮换。secret 已存在但与内嵌值不一致时同样硬错（发布 App 解不开的包比红更糟）——恢复路径同上：删除 secret 后重跑自动对齐。

**签名密钥例外**：`ASR_SIGNING_KEYS_JSON` 不做自动生成——目录签名私钥与提交入仓的信任根强耦合（新密钥必须伴随新根 envelope 人工提交，否则 App 拒绝候选目录），保持 `generate-asr-signing-keys.py` 本地生成 + 人工提交的流程。

## 验证边界

本机 Python 验证涵盖脚本/协议和完整包；Linux sherpa 原生加载检查不等于 iPhone 准确率验收。Swift App/Infrastructure 的类型检查、单元/UI 和归档在 macOS CI；iPhone 11 Pro / iOS 26.6.2 上另测实际方言/混说质量、内存和耗时。

## 变更记录

- V1.4（2026-10-07）：README 同步（方案 B 触发链）：发布成功后经 `CNBReleaseClient.start_readme_sync` 触发资源仓 `api_trigger_readme_sync` 管线（`repo-cnb-trigger:rw`；失败仅 `::warning::` 不阻塞发布）；资源仓 README 三部分自动生成（`tools/readme-sync` 模块）/ VL-INDEX v1 加密索引 / 流水线锁 + 非 force push + git/blob 双读回 + 尾块畸形硬错纪律。
- V1.3（2026-10-06）：13 档全矩阵（7 家族实档）与单一 JSON 架构（manifest.json 固定名 + 包级 Ed25519 签名 + publish 开关删除 + 命名去重段）；CNB 资产面收敛为「模型包 + manifest.json」。
- V1.2（2026-10-05）：模型家族与档位改为目录驱动（families[]/tierName/tierHint 单一事实源，App 零内置模型数据表；引擎支持枚举只是渲染上限）；基线剖面按 bundledModels 声明裁剪；加密信封帧合同修正（nonce 不入帧）与 nonce 派生长度合同（python len=12 == Swift 32 字节派生前缀 12，RFC 5869 前缀性质）；HKDF 改为 HMAC 原语手动展开（CryptoKit 泛型糖 macOS CI 两轮过载解析失败 37315378507/37327812812，已记录例外，金样测试钉字节一致）。
- V1.1（2026-10-05）：ASR_PACKAGE_KEY 本地脚本引导（`init_asr_secrets.py`：生成 → 注册 secret → 改写内嵌密钥，CI 只做有值校验）+ 轮换语义与签名密钥例外说明；签名流程更新为 CI 候选签名 + 人工提交目录；`workflow_call.secrets` 的 `required: true` 降级为 job 内前置校验（消除无日志 startup_failure 族）。
- V1.0（2026-09-12）：Releases-only、version.txt、独立/可调用 ASR 构建、runner 临时产物与签名动态更新合同。
