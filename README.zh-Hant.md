# Vita Liber · 青囊書

> 你的家庭健康手抄本 —— 隱私優先、完全離線的家庭醫療記錄 App（iOS 17+，iPhone/iPad，SwiftUI）

[English](README.md)
[简体中文说明](README.zh-CN.md)

## 專案狀態
- 儲存庫包含實際 SwiftUI / CoreKit 原始碼；規格與審查記錄保留在本機私有的 `refactor/`。
- iOS 編譯、應用測試、封存和分發由 GitHub Actions macOS Runner 執行。

## 功能介紹
| 領域 | 亮點 |
|---|---|
| 病歷檔案 | OCR 預填資訊卡、按卡明確確認、就診互聯與來源頁追溯 |
| 匯入 | 四角矯正拍攝掃描、Vision 文字辨識（簡繁英）、檔案/相簿匯入 |
| 家庭成員 | 多成員檔案、依人員歸屬、長輩照護模式 |
| 用藥管理 | 處方→計畫→提醒→用藥確認閉環；雙軌庫存與續藥提醒 |
| 健康洞察 | 疾病時間軸、指標趨勢圖（Swift Charts）、本機 AI 摘要（附引用） |
| 語音輸入 | 自主選擇隨附 ASR，優先中文方言；具體準確率須本機金樣驗證 |
| 健康匯入 | Apple 健康專頁、本人綁定增量匯入、資料數量與歷史檢視 |
| 安全防護 | 系統裝置擁有者認證、敏感媒體遮蔽、急救資訊卡 |
| 資料自主 | PDF/CSV/JSON 匯出、自包含 `.vlbu` 備份還原 |


## 產品原則
- **隱私紅線**：資料僅存於本機；不提供診斷與用藥建議；敏感性媒體預設遮蔽；AI 於緊急情境一律拒答
- **永久免費**：服藥提醒、隱私保護、離線存取、搜尋、無障礙、急救卡
- **雙語介面**：簡體中文 / 繁體中文

## 儲存庫說明
`App/` 為 SwiftUI 頁面，`CoreKit/` 為 Domain/Protocols/Infrastructure，`Tests/` 與 `UITests/` 為應用測試。

## 隨附 ASR 資源
`Resources/ASRModels/manifest.json` 固定模型版本和校驗值。CI 在應用編譯前執行 `python3 .github/workflows/fetch-asr-models.py`，權重不進 Git、全部隨應用封裝。下載僅發生在建置機；應用推理不依賴網路。授權條款與來源說明隨附保留。整套模型超過1GB，磁碟大小不代表實際推理記憶體或速度。
