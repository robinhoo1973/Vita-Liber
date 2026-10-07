# ASR 下载文件与 TestFlight 工作流

> 版本：V1.8（2026-10-07）

## 版本与资产来源

- **App release 版本**：根目录 `version.txt`，一行 `major.minor.patch`，当前 `0.0.1`。GitHub Release/tag 不决定 App 版本。
- **TestFlight build 号**：`run_number.run_attempt`；代码标识取当前提交 hash。
- **ASR 模型版本**：`Resources/ASRModels/manifest.json` 的批准上游来源，以及 `Resources/ASRModelUpdates/manifest.json`（签名信封）的发布版本（`catalogVersion`，全链单调）/制作日期/打包修订。
- **分发**：CNB 资源仓 `robinhoo1973/Resources` 的 `asr-models` Release——固定名 `manifest.json` 是唯一权威目录（TUF fixed-name）；GitHub Releases 不再承载模型资产。
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
gh workflow run release-asr-models.yml --repo robinhoo1973/Vita-Liber
```

其他 workflow 调用（无输入；发布一气呵成）：

```yaml
jobs:
  asr-models:
    uses: ./.github/workflows/release-asr-models.yml
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
gh workflow run release-asr-models.yml --repo robinhoo1973/Vita-Liber
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
