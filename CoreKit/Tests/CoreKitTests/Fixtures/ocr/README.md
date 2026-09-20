# OCR 识别基线夹具（Stage 0，双轨，round3 裁定 C4）

## 合成轨（入仓，硬哨兵）

- 定义文件 = `../extraction/{prescription,lab,encounter}_golden.json` 的 `lines`（已入仓）。
- `OCRRecognitionEvaluationTests.syntheticRenderedGoldensRecognizeBelowSanityCER` 在 macOS CI
  用 CoreText（PingFang SC 24pt / 32pt 行高 / 20pt 边距）运行时渲染成图后跑 Vision，
  行级 CER < 0.5 为 sanity 上界。定义文件缺失/解码失败即红——堵 harness 腐烂（T2 族防复发）。

## 真实轨（`real/`，gitignore，CI 侧投放）

- 业主提供 ≥30 张**脱敏**单据（不得含真实姓名/证件号；脱敏后再投放），经 CI 侧
  放置到 `Fixtures/ocr/real/`（不入库）。
- `<id>.png|jpg` + `<id>.lines.txt`（人工校正的视觉行，一行一条，UTF-8，与图像阅读顺序一致）。
- 成对完整性：有图无 `.lines.txt` 无论测试是否跳过都**硬红**（`realFixturesArePaired`）。
- 样本在场时 `realVisionBaselineCER` 跑严格 CER（< 0.5 sanity 上界；Stage B 起 Paddle 对照、
  `usesLanguageCorrection` on/off 分层对照、分歧率统计均基于此轨）。
- 无样本时真跳过（`@Test(.enabled(if:))`，不伪绿）；基线缺失登记 tech §11 债务。
