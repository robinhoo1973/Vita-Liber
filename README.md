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
| Voice | User-selectable offline ASR, a bundled Zipformer baseline and signed model downloads from GitHub Releases; dialect accuracy requires device-specific validation |
| Health import | Dedicated Apple Health settings, owner-bound incremental import, imported-data counts and history |
| Safety | System device-owner authentication, sensitive media masking, emergency card |
| Data | PDF/CSV/JSON export and self-contained `.vlbu` backup/restore |


## Principles
- **Privacy red lines**: data stays on-device; no diagnoses or dosing advice; sensitive media masked by default; AI refuses emergency queries
- **Permanently free**: reminders, sensitive protection, offline access, search, accessibility, emergency card
- **Bilingual UI**: Simplified & Traditional Chinese

## Repository
`App/` contains SwiftUI screens; `CoreKit/` contains Domain, Protocols and Infrastructure; `Tests/` and `UITests/` hold the app test suites.

## App versions and ASR model releases
The App release version comes from root `version.txt`, independently of GitHub Release tags. TestFlight calls `release-asr-models.yml`, which also supports standalone `workflow_dispatch`: it prepares all four complete model ZIPs in runner temporary storage, verifies their contents and signed catalog, and publishes the `asr-models` Release. Zipformer ships as the offline baseline; larger models are explicitly downloaded and verified before local use. Every App build generates an embedded hash baseline from the signed metadata. Public configuration lives in `Resources/ASRModelUpdates/`; the repository has no `downloads/` directory or model binaries. See [workflow and signing instructions](.github/ASR_RELEASE.md). Disk size does not establish inference memory, speed, or accuracy.
