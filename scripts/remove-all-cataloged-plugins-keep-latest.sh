#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CATALOG_PATH="$REPO_DIR/catalog.json"
SINGLE_REMOVE_SCRIPT="$REPO_DIR/scripts/remove-plugin-releases-up-to.sh"

usage() {
  cat <<'USAGE'
Usage:
  scripts/remove-all-cataloged-plugins-keep-latest.sh \
    --keep-latest <number> \
    [--catalog <path>] \
    [--continue-on-error] \
    [--dry-run]

Description:
  For each plugin in catalog.json, keeps only the latest N release entries.
  If a plugin has more than N releases, this script finds the cutoff release
  and calls scripts/remove-plugin-releases-up-to.sh for that plugin.

Examples:
  bash scripts/remove-all-cataloged-plugins-keep-latest.sh --keep-latest 4
  bash scripts/remove-all-cataloged-plugins-keep-latest.sh --keep-latest 2 --dry-run
USAGE
}

KEEP_LATEST=""
DRY_RUN=0
CONTINUE_ON_ERROR=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep-latest)
      KEEP_LATEST="$2"
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
    --continue-on-error)
      CONTINUE_ON_ERROR=1
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

if [[ -z "$KEEP_LATEST" ]]; then
  echo "--keep-latest is required." >&2
  usage
  exit 1
fi

if [[ ! "$KEEP_LATEST" =~ ^[0-9]+$ ]]; then
  echo "--keep-latest must be a non-negative integer." >&2
  exit 1
fi

if [[ "$KEEP_LATEST" -lt 1 ]]; then
  echo "--keep-latest must be at least 1." >&2
  exit 1
fi

if [[ ! -f "$CATALOG_PATH" ]]; then
  echo "Catalog not found: $CATALOG_PATH" >&2
  exit 1
fi

if [[ ! -x "$SINGLE_REMOVE_SCRIPT" ]]; then
  echo "Missing helper script: $SINGLE_REMOVE_SCRIPT" >&2
  exit 1
fi

plugin_rows=()
while IFS= read -r line; do
  plugin_rows+=("$line")
done < <(
  python3 - "$CATALOG_PATH" "$KEEP_LATEST" <<'PY'
import json
import sys

catalog_path = sys.argv[1]
keep_latest = int(sys.argv[2])

with open(catalog_path, "r", encoding="utf-8") as f:
    catalog = json.load(f)

plugins = catalog.get("plugins")
if not isinstance(plugins, list):
    print("ERROR\tInvalid catalog: plugins must be an array")
    sys.exit(1)

for plugin in plugins:
    plugin_id = str(plugin.get("pluginId", "")).strip()
    releases = plugin.get("releases")
    if not plugin_id or not isinstance(releases, list):
        continue

    if len(releases) <= keep_latest:
        print(f"SKIP\t{plugin_id}\t{len(releases)}")
        continue

    cutoff = releases[keep_latest]
    cutoff_version = str(cutoff.get("version", "")).strip()
    if not cutoff_version:
        print(f"ERROR\t{plugin_id}\tMissing cutoff version at index {keep_latest}")
        continue

    print(f"RUN\t{plugin_id}\t{cutoff_version}\t{len(releases)}")
PY
)

if [[ ${#plugin_rows[@]} -eq 0 ]]; then
  echo "No cataloged plugins found." >&2
  exit 1
fi

failures=()
pruned_count=0
skipped_count=0

for row in "${plugin_rows[@]}"; do
  kind="${row%%$'\t'*}"

  if [[ "$kind" == "SKIP" ]]; then
    plugin_id="$(echo "$row" | awk -F'\t' '{print $2}')"
    release_count="$(echo "$row" | awk -F'\t' '{print $3}')"
    echo "Skipping plugin=$plugin_id (releases=$release_count <= keepLatest=$KEEP_LATEST)"
    skipped_count=$((skipped_count + 1))
    continue
  fi

  if [[ "$kind" == "ERROR" ]]; then
    message="$(echo "$row" | cut -f2-)"
    if [[ "$CONTINUE_ON_ERROR" -eq 1 ]]; then
      echo "WARN: $message" >&2
      failures+=("$message")
      continue
    fi
    echo "ERROR: $message" >&2
    exit 1
  fi

  if [[ "$kind" != "RUN" ]]; then
    message="Unexpected planner row: $row"
    if [[ "$CONTINUE_ON_ERROR" -eq 1 ]]; then
      echo "WARN: $message" >&2
      failures+=("$message")
      continue
    fi
    echo "ERROR: $message" >&2
    exit 1
  fi

  plugin_id="$(echo "$row" | awk -F'\t' '{print $2}')"
  cutoff_version="$(echo "$row" | awk -F'\t' '{print $3}')"
  release_count="$(echo "$row" | awk -F'\t' '{print $4}')"

  cmd=(
    bash "$SINGLE_REMOVE_SCRIPT"
    --catalog "$CATALOG_PATH"
    --plugin-id "$plugin_id"
    --release-version "$cutoff_version"
  )

  if [[ "$DRY_RUN" -eq 1 ]]; then
    cmd+=(--dry-run)
  fi

  echo "Processing plugin=$plugin_id releases=$release_count cutoff=$cutoff_version"
  if ! "${cmd[@]}"; then
    message="plugin=$plugin_id cutoff=$cutoff_version"
    if [[ "$CONTINUE_ON_ERROR" -eq 1 ]]; then
      echo "WARN: failed, continuing: $message" >&2
      failures+=("$message")
      continue
    fi
    echo "ERROR: failed: $message" >&2
    exit 1
  fi

  pruned_count=$((pruned_count + 1))
done

echo "Done. plugins_pruned=$pruned_count plugins_skipped=$skipped_count failures=${#failures[@]}"

if [[ ${#failures[@]} -gt 0 ]]; then
  for failure in "${failures[@]}"; do
    echo "  - $failure" >&2
  done
  if [[ "$CONTINUE_ON_ERROR" -eq 0 ]]; then
    exit 1
  fi
fi
