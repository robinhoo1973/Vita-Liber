# ASR 下载文件与 TestFlight 工作流

> 版本：V1.0（2026-09-12）

## 版本与资产来源

- **App release 版本**：根目录 `version.txt`，一行 `major.minor.patch`，当前 `0.0.1`。GitHub Release/tag 不决定 App 版本。
- **TestFlight build 号**：`run_number.run_attempt`；代码标识取当前提交 hash。
- **ASR 模型版本**：`Resources/ASRModels/manifest.json` 的批准上游来源，以及 `Resources/ASRModelUpdates/index.json` 的发布版本/制作日期/打包修订。
- **分发**：仅 GitHub Releases，资源 Release 为 `asr-models`。ZIP 文件名不可变；App 动态目录为该 Release 的 `catalog.json`。
- 模型下载、生成与校验都在 runner 的 `RUNNER_TEMP` 完成；仓库无 `downloads/` 目录，也不提交模型二进制。

## 工作流

### TestFlight

`.github/workflows/build-testflight.yml`：

```
version.txt 校验 → 调用 ASR workflow → 获取离线基线 bundle
  → L0 → macOS CoreKit 测试 → iOS 编译/单元/UI
  → 每次编译生成并嵌入模型哈希基线 → 签名归档 → 上传 TestFlight
```

离线基线包含 Zipformer（普通话/英语）；较大模型按需从 Release 下载。只有明确声明的 bundledModels 通过逐文件校验后，IPA 资源检查才通过。

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
3. 生成四个完整 ZIP：Qwen3-ASR-0.6B int8、Dolphin-small CTC int8、Zipformer bilingual、Whisper-small int8。顺序/时间戳固定；缓存下载地址不影响包内容。
4. 逐包校验整体 SHA/字节、每个声明文件的 SHA/字节、ZIP CRC、路径/成员类型/展开上限，以及完整推理角色与许可。
5. 生成 App 的 Zipformer 离线基线 bundle。
6. `publish=true` 时，生成索引必须与仓库已签名目录完全一致，才发布到 `asr-models`；已有同名不同内容的 ZIP 拒绝覆盖。
7. 通过支持 draft 的 GitHub CLI 查询恢复发布过程，全部资源就绪后发布，且不标成 App 的 latest Release。

输出三个 artifact 名称：`bundle_artifact`、`packages_artifact`、`metadata_artifact`。最后一个只有索引和校验回执，供发布者签名，无需下载模型到本地。

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

从该次运行下载轻量 `asr-metadata-<run-id>-<attempt>` artifact，核对源提交/模型/许可和回执。发布者用本地 `refactor/scripts/sign-asr-release.py` 对核准索引签名，再更新公开配置；私钥不进入仓库或 CI。签名工具支持目录续签与根轮换。

把新的公开配置提交并部署后，再运行 `publish=true`。生成字节与签名不一致会失败，不能通过更新远端自报哈希规避。

## 验证边界

本机 Python 验证涵盖脚本/协议和完整包；Linux sherpa 原生加载检查不等于 iPhone 准确率验收。Swift App/Infrastructure 的类型检查、单元/UI 和归档在 macOS CI；iPhone 11 Pro / iOS 26.6.2 上另测实际方言/混说质量、内存和耗时。

## 变更记录

- V1.0（2026-09-12）：Releases-only、version.txt、独立/可调用 ASR 构建、runner 临时产物与签名动态更新合同。
