#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CATALOG_PATH="$REPO_DIR/catalog.json"

usage() {
  cat <<'USAGE'
Usage:
  scripts/update-catalog-release.sh \
    --plugin-id <plugin-id> \
    --version <version> \
    --asset-url <https-url> \
    [--sha256 <sha256-hex>] \
    [--platforms <comma-separated>] \
    [--notes <text>] \
    [--author <author>] \
    [--name <plugin-name>] \
    [--source-repository-url <https-url>] \
    [--prerelease <true|false>]

Examples:
  scripts/update-catalog-release.sh \
    --plugin-id emma.plugin.test \
    --version 0.2.0 \
    --asset-url https://github.com/5EUS/emma-test-plugin/releases/download/v0.2.0/emma.plugin.test_0.2.0_linux-x64.zip \
    --platforms linux \
    --prerelease false

Notes:
- If --sha256 is omitted, the script downloads the asset URL and computes sha256 automatically.
- The script inserts or updates the release entry for the plugin and bumps generatedAtUtc.
USAGE
}

PLUGIN_ID=""
VERSION=""
ASSET_URL=""
SHA256=""
PLATFORMS="linux"
NOTES=""
AUTHOR="EMMA"
PLUGIN_NAME=""
SOURCE_REPOSITORY_URL=""
IS_PRERELEASE="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --plugin-id)
      PLUGIN_ID="$2"
      shift 2
      ;;
    --version)
      VERSION="$2"
      shift 2
      ;;
    --asset-url)
      ASSET_URL="$2"
      shift 2
      ;;
    --sha256)
      SHA256="$2"
      shift 2
      ;;
    --platforms)
      PLATFORMS="$2"
      shift 2
      ;;
    --notes)
      NOTES="$2"
      shift 2
      ;;
    --author)
      AUTHOR="$2"
      shift 2
      ;;
    --name)
      PLUGIN_NAME="$2"
      shift 2
      ;;
    --source-repository-url)
      SOURCE_REPOSITORY_URL="$2"
      shift 2
      ;;
    --prerelease)
      IS_PRERELEASE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$PLUGIN_ID" || -z "$VERSION" || -z "$ASSET_URL" ]]; then
  echo "--plugin-id, --version, and --asset-url are required." >&2
  usage
  exit 1
fi

if [[ ! -f "$CATALOG_PATH" ]]; then
  echo "Catalog not found: $CATALOG_PATH" >&2
  exit 1
fi

if [[ -z "$SHA256" ]]; then
  echo "Computing sha256 from asset URL..."
  TMP_FILE="$(mktemp)"
  trap 'rm -f "$TMP_FILE"' EXIT
  curl -fL "$ASSET_URL" -o "$TMP_FILE"
  SHA256="$(sha256sum "$TMP_FILE" | awk '{print $1}')"
fi

SHA256="$(echo "$SHA256" | tr '[:upper:]' '[:lower:]')"

if [[ ! "$SHA256" =~ ^[0-9a-f]{64}$ ]]; then
  echo "Invalid sha256: $SHA256" >&2
  exit 1
fi

if [[ "$IS_PRERELEASE" != "true" && "$IS_PRERELEASE" != "false" ]]; then
  echo "--prerelease must be true or false." >&2
  exit 1
fi

python3 - "$CATALOG_PATH" "$PLUGIN_ID" "$VERSION" "$ASSET_URL" "$SHA256" "$PLATFORMS" "$NOTES" "$AUTHOR" "$PLUGIN_NAME" "$SOURCE_REPOSITORY_URL" "$IS_PRERELEASE" <<'PY'
import json
import sys
from datetime import datetime, timezone

catalog_path = sys.argv[1]
plugin_id = sys.argv[2]
version = sys.argv[3]
asset_url = sys.argv[4]
sha256 = sys.argv[5]
platforms_csv = sys.argv[6]
notes = sys.argv[7]
author = sys.argv[8]
plugin_name = sys.argv[9]
source_repository_url = sys.argv[10]
is_prerelease = sys.argv[11] == "true"

with open(catalog_path, "r", encoding="utf-8") as f:
    catalog = json.load(f)

plugins = catalog.setdefault("plugins", [])
platforms = [p.strip() for p in platforms_csv.split(",") if p.strip()]
if not platforms:
    platforms = ["linux"]

plugin = None
for p in plugins:
    if p.get("pluginId", "").lower() == plugin_id.lower():
        plugin = p
        break

if plugin is None:
    plugin = {
        "pluginId": plugin_id,
        "name": plugin_name or plugin_id,
        "description": "",
        "author": author,
        "sourceRepositoryUrl": source_repository_url or None,
        "releases": [],
    }
    plugins.append(plugin)

if plugin_name:
    plugin["name"] = plugin_name
if author:
    plugin["author"] = author
if source_repository_url:
    plugin["sourceRepositoryUrl"] = source_repository_url

release = {
    "version": version,
    "assetUrl": asset_url,
    "sha256": sha256,
    "platforms": platforms,
    "isPrerelease": is_prerelease,
}
if notes:
    release["notes"] = notes

releases = plugin.setdefault("releases", [])
updated = False
for idx, current in enumerate(releases):
    if str(current.get("version", "")).lower() == version.lower():
        releases[idx] = release
        updated = True
        break

if not updated:
    releases.insert(0, release)

catalog["generatedAtUtc"] = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")

with open(catalog_path, "w", encoding="utf-8") as f:
    json.dump(catalog, f, indent=2)
    f.write("\n")

print(f"catalog updated: plugin={plugin_id} version={version} sha256={sha256}")
PY

echo "Done."
