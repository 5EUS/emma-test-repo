#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CATALOG_PATH="$REPO_DIR/catalog.json"
SINGLE_UPDATE_SCRIPT="$REPO_DIR/scripts/update-catalog-release.sh"

usage() {
  cat <<'USAGE'
Usage:
  scripts/update-all-cataloged-plugins.sh \
    --version <version> \
    [--tag <release-tag>] \
    [--from-github-latest] \
    [--include-prerelease] \
    [--platforms <comma-separated>] \
    [--primary-platform <platform>] \
    [--platform-suffixes <platform=suffix,...>] \
    [--prerelease <true|false>] \
    [--dry-run]

Description:
  Updates release entries for every unique plugin in catalog.json.
  For each plugin and platform, this script builds the expected release asset URL,
  then calls scripts/update-catalog-release.sh (which fetches and computes sha256).

Defaults:
  --tag                v<version>
  --platforms          linux,wasm
  --primary-platform   linux
  --platform-suffixes  linux=linux-x64,wasm=wasm
  --prerelease         false

Latest-release mode:
  --from-github-latest resolves the latest GitHub release per plugin source repo.
  In this mode, --version and --tag are ignored and release prerelease state is
  taken from the GitHub release metadata.
  Use --include-prerelease to allow selecting prerelease tags.

Versioning model:
  - Primary platform keeps --version as-is.
  - Other platforms use <version>-<platform> (for example 0.1.4-wasm).

Example:
  bash scripts/update-all-cataloged-plugins.sh \
    --version 0.1.4 \
    --tag v0.1.4 \
    --platforms linux,wasm \
    --primary-platform linux
USAGE
}

VERSION=""
TAG=""
FROM_GITHUB_LATEST=0
INCLUDE_PRERELEASE=0
PLATFORMS="linux,wasm"
PRIMARY_PLATFORM="linux"
PLATFORM_SUFFIXES="linux=linux-x64,wasm=wasm"
IS_PRERELEASE="false"
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      VERSION="$2"
      shift 2
      ;;
    --tag)
      TAG="$2"
      shift 2
      ;;
    --from-github-latest)
      FROM_GITHUB_LATEST=1
      shift
      ;;
    --include-prerelease)
      INCLUDE_PRERELEASE=1
      shift
      ;;
    --platforms)
      PLATFORMS="$2"
      shift 2
      ;;
    --primary-platform)
      PRIMARY_PLATFORM="$2"
      shift 2
      ;;
    --platform-suffixes)
      PLATFORM_SUFFIXES="$2"
      shift 2
      ;;
    --prerelease)
      IS_PRERELEASE="$2"
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

if [[ "$FROM_GITHUB_LATEST" -eq 0 && -z "$VERSION" ]]; then
  echo "--version is required." >&2
  usage
  exit 1
fi

if [[ "$FROM_GITHUB_LATEST" -eq 0 && -z "$TAG" ]]; then
  TAG="v$VERSION"
fi

if [[ "$IS_PRERELEASE" != "true" && "$IS_PRERELEASE" != "false" ]]; then
  echo "--prerelease must be true or false." >&2
  exit 1
fi

if [[ ! -f "$CATALOG_PATH" ]]; then
  echo "Catalog not found: $CATALOG_PATH" >&2
  exit 1
fi

if [[ ! -x "$SINGLE_UPDATE_SCRIPT" ]]; then
  echo "Missing update helper: $SINGLE_UPDATE_SCRIPT" >&2
  exit 1
fi

fetch_latest_release_lines() {
  local source_repo="$1"
  local include_prerelease="$2"

  python3 - "$source_repo" "$include_prerelease" <<'PY'
import json
import os
import re
import sys
import urllib.request

source_repo = sys.argv[1].strip()
include_prerelease = sys.argv[2] == "1"

match = re.match(r"^https://github\.com/([^/]+)/([^/]+?)/?$", source_repo)
if not match:
  match = re.match(r"^https://github\.com/([^/]+)/([^/]+?)\.git/?$", source_repo)
if not match:
  print(f"ERROR\tUnsupported sourceRepositoryUrl for latest mode: {source_repo}")
  sys.exit(2)

owner = match.group(1)
repo = match.group(2)
api_url = f"https://api.github.com/repos/{owner}/{repo}/releases?per_page=30"

headers = {
  "Accept": "application/vnd.github+json",
  "User-Agent": "emma-test-repo-catalog-updater"
}
token = os.getenv("GITHUB_TOKEN", "").strip()
if token:
  headers["Authorization"] = f"Bearer {token}"

req = urllib.request.Request(api_url, headers=headers)
try:
  with urllib.request.urlopen(req, timeout=30) as resp:
    body = resp.read().decode("utf-8")
except Exception as ex:
  print(f"ERROR\tFailed to query GitHub releases for {owner}/{repo}: {ex}")
  sys.exit(3)

try:
  releases = json.loads(body)
except json.JSONDecodeError as ex:
  print(f"ERROR\tInvalid GitHub API response for {owner}/{repo}: {ex}")
  sys.exit(4)

if not isinstance(releases, list):
  print(f"ERROR\tUnexpected releases payload for {owner}/{repo}")
  sys.exit(5)

selected = None
for release in releases:
  if not isinstance(release, dict):
    continue
  if release.get("draft"):
    continue
  if not include_prerelease and release.get("prerelease"):
    continue
  selected = release
  break

if selected is None:
  mode = "including prereleases" if include_prerelease else "excluding prereleases"
  print(f"ERROR\tNo matching GitHub release found for {owner}/{repo} ({mode})")
  sys.exit(6)

tag = str(selected.get("tag_name") or "").strip()
if not tag:
  print(f"ERROR\tSelected release has empty tag for {owner}/{repo}")
  sys.exit(7)

version = tag
if len(version) > 1 and version[0] in ("v", "V") and version[1].isdigit():
  version = version[1:]

is_prerelease = "true" if bool(selected.get("prerelease")) else "false"
print(f"META\t{tag}\t{version}\t{is_prerelease}")

assets = selected.get("assets") or []
for asset in assets:
  if not isinstance(asset, dict):
    continue
  name = str(asset.get("name") or "").strip()
  url = str(asset.get("browser_download_url") or "").strip()
  if not name or not url:
    continue
  print(f"ASSET\t{name}\t{url}")
PY
}

mapfile -t plugin_rows < <(
  python3 - "$CATALOG_PATH" <<'PY'
import json
import sys

catalog_path = sys.argv[1]
with open(catalog_path, 'r', encoding='utf-8') as f:
    catalog = json.load(f)

seen = set()
for plugin in catalog.get('plugins', []):
    plugin_id = str(plugin.get('pluginId', '')).strip()
    source_repo = str(plugin.get('sourceRepositoryUrl', '')).strip()
    if not plugin_id or not source_repo:
        continue
    key = (plugin_id.lower(), source_repo)
    if key in seen:
        continue
    seen.add(key)
    print(f"{plugin_id}\t{source_repo}")
PY
)

if [[ ${#plugin_rows[@]} -eq 0 ]]; then
  echo "No unique plugins with sourceRepositoryUrl found in catalog." >&2
  exit 1
fi

IFS=',' read -r -a platform_arr <<< "$PLATFORMS"
IFS=',' read -r -a suffix_arr <<< "$PLATFORM_SUFFIXES"

declare -A suffix_map=()
for pair in "${suffix_arr[@]}"; do
  trimmed="$(echo "$pair" | xargs)"
  [[ -z "$trimmed" ]] && continue
  key="${trimmed%%=*}"
  val="${trimmed#*=}"
  if [[ -z "$key" || -z "$val" || "$trimmed" != *"="* ]]; then
    echo "Invalid --platform-suffixes entry: $pair" >&2
    exit 1
  fi
  suffix_map["$key"]="$val"
done

for platform in "${platform_arr[@]}"; do
  platform="$(echo "$platform" | xargs)"
  if [[ -z "$platform" ]]; then
    continue
  fi
  if [[ -z "${suffix_map[$platform]:-}" ]]; then
    echo "Missing suffix mapping for platform '$platform'." >&2
    echo "Pass --platform-suffixes to define it, e.g. linux=linux-x64,wasm=wasm" >&2
    exit 1
  fi
done

for row in "${plugin_rows[@]}"; do
  plugin_id="${row%%$'\t'*}"
  source_repo="${row#*$'\t'}"

  latest_tag=""
  latest_version=""
  latest_prerelease="$IS_PRERELEASE"
  declare -A latest_assets=()

  if [[ "$FROM_GITHUB_LATEST" -eq 1 ]]; then
    mapfile -t latest_lines < <(fetch_latest_release_lines "$source_repo" "$INCLUDE_PRERELEASE")
    for line in "${latest_lines[@]}"; do
      IFS=$'\t' read -r kind a b c <<< "$line"
      if [[ "$kind" == "ERROR" ]]; then
        echo "$line" >&2
        exit 1
      fi
      if [[ "$kind" == "META" ]]; then
        latest_tag="$a"
        latest_version="$b"
        latest_prerelease="$c"
      elif [[ "$kind" == "ASSET" ]]; then
        latest_assets["$a"]="$b"
      fi
    done

    if [[ -z "$latest_tag" || -z "$latest_version" ]]; then
      echo "Failed to resolve latest GitHub release metadata for plugin '$plugin_id'." >&2
      exit 1
    fi
  fi

  for platform in "${platform_arr[@]}"; do
    platform="$(echo "$platform" | xargs)"
    [[ -z "$platform" ]] && continue

    base_version="$VERSION"
    base_tag="$TAG"
    effective_prerelease="$IS_PRERELEASE"

    if [[ "$FROM_GITHUB_LATEST" -eq 1 ]]; then
      base_version="$latest_version"
      base_tag="$latest_tag"
      effective_prerelease="$latest_prerelease"
    fi

    release_version="$base_version"
    if [[ "$platform" != "$PRIMARY_PLATFORM" ]]; then
      release_version="${base_version}-${platform}"
    fi

    suffix="${suffix_map[$platform]}"
    asset_name="${plugin_id}_${base_version}_${suffix}.zip"

    if [[ "$FROM_GITHUB_LATEST" -eq 1 ]]; then
      asset_url="${latest_assets[$asset_name]:-}"
      if [[ -z "$asset_url" ]]; then
        echo "Missing asset '$asset_name' in latest release '$base_tag' for plugin '$plugin_id'." >&2
        exit 1
      fi
    else
      asset_url="${source_repo}/releases/download/${base_tag}/${asset_name}"
    fi

    cmd=(
      bash "$SINGLE_UPDATE_SCRIPT"
      --plugin-id "$plugin_id"
      --version "$release_version"
      --asset-url "$asset_url"
      --platforms "$platform"
      --prerelease "$effective_prerelease"
      --source-repository-url "$source_repo"
    )

    if [[ "$DRY_RUN" -eq 1 ]]; then
      printf 'DRY RUN: '
      printf '%q ' "${cmd[@]}"
      printf '\n'
    else
      "${cmd[@]}"
    fi
  done
done

if [[ "$DRY_RUN" -eq 0 ]]; then
  echo "All cataloged plugins updated for version $VERSION."
fi
