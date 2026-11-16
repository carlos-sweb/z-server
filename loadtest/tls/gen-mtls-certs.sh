#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
  -keyout ca.key -out ca.crt -subj "/CN=Test CA"
openssl req -newkey rsa:2048 -nodes \
  -keyout client.key -out client.csr -subj "/CN=test-client"
openssl x509 -req -in client.csr -CA ca.crt -CAkey ca.key \
  -CAcreateserial -out client.crt -days 365
openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
  -keyout other_ca.key -out other_ca.crt \
  -subj "/CN=Other CA"
openssl req -newkey rsa:2048 -nodes \
  -keyout other_client.key -out other_client.csr \
  -subj "/CN=other-client"
openssl x509 -req -in other_client.csr -CA other_ca.crt \
  -CAkey other_ca.key -CAcreateserial \
  -out other_client.crt -days 365
rm -f *.csr *.srl
