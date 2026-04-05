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
import pathlib
import re
import sys

catalog_path = sys.argv[1]
strict_placeholders = sys.argv[2] == "1"

with open(catalog_path, "r", encoding="utf-8") as f:
    catalog = json.load(f)

errors = []
warnings = []

def in_scope(plugin_id, scope):
    s = str(scope or "").strip()
    if not s:
        return False
    if s.endswith("*"):
        return plugin_id.lower().startswith(s[:-1].lower())
    return plugin_id.lower() == s.lower()

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

repository_id = str(catalog.get("repositoryId", "")).strip()
trust_dir = pathlib.Path(catalog_path).resolve().parent / "trust"
delegation_path = trust_dir / f"{repository_id}.delegations.json"

if not delegation_path.exists():
    errors.append(f"missing delegation metadata file: {delegation_path}")
else:
    try:
        delegation = json.loads(delegation_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as ex:
        errors.append(f"invalid delegation JSON at {delegation_path}: line {ex.lineno}, column {ex.colno}")
        delegation = None

    if isinstance(delegation, dict):
        if str(delegation.get("repositoryId", "")).strip() != repository_id:
            errors.append("delegation repositoryId must match catalog repositoryId")

        root_key_id = str(delegation.get("rootKeyId", "")).strip()
        if not root_key_id:
            errors.append("delegation rootKeyId is required")
        else:
            root_key_path = trust_dir / "roots" / f"{root_key_id}.pem"
            if not root_key_path.exists():
                warnings.append(f"trusted root key file not found: {root_key_path}")

        sig = delegation.get("signature")
        if not isinstance(sig, dict):
            errors.append("delegation signature block is required")
        else:
            sig_alg = str(sig.get("algorithm", "")).strip().lower()
            sig_value = str(sig.get("value", "")).strip()
            if sig_alg != "rsa-sha256":
                errors.append("delegation signature.algorithm must be 'rsa-sha256'")
            if not sig_value:
                errors.append("delegation signature.value is required")
            elif strict_placeholders and "REPLACE_" in sig_value:
                errors.append("delegation signature.value contains placeholder")

        delegations = delegation.get("delegations")
        if not isinstance(delegations, list) or not delegations:
            errors.append("delegation delegations array must be non-empty")
            delegations = []

        all_scopes = []
        for item in delegations:
            if not isinstance(item, dict):
                errors.append("delegation entries must be objects")
                continue

            key_id = str(item.get("keyId", "")).strip()
            public_key_pem = str(item.get("publicKeyPem", "")).strip()
            status = str(item.get("status", "")).strip().lower()
            valid_from = str(item.get("validFromUtc", "")).strip()
            valid_until = str(item.get("validUntilUtc", "")).strip()
            scopes = item.get("scopes")

            if not key_id:
                errors.append("delegation keyId is required")
            if "BEGIN PUBLIC KEY" not in public_key_pem:
                errors.append(f"delegation {key_id or '<unknown>'} publicKeyPem must be a PEM public key")
            if status not in {"active", "retired", "revoked"}:
                errors.append(f"delegation {key_id or '<unknown>'} status must be active|retired|revoked")
            if not valid_from:
                errors.append(f"delegation {key_id or '<unknown>'} validFromUtc is required")
            if not valid_until:
                errors.append(f"delegation {key_id or '<unknown>'} validUntilUtc is required")
            if not isinstance(scopes, list) or not scopes:
                errors.append(f"delegation {key_id or '<unknown>'} scopes must be a non-empty array")
                continue

            cleaned = [str(scope).strip() for scope in scopes if str(scope).strip()]
            if not cleaned:
                errors.append(f"delegation {key_id or '<unknown>'} scopes must contain non-empty values")
                continue

            all_scopes.extend(cleaned)

        plugin_ids = [str(p.get("pluginId", "")).strip() for p in (catalog.get("plugins") or []) if str(p.get("pluginId", "")).strip()]
        for plugin_id in plugin_ids:
            if not any(in_scope(plugin_id, scope) for scope in all_scopes):
                errors.append(f"no delegation scope authorizes pluginId '{plugin_id}'")

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
