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

## CI

GitHub Actions runs `scripts/validate-catalog.sh` on push and pull request.
