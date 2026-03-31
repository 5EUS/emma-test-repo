#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CATALOG_PATH="$REPO_DIR/catalog.json"

usage() {
  cat <<'USAGE'
Usage:
  scripts/remove-plugin-releases-up-to.sh \
    --plugin-id <plugin-id> \
    --release-version <version> \
    [--catalog <path>] \
    [--dry-run]

Description:
  Removes releases for one plugin starting at --release-version and all older
  releases that come after it in the plugin's releases array.

  Assumes releases are ordered newest to oldest in catalog.json.

Examples:
  bash scripts/remove-plugin-releases-up-to.sh \
    --plugin-id emma.plugin.test \
    --release-version 0.1.9

  bash scripts/remove-plugin-releases-up-to.sh \
    --plugin-id emma.video.test \
    --release-version 0.1.8 \
    --dry-run
USAGE
}

PLUGIN_ID=""
RELEASE_VERSION=""
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --plugin-id)
      PLUGIN_ID="$2"
      shift 2
      ;;
    --release-version)
      RELEASE_VERSION="$2"
      shift 2
      ;;
    --catalog)
      CATALOG_PATH="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
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

if [[ -z "$PLUGIN_ID" || -z "$RELEASE_VERSION" ]]; then
  echo "--plugin-id and --release-version are required." >&2
  usage
  exit 1
fi

if [[ ! -f "$CATALOG_PATH" ]]; then
  echo "Catalog not found: $CATALOG_PATH" >&2
  exit 1
fi

python3 - "$CATALOG_PATH" "$PLUGIN_ID" "$RELEASE_VERSION" "$DRY_RUN" <<'PY'
import json
import sys
from datetime import datetime, timezone

catalog_path = sys.argv[1]
plugin_id = sys.argv[2].strip()
release_version = sys.argv[3].strip()
dry_run = sys.argv[4] == "1"

with open(catalog_path, "r", encoding="utf-8") as f:
    catalog = json.load(f)

plugins = catalog.get("plugins")
if not isinstance(plugins, list):
    print("Invalid catalog: plugins must be an array.", file=sys.stderr)
    sys.exit(1)

plugin = None
for entry in plugins:
    if str(entry.get("pluginId", "")).strip().lower() == plugin_id.lower():
        plugin = entry
        break

if plugin is None:
    print(f"Plugin not found: {plugin_id}", file=sys.stderr)
    sys.exit(2)

releases = plugin.get("releases")
if not isinstance(releases, list) or not releases:
    print(f"Plugin '{plugin_id}' has no releases to prune.", file=sys.stderr)
    sys.exit(3)

cutoff_index = None
for idx, release in enumerate(releases):
    current = str(release.get("version", "")).strip()
    if current.lower() == release_version.lower():
        cutoff_index = idx
        break

if cutoff_index is None:
    print(
        f"Release version '{release_version}' not found for plugin '{plugin_id}'.",
        file=sys.stderr,
    )
    sys.exit(4)

removed = releases[cutoff_index:]
kept = releases[:cutoff_index]

if not removed:
    print(f"No releases removed for plugin '{plugin_id}'.")
    sys.exit(0)

if dry_run:
    print(f"DRY RUN: plugin={plugin_id}")
    print(f"  kept={len(kept)} removed={len(removed)}")
    print("  removed_versions=" + ", ".join(str(r.get("version", "")) for r in removed))
    sys.exit(0)

plugin["releases"] = kept
catalog["generatedAtUtc"] = (
    datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
)

with open(catalog_path, "w", encoding="utf-8") as f:
    json.dump(catalog, f, indent=2)
    f.write("\n")

print(f"Pruned plugin '{plugin_id}': kept={len(kept)} removed={len(removed)}")
print("Removed versions: " + ", ".join(str(r.get("version", "")) for r in removed))
PY
