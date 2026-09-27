# Medical data Release and App update contract (V1.9)

> **Status:** design approved; Go `medrelease` tooling implemented and tested offline against a fake GitHub; Secrets/Release not yet provisioned. Normative design: `docs/superpowers/specs/2026-09-26-shared-medical-fetch-sqlite-release-design.md` V1.9 (V1.5 behaviour; V1.7 all-Go toolchain; V1.8 tracked source location; V1.9 owner decisions 1A/1B — ingress signature verification at publish, verify-then-select egress).

The medical catalog is a B-level, read-only reference asset, separate from the patient database. Package authenticity is not clinical review; the App must not produce diagnosis/dosing conclusions or automatically write `medication_id` from a match. The App remains useful offline with its last-good local catalog; an absent catalog or failed update never blocks patient workflows.

## Trust and keys

Two cryptographic layers are independent:

1. **age X25519** encrypts the ordinary SQLite ZIP for Release transport. The App and CI use the same stable identity: CI needs it to restore the previous checkpoint; the signed App archive embeds it to open a package. An App user can extract the identity and is considered an authorized decryptor. Do not describe age as secrecy from App users.
2. **Ed25519 medical-data root/catalog signatures** authenticate pointer metadata and the exact package/database hashes. ASR trust keys are never reused. The App ships an independently pinned medical root; a root delivered by GitHub cannot authorize itself. Initial root rotation requires a new App pin or a monotonic, verifiable transition rooted in the installed pin.

The owner selected **2-of-2 signature threshold**, not independent key custody. The two catalog signing seeds may be available within the same restricted Actions secret/job; that means two valid signatures are required, but it does **not** claim resilience to compromise of that shared trust boundary. Root private keys remain offline and are not used by the routine signer.

### Actions secrets (not yet configured)

They are created exactly once by `medrelease provision --execute` (see Tooling below), which refuses to run if the Release or any of the four names already exists; rotation is a separate owner decision, never an automatic re-run.

- `MEDICAL_DATA_AGE_RECIPIENT`: public recipient used for age encryption.
- `MEDICAL_DATA_AGE_IDENTITY`: matching private identity; injected only into checkpoint restore/package-open steps and the signed Release archive build resource step. Never log it, pass it as a command argument, or upload it as an artifact.
- `MEDICAL_DATA_TRUST_ROOT_JSON`: signed public root envelope. Bundle the authorized public root into the App as a pin; do not reuse `Resources/ModelTrustRoot.json` (ASR scope).
- `MEDICAL_DATA_SIGNING_KEYS_JSON`: the two authorized catalog Ed25519 seeds in the existing JSON format; public key IDs must match the pinned root's catalog key IDs. Never commit the secret or expose seed values in CI logs.

The App build-for-testing, previews, debug runs and unit tests must use fixture keys, not production identity. Actual Secret provisioning is a one-time security-sensitive operation after all offline plan gates and a separate owner confirmation.

## Signed versions and asset names

Keep these versions distinct:

- `catalogVersion`: globally unique, monotonically increasing **pointer publication** sequence across installable and progress pointers; one sequence may name only one pointer.
- `dataVersion`: canonical App-visible catalog content identity in `catalog_meta.data_version`.
- SQLite `schema_version`: physical database schema version (target v5).
- `sqliteSha256`: exact decrypted SQLite byte digest; because CI-only `fetch_` state is inside the same database, this may change while `dataVersion` remains stable.

The signed canonical pointer must bind `rootVersion`, `catalogVersion`, `dataVersion`, `schemaVersion`, strict Boolean `installable`, repository/tag/assetKind, issued/expiry times, exact package basename/size/ciphertext SHA-256, decrypted SQLite SHA-256, `contentSha256`, `fetchStateSha256`, and a retained manifest basename/hash. Every install-relevant field is signed and checked against both filename and Release metadata.

Assets are append-only by publisher protocol (no `--clobber`, no overwrite, no automatic delete):

- `medical-data-catalog-installable-<catalogVersion>.json`
- `medical-data-catalog-progress-<catalogVersion>.json` (`installable=false`; CI checkpoint only)
- `medical-data-package-sqlite-<sqliteSha256>-cipher-<packageSha256>.bin`
- optional versioned root/manifest assets, e.g. `medical-data-root-<rootVersion>.json` and `medical-data-manifest-<manifestSha256>.json`

Do not publish fixed-name checksum sidecars as authorities. A repeated asset name with identical bytes/digest is idempotent; different bytes under that name is a hard collision. Upload and verify root/manifest/package first, upload the signed pointer last, then read back and verify all references. An orphan package may be retained and reused only after exact digest validation.

The single `medical-data` Release remains a mutable asset container, not provider-enforced immutable/WORM storage (GitHub's immutable-release mode prevents later appends). The owner accepts GitHub TLS/release inventory as freshness authority for new installs and stateless CI; a privileged Release writer can still delete/replay inventory and cause rollback/availability failure. Returning Apps persist a highest-seen installable pointer floor. Do not add an external monotonic head without a new owner decision. Preserve pointer/root history; the 1000-asset cap triggers an owner-reviewed topology change at 800 assets; do not auto-prune pointers.

## CI restore, completeness and publishing

- Workflow trigger: dispatch plus Sunday 08:00 `Asia/Shanghai` (`cron: '0 0 * * 0'` UTC), `cancel-in-progress: false`.
- CI confirms repository access before treating a missing `medical-data` tag as first-run. An API/auth/network/rate-limit failure, malformed or missing inventory, missing package, hash/signature/schema/FK error **fails closed**; fixed-name legacy assets require an explicit one-time migration path.
- **Owner decision 1B (2026-09-26, verify-then-select egress)**: restore picks the highest pointer whose envelope **verifies** under the pinned root, downloading candidates in descending `catalogVersion` order and skipping unverifiable ones (a token-holder's forged high-version pointer can no longer brick all restores — bad metadata never invalidates an older verified pointer, as with apt/dnf repo metadata). Only when **every** pointer fails verification does restore fail closed with an aggregate error. Never fall back to an empty DB.
- CI resumes from the highest valid `catalogVersion` across progress and installable pointers. The latest installable pointer separately supplies the App-visible content comparison baseline. App selection is different: it selects only the highest valid installable pointer. A valid newer progress pointer is never opened by the App.
- Complete source/content changes publish a new package and installable pointer. Partial source/NMPA-blocked runs may publish progress only and leave the canonical App-visible catalog last-good unchanged. When a complete unchanged run reaches the 7-day safety window before the current pointer's 31-day expiry, publish a higher-sequence installable metadata pointer and reuse the exact package; do not re-encrypt. Partial runs do not renew installable metadata.
- Before packaging, checkpoint WAL and use the ordinary SQLite main file. Verify signed package size/cipher SHA before age open; then SQLite SHA, schema/meta, `PRAGMA integrity_check`, `PRAGMA foreign_key_check` and FTS consistency. ZIP is bounded and has one safe SQLite entry only.

## App manual update and privacy

- No network request on launch, Settings appearance, background/foreground transition, prescription search/detail, or patient read/write. The UI offers **Check** and a separate **Update** action; checking reads the public Release inventory and selected small pointer only. Package bytes are not downloaded until the second explicit tap.
- The App embeds the pinned medical root and the shared age identity. It sends no GitHub token, account/member ID, patient data or search term. Public API checks are unauthenticated (60 requests/hour/IP); conditional 304 can still count toward quota. ETag is an exact-URL cache hint, not a trust signal or quota guarantee. Respect `Retry-After`/`x-ratelimit-reset`; do not auto-retry.
- 404 from the anonymous tag endpoint is shown as “unavailable/not yet published,” not “up to date.” Keep the active local version visible independently from check state. A candidate is metadata-verified; package integrity is verified only after the user taps Update.
- Installer independently rejects `installable=false`, bounds download/ZIP expansion, validates all signed hashes/schema/integrity/FK, and stages on the same volume. A transaction journal and last-good backup recover before `MedicalCatalogStore` opens. Cancel/failure keeps the old catalog active; activation never touches the patient database.

## Tooling: `scripts/medical-data/go/medrelease`

All Release trust operations are one Go module (source tracked in the repository, built by CI with `actions/setup-go`; no self-extracting payload). Library: `filippo.io/age`, `google/go-github`, `modernc.org/sqlite`, stdlib `crypto/ed25519`/`archive/zip`. Subcommands (JSON on stdout; `MEDRELEASE-ERROR:` rc 1, usage rc 2; the GitHub token is read only from `GITHUB_TOKEN`/`GH_TOKEN` and never sent to asset hosts):

| Subcommand | Role | Guarantees |
|---|---|---|
| `sign-pointer` / `verify-pointer` | sign/verify a pointer envelope under the pinned root | 2-of-2 catalog signatures, root keys may not sign catalogs, asset-name/payload binding, expiry (`--allow-expired` for CI history only) |
| `restore` | CI checkpoint restore | repository access verified before a 404 may mean "first run" (`no-release`); **verify-then-select** (owner decision 1B): highest pointer whose envelope verifies under the pinned root, unverifiable higher versions skipped; signed size/cipher SHA before age open; SQLite SHA, schema, `data_version`, integrity and FK checks; destination untouched on any failure |
| `publish` | CI publication | **Ingress signature verification (owner decision 1A)**: the new pointer must verify under the pinned root before any upload — a Release-write token alone cannot publish; `Decide` (content/state change → progress/installable; unchanged complete run within the 7-day window → metadata renewal reusing the exact package; partial runs never renew), `catalogVersion = max(epoch, highest+1)`, deterministic ZIP + age round-trip verification, append-only uploads (identical bytes reused, different bytes = collision), pointer uploaded last, read-back verification, `MEDRELEASE-WARN` at 800 assets; `--dry-run` signs but never uploads |
| `provision` | one-time key/Secret setup | dry-run by default (read-only preflight); `--execute` generates the age identity and four Ed25519 keys, self-signs root v1 (2-of-2, 2-year validity), writes passphrase-encrypted (age scrypt) backups plus the public `pinned-root.json` to a fresh 0700 vault, verifies every backup decrypts, then sets the four Secrets via `gh secret set` on stdin. Root private seeds exist only in the vault backup, never in CI |

The public `pinned-root.json` from the vault is what the App bundles as its medical root pin; the age identity is extractable from the App by design (see Trust and keys).

## Operational and test gates

Before any real source run or Release publish, pass all four plan offline gates and current macOS App/CoreKit/UI test gates; then re-read remote Release/Secret names and obtain owner confirmation for one-time provisioning. Tests use fake GitHub/URLProtocol/SQLite/Ed25519/age fixtures and do not contact live sources. NMPA `code=2021` blocks same-fingerprint tasks and does not skip them to request later details. The self-extracting CI payload (`scripts/medical-data/medical-data-ci.sh` + `pack-medical-data-ci.sh`) is retired in favour of tracked Go source; the workflow migration is pending, and the payload was repacked once with owner-approved hardening (2026-09-26, owner decision 2: extract to a fresh `mktemp` directory each run instead of trusting a predictable `$RUNNER_TEMP` path); do not repack it again.

## Emergency recovery runbook

Owner-only operations for the catastrophic states that 1A/1B leave intentionally closed:

1. **A forged/unverifiable pointer reached the Release** (only possible if 1A's ingress check is bypassed or the root pin changed after publication). With 1B in place this does not brick restores — clients skip it and use the last verifiable pointer. No recovery action is required beyond investigating how the upload happened. Do **not** delete the asset (append-only policy); it remains as evidence and is skipped forever.
2. **Every pointer fails verification** (e.g. the pinned root expired and no valid renewal exists). Restores fail closed with an aggregate error listing each rejection. Recovery = publish a **new valid pointer with a higher `catalogVersion`** (normal `publish` flow) — no deletion, no rollback. If the signing keys are lost, this is a root-rotation event requiring a new App pin; treat it as a new provisioning with owner confirmation, never a silent rotation.
3. **A malicious higher version passed verification** (signing keys compromised). The trusted boundary itself is broken: 1B cannot help and must not be extended to hide it. Revoke by publishing an even-higher valid pointer only after the key compromise is contained; a compromised catalog key set is a new-root event, and the App pin update is the real remediation.

`medical_reference.jsonl` continues to contain official image URLs only; the Release pipeline does not download or embed drug images.
