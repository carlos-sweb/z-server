#!/usr/bin/env bash
# Helper script to run testssl.sh against local z-server TLS listener.
set -euo pipefail

TARGET="${1:-https://127.0.0.1:8443}"
TESTSSL_DIR="/tmp/testssl"

if [ ! -x "$TESTSSL_DIR/testssl.sh" ]; then
    echo "testssl.sh not found in $TESTSSL_DIR, attempting to clone repository..."
    if ! git clone --depth 1 https://github.com/drwetter/testssl.sh.git "$TESTSSL_DIR" 2>/dev/null; then
        echo "note: testssl.sh requires network to download; skip and use openssl s_client manually." >&2
        exit 0
    fi
fi

echo "Running testssl.sh against $TARGET..."
"$TESTSSL_DIR/testssl.sh" --quiet --color 0 "$TARGET"
