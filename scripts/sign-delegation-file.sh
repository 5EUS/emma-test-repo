#!/usr/bin/env bash
set -euo pipefail

if ! command -v openssl >/dev/null 2>&1; then
  echo "openssl is required." >&2
  exit 1
fi

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <delegation-json-path>" >&2
  exit 1
fi

DELEGATION_PATH="$1"
if [[ ! -f "$DELEGATION_PATH" ]]; then
  echo "Delegation file not found: $DELEGATION_PATH" >&2
  exit 1
fi

KEY_MATERIAL=""
normalize_key_value() {
  local value="$1"

  value="${value//$'\r'/}"
  if [[ ${#value} -ge 2 && "${value:0:1}" == '"' && "${value: -1}" == '"' ]]; then
    value="${value:1:${#value}-2}"
  elif [[ ${#value} -ge 2 && "${value:0:1}" == "'" && "${value: -1}" == "'" ]]; then
    value="${value:1:${#value}-2}"
  fi

  printf '%s' "$value"
}

decode_private_key_material() {
  local value
  local decoded

  value="$(normalize_key_value "$1")"

  if [[ "$value" == *"BEGIN"*"PRIVATE KEY"* ]]; then
    printf '%s' "$value"
    return 0
  fi

  local normalized
  normalized="${value//\\n/$'\n'}"
  normalized="$(normalize_key_value "$normalized")"
  if [[ "$normalized" == *"BEGIN"*"PRIVATE KEY"* ]]; then
    printf '%s' "$normalized"
    return 0
  fi

  if decoded="$(printf '%s' "$value" | base64 --decode 2>/dev/null)" \
    && [[ "$decoded" == *"BEGIN"*"PRIVATE KEY"* ]]; then
    printf '%s' "$(normalize_key_value "$decoded")"
    return 0
  fi

  if decoded="$(printf '%s' "$value" | openssl base64 -d -A 2>/dev/null)" \
    && [[ "$decoded" == *"BEGIN"*"PRIVATE KEY"* ]]; then
    printf '%s' "$(normalize_key_value "$decoded")"
    return 0
  fi

  return 1
}

if [[ -n "${EMMA_PLUGIN_ROOT_SIGNING_PRIVATE_KEY_PEM:-}" ]]; then
  KEY_MATERIAL="$(decode_private_key_material "${EMMA_PLUGIN_ROOT_SIGNING_PRIVATE_KEY_PEM}")"
elif [[ -n "${EMMA_PLUGIN_ROOT_SIGNING_PRIVATE_KEY_BASE64:-}" ]]; then
  KEY_MATERIAL="$(decode_private_key_material "${EMMA_PLUGIN_ROOT_SIGNING_PRIVATE_KEY_BASE64}")"
fi

if [[ -z "$KEY_MATERIAL" ]]; then
  echo "Set EMMA_PLUGIN_ROOT_SIGNING_PRIVATE_KEY_PEM or EMMA_PLUGIN_ROOT_SIGNING_PRIVATE_KEY_BASE64." >&2
  exit 1
fi

if [[ "$KEY_MATERIAL" != *"BEGIN"*"PRIVATE KEY"* ]]; then
  echo "Root key material is not a PEM private key." >&2
  exit 1
fi

KEY_FILE="$(mktemp)"
trap 'rm -f "$KEY_FILE"' EXIT
umask 077
printf '%s\n' "$KEY_MATERIAL" > "$KEY_FILE"

if ! openssl pkey -in "$KEY_FILE" -noout >/dev/null 2>&1; then
  echo "Root signing key material could not be parsed as a valid private key." >&2
  echo "Ensure the secret contains an unencrypted PEM private key (raw PEM or base64 PEM)." >&2
  exit 1
fi

export DELEGATION_PATH
export KEY_FILE
python3 - <<'PY'
import base64
import json
import os
import pathlib
import subprocess
import sys

path = pathlib.Path(os.environ["DELEGATION_PATH"])
key_file = os.environ["KEY_FILE"]

def req_str(obj, key):
    value = obj.get(key)
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"Missing required string field: {key}")
    return value.strip()

payload = json.loads(path.read_text(encoding="utf-8"))
repository_id = req_str(payload, "repositoryId")
root_key_id = req_str(payload, "rootKeyId")
issued_at_utc = req_str(payload, "issuedAtUtc")
version = int(payload.get("version", 1))

delegations = payload.get("delegations")
if not isinstance(delegations, list) or not delegations:
    raise ValueError("delegations must be a non-empty array")

normalized = []
for item in delegations:
    if not isinstance(item, dict):
        raise ValueError("delegation entries must be objects")

    key_id = req_str(item, "keyId")
    public_key_pem = req_str(item, "publicKeyPem")
    status = req_str(item, "status")
    valid_from = req_str(item, "validFromUtc")
    valid_until = req_str(item, "validUntilUtc")

    scopes = item.get("scopes") or []
    if not isinstance(scopes, list):
        raise ValueError(f"delegation scopes for {key_id} must be an array")

    normalized.append({
        "keyId": key_id,
        "publicKeyPem": public_key_pem,
        "status": status,
        "validFromUtc": valid_from,
        "validUntilUtc": valid_until,
        "scopes": [str(x).strip() for x in scopes if str(x).strip()],
    })

normalized.sort(key=lambda x: x["keyId"])

lines = [
    f"repositoryId={repository_id}",
    f"version={version}",
    f"issuedAtUtc={issued_at_utc}",
]

for item in normalized:
    lines.append(f"delegation.keyId={item['keyId']}")
    lines.append(f"delegation.status={item['status']}")
    lines.append(f"delegation.validFromUtc={item['validFromUtc']}")
    lines.append(f"delegation.validUntilUtc={item['validUntilUtc']}")
    lines.append(f"delegation.publicKeyPem={item['publicKeyPem'].strip()}")
    for scope in sorted(item["scopes"]):
        lines.append(f"delegation.scope={scope}")

payload_bytes = "\n".join(lines).encode("utf-8")
proc = subprocess.run(
    ["openssl", "dgst", "-sha256", "-sign", key_file],
    input=payload_bytes,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    check=False,
)
if proc.returncode != 0:
    sys.stderr.write(proc.stderr.decode("utf-8", errors="replace"))
    raise SystemExit(proc.returncode)

sig_b64 = base64.b64encode(proc.stdout).decode("ascii")
payload["version"] = version
payload["repositoryId"] = repository_id
payload["rootKeyId"] = root_key_id
payload["issuedAtUtc"] = issued_at_utc
payload["delegations"] = normalized
payload["signature"] = {
    "algorithm": "rsa-sha256",
    "value": sig_b64,
}

path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
print(f"Signed delegation metadata: {path}")
PY
