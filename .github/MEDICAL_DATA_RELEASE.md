# Medical data Release trust and encryption

The medical-data Release uses two independent layers:

1. **Ed25519 metadata signature** — reused verifier code from `model_trust.py`, but with:
   ```json
   "assetKind": "medical-data"
   ```
   It authenticates the plaintext content hash, manifest hash, release tag, and repository.
2. **age encryption** — encrypts the deterministic compressed data payload with
   `MEDICAL_DATA_AGE_RECIPIENT`.

The ASR keys are never reused. Medical-data trust root and catalog keys must be a separate key set.

## Required Actions secrets

### `MEDICAL_DATA_AGE_RECIPIENT`

The age recipient/public key used to encrypt the `.bin` payload. The matching private key is not stored in GitHub Actions.

### `MEDICAL_DATA_TRUST_ROOT_JSON`

The signed public trust-root envelope. Its payload must use:

```json
{
  "schemaVersion": 1,
  "role": "root",
  "app": "vitaliber",
  "assetKind": "medical-data",
  "assetBaseURL": "https://github.com/OWNER/REPO/releases/download/medical-data",
  "rootKeyIDs": [],
  "catalogKeyIDs": [],
  "rootThreshold": 2,
  "catalogThreshold": 2
}
```

The public root should also be shipped in the App as the medical-data trust root. Do not use `Resources/ModelTrustRoot.json`; that root is scoped to ASR.

### `MEDICAL_DATA_SIGNING_KEYS_JSON`

Temporary CI signing input, never committed:

```json
{
  "keys": [
    {"keyId": "sha256-of-public-key", "privateKey": "base64-32-byte-ed25519-seed"}
  ]
}
```

The workflow selects the authorized `catalogKeyIDs` from the medical root and requires at least `catalogThreshold` private keys.

## Publication rule

The workflow compares `medical-data-content.sha256` from the latest Release. This hash is calculated from the deterministic canonical JSON/JSONL source payload (excluding volatile manifest metadata). Because age encryption is randomized, ciphertext is never used for change detection. If the JSON content hash is unchanged, no new Release is created.

The encrypted payload itself is a zstd-compressed `medical-catalog.sqlite`. The SQLite file stores `catalog_version`, `generated_at`, `change_note`, schema version, and row counts in `catalog_meta`; its independent SHA-256 is published as `medical-catalog.sqlite.sha256` for post-decryption validation.

The workflow does not download or embed drug images; `medical_reference.jsonl` contains official image URLs only.
