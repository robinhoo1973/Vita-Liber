# 运行时资源下载目录（Runtime Downloads）

本目录是 **App 运行时按需下载资源** 的发布与索引规范目录。首个用途是 ASR（语音识别）模型包；
目录结构按「应用 / 资源类别」分层，后续其他 App 或资源类型（OCR 模型、词库、风格包等）直接平级扩展。

## 目录层次

```
downloads/
  README.md                 ← 本文件：全局规范
  <app>/                    ← 应用标识（如 vitaliber / <other-app>）
    <asset-kind>/           ← 资源类别（asr / ocr / lexicon / …）
      index.json            ← 该类别索引（App 只读这一个文件）
      README.md             ← 类别说明 + 命名规范 + 发布流程
```

> 打包/固化脚本为**发布者本地工具**，位于 `refactor/scripts/`（不入库），用法见「发布流程」。

## 二进制承载策略（重要）

| 事实 | 结论 |
|---|---|
| GitHub 仓库单文件硬上限 **100 MB**（超过直接拒收）；模型包 400 MB–1 GB 级 | **二进制不入 Git**，只入 GitHub **Releases 资产**（单资产上限 2 GB）或对象存储 |
| 本仓库 `.gitignore` 为「默认全私有 + 白名单」 | `downloads/` 已加入白名单，**只跟踪索引**（打包/固化脚本为本地发布工具，不入库）；`*.zip` / `*.onnx` 等二进制被忽略 |
| 索引里需要固定下载地址 | 索引中使用 **`baseUrl` + 相对文件名**（发布时替换 `baseUrl` 为 Release 资产前缀或自有域名） |

> 如果要换自建对象存储（CDN/OSS/S3），只改 `index.json` 的 `baseUrl`，**App 侧无需发版**——这是把地址放在索引而非硬编码的原因。

## 索引规范（index.json）

```jsonc
{
  "schemaVersion": 1,           // 索引结构版本；App 不认识的版本必须拒绝（防降级到未知语义）
  "app": "vitaliber",
  "assetKind": "asr",
  "updatedAt": "2026-09-12",
  "baseUrl": "https://github.com/<owner>/VitaLiber/releases/download/asr-models",
  "models": [
    {
      "id": "qwen3",                     // 与 VoiceEngineChoice.rawValue 一致
      "version": "0.6b-int8-v2026.03.25",// 版本号（含制作日期或语义版本，见命名规范）
      "packaging": "zip",                // 打包格式（当前仅 zip）
      "builtAt": "2026-09-12",           // 制作/提供下载日期
      "bytes": 878702423,                // 包字节数（App 用于分段下载与进度）
      "sha256": "<64 hex>",              // 整包 SHA-256（App 下载后校验，必填）
      "url": "qwen3-0.6b-int8-v2026.03.25-20260912.zip",  // 仅相对 baseUrl 的路径（安全审查 2026-09-12：绝对/协议相对形式一律拒绝）
      "minAppVersion": "1.0.0",          // 可选：低于该版本 App 不提供此包
      "license": "Apache-2.0"
    }
  ]
}
```

## 版本与升级语义（App 侧契约）

1. App 拉取 `index.json` → 与本地已安装版本比对 → 取 **同 id 的最高版本**（版本比较见 `ASRModelRelease.isNewer`）。
2. 下载 → **SHA-256 校验** → 解压到暂存目录 → 逐文件校验（manifest 字节数/SHA） → 原子替换到正式目录。
3. 校验失败/中断：**保持旧版本可用**（先装后切），并在界面上给出可重试的错误。
4. 已安装目录旁保留上一版本，成功运行后按保留策略清理（默认保留 1 个旧版本以便回滚）。
5. **离线优先红线**：下载与索引拉取仅由用户在模型设置页显式触发（[检查更新] / [下载模型] / [更新]按钮；页面出现不自动联网——安全审查 2026-09-12）；**识别会话路径绝不隐式联网**，未安装/未就绪时按既有回落链（平台轨/基线轨）工作。

## 命名规范

`<id>-<version>-<yyyymmdd>.zip`

- `id`：与设置键/枚举 `rawValue` 一致（`qwen3` / `zipformer` / `dolphin` / `whisper`）。
- `version`：模型自身版本（含上游发布日期，如 `0.6b-int8-v2026.03.25`；或语义版本 `1.2.0`）。
- `yyyymmdd`：**本次打包/提供下载的日期**——同一模型可多次重打包（上游修复、量化重制），文件名据此区分。

## 发布流程（发布者）

```bash
# 1. 打包（生成 zip + sha256 + 更新索引）——发布者本地工具，不入库
refactor/scripts/package-asr-model.sh <模型目录> <id> <version> [--base-url <前缀>]

# 2. 固化信任锚（索引 → Resources/TrustedModelHashes.json）
refactor/scripts/generate-trusted-hashes.sh

# 3. 上传资产到 GitHub Release（示例：tag 固定为 asr-models）
gh release upload asr-models downloads/vitaliber/asr/<生成的文件>.zip --clobber

# 4. 提交索引 + 信任锚（二进制被 .gitignore 忽略）
git add downloads/vitaliber/asr/index.json Resources/TrustedModelHashes.json \
  && git commit -m "chore(downloads): asr <id> <version>"
```

## 安全与合规

- **构建期信任锚（业主 2026-09-12，核心机制）**：App 侧校验**不只**看本索引自报的 `sha256`——
  索引来自网络、可被 CDN/中间人替换，仅凭它比对等于没有信任根。因此：
  1. 打包时本地工具 `refactor/scripts/package-asr-model.sh`（不入库）把真实哈希写入本索引（已实现）；
  2. 发布者用本地工具 `refactor/scripts/generate-trusted-hashes.sh` 把索引固化为 App 内置
     资源 `Resources/TrustedModelHashes.json` 并提交；编译期 `project.yml` preBuildScripts
     对两者做 fail-closed 漂移校验（不一致即构建失败）；
  3. App 安装下载包时以**内置表**为唯一信任锚：未登记版本 / 哈希不一致一律拒绝安装
     （fail closed；空表 = 禁止一切运行时下载）。
  4. 发布新模型版本 ⇒ 必须同步更新索引并重新发版（新增/变更哈希需随 App 过审与签名保护）。
- CI/编译守卫：`project.yml` preBuildScripts 内联漂移校验（原 `--check` 语义）在条目漂移时
  退出码非 0，用于拦「索引改了但忘记提交生成物」。
- 索引与整包 **双 SHA-256**（整包一个；包内 `manifest.json` 每文件一个）——前者由内置表锚定，
  后者由 `ASRModelAssets.validate` 逐文件核对。
- 传输强制 HTTPS；不提供未签名的第三方镜像地址。
- 许可信息随 `license` 字段与包内 `LICENSE` 文件双呈现（MIT/Apache-2.0 等）。
- App 端不做遥测：下载服务不携带设备标识，仅标准 HTTP 头。
