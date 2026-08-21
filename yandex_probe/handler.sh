#!/bin/bash
set -euo pipefail

# Yandex Cloud Functions passes the invocation JSON through stdin.
# We do not need it for this probe.
cat >/dev/null || true

ROOT="$(cd "$(dirname "$0")" && pwd)"
WORK="/tmp/mihomo-probe"
mkdir -p "$WORK"

cp "$ROOT/probe_config.yaml" "$WORK/config.yaml"
chmod +x "$ROOT/mihomo"

cleanup() {
  if [[ -n "${MIHOMO_PID:-}" ]]; then
    kill "$MIHOMO_PID" 2>/dev/null || true
    wait "$MIHOMO_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

VERSION="$("$ROOT/mihomo" -v 2>&1 | head -n 1)"

"$ROOT/mihomo" -d "$WORK" -f "$WORK/config.yaml" \
  >"$WORK/mihomo.stdout.log" \
  2>"$WORK/mihomo.stderr.log" &
MIHOMO_PID=$!

# Wait until Mihomo's local controller is accepting connections.
READY=0
for _ in $(seq 1 50); do
  if (echo >/dev/tcp/127.0.0.1/9090) >/dev/null 2>&1; then
    READY=1
    break
  fi
  if ! kill -0 "$MIHOMO_PID" 2>/dev/null; then
    break
  fi
  sleep 0.1
done

if [[ "$READY" != "1" ]]; then
  LOG="$(tail -c 4000 "$WORK/mihomo.stderr.log" 2>/dev/null || true)"
  BODY="$(jq -cn --arg version "$VERSION" --arg log "$LOG" \
    '{ok:false,mihomo_version:$version,error:"mihomo_controller_not_ready",log:$log}')"
  jq -cn --arg body "$BODY" '{statusCode:500,body:$body}'
  exit 0
fi

# Ask Mihomo itself to perform a real HTTPS delay test through DIRECT.
# This proves that the Mihomo core can make outbound traffic from the
# Yandex Cloud Function environment.
HTTP_RESPONSE="$(
  exec 3<>/dev/tcp/127.0.0.1/9090
  printf '%s\r\n' \
    'GET /proxies/DIRECT/delay?timeout=5000&url=https%3A%2F%2Fcp.cloudflare.com%2Fgenerate_204 HTTP/1.1' \
    'Host: 127.0.0.1:9090' \
    'Connection: close' \
    '' >&3
  cat <&3
  exec 3<&-
  exec 3>&-
)"

PROBE_BODY="$(
  printf '%s' "$HTTP_RESPONSE" |
    tr -d '\r' |
    awk 'found {print} /^$/ {found=1}'
)"

if printf '%s' "$PROBE_BODY" | jq -e '.delay > 0' >/dev/null 2>&1; then
  DELAY="$(printf '%s' "$PROBE_BODY" | jq -r '.delay')"
  BODY="$(jq -cn \
    --arg version "$VERSION" \
    --argjson delay "$DELAY" \
    '{ok:true,mihomo_version:$version,direct_ru_delay_ms:$delay}')"
  jq -cn --arg body "$BODY" '{statusCode:200,body:$body}'
else
  LOG="$(tail -c 4000 "$WORK/mihomo.stderr.log" 2>/dev/null || true)"
  BODY="$(jq -cn \
    --arg version "$VERSION" \
    --arg probe "$PROBE_BODY" \
    --arg log "$LOG" \
    '{ok:false,mihomo_version:$version,error:"direct_delay_test_failed",probe:$probe,log:$log}')"
  jq -cn --arg body "$BODY" '{statusCode:500,body:$body}'
fi
