# Vita Liber · 青囊书

> 你的家庭健康手抄本 —— 隐私优先、完全离线的家庭医疗档案 App（iOS 17+，iPhone/iPad，SwiftUI）

[English](README.md)
[繁體中文說明](README.zh-Hant.md)

## 项目状态
- 仓库包含实际 SwiftUI / CoreKit 源码；规格与审查记录保留在本地私有的 `refactor/`。
- iOS 编译、应用测试、归档和分发由 GitHub Actions macOS Runner 执行。

## 功能介绍
| 领域 | 亮点 |
|---|---|
| 病历档案 | OCR 预填信息卡、按卡显式确认、就诊互联与来源页追溯 |
| 导入 | 四角矫正拍摄扫描、Vision 文字识别（简繁英）、文件/相册导入 |
| 家庭成员 | 多成员档案、按人归属、长辈关怀模式 |
| 用药管理 | 处方→计划→提醒→服药确认闭环；双轨库存与续药提醒 |
| 健康洞察 | 疾病时间轴、指标趋势图（Swift Charts）、本地 AI 摘要（带引用） |
| 语音输入 | 自主选择离线 ASR，Zipformer 随包基线 + GitHub Releases 签名模型下载；方言准确率须真机金样验证 |
| 健康导入 | Apple 健康专页、本人绑定增量导入、数据数量与历史查看 |
| 安全防护 | 系统设备所有者认证、敏感媒体遮挡、急救信息卡 |
| 数据自主 | PDF/CSV/JSON 导出、自包含 `.vlbu` 备份恢复 |


## 产品原则
- **隐私红线**：数据只在本机；无诊断、无用药建议；敏感媒体默认遮挡；AI 紧急情况拒答
- **永久免费**：提醒、敏感保护、离线访问、搜索、无障碍、急救卡
- **双语界面**：简体中文 / 繁體中文

## 仓库说明
`App/` 为 SwiftUI 页面，`CoreKit/` 为 Domain/Protocols/Infrastructure，`Tests/` 与 `UITests/` 为应用测试。

## App 版本与 ASR 模型发布
App release 版本只读取根目录 `version.txt`，与 GitHub Release tag 独立。TestFlight 调用 `release-asr-models.yml`；它同时支持独立 `workflow_dispatch`，在 runner 临时目录准备四个完整模型 ZIP、校验包与签名目录并发布 `asr-models` Release。Zipformer 是随包离线基线，大模型经用户显式下载/校验后在本机运行。每次 App 编译从已签名元数据生成并嵌入哈希基线。公开配置位于 `Resources/ASRModelUpdates/`，仓库不保存 `downloads/` 目录或模型二进制。操作见[工作流与签名说明](.github/ASR_RELEASE.md)。模型磁盘大小不代表推理内存、速度或准确率。
