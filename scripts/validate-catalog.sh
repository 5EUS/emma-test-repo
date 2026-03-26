#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CATALOG_PATH="$REPO_DIR/catalog.json"
STRICT_PLACEHOLDERS=0

if [[ "${1:-}" == "--strict-placeholders" ]]; then
    STRICT_PLACEHOLDERS=1
fi

if [[ ! -f "$CATALOG_PATH" ]]; then
  echo "catalog.json not found at $CATALOG_PATH" >&2
  exit 1
fi

python3 - "$CATALOG_PATH" "$STRICT_PLACEHOLDERS" <<'PY'
import json
import re
import sys

catalog_path = sys.argv[1]
strict_placeholders = sys.argv[2] == "1"

with open(catalog_path, "r", encoding="utf-8") as f:
    catalog = json.load(f)

errors = []
warnings = []

if catalog.get("repositoryId") != "emma-test":
    errors.append("repositoryId must be 'emma-test'.")

plugins = catalog.get("plugins")
if not isinstance(plugins, list) or not plugins:
    errors.append("plugins must be a non-empty array.")
else:
    seen_plugin_ids = set()
    for plugin in plugins:
        plugin_id = str(plugin.get("pluginId", "")).strip()
        if not plugin_id:
            errors.append("pluginId is required for each plugin.")
            continue
        lower_plugin_id = plugin_id.lower()
        if lower_plugin_id in seen_plugin_ids:
            errors.append(f"duplicate pluginId: {plugin_id}")
        seen_plugin_ids.add(lower_plugin_id)

        releases = plugin.get("releases")
        if not isinstance(releases, list) or not releases:
            errors.append(f"plugin '{plugin_id}' must have at least one release.")
            continue

        seen_versions = set()
        for release in releases:
            version = str(release.get("version", "")).strip()
            asset_url = str(release.get("assetUrl", "")).strip()
            sha256 = str(release.get("sha256", "")).strip().lower()
            platforms = release.get("platforms")

            if not version:
                errors.append(f"plugin '{plugin_id}' has release with missing version.")
            else:
                lower_version = version.lower()
                if lower_version in seen_versions:
                    errors.append(f"plugin '{plugin_id}' has duplicate release version '{version}'.")
                seen_versions.add(lower_version)

            if not asset_url.startswith("https://"):
                errors.append(f"plugin '{plugin_id}' release '{version}' must use https assetUrl.")

            if "your-org" in asset_url:
                if strict_placeholders:
                    errors.append(f"plugin '{plugin_id}' release '{version}' contains placeholder assetUrl.")
                else:
                    warnings.append(f"plugin '{plugin_id}' release '{version}' contains placeholder assetUrl.")

            if not re.fullmatch(r"[0-9a-f]{64}", sha256):
                errors.append(f"plugin '{plugin_id}' release '{version}' has invalid sha256.")

            if sha256 == "0" * 64:
                if strict_placeholders:
                    errors.append(f"plugin '{plugin_id}' release '{version}' uses placeholder sha256.")
                else:
                    warnings.append(f"plugin '{plugin_id}' release '{version}' uses placeholder sha256.")

            if not isinstance(platforms, list) or not platforms:
                errors.append(f"plugin '{plugin_id}' release '{version}' must define at least one platform.")

if errors:
    print("catalog validation failed:")
    for error in errors:
        print(f"- {error}")
    sys.exit(1)

if warnings:
    print("catalog validation warnings:")
    for warning in warnings:
        print(f"- {warning}")

print("catalog validation passed")
PY
