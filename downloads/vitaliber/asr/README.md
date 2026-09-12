# ASR 模型包（runtime ASR model packages）

> 所属：`downloads/vitaliber/asr/` 规范的下游实现；本文件说明 ASR 类别的包内容、命名与校验要求。

## 索引

App 唯一读取的文件是 [`index.json`](index.json)。字段含义见上级 `downloads/README.md`。
`url` 仅支持相对 `baseUrl` 的路径——绝对与协议相对（`//host/x`）形式一律拒绝
（安全审查 2026-09-12：保证下载目标主机恒等于 baseUrl 主机；baseUrl 必须 https）。

## 包内容要求（zip 根）

模型包解压后**根目录**必须直接包含：

```
manifest.json          # 与 App 端 ASRModelAssets.Manifest 结构一致：
                       # { formatVersion:1, models:[{id,license,revision,files:[...],archive?}], shared:[...], sourceDigest? }
<model files>          # 与 manifest.files[].path 一一对应（如 qwen3/encoder.onnx …）
LICENSE-<license>.txt  # 许可证全文（随包）
NOTICE.md              # 上游归属说明（可选但推荐）
```

- `manifest.json` 的 `models[].id` 必须等于索引里的 `id`；`revision` 必须等于索引里的 `version`。
- `files[].bytes` / `files[].sha256` 必须与包内真实文件一致——App 在解压后逐文件校验，不一致即判定该版本不可用。
- 多个模型可各自独立成包（互不依赖）；`shared`（如 VAD）如果被某模型引用，必须随该模型包携带。

## 命名

`<id>-<version>-<yyyymmdd>.zip`，例：`qwen3-0.6b-int8-v2026.03.25-20260912.zip`

## 当前登记

| id | version | builtAt | bytes | 状态 |
|---|---|---|---|---|
| zipformer | 2023-02-20 | 20260912 | 176,106,266 | ✅ 已发布（asr-models Release） |
| qwen3 | 0.6b-int8-v2026.03.25 | 20260912 | 844,122,000 | ✅ 已发布（asr-models Release） |
| dolphin | small-ctc-int8-2025-04-02 | 20260912 | 188,325,543 | ✅ 已发布（asr-models Release） |
| whisper | small-int8-2024-07-13 | 20260912 | 233,007,777 | ✅ 已发布（asr-models Release） |

> `sha256` 为空串表示**未发布**；App 必须把空 sha256 视为「不可用条目」直接跳过（防下载未完成/被篡改的包）。

## 发布步骤

```bash
# 打包脚本为发布者本地工具（refactor/scripts/，不入库）
refactor/scripts/package-asr-model.sh ./qwen3-package qwen3 0.6b-int8-v2026.03.25 \
  --base-url https://github.com/<owner>/VitaLiber/releases/download/asr-models
gh release upload asr-models downloads/vitaliber/asr/qwen3-*.zip --clobber
refactor/scripts/generate-trusted-hashes.sh   # 固化信任锚
git add downloads/vitaliber/asr/index.json Resources/TrustedModelHashes.json
```
