# LLM model packages

## Vita Liber 大语言模型资源 / 大語言模型資源 / LLM model resources

### 简体中文

这里是 Vita Liber App 使用的**离线大语言模型资源**,包含随包分发的通用小模型,以及由训练管线产出的专用模型(如本机医疗文本抽取模型)——供 App 在**离线**状态下把识别出的文本整理为结构化医疗信息。模型在本机运行,不用于诊断,不产生推测性结论。

模型清单与逐文件校验信息由本 Release 的**固定名清单文件 `catalog.json`** 承载(文件名 / 字节数 / SHA-256);App 会先按清单逐项校验,校验不通过就保留设备上已有的模型。**只有通过校验的内容才会被 App 采用;本页文字与下方文件清单仅供了解更新内容,一律以 App 内校验通过的清单为准。**

本页**不包含**任何 App 源代码,也不包含任何患者或家庭成员的数据。模型更新不会在后台自动进行:请在 App 的「设置 → 数据与资源」中手动点【检查更新】,确认后再下载安装。模型更新永久免费,安装后离线可用。

### 繁體中文

這裡是 Vita Liber App 使用的**離線大語言模型資源**,包含隨包分發的通用小模型,以及由訓練管線產出的專用模型(如本機醫療文本抽取模型)——供 App 在**離線**狀態下把辨識出的文本整理為結構化醫療資訊。模型在本機執行,不用於診斷,不產生推測性結論。

模型清單與逐檔案校驗資訊由本 Release 的**固定名清單檔案 `catalog.json`** 承載(檔案名 / 位元組數 / SHA-256);App 會先按清單逐項校驗,校驗未通過就保留裝置上已有的模型。**只有通過校驗的內容才會被 App 採用;本頁文字與下方檔案清單僅供了解更新內容,一律以 App 內校驗通過的清單為準。**

本頁**不包含**任何 App 原始碼,也不包含任何病人或家庭成員的資料。模型更新不會在背景下自動進行:請在 App 的「設定 → 資料與資源」手動點【檢查更新】,確認後再下載安裝。模型更新永久免費,安裝後離線可用。

### English

These are the **offline large-language-model resources** used by the Vita Liber app: a general small model distributed with the app, plus specialized models produced by the training pipeline (such as the on-device medical-text extraction model). They let the app turn recognized text into structured medical information **offline**. The models run on-device, are not used for diagnosis, and do not produce speculative conclusions.

The model list and per-file verification data live in this release's **fixed-name catalog file `catalog.json`** (file name / byte size / SHA-256). The app verifies every entry against the catalog first, and keeps the models already on your device if verification fails. **Only content that passes verification is adopted by the app; this page and the file list below are informational — the verified catalog in the app is authoritative.**

This page contains **no** app source code and no patient or family data. Updates are never downloaded in the background: in the app, open Settings → Data & Resources, tap Check for updates, then download. Model updates are permanently free and work offline once installed.
