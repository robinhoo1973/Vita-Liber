# ASR 下载文件与 TestFlight 工作流

> 版本：V1.19（2026-10-09）

## 版本与资产来源

- **App release 版本**：根目录 `version.txt`，一行 `major.minor.patch`，当前 `0.0.1`。GitHub Release/tag 不决定 App 版本。
- **TestFlight build 号**：`run_number.run_attempt`；代码标识取当前提交 hash。
- **ASR 模型版本**：`Resources/ASRModels/manifest.json` 的批准上游来源，以及 `Resources/ASRModelUpdates/manifest.json`（签名信封）的发布版本（`catalogVersion`，全链单调）/制作日期/打包修订。
- **分发**：CNB 资源仓 `robinhoo1973/Resources` 的 `asr-models` Release——固定名 `manifest.json` 是唯一权威目录（TUF fixed-name）；GitHub Releases 不再承载模型资产。同批发布固定名 `overview.json`（V1.9 恢复批）：
  家族×档位**人读概览**（非权威展示件——安全/安装判定一律以签名目录为准；由 `asr_overview.py` 从签名载荷纯函数生成，可重跑同字节；生成/上传失败仅 `::warning::` 不阻塞）。
  发布成功后 `readme-sync` 触发并**下游确认**：`GET /-/build/status/{sn}` ≤5×15s 轮询（V1.16：3×10s 实测两次 marginal 超窗——success 实测需 ~40s，窗口放宽），非 success 仅告警（V1.9）。

## config（模型目录配置，2026-10-07 业主指令）

- **单一手工维护面**：`.github/config/asr/models.json`（业主指定目录 = `.github/config`）——每条目含 `watch`（上游发现规则：`hf-repo` = HuggingFace 仓库、revision 为 commit；`github-release` = GitHub Release 资产（asset 通配）；`github-commit` = raw.githubusercontent 静态文件）+ `versionPolicy`（版本标签派生规则）+ 文件布局（`member`/`url` 恰一；member 型 URL 由生成器按 watch 文法合成）+ pin 值（`revision`/`bytes`/`sha256`）。
- **投影**：`generate-asr-source-manifest.py` 把 config 纯投影为 `Resources/ASRModels/manifest.json`；**逐字节复现**为迁移验收基准（`test-asr-config-projection.py`），`--check` 为漂移闸。
- **上游新版采纳（业主 2026-10-07 裁决）＝全自动（V1.11 落地）**：`asr.yml` 每次 run 先执行「解析上游最新版」步（`resolve-asr-models.py`）——hf-repo 取模型 API `sha`、github-release 取最新匹配资产（versionRegex 提取版本段）、github-commit 取该文件路径最近 commit；**内容有变才滚动 pin**（下载实测 bytes/sha256；元数据类提交按内容等值处理，不产生重建），解析失败保留现行 pin 仅 `::warning::`，实测失败 = 硬错（fail-closed）。解析结果经「投影源清单并暂存」步（config → manifest.json）进入 prepare；build 对已滚动条目**动态派生身份**（version = versionPolicy 派生 / builtAt = 当日 / artifactRevision = r+1）强制重建；无变化条目全量复用。次源锁定文件（各 notice）不参与自动追踪。

## 文案链（2026-10-08 委员会终裁：明文 copy 源 + 签名前投影）

- **唯一文案手工面**：`.github/config/asr/catalog-copy.json`（明文可 diff/可 PR 评审）——families：`name/hint/strengths/limitations`（**strengths/limitations 为签名点必填**，三语、每值 ≤1024B）；tiers：`tierName/tierHint`（沿用 4096B 上限）；可选 `changeNote` 按 `(id, variant, upstreamRevision)` 键控（revision 不符自动不发射——陈旧说明不可能变成谎言）。
- **投影**：`apply-asr-catalog-copy.py` 在 **build 之后、签名之前**把文案覆盖进构建索引（保序：families 顺序 = auto 链优先序；行为字段 languages/dialects/availability 与全部身份字段零触碰；文案改动**零重建、零本地重签**）。fail-closed：覆盖缺口/三语不齐/超长/**负清单词**（绝对化·推荐语义·医疗结论，zh/zh-Hant/en 三语表）/未知 (id,variant) 一律硬错。
- **R3 闸扩展**：签名点要求 families 必带 strengths/limitations——投影步被误删时硬红，**绝不静默回退模板旧文案**。
- **「最新变化」**：`overview.json` 增 `changes` 块（非签名面；added/updated/removed + 版本迁移，判定与发布页增量行共用单源 `asr_change_set.py`；previous 缺失/同版本 → 整块 null，绝不解释）。App 不消费 changes；签名载荷保持确定性。
- **模板文案字段**：保留为**生成物缓存**（App 离线基线经 `build_baseline` 嵌模板内容，删除=改 App 合同）；刷新方式=提交某次 run 的 metadata_artifact（现场签名信封）回仓（顺带闭合信封时效与版本滞后，见下）。
- **信封刷新规程（治理）**：仓库模板信封 `expiresAt` 为签发 +30 天（当前 v10 → **2026-11-06 到期**，2026-10-08 按仓库模板 payload 实证核对）；逾期后果 = TestFlight preBuild（`model-trust.py build` 验签）全红。刷新=**提交最近一次 run 的 `asr-metadata-*` artifact 中的 manifest.json 回仓**（三合一：时效 + repo/远端版本对齐 + 模板文案缓存刷新）；`catalogVersion` 无需与远端强对齐（next-catalog-version 取 max，模板仅是地板；禁止把模板版本号抬到远端之上——App 基线同版本异字节=rollback 拒收）。
- **发布前模板验签（V1.12 补闸）**：`asr.yml`「校验构建、签名及版本规则」步内新增 `model-trust.py verify --root … --catalog Resources/ASRModelUpdates/manifest.json`——此前 Linux 链无人验模板签名，「改模板不重签」可经 CI 重签发布、直到 macOS App 构建才翻车；现在发布前硬红闭合该盲路。（不进 L0：该验证含挂钟时效，L0 必须时间无关。）

**文案链 P2 登记**：①AI 离线草拟工具（本地、人审、内容寻址缓存；CI 零 AI 供应商——四席一致裁决）；②`families[].languages` 语义修复（whisper 目录 [zh,en] vs 上游 100 语种、fire-red [zh] vs zh_en；**行为数据，需业主裁决**，或拆 covers/autoEligible）；③NOTICE.md 补署名 sense-voice/fire-red/moonshine（⚠ 需 13 包全量重建+重传，GB 级成本）；④README `sections.json` 与 copy 单源统一；⑤overview 上游 member 级变化（resolver report 接线）；⑥App 展示批（详情页 tierHint、strengths/limitations、changeNote 上屏）。

## bootstrap（按名启动，2026-10-08 业主目标）

- **目标**：「给出几个模型名称即可启动」——候选条目由搜索抓取生成、人工过目一次后合并，其后全自动（resolver 追新 → 投影 → 发布）。
- **工具**：`bootstrap-asr-model.py`（**本地/离线工具；CI 不运行、零 AI 依赖**）：
  - 发现层 = 官方**结构化 API 优先**（HF `/api/models?search=` 按名检索、可限作者域；GitHub releases 资产名匹配）——免费、无限额、确定可复现；通用搜索引擎仅在结构化 API 无命中时人工补充（免费档 Tavily/Exa 或自建 SearXNG；CI 发布链保持零外部搜索依赖）；
  - 探针层 = **下载实测** bytes/sha256（钉版纪律：Xet CAS 块哈希不可用）+ 成员角色推断（preprocess/encode/uncached_decode/decoder/joiner/model/tokens/bpe/…）+ 许可启发（LICENSE 成员内容）；
  - 组装层 = draft（models.json 条目候选 + copy 骨架 + 溯源）；`--compare-config` 逆测对账：与现有条目逐字段比对（match / mismatch / cosmetic 三分——路径约定差异只算外观），证明「从名字可复得人工钉版」。
- **边界**：机械字段（repo/revision/哈希/字节/角色）自动；档位映射语义、许可判定、文案表述 = 人工确认一次。
- 契约测试第 18 例 `test-bootstrap-asr-model.py`（纯函数面）入双侧执行列。
- **家族种子层（V1.15，业主口径）**：`.github/config/asr/seeds.json` **只放家族名**（7 条：whisper/zipformer/dolphin/sense-voice/fire-red/moonshine/qwen3）——repo 与档位规格全部由工具自找：
  - `--from-seeds` 默认=**家族档位清单（轻层，API 零下载，秒级）**：逐家族列候选镜像仓的在册（`in-config:`，按 watch.repo 精确匹配）/未收录（`new-candidate`）状态，以及对「钉版仓库未在候选出现」的发现层回归告警。**实测 13/13 在册、钉版缺候选 0、未知 0；另发现 128 个未收录候选（拓展空间）**；
  - `--from-seeds --probe [--only <家族>]`=**深探验证**：对在册候选下载实测（bytes/sha256 + 角色推断）并与现有条目逐字段对账（match/mismatch/cosmetic 三分）——重下载，人工触发的验证运行；**口径（V1.16）：「13/13 在册」属轻层（API 零下载）清单；深探=12/13 档复现**——qwen3 为 `github-release` 型，probe 仅覆盖 `hf-repo`，其字节复现由 verify job 下载补测承担；
  - 发现层两账号域（csukuangfj + csukuangfj2，fire-red 在后者的实测修复）+ 词边界身份识别（连字家族 sense-voice/fire-red 拆词扫描曾全数失配）+ qwen3 按 tag 单发布查询（全量 releases 响应 287 资产超 8MB 读取上限截断的实测修复）。
- **轻依赖拆分（V1.15）**：家族/档位常量拆至 `asr_constants.py`——漂移/bootstrap 等轻工具免装 cryptography（CI maintenance 漂移 job `ModuleNotFoundError` 实证；asr_package 继续 re-export，消费面零改动）。
- **漂移周检（V1.14，方案三落地）**：同一工具的 `--from-config` 模式被 `maintenance.yml` 的 `catalog-drift` job 消费——**模型名自 `.github/config/asr/models.json` 自动获取（零 Actions 输入）**；调度=每周一 UTC 03:23 cron + 手动 dispatch；逐条 API 级检查（镜像仓修订滚动=info；**钉版成员缺失 / 归档远端缺位=::warning::**；网络形状失败=unknown）；报告上传 artifact `asr-catalog-drift`，**不红灯**（cron 静默）；只读权限（`contents: read`）；哈希级验证由发布链承担。**边界**：silero 共享件未纳入 v1。
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

`.github/workflows/testflight.yml`：

```
version.txt 校验 → L0 → macOS CoreKit 测试 → iOS 编译/单元/UI
  → 签名归档 → IPA 校验（框架 minOS/路径安全）→ 上传 TestFlight
```

2026-10-06 业主指令：ASR/LLAMA 构建步骤已自 TestFlight 链删除——模型构建与发布由本工作流（asr.yml）独立承担（CNB 发布面 + 目录驱动矩阵），App 随包模型改为运行时按签名目录自 CNB 下载，IPA 不再内置基线模型；ASR 数据校验（test-asr-assets.py / fetch-asr-models.py --manifest-only）随之收口到本工作流的「校验构建、签名及版本规则」步。

### 独立或可调用的 ASR 构建

`.github/workflows/asr.yml` 同时声明 `workflow_call` 和 `workflow_dispatch`。

手动构建并发布：

```bash
gh workflow run asr.yml --repo robinhoo1973/Vita-Liber
```

其他 workflow 调用（无输入；发布一气呵成）：

```yaml
jobs:
  asr-models:
    uses: ./.github/workflows/asr.yml
    secrets: inherit
```

它会：

1. 运行版本、包、签名与发布规则回归。
2. 优先复用已发布且哈希匹配的模型包作为构建缓存，并核对上游清单；缓存不可用时获取已钉版权重。
3. 按源清单 families 生成完整 ZIP（2026-10-05 目录驱动：家族集与档位随清单，如 whisper 三档 base/small/medium、zipformer 两档 small/large、dolphin 两档 base/small、qwen3 单档 0.6B——各按上游可得性）。每包 `url` 含 id-variant-version-builtAt-revision 段；顺序/时间戳固定；缓存下载地址不影响包内容。
4. 逐包校验整体 SHA/字节、每个声明文件的 SHA/字节、ZIP CRC、路径/成员类型/展开上限，以及完整推理角色与许可。
5. 版本推进（`next-catalog-version.py`，2026-10-07 单调修复）：取 仓库信封 / CNB 远端固定名 manifest / git 历史 三源 `catalogVersion` 的 **max + 1**（地板 6）；远端非 404 异常（网络/5xx/形状）= 硬错，绝不静默降版本。发布前链校验读取版本化根：`--root-store Resources/ASRModelUpdates`。
6. 现场签名（`ASR_SIGNING_KEYS_JSON`，无密钥=硬错）→ 验证 → 发布 CNB：模型资产按业主 R2 哈希比对（同名同摘要复用、异内容 overwrite 更新）；固定名 `manifest.json` 覆盖更新，同版本异字节 = 等价歧义硬错（发布侧对远端做单调闸 + 同版比字节）。下载包整体为 aes256gcm-v1 加密信封（R1：加密+压缩；主密钥 = CI secret `ASR_PACKAGE_KEY`，与 App 内嵌 `ASRPackageCrypto.masterKeyHex` 同值）。
7. 发布成功后触发资源仓 README 同步（见下节；失败仅告警，不阻塞发布）。

输出 artifact：`packages_artifact`（全部加密模型 ZIP、签名目录与校验回执）与 `metadata_artifact`（轻量索引/签名目录与校验回执，run 页人工取用）上传留档；`bundle_artifact` 随 2026-10-06 业主指令（IPA 不再内置基线模型、App 运行时按签名目录下载）退役。

## 更新模型与签名（方案 B）

App 内置公钥根和每次编译生成的已知哈希基线。目录使用 Ed25519 签名；根/目录角色各为独立 2-of-3，支持连续根轮换、有效期、单调版本和撤销。未来模型经签名目录授权，不能只依据网络自报 SHA。

源码中的公开配置：

```
Resources/ModelTrustRoot.json              App 启动信任根（当前根信封，签名用）
Resources/TrustedModelHashes.json         当前公开基线（构建时重新生成）
Resources/ASRModelUpdates/manifest.json    唯一数据文件（签名信封；家族+全档位+包级签名）
Resources/ASRModelUpdates/N.root.json      版本化公开根（1/2；链校验 --root-store 读取）
```

修改权重或打包配方：直接 dispatch（无输入）——构建 → 现场签名（`ASR_SIGNING_KEYS_JSON`）→ 验证 → 发布 CNB → 触发 README 同步，一气呵成：

```bash
gh workflow run asr.yml --repo robinhoo1973/Vita-Liber
```

目录签名密钥由 `generate-asr-signing-keys.py` 本地生成：私钥 JSON 注册为 `ASR_SIGNING_KEYS_JSON` secret（不进仓库）。**根轮换**仍为人工流程：新根 envelope 人工提交入仓（`Resources/ASRModelUpdates/N.root.json` + `Resources/ModelTrustRoot.json`）；旧根签的目录重签进新根时沿用全链单调 `catalogVersion`（发布侧跨根回滚闸拒绝回退）。生成字节与签名不一致会失败，不能通过更新远端自报哈希规避。

## README 同步（CNB 资源仓，2026-10-07 业主定案「方案 B」；索引载体 = 二维码）

CNB 资源仓 `robinhoo1973/Resources` 的 README 由该仓内 `tools/readme-sync` 模块（CNB 流水线执行）自动维护，三部分：**永久介绍段**（`README-header.md`，逐发布字节稳定；显式修订走 git 历史）+ **人类分节**（标题链接下载页、仅列最新文件；ASR 按家族分块，描述文案在 `sections.json`）+ **App 索引（`vl-index.png` 二维码数据载体**，2026-10-07 业主裁决；纯数据载体、无需扫描）。

**索引语义**：payload JSON（每 release 的 latest/history/unclassified，含名称/URL/大小/sha256；历史**每 tag 只保留最近 3 条**）→ 单 entry ZIP → aes256gcm-v1 信封（identity=`update-payload-<sha256(明文)>`，密钥 = App 内嵌公开常量）→ QR 内容 = identity 前缀(79B) + 信封字节二进制直编（ECC-L）。载荷 ≤ 预算 2800B 走 QR，**超限自动降级文本块**（双形态）。载荷是提示索引、**非信任源**，App 以签名目录/信任根为准。`vl-index.payload`（state 文件，= QR 内容字节）是模块 RMW 的唯一事实源（git 历史即备份）。

**App 读取通道（实证）**：`https://cnb.cool/robinhoo1973/Resources/-/git/raw/main/tools/readme-sync/vl-index.png`（匿名 200；与 README 页 `<img>` 渲染同源）。解码双路径（本地实证 zxing 逐字节命中、zbar 走 Latin-1 映射可逆向）：Vision `payloadData`（原始字节，可能含 QR 段结构需按位剥离；**iOS 17+/macOS 14+——App 部署目标 iOS 16，经 `#available` 守卫在 iOS 16 走字符串回退**）优先，`payloadStringValue`→`.isoLatin1` 回退；macOS CI 金色测试（本仓 PNG+state 字节对拍）为 App 侧合入门槛。**注意（2026-10-07 评审纠正）**：Vision 不可用时服务器侧切回文本形态（`QR_PAYLOAD_BUDGET=0`）会**删除 `vl-index.png`**（readme-sync `removes.append(png_path)`）——App 通道整体显示「不可用」（fail-closed），**并非**「常量一改、向后兼容」；恢复需回切 QR 形态，或待后续批次（state 文件直读机制）落地。

**触发链（方案 B）**：发布步骤成功收尾后，`publish-asr-release.py` 调 `CNBReleaseClient.start_readme_sync("asr-models")`（`POST {repo}/-/build/start`，事件 `api_trigger_readme_sync`，env `README_SYNC_TAG`，`sync="false"` 异步；令牌需 `repo-cnb-trigger:rw`，`CNB_RESOURCE_TOKEN` 实测已含）。触发失败 = `::warning::` 不阻塞发布（通知通道纪律）；同步管线幂等（无变化零推送），可经 CNB 页面「同步 README」按钮（`web_trigger_readme_sync`，可输入 tag）手动重同步。

**同步管线纪律**：资源仓不声明 push 事件（README 回写不再次触发流水线，防回环）；流水线锁 `readme-sync` 串行（单写者）；非 force push（≤3 次 fetch+rebase 重算）；四通道读回——git（硬）+ blob（软）+ `/git/raw` README（软）+ `/git/raw` PNG（硬，App 通道）；state/尾块存在但畸形 = **硬错**（不静默重建、不销毁历史）；依赖 `cryptography==49.0.0` + `qrcode==8.2`/`pypng`（`--require-hashes`）。

## 发布页正文（三语永久头 + 动态段，2026-10-07 委员会 S3）

`asr-models` 下载页正文 = **永久头**（`cnb-release-notes/asr-models.md`：三语 简/繁/英 介绍用途/权威声明/更新方式，创建时写入、原样复用；本轮同时清除了旧模板的过期「numeric versioned catalog」表述）+ **动态段**（`asr_release_page.py` 生成，简→繁→英）：

- 版本三元组（目录版本/信任根版本/构建/签发时间——全部取自签名载荷，零墙钟，重跑同字节）；
- 家族×档位统计表（家族名/档位名/合计大小，文案零新增——直接复用签名载荷的三语字段）；
- 增量行（与上一版签名载荷 diff：新增/更新/移除档位；无基线或同版本重跑=整行省略；取不到静默省略，绝不解释原因）。
- **硬规则**：动态段不列文件名/URL/哈希；不出现数据来源或失败措辞（负样例测试钉住）。

**刷新机制**：`CNBReleaseClient.update_release_body`（PATCH + 回读比对，有界 3 次；不存在=硬错绝不隐式创建）。调用点在提交点之后（manifest 上传与资产齐备检查之后、README 触发之前）；失败 = `::warning::` **绝不阻塞发布**（页面是展示面；此前无 PATCH 能力导致的错误正文永滞问题由此解除——下一次任意发布即自动修正）。

## 密钥引导与轮换（ASR_PACKAGE_KEY）

下载包加密主密钥与 App 内嵌 `ASRPackageCrypto.masterKeyHex` 同值；`test-asr-package-integrity.py` 断言三处一致（CI secret / App 内嵌 / 测试常量），漏改任何一侧 CI 即红。

**引导（本地脚本，一次性）**：`gh auth login` 后执行 `python3 .github/actions/release/init_asr_secrets.py --repo robinhoo1973/Vita-Liber`——自动生成 32 字节密钥、注册 `ASR_PACKAGE_KEY` secret、改写 App 内嵌常量与测试常量；随后提交推送两处改写。CI 不参与生成与注册，只在「包加密密钥前置校验」步判断有值（缺失/为空 = 带日志硬错）。

**轮换语义**：删除 secret 后重跑脚本 = 新密钥。旧密钥加密的已发布包对新 App 全部不可解，必须随后全量重发布（新目录版本 + 全部包重加密）；因此除非密钥泄露，否则不轮换。secret 已存在但与内嵌值不一致时同样硬错（发布 App 解不开的包比红更糟）——恢复路径同上：删除 secret 后重跑自动对齐。

**签名密钥例外**：`ASR_SIGNING_KEYS_JSON` 不做自动生成——目录签名私钥与提交入仓的信任根强耦合（新密钥必须伴随新根 envelope 人工提交，否则 App 拒绝候选目录），保持 `generate-asr-signing-keys.py` 本地生成 + 人工提交的流程。

## LLM 辅助草拟与蒸馏合并（2026-10-08 旁路 → 2026-10-09 入流;业主指令 + 委员会定案）

- **模块化（2026-10-09 业主指令）**：通用内核抽为 `release/llm_client.py`
  （`llm_chat`/内容寻址缓存/JSON 块容错/`make_chat`；逐字抽取，行为不变——
  `suggest-asr-metadata.py` 改为导入）。新增消费者 `draft-release-text.py`：
  `--mode release-notes` 由公开事实（tag/资产清单/上版说明）草拟三语 Release
  变更说明；`--mode readme-block` 草拟 readme-sync `sections.json` 的分节文案
  （intro+blocks）。**只写 `--out` 侧车目录，绝不触碰权威模板与 sections.json**
  （采纳 = 人工誊写）；两消费者同受下方治理条款约束。端点缺省本机 llama-server，
  在线免费档（智谱 GLM-4.7-Flash：`--endpoint https://open.bigmodel.cn/api/paas/v4
  --model glm-4.7-flash --api-key-env LLM_API_KEY`）。
- **形态（两段工具）**：`suggest-asr-metadata.py`（建议侧车
  `suggested/*.suggested.json` + `errors.json` 台账;429/5xx 指数退避;
  `--max-seconds` 总时限,重试预算不得超 job timeout;逐字段容错,部分成功照常
  落盘）→ `distill-asr-metadata.py`（逐项择优:**确定性为真值底,LLM 只填空缺**
  （REVIEW/空串/空 prefix）;哨兵字符串归一（模型误写的 "null"）;置信度阈值
  `--min-confidence`;与投影器同源负清单复检;provenance 报告
  adopted/shadowed/rejected/leftOpen/orphans）。
- **入流（2026-10-09 业主指令）**：asr.yml ③ 草案 → ④ 草拟（非阻塞:
  `if: !cancelled()` 语义 + 显式降级告警）→ ⑤ 蒸馏（结构闸:REVIEW / variant=null /
  seeds 家族覆盖 / 条目缺口（files 与 archive 双面皆空）= 硬红）;⑥ 上游解析起
  全链消费**蒸馏终稿**（models.json → rolling pin;catalog-copy.json → ⑧ 文案
  投影）,⑪⑫ 验收挂 ⑤。
- **引擎**：智谱 GLM-4.7-Flash（免费档;密钥经 repo secret `LLM_API_KEY`）;缺省
  端点 `open.bigmodel.cn`（z.ai 注册 key 同宗;端点一行切换）;内容寻址缓存
  （prompt‖model‖温度‖seed 的 sha256）经 actions/cache 跨 run 复用——候选未变时
  零调用（免费档日配额有限,run 37860771905 实证限流全败=降级照走）。
- **治理条款（2026-10-09 修订）**：①只发公开模型元数据（禁私仓/密钥/用户数据）;
  ②在线来源必标 vendor@版本;③内容寻址缓存,换模型/参数=新键;④文案建议先过**与
  投影器同源**的负清单预检（投影器仍为终闸）;⑤许可三段式改为:LLM 建议 →
  阈值采纳（conf ≥ --min-confidence）→ provenance 全量留档（蒸馏报告）;
  ⑥**修订**（业主 2026-10-09 指令）:原「CI/发布链零 AI 零外部搜索」改为——
  LLM 建议经**阈值 + 负清单 + provenance** 后可参与终稿生成;确定性为真值底、
  AI 仅填空缺、可全量审计;投影器/签名仍为终闸;⑦「禁本地跑 asr 任务」不覆盖
  纯草拟器/蒸馏器（不下载/不构建/不发布）。
- **反过拟合**：确定性实测面不被建议覆盖（shadowed 仅参考）;蒸馏报告的 rejected/
  leftOpen 是「LLM 未能补上」的显式台账,不静默。

## LLM 客户端调用标准（llm_client,2026-10-09 业主指令）

**单一出口**：release 链任何 LLM 调用一律经 `.github/actions/release/llm_client.py`
（OpenAI 兼容 `/chat/completions`）;禁止消费者各自实现请求/重试/缓存。现有消费者:
`suggest-asr-metadata.py`（ASR 目录草拟）、`draft-release-text.py`（发布文案草稿）;
后续新增消费者同受本标准约束。

- **接口面**（全部导出,纯 stdlib）：
  `llm_chat(endpoint, model, prompt, *, api_key, temperature=0.2, timeout=180,
  retries=3, backoff=5.0) → str` · `make_chat(endpoint, model, *, api_key_env,
  temperature, timeout, retries, backoff) → chat(prompt)`（密钥只经环境变量名注入）·
  `cached_chat(chat, cache_dir, prompt, model, temperature) → (output, cacheKey,
  hit)` · `cache_key(prompt, model, temperature, seed=0)` · `parse_json_block(text)`
  （首个平衡 `{}` 容错解析,失败 None） · `default_cache_dir(slug) →
  ~/.cache/vitaliber-<slug>` · 异常统一 `LLMError`。
- **重试标准**：可重试集 `{429,500,502,503,504}` + 网络抖动;指数退避
  `backoff × 2^attempt`;重试点打 stderr（`SUGGEST-RETRY:`）。重试属**传输层**;
  批级策略（逐字段容错/`--max-seconds` 总时限/`errors.json` 台账/零采纳降级）
  属消费者——两层职责不得混。
- **缓存标准**：内容寻址 `sha256(prompt‖model‖temperature‖seed)`;命中复用
  （`hit=True`）;换模型/参数=新键;CI 内由 actions/cache 跨 run 承接
  （候选未变→零调用,免费档配额友好）。
- **配置标准**：端点 `https://open.bigmodel.cn/api/paas/v4`（z.ai 注册 key
  同宗,端点一行切换）、模型 `glm-4.7-flash`（免费档;日配额有限——限流
  429（1302/1305）=显式降级,绝不静默坏）、密钥=repo secret `LLM_API_KEY`
  经 `--api-key-env` 注入;密钥永不入仓、入日志、入提示词。
- **治理条款**（模块 docstring 同源,全部消费者同受约束）：①只发公开元数据;
  ②输出=建议/草稿侧车,**绝不直写权威文件**（金样/模板/sections.json 须人工采纳）;
  ③在线来源标 vendor@版本;④文案建议先过**与投影器同源**负清单预检;
  provenance 全量留档（蒸馏报告/侧车台账）。

## 验证边界

本机 Python 验证涵盖脚本/协议和完整包；Linux sherpa 原生加载检查不等于 iPhone 准确率验收。Swift App/Infrastructure 的类型检查、单元/UI 和归档在 macOS CI；iPhone 11 Pro / iOS 26.6.2 上另测实际方言/混说质量、内存和耗时。

## 变更记录

- V1.8（2026-10-07）：逃生门语义纠正（委员会评审）：文本形态降级会删除 `vl-index.png`、App 通道不可用（fail-closed）——原文「常量一改，向后兼容」与 readme-sync 实现不符；标注 `payloadData` 的 iOS 17 可用性（iOS 16 经 `#available` 守卫走字符串回退）。
- V1.7（2026-10-07）：发布页正文（委员会 S3）：三语永久头模板重写（清除过期表述）+ `asr_release_page.py` 动态段（版本三元组/家族×档位统计/增量行，全部取自签名载荷）+ `update_release_body` PATCH 能力（回读比对、失败仅告警）——错误正文可随任意发布自动修正。
- V1.6（2026-10-07）：文档与实现对齐（委员会 CI 席清单）：资产来源/分发改写为 CNB 固定名 `manifest.json` 体系（index.json / catalog.json / N.root 残留表述退役）；「publish 开关」残留清除（`-f publish=true`、`with: publish`、candidate 人工提交流程、`bundle_artifact`）；新增版本推进机制（`next-catalog-version.py` max(全源)+1、远端异常硬错、`--root-store` 链校验根）与发布后 README 触发说明。
- V1.5（2026-10-07）：README 索引载体改为**二维码数据载体**（业主裁决）：`vl-index.png` = identity 前缀 + 信封二进制直编（ECC-L，纯数据载体）；`vl-index.payload` state 文件为 RMW 事实源；历史保留改为每 tag 最近 3 条；超 2800B 预算自动降级文本块；App 读取通道 = `/git/raw` 匿名直读（实测）+ Vision 双路径解码规格；QR 生成依赖 `qrcode==8.2`/`pypng` 钉版。
- V1.4（2026-10-07）：README 同步（方案 B 触发链）：发布成功后经 `CNBReleaseClient.start_readme_sync` 触发资源仓 `api_trigger_readme_sync` 管线（`repo-cnb-trigger:rw`；失败仅 `::warning::` 不阻塞发布）；资源仓 README 三部分自动生成（`tools/readme-sync` 模块）/ VL-INDEX v1 加密索引 / 流水线锁 + 非 force push + git/blob 双读回 + 尾块畸形硬错纪律。
- V1.3（2026-10-06）：13 档全矩阵（7 家族实档）与单一 JSON 架构（manifest.json 固定名 + 包级 Ed25519 签名 + publish 开关删除 + 命名去重段）；CNB 资产面收敛为「模型包 + manifest.json」。
- V1.2（2026-10-05）：模型家族与档位改为目录驱动（families[]/tierName/tierHint 单一事实源，App 零内置模型数据表；引擎支持枚举只是渲染上限）；基线剖面按 bundledModels 声明裁剪；加密信封帧合同修正（nonce 不入帧）与 nonce 派生长度合同（python len=12 == Swift 32 字节派生前缀 12，RFC 5869 前缀性质）；HKDF 改为 HMAC 原语手动展开（CryptoKit 泛型糖 macOS CI 两轮过载解析失败 37315378507/37327812812，已记录例外，金样测试钉字节一致）。
- V1.1（2026-10-05）：ASR_PACKAGE_KEY 本地脚本引导（`init_asr_secrets.py`：生成 → 注册 secret → 改写内嵌密钥，CI 只做有值校验）+ 轮换语义与签名密钥例外说明；签名流程更新为 CI 候选签名 + 人工提交目录；`workflow_call.secrets` 的 `required: true` 降级为 job 内前置校验（消除无日志 startup_failure 族）。
- V1.0（2026-09-12）：Releases-only、version.txt、独立/可调用 ASR 构建、runner 临时产物与签名动态更新合同。
- V1.9（2026-10-07）：恢复批——发布面新增签名概览 `overview.json`（人读面：家族×档位/字节统计；非权威）；README 同步触发后增加下游状态轮询确认（触发≠成功，日志出现 `readme-sync 完成: status=success`）；契约测试第 13 例 `test-asr-overview.py` 入双侧执行列（l0-gate action 与 asr.yml）；配套 Resources 仓 readme-sync：QR 尾可见「索引版本 v{n}」行 + asr-models 数据概览块。
- V1.10（2026-10-07）：模型 config 批：新增 `.github/config/asr/models.json`（watch 规则/versionPolicy/pin 值的单一手工维护面）+ `generate-asr-source-manifest.py`（config→源清单纯投影，逐字节复现为迁移验收基准）+ `test-asr-config-projection.py`（第 14 例入双侧执行列）；上游新版采纳裁决为**全自动**（见「config」节）。
- V1.11（2026-10-07）：全自动升级批（业主三焦点指令）——`resolve-asr-models.py`（上游解析：hf-repo / github-release / github-commit 三规则；内容等值不回滚；解析失败保留 pin 仅告警；实测失败硬错；`--plan-only` 观测模式）+ asr.yml 接线（「解析上游最新版」→「投影源清单并暂存」→ prepare/build 消费）+ build 动态身份（`--config`；version/builtAt/r+1）+ 第 15 例 `test-resolve-asr-models.py` 入双侧执行列。
- V1.12（2026-10-08）：文案链批（委员会四席两轮终裁）——明文 copy 源 `.github/config/asr/catalog-copy.json`（唯一文案手工面：name/hint/strengths/limitations + tierName/tierHint + 修订键控 changeNote）+ 签名前投影器 `apply-asr-catalog-copy.py`（fail-closed：覆盖/三语/负清单/超长）；R3 闸扩展（families 必带 strengths/limitations）；overview 增确定性 `changes` 块（单源 `asr_change_set.py`，发布页共用）；迁移改写存量绝对化文案（zipformer「最高质量」、dolphin/zipformer「首选/优选」、英文 highest/best）；发布前模板验签补闸（`model-trust.py verify` 入校验步——闭合「改模板不重签」盲路）；第 16/17 例 `test-apply-asr-catalog-copy.py` / `test-asr-change-set.py` 入双侧执行列；信封刷新规程（2026-11-05 到期）与文案链 P2 登记（见「文案链」节）。
- V1.13（2026-10-08）：bootstrap 批（业主「按名启动」目标）——`bootstrap-asr-model.py`（本地/离线：HF/GitHub 结构化 API 按名发现 → 下载实测探针 + 角色/许可推断 → draft 组装；`--compare-config` 逆测对账三分法）；第 18 例 `test-bootstrap-asr-model.py`（纯函数面）入双侧执行列；配套模板信封已刷新至 v10（提交 run 现场签名目录：时效 +30 天 / 版本对齐 / 文案缓存三合一）。
- V1.14（2026-10-08）：漂移周检批（业主「方案三 + 零输入 + cron」）——`bootstrap-asr-model.py` 增 `--from-config`（模型名自 config 自动获取；漂移三态 ok/drift/unknown）；`maintenance.yml` 增 `catalog-drift` job（周一 UTC 03:23 cron + dispatch；只读；报告 artifact，不红灯）；角色规则修复（旧前缀 glob 对 whisper 系带档位前缀成员名全失配 → 有序正则；漂移 job 遍历全目录的前置——whisper 五档曾会直接报错）。
- V1.15（2026-10-08）：家族种子层 + 热修——`seeds.json` 收窄为 7 家族名（repo/档位由工具自找）；`--from-seeds` 家族档位清单（轻层零下载；13/13 在册实测）+ `--probe` 深探对账；发现层修复三连（双账号域/连字家族词边界/qwen3 按 tag 查询）；`asr_constants.py` 轻依赖拆分（maintenance 漂移 job 免 cryptography；asr_package re-export 零改动）；模板映射测试合成树补件。
- V1.19（2026-10-09）：LLM 客户端调用标准成文（业主指令）——新增「LLM 客户端调用标准（llm_client）」节:单一出口/接口面/重试与缓存标准/配置标准/治理条款五面;`make_chat` 增 timeout/retries/backoff 透传（批级策略归消费者,传输层标准归模块）;`test-llm-client`/`test-suggest-asr-metadata`/`test-draft-release-text` 三测入 L0 电池（双侧执行列对齐）。
- V1.18（2026-10-09）：生成链入流（业主指令）——asr.yml 新 12 段图:③ 草案 → ④ LLM 草拟（非阻塞;429 退避/总时限/逐字段容错/恒落盘+errors 台账/actions/cache 跨 run 复用）→ ⑤ 蒸馏（逐项择优+provenance+结构闸;条目完整口径=files 或 archive 双面）;⑥ 上游解析与 ⑧ 文案投影消费**蒸馏终稿**;⑪⑫ 验收挂 ⑤。配套:发现层全局兜底（域内零命中→无作者域搜索,csukuangfj2 域可达）;download-artifact v4 线→v8.0.2（node24 弃用清理）;TEMP 快车道同闸;候选 artifact 层级契约（单路径上传=扁平化,下载侧直指目标目录+就位断言）。git 金样 config 仍为生成基底（深探对账+手写知识载体:qwen3 型 github-release watch 规则/许可覆盖无法从 seeds 重建）,退役迁移另批评估。
- V1.17（2026-10-08）：LLM 辅助草拟（旁路）——suggest-asr-metadata.py（建议侧车+内容寻址缓存+同源负清单预检；本机 llama.cpp 缺省/在线兼容端点可选）+测试第 19 例入双侧执行列；治理七条（只发公开元数据/在线标注/许可三段式/CI 零 AI 不变）；「禁本地跑 asr 任务」边界=不覆盖纯草拟器。同批:生成链泛化钉（download/families 注入缝+新家族全链离线 e2e,第 28 测）。
- V1.16（2026-10-08）：遗留项批（委员会四席两轮，业主授权自主决策）——①`_confirm_readme_sync` 窗口 3×10s→5×15s；②overview.json 上传后**内容级匿名回读对账**（清单级回读由 `upload_immutable` 内建；内容级不一致仅 `::warning::`，展示面不阻塞）；③build **T4 配对闸**：身份未滚动 + 已签名时，缓存文件存在但摘要不符=硬红（缓存损坏不得被静默重建掩盖）；缓存缺失=显式降级消息后重建（保留冷启动恢复语义）；④publish 逐资产计时打点（skip 形态 ~0.0s 可辨识）；⑤`asr.yml` 增**零密钥验收 job `verify`**（dispatch 并联；`verify_only=true` 时跳过 models 构建/发布——脚本改动唯一零副作用验证通道）：离线契约电池 + bootstrap 复现验收（inventory 13/13 在册/0 缺候选/0 未知；probe 12/12 复现/0 mismatch/0 error）+ qwen3 字节级补测（直连 GitHub 下载面比 sha256+bytes）；闭环判据=一次绿色 verify dispatch。
- V1.18（2026-10-09）：LLM 模块化批（业主指令）——通用内核抽为 `release/llm_client.py`（`llm_chat`/`cache_key`/`cached_chat`/`parse_json_block`/`default_cache_dir`/`make_chat`；行为逐字保持，`suggest-asr-metadata.py` 改为导入 + `SuggestError = LLMError` 别名兼容）；新增 `draft-release-text.py`（release-notes 三语变更说明 / readme-block 分节文案草稿；facts JSON 只含公开内容；负清单预检与投影器同源；只写 --out）；配套 `test-llm-client.py`（6 例）与 `test-draft-release-text.py`（6 例）入双侧执行列；治理条款不变（侧车/缓存/零 AI 裁决），适用于全部消费者。
