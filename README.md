# Vita Liber

> Your family's health codex — a privacy-first, fully offline family medical records app for iPhone/iPad (iOS 17+, SwiftUI)

[简体中文](README.zh-CN.md) · [繁體中文](README.zh-Hant.md)

## Status
Planning stage. Product / UI / tech / test specifications are complete (kept private locally under `refactor/`). CI tooling templates are live in `.github/workflows/`. Implementation starts at milestone M0.

## Features
| Area | Highlights |
|---|---|
| Records | 14 medical record types; OCR field confirmation with revision history |
| Import | Camera scan with 4-corner correction, Vision OCR (zh-Hans/zh-Hant/EN), file/photo import |
| Family | Multi-member profiles, per-member attribution, care mode for elders |
| Medication | Prescription→plan→reminder→intake confirmation loop; dual-track stock & refill alerts |
| Insights | Disease timeline, metric trends (Swift Charts), local AI summaries with citations |
| Voice | Hands-free entry in Mandarin/Cantonese/Hokkien/Shanghainese/Sichuanese/English, mixed speech |
| Safety | PIN + Face ID auto-lock, sensitive media masking, emergency card |
| Data | PDF/CSV/JSON export, ZIP backup & restore, iCloud Drive, optional encrypted cloud sync |


## Principles
- **Privacy red lines**: data stays on-device; no diagnoses or dosing advice; sensitive media masked by default; AI refuses emergency queries
- **Permanently free**: reminders, sensitive protection, offline access, search, accessibility, emergency card
- **Bilingual UI**: Simplified & Traditional Chinese

## Repository
Only CI workflows and docs are public here. App sources land after the M0 project rebuild.
