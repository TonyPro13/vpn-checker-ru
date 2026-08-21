#!/bin/bash
set -uo pipefail

# Consume invocation payload. The probe does not use it yet.
cat >/dev/null || true

ROOT="$(cd "$(dirname "$0")" && pwd)"
WORK="/tmp/mihomo-probe-${REQUEST_ID:-manual}"
MIHOMO_BIN="$ROOT/mihomo"

rm -rf "$WORK"
mkdir -p "$WORK"
cp "$ROOT/probe_config.yaml" "$WORK/config.yaml"

respond() {
  local status="$1"
  local body="$2"
  jq -cn --argjson status "$status" --arg body "$body" \
    '{statusCode:$status,body:$body}'
  exit 0
}

echo "probe: ROOT=$ROOT" >&2
echo "probe: WORK=$WORK" >&2
echo "probe: mihomo permissions: $(ls -l "$MIHOMO_BIN" 2>&1)" >&2

# Yandex mounts /tmp with NOEXEC.
# Uploaded executable dependencies must run directly from /function/code.
if [[ ! -x "$MIHOMO_BIN" ]]; then
  BODY="$(jq -cn \
    --arg permissions "$(ls -l "$MIHOMO_BIN" 2>&1 || true)" \
    '{ok:false,error:"mihomo_not_executable_in_function_code",permissions:$permissions}')"
  respond 500 "$BODY"
fi

VERSION_OUTPUT="$("$MIHOMO_BIN" -v 2>&1)"
VERSION_STATUS=$?

if [[ "$VERSION_STATUS" -ne 0 ]]; then
  echo "probe: mihomo -v failed: $VERSION_OUTPUT" >&2
  BODY="$(jq -cn \
    --arg output "$VERSION_OUTPUT" \
    --argjson status "$VERSION_STATUS" \
    '{ok:false,error:"mihomo_binary_execution_failed",exit_status:$status,output:$output}')"
  respond 500 "$BODY"
fi

VERSION="$(printf '%s' "$VERSION_OUTPUT" | head -n 1)"
echo "probe: mihomo version: $VERSION" >&2

cleanup() {
  if [[ -n "${MIHOMO_PID:-}" ]]; then
    kill "$MIHOMO_PID" 2>/dev/null || true
    wait "$MIHOMO_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

"$MIHOMO_BIN" -d "$WORK" -f "$WORK/config.yaml" \
  >"$WORK/mihomo.stdout.log" \
  2>"$WORK/mihomo.stderr.log" &
MIHOMO_PID=$!

echo "probe: mihomo pid=$MIHOMO_PID" >&2

# Wait until the local controller is ready.
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
  STDERR_LOG="$(tail -c 6000 "$WORK/mihomo.stderr.log" 2>/dev/null || true)"
  STDOUT_LOG="$(tail -c 6000 "$WORK/mihomo.stdout.log" 2>/dev/null || true)"
  echo "probe: controller not ready" >&2
  echo "probe: mihomo stderr: $STDERR_LOG" >&2
  echo "probe: mihomo stdout: $STDOUT_LOG" >&2

  BODY="$(jq -cn \
    --arg version "$VERSION" \
    --arg stderr "$STDERR_LOG" \
    --arg stdout "$STDOUT_LOG" \
    '{ok:false,mihomo_version:$version,error:"mihomo_controller_not_ready",stderr:$stderr,stdout:$stdout}')"
  respond 500 "$BODY"
fi

echo "probe: controller ready" >&2

# Ask Mihomo itself to run a real HTTPS delay test through DIRECT.
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

echo "probe: controller response body: $PROBE_BODY" >&2

# Normal non-chunked JSON response.
if printf '%s' "$PROBE_BODY" | jq -e '.delay > 0' >/dev/null 2>&1; then
  DELAY="$(printf '%s' "$PROBE_BODY" | jq -r '.delay')"
  BODY="$(jq -cn \
    --arg version "$VERSION" \
    --argjson delay "$DELAY" \
    '{ok:true,mihomo_version:$version,direct_ru_delay_ms:$delay}')"
  respond 200 "$BODY"
fi

# Handle a possible HTTP chunked response: strip hex chunk-size lines.
DECHUNKED="$(
  printf '%s\n' "$PROBE_BODY" |
    sed -E '/^[0-9A-Fa-f]+$/d' |
    tr -d '\n'
)"

if printf '%s' "$DECHUNKED" | jq -e '.delay > 0' >/dev/null 2>&1; then
  DELAY="$(printf '%s' "$DECHUNKED" | jq -r '.delay')"
  BODY="$(jq -cn \
    --arg version "$VERSION" \
    --argjson delay "$DELAY" \
    '{ok:true,mihomo_version:$version,direct_ru_delay_ms:$delay}')"
  respond 200 "$BODY"
fi

STDERR_LOG="$(tail -c 6000 "$WORK/mihomo.stderr.log" 2>/dev/null || true)"
BODY="$(jq -cn \
  --arg version "$VERSION" \
  --arg probe "$PROBE_BODY" \
  --arg log "$STDERR_LOG" \
  '{ok:false,mihomo_version:$version,error:"direct_delay_test_failed",probe:$probe,log:$log}')"
respond 500 "$BODY"
