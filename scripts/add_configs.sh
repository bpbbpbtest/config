#!/usr/bin/env bash
set -uo pipefail

TOKEN="${MAHSA_API_TOKEN:?MAHSA_API_TOKEN secret is not set}"
API_URL="${MAHSA_API_URL:-https://www.mahsaserver.com/backend/api/v1/config/}"
CONFIGS_FILE="${CONFIGS_FILE:-config.txt}"
DELAY="${DELAY:-45}"
ADS_URL="${ADS_URL:-🔥برای اتصال رایگان و با کیفیت آموزش های پین شده را چک کنید: https://t.me/DeltaKroneckerGithub}"
USER_AGENT="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36"
MAX_ATTEMPTS=15
# حداکثر مدت اجرا: 5 ساعت و 30 دقیقه = 19800 ثانیه
MAX_RUNTIME="${MAX_RUNTIME:-19800}"

RESP_FILE="$(mktemp)"
HDR_FILE="$(mktemp)"
TMP_REMAINING="$(mktemp)"
START_TIME=$(date +%s)

cleanup() {
  rm -f "$RESP_FILE" "$HDR_FILE" "$TMP_REMAINING"
}
trap cleanup EXIT

[ -f "$CONFIGS_FILE" ] || { echo "Config file '$CONFIGS_FILE' not found"; exit 1; }

added=0
already=0
failed=0
total=0
line_num=0
removed=0

# خطوط باقی‌مانده (اضافه‌نشده) را در فایل موقت ذخیره می‌کنیم
: > "$TMP_REMAINING"

while IFS= read -r line; do
  line_num=$((line_num + 1))

  # بررسی زمان اجرا
  now=$(date +%s)
  elapsed=$((now - START_TIME))
  if [ "$elapsed" -ge "$MAX_RUNTIME" ]; then
    echo "⏰ Max runtime (${MAX_RUNTIME}s) reached. Stopping."
    # این خط و خطوط بعدی را دست‌نخورده نگه می‌داریم
    printf '%s\n' "$line" >> "$TMP_REMAINING"
    continue
  fi

  line="${line%$'\r'}"
  url="${line#"${line%%[![:space:]]*}"}"
  url="${url%"${url##*[![:space:]]}"}"

  if [ -z "$url" ]; then
    # خط خالی را حفظ می‌کنیم
    printf '\n' >> "$TMP_REMAINING"
    continue
  fi

  total=$((total + 1))

  payload="$(jq -nc --arg url "$url" --arg ads "$ADS_URL" '{url:$url, ads_url:$ads, pool:"mahsa", use_fragment:true, use_mux:false}')"

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
    removed=$((removed + 1))
    echo "[line $line_num] ADDED (removed from file)"
    # خط اضافه‌شده را در فایل باقی‌مانده نمی‌نویسیم => حذف می‌شود
  elif echo "$body" | grep -q "already used by another donor\|You cannot submit same config"; then
    already=$((already + 1))
    echo "[line $line_num] ALREADY EXISTS (removed from file)"
    # این خط هم دیگر نیازی به تلاش مجدد ندارد => حذف می‌شود
  else
    failed=$((failed + 1))
    echo "[line $line_num] FAILED (HTTP $code): $body"
    # خط ناموفق را برای تلاش بعدی نگه می‌داریم
    printf '%s\n' "$line" >> "$TMP_REMAINING"
  fi

  sleep "$DELAY"
done < "$CONFIGS_FILE"

# جایگزینی فایل اصلی با خطوط باقی‌مانده
if [ -f "$TMP_REMAINING" ]; then
  # حذف خطوط خالی اضافی انتهای فایل
  awk 'NF || prev {print} {prev=NF}' "$TMP_REMAINING" > "${TMP_REMAINING}.clean" || true
  mv "${TMP_REMAINING}.clean" "$CONFIGS_FILE"
fi

echo ""
echo "===== SUMMARY ====="
echo "total lines  : $total"
echo "added        : $added"
echo "already exist: $already"
echo "removed      : $removed"
echo "failed       : $failed"

# اگر خطای واقعی رخ داده بود، با کد خطا خارج می‌شویم
[ "$failed" -eq 0 ]
