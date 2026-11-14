#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${1:-$SCRIPT_DIR}"
mkdir -p "$OUTPUT_DIR"

CERT_PATH="$OUTPUT_DIR/server.crt"
KEY_PATH="$OUTPUT_DIR/server.key"
DAYS=365

echo "Generating self-signed RSA certificate and key in $OUTPUT_DIR..."

openssl req -x509 -newkey rsa:2048 -nodes -sha256 \
  -keyout "$KEY_PATH" \
  -out "$CERT_PATH" \
  -days "$DAYS" \
  -subj "/CN=localhost" \
  -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" \
  2>/dev/null

chmod 600 "$KEY_PATH"
chmod 644 "$CERT_PATH"

echo "Certificate generated: $CERT_PATH"
echo "Key generated:         $KEY_PATH"
