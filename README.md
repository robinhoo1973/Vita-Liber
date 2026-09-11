# Vita Liber

> Your family's health codex — a privacy-first, fully offline family medical records app for iPhone/iPad (iOS 17+, SwiftUI)

[简体中文](README.zh-CN.md) · [繁體中文](README.zh-Hant.md)

## Status
Active SwiftUI app and CoreKit sources are included. Specifications and review records remain private under the ignored `refactor/` directory. iOS builds, tests, and distribution run on GitHub Actions macOS runners.

## Features
| Area | Highlights |
|---|---|
| Records | OCR-prefilled review cards, explicit confirmation, encounter links and original-page provenance |
| Import | Camera scan with 4-corner correction, Vision OCR (zh-Hans/zh-Hant/EN), file/photo import |
| Family | Multi-member profiles, per-member attribution, care mode for elders |
| Medication | Prescription→plan→reminder→intake confirmation loop; dual-track stock & refill alerts |
| Insights | Disease timeline, metric trends (Swift Charts), local AI summaries with citations |
| Voice | User-selectable bundled ASR, with Chinese dialect recognition prioritized; accuracy requires device-specific validation |
| Health import | Dedicated Apple Health settings, owner-bound incremental import, imported-data counts and history |
| Safety | System device-owner authentication, sensitive media masking, emergency card |
| Data | PDF/CSV/JSON export and self-contained `.vlbu` backup/restore |


## Principles
- **Privacy red lines**: data stays on-device; no diagnoses or dosing advice; sensitive media masked by default; AI refuses emergency queries
- **Permanently free**: reminders, sensitive protection, offline access, search, accessibility, emergency card
- **Bilingual UI**: Simplified & Traditional Chinese

## Repository
`App/` contains SwiftUI screens; `CoreKit/` contains Domain, Protocols and Infrastructure; `Tests/` and `UITests/` hold the app test suites.

## Bundled ASR resources
`Resources/ASRModels/manifest.json` pins the model exports and checksums. CI runs `python3 .github/workflows/fetch-asr-models.py` before app compilation; weights are git-ignored and bundled into the app. Downloading these resources is a build-machine operation, not a runtime dependency. Model licenses and notices accompany the bundle. The complete set is large (over 1 GB); disk size does not establish inference memory or speed.
