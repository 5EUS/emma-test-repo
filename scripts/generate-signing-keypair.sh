#!/usr/bin/env bash
set -euo pipefail

OUT_DIR=""
KEY_NAME=""
KEY_BITS="3072"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out-dir)
      OUT_DIR="$2"
      shift 2
      ;;
    --name)
      KEY_NAME="$2"
      shift 2
      ;;
    --bits)
      KEY_BITS="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      echo "Usage: $0 --out-dir <dir> --name <key-id> [--bits 3072]" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$OUT_DIR" || -z "$KEY_NAME" ]]; then
  echo "Usage: $0 --out-dir <dir> --name <key-id> [--bits 3072]" >&2
  exit 1
fi

if ! [[ "$KEY_BITS" =~ ^[0-9]+$ ]]; then
  echo "--bits must be a number" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"
PRIVATE_KEY_PATH="$OUT_DIR/$KEY_NAME.private.pem"
PUBLIC_KEY_PATH="$OUT_DIR/$KEY_NAME.public.pem"

umask 077
openssl genpkey -algorithm RSA -pkeyopt "rsa_keygen_bits:$KEY_BITS" -out "$PRIVATE_KEY_PATH" >/dev/null 2>&1
openssl rsa -in "$PRIVATE_KEY_PATH" -pubout -out "$PUBLIC_KEY_PATH" >/dev/null 2>&1

echo "Generated private key: $PRIVATE_KEY_PATH"
echo "Generated public key:  $PUBLIC_KEY_PATH"

echo
echo "GitHub Actions secret payload (base64 PEM):"
base64 -w 0 "$PRIVATE_KEY_PATH"
echo
