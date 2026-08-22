#!/usr/bin/env bash
set -uo pipefail

TOKEN="${MAHSA_API_TOKEN:?MAHSA_API_TOKEN secret is not set}"
API_URL="${MAHSA_API_URL:-https://www.mahsaserver.com/backend/api/v1/config/}"
CONFIGS_FILE="${CONFIGS_FILE:-config.txt}"
DELAY="${DELAY:-30}"
ADS_URL="${ADS_URL:- برای کانفیگ های بیشتر به تلگرام ما بپیوندید     https://t.me/DeltaKroneckerGithub}"
USER_AGENT="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36"
MAX_ATTEMPTS=15

RESP_FILE="$(mktemp)"
HDR_FILE="$(mktemp)"

[ -f "$CONFIGS_FILE" ] || { echo "Config file '$CONFIGS_FILE' not found"; exit 1; }

added=0
already=0
failed=0
total=0
line_num=0

while IFS= read -r line; do
  line_num=$((line_num + 1))
  line="${line%$'\r'}"
  url="${line#"${line%%[![:space:]]*}"}"
  url="${url%"${url##*[![:space:]]}"}"
  [ -z "$url" ] && continue
  total=$((total + 1))

  payload="$(jq -nc --arg url "$url" --arg ads "$ADS_URL" '{url:$url, ads_url:$ads, pool:"mahsa", use_fragment:false, use_mux:false}')"

  code=000
  attempt=0
  while [ "$code" != "201" ] && [ "$attempt" -lt "$MAX_ATTEMPTS" ]; do
    attempt=$((attempt + 1))
    code="$(curl -s -D "$HDR_FILE" -o "$RESP_FILE" -w '%{http_code}' \
      -X POST "$API_URL" \
      -H "Authorization: Token $TOKEN" \
      -H "Content-Type: application/json" \
      -H "User-Agent: $USER_AGENT" \
      --data "$payload")"

    if [ "$code" = "429" ]; then
      body="$(cat "$RESP_FILE")"
      wait="$(tr -d '\r' < "$HDR_FILE" | grep -i '^retry-after:' | head -1 | cut -d: -f2 | tr -d ' ')"
      [ -z "$wait" ] && wait="$(printf '%s' "$body" | sed -n 's/.*Expected available in \([0-9.]*\) seconds.*/\1/p')"
      if [ -z "$wait" ]; then
        secs="$DELAY"
      else
        secs="$(awk -v v="$wait" 'BEGIN{printf "%d", v+2}')"
        [ "$secs" -lt 5 ] && secs=5
      fi
      echo "[line $line_num] throttled, waiting ${secs}s (attempt $attempt/$MAX_ATTEMPTS)..."
      sleep "$secs"
    fi
  done

  body="$(cat "$RESP_FILE")"
  if [ "$code" = "201" ]; then
    added=$((added + 1))
    echo "[line $line_num] ADDED"
  elif echo "$body" | grep -q "already used by another donor\|You cannot submit same config"; then
    already=$((already + 1))
    echo "[line $line_num] ALREADY EXISTS"
  else
    failed=$((failed + 1))
    echo "[line $line_num] FAILED (HTTP $code): $body"
  fi
  sleep "$DELAY"
done < "$CONFIGS_FILE"

rm -f "$RESP_FILE" "$HDR_FILE"

echo ""
echo "===== SUMMARY ====="
echo "total lines  : $total"
echo "added        : $added"
echo "already exist: $already"
echo "failed       : $failed"

[ "$failed" -eq 0 ]
