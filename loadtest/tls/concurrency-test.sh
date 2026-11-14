#!/usr/bin/env bash
set -euo pipefail

PORT="${1:-8443}"
BASE_URL="https://127.0.0.1:$PORT"
CONCURRENCY="${2:-50}"
TOTAL_REQUESTS="${3:-200}"

echo "Starting TLS concurrency test: $TOTAL_REQUESTS requests with concurrency $CONCURRENCY against $BASE_URL"

FAILED=0
TMP_OUT="$(mktemp -d)"
trap 'rm -rf "$TMP_OUT"' EXIT

START_TIME=$(date +%s%N)

seq 1 "$TOTAL_REQUESTS" | xargs -P "$CONCURRENCY" -I {} bash -c '
  ID="$1"
  BASE_URL="$2"
  TMP_OUT="$3"
  MOD=$((ID % 3))
  if [ $MOD -eq 0 ]; then
    HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" "$BASE_URL/health")
  elif [ $MOD -eq 1 ]; then
    HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" "$BASE_URL/items")
  else
    HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/items" \
      -H "Content-Type: application/json" \
      -d "{\"name\":\"c-test-$ID\",\"payload\":{\"val\":$ID}}")
  fi

  if [ "$HTTP_CODE" -ne 200 ] && [ "$HTTP_CODE" -ne 201 ]; then
    echo "Request $ID failed with HTTP $HTTP_CODE" >> "$TMP_OUT/errors.log"
  else
    echo "$HTTP_CODE" >> "$TMP_OUT/success.log"
  fi
' _ {} "$BASE_URL" "$TMP_OUT"

END_TIME=$(date +%s%N)
DURATION_MS=$(( (END_TIME - START_TIME) / 1000000 ))
SUCCESS_COUNT=$(if [ -f "$TMP_OUT/success.log" ]; then wc -l < "$TMP_OUT/success.log"; else echo 0; fi)
ERROR_COUNT=$(if [ -f "$TMP_OUT/errors.log" ]; then wc -l < "$TMP_OUT/errors.log"; else echo 0; fi)

RPS=$(awk "BEGIN { if ($DURATION_MS > 0) printf \"%.2f\", ($SUCCESS_COUNT * 1000.0) / $DURATION_MS; else print 0 }")

echo "=== TLS Concurrency Test Results ==="
echo "Total requests: $TOTAL_REQUESTS"
echo "Concurrency:    $CONCURRENCY"
echo "Success:        $SUCCESS_COUNT"
echo "Errors:         $ERROR_COUNT"
echo "Duration:       ${DURATION_MS} ms"
echo "Throughput:     $RPS req/s"

if [ -f "$TMP_OUT/errors.log" ]; then
  head -n 10 "$TMP_OUT/errors.log"
  exit 1
fi

echo "TLS concurrency test PASSED!"
