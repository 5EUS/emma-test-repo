# emma-test-repo

Metadata-only plugin repository for EMMA.

## Mode

This repository intentionally stores only catalog metadata.
It does not store plugin ZIP artifacts.

## Catalog

- File: `catalog.json`
- Repository ID: `emma-test`
- Validation script: `scripts/validate-catalog.sh`
- Update helper: `scripts/update-catalog-release.sh`
- Batch update helper: `scripts/update-all-cataloged-plugins.sh`
- Delegation metadata: `trust/emma-test.delegations.json`
- Root trust directory: `trust/roots/`

## Delegated signing trust model

This repository publishes root-signed delegation metadata for plugin signer authorization scopes.

## End-to-end key setup guide (repository + plugins)

This section is the canonical operator runbook for signing trust setup across:

- This repository (delegation metadata and trusted root key distribution)
- Plugin repositories (release manifest signing)

### 1) Generate keys

Generate one root key pair and one delegated release key pair:

```bash
bash scripts/generate-signing-keypair.sh --out-dir .keys --name emma-root-2026
bash scripts/generate-signing-keypair.sh --out-dir .keys --name emma-test-shared-release-2026-q2
```

Copy only the root public key into trust roots:

```bash
cp .keys/emma-root-2026.public.pem trust/roots/emma-root-2026.pem
```

Important:

- Keep all private keys only under .keys (already gitignored).
- Only public keys belong in trust/roots and delegation JSON.

### 2) Author delegation metadata

Edit trust/emma-test.delegations.json with:

- repositoryId: emma-test
- rootKeyId: emma-root-2026
- delegations[].keyId: emma-test-shared-release-2026-q2
- delegations[].publicKeyPem: contents of .keys/emma-test-shared-release-2026-q2.public.pem
- delegations[].scopes: plugin IDs this delegated signer may sign
- delegations[].validFromUtc and validUntilUtc windows
- delegations[].status: active

### 3) Sign delegation metadata with root private key

Use the root private key to produce signature.value:

```bash
export EMMA_PLUGIN_ROOT_SIGNING_PRIVATE_KEY_BASE64="$(base64 -w 0 .keys/emma-root-2026.private.pem)"
bash scripts/sign-delegation-file.sh trust/emma-test.delegations.json
```

The signer script accepts either:

- base64 PEM in EMMA_PLUGIN_ROOT_SIGNING_PRIVATE_KEY_BASE64
- raw PEM in EMMA_PLUGIN_ROOT_SIGNING_PRIVATE_KEY_PEM

### 4) Validate repository metadata

Run:

```bash
bash scripts/validate-catalog.sh
```

For strict placeholder enforcement:

```bash
bash scripts/validate-catalog.sh --strict-placeholders
```

### 5) Configure plugin repositories CI signing secret

In each plugin repository GitHub Secrets, set:

- Name: EMMA_HMAC_KEY_BASE64 (legacy secret name kept for workflow compatibility)
- Value: one-line base64 of delegated private key PEM

Generate value from this repository:

```bash
base64 -w 0 .keys/emma-test-shared-release-2026-q2.private.pem
```

Paste exact output as the secret value (no extra quotes).

### 6) Configure plugin signer metadata

Plugin packaging scripts should provide:

- EMMA_PLUGIN_SIGNING_KEY_ID=emma-test-shared-release-2026-q2
- EMMA_PLUGIN_REPOSITORY_ID=emma-test

Optional metadata:

- EMMA_PLUGIN_SIGNATURE_ISSUED_AT_UTC
- EMMA_PLUGIN_SIGNATURE_EXPIRES_AT_UTC

Current plugin scripts default key and repository values for emma-test usage.

### 7) Runtime trust distribution

Runtime expects:

- root public keys at trust/roots/<rootKeyId>.pem
- delegation metadata at trust/<repositoryId>.delegations.json

Never distribute root or delegated private keys with runtime assets.

### 8) Rotation model

Delegated key rotation:

1. Add new delegation entry with new keyId/publicKey/scopes/time window.
2. Re-sign delegation file with root private key.
3. Update plugin CI secret to new delegated private key.
4. After rollout, retire old key by setting status to retired or revoked.

Root key rotation:

1. Generate new root pair.
2. Publish new root public key in trust/roots.
3. Re-sign delegation metadata with new root and update rootKeyId.
4. Roll out updated trust roots to runtime.

### 9) Emergency revocation

If delegated key compromise is suspected:

1. Mark compromised delegation status as revoked.
2. Add replacement delegated key entry.
3. Re-sign delegation metadata immediately.
4. Update plugin CI secret and force new release signing.
5. Ensure runtime receives updated delegation metadata before next install operations.

Plugin release pipelines should sign manifests with delegated key metadata:

- `EMMA_PLUGIN_SIGNING_KEY_ID`
- `EMMA_PLUGIN_REPOSITORY_ID`
- `EMMA_PLUGIN_SIGNING_PRIVATE_KEY_BASE64`

## Artifact hosting model

Each plugin artifact is published in that plugin's own repository releases.
The catalog references immutable HTTPS release URLs and pinned SHA-256 digests.

## One-time migration note

The initial `sha256` in `catalog.json` is a placeholder until the TestPlugin is moved to
`https://github.com/5EUS/emma-test-plugin` and a first release asset is published.

## Release update workflow

1. Publish a new plugin ZIP in the plugin repository release.
2. Update catalog using the helper script (auto-computes SHA-256 from URL if omitted):

```bash
bash scripts/update-catalog-release.sh \
  --plugin-id emma.plugin.test \
  --version 0.2.0 \
  --asset-url https://github.com/5EUS/emma-test-plugin/releases/download/v0.2.0/emma.plugin.test_0.2.0_linux-x64.zip \
  --platforms linux \
  --prerelease false \
  --source-repository-url https://github.com/5EUS/emma-test-plugin
```

3. Validate catalog:

```bash
bash scripts/validate-catalog.sh
```

When migration is complete and placeholders are removed, enforce strict mode:

```bash
bash scripts/validate-catalog.sh --strict-placeholders
```

4. Commit and push.

## Batch update all cataloged plugins

For bulk updates across every unique `pluginId` in `catalog.json`, use:

```bash
bash scripts/update-all-cataloged-plugins.sh \
  --version 0.1.4 \
  --tag v0.1.4 \
  --platforms linux,wasm \
  --primary-platform linux
```

Notes:
- Primary platform keeps `--version` as-is (for example `0.1.4`).
- Other platforms get `-<platform>` suffix (for example `0.1.4-wasm`).
- Asset names are built from plugin metadata using this pattern:
  - `<pluginId>_<version>_<platform-suffix>.zip`
- Default platform suffix mapping is:
  - `linux=linux-x64`
  - `wasm=wasm`

Preview commands without writing changes:

```bash
bash scripts/update-all-cataloged-plugins.sh \
  --version 0.1.4 \
  --dry-run
```

Use latest GitHub release per plugin instead of passing a version:

```bash
bash scripts/update-all-cataloged-plugins.sh \
  --from-github-latest \
  --platforms linux,wasm \
  --primary-platform linux
```

Include prerelease tags in latest-mode selection:

```bash
bash scripts/update-all-cataloged-plugins.sh \
  --from-github-latest \
  --include-prerelease
```

## CI

GitHub Actions runs `scripts/validate-catalog.sh` on push and pull request.
