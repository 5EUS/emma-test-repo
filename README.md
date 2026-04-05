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

Generate root/delegated keys:

```bash
bash scripts/generate-signing-keypair.sh --out-dir trust/roots --name emma-root-2026
bash scripts/generate-signing-keypair.sh --out-dir .keys --name emma-test-shared-release-2026-q2
```

Update `trust/emma-test.delegations.json` with delegated public keys and scopes, then sign it with the root private key:

```bash
export EMMA_PLUGIN_ROOT_SIGNING_PRIVATE_KEY_BASE64="<base64 root private pem>"
bash scripts/sign-delegation-file.sh trust/emma-test.delegations.json
```

Runtime expects root public keys as `trust/roots/<rootKeyId>.pem` and repository delegation metadata in `trust/<repositoryId>.delegations.json`.

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
