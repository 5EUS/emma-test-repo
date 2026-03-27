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
