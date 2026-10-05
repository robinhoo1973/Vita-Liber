# Vita Liber 资源仓(Resource-only repository)

本仓库只承载 App 运行时下载的**资源 Release 附件**,不含任何 App 源码、Go 源码、workflow、构建脚本或源码镜像(2026-10-03 cutover 定案 §2.1)。

## Release 标签

| Tag | 内容 |
|---|---|
| `asr-models` | 签名 ASR 目录/信任根与模型 ZIP(数字版本目录 `N.catalog.json` 为权威,固定别名非权威) |
| `llama-models` | Qwen GGUF 模型包(App 构建取模) |
| `llama-xcframework` | SwiftPM 二进制依赖 |
| `medical-data` | 签名医疗参考目录与加密 SQLite 包 |

## 下载与完整性

- 全部附件**匿名可下载**(HTTPS,无凭据),逐字节 SHA-256 可校验;
- 附件不可变:同名同摘要幂等复用,同名异内容为硬碰撞(发布者侧校验);
- App 端始终按**签名根/目录**授权下载,页面清单只是定位候选,不是信任源。
