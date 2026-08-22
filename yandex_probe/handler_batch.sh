#!/bin/bash
set -uo pipefail

cat >/dev/null || true

ROOT="$(cd "$(dirname "$0")" && pwd)"
WORK="/tmp/mihomo-batch-${REQUEST_ID:-manual}"
MIHOMO_BIN="$ROOT/mihomo"

rm -rf "$WORK"
mkdir -p "$WORK"
cp "$ROOT/config.yaml" "$WORK/config.yaml"

respond() {
  local status="$1"
  local body="$2"
  jq -cn --argjson status "$status" --arg body "$body" \
    '{statusCode:$status,body:$body}'
  exit 0
}

META="$(cat "$ROOT/meta.json" 2>/dev/null || echo '{}')"

echo "batch: starting Mihomo RU test" >&2
echo "batch: meta=$META" >&2
echo "batch: binary=$(ls -l "$MIHOMO_BIN" 2>&1)" >&2

VERSION_OUTPUT="$("$MIHOMO_BIN" -v 2>&1)"
VERSION_STATUS=$?

if [[ "$VERSION_STATUS" -ne 0 ]]; then
  BODY="$(jq -cn \
    --arg output "$VERSION_OUTPUT" \
    --argjson exit_status "$VERSION_STATUS" \
    '{ok:false,error:"mihomo_binary_execution_failed",exit_status:$exit_status,output:$output}')"
  respond 500 "$BODY"
fi

VERSION="$(printf '%s' "$VERSION_OUTPUT" | head -n 1)"

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

READY=0
for _ in $(seq 1 100); do
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
  STDERR_LOG="$(tail -c 8000 "$WORK/mihomo.stderr.log" 2>/dev/null || true)"
  BODY="$(jq -cn \
    --arg version "$VERSION" \
    --arg stderr "$STDERR_LOG" \
    --argjson meta "$META" \
    '{ok:false,mihomo_version:$version,error:"controller_not_ready",stderr:$stderr,meta:$meta}')"
  respond 500 "$BODY"
fi

START_MS="$(date +%s%3N)"

HTTP_RESPONSE="$(
  exec 3<>/dev/tcp/127.0.0.1/9090
  printf '%s\r\n' \
    'GET /group/RU-BATCH/delay?timeout=5000&url=https%3A%2F%2Fcp.cloudflare.com HTTP/1.1' \
    'Host: 127.0.0.1:9090' \
    'Connection: close' \
    '' >&3
  cat <&3
  exec 3<&-
  exec 3>&-
)"

END_MS="$(date +%s%3N)"
ELAPSED_MS=$((END_MS - START_MS))

PROBE_BODY="$(
  printf '%s' "$HTTP_RESPONSE" |
    tr -d '\r' |
    awk 'found {print} /^$/ {found=1}'
)"

if ! printf '%s' "$PROBE_BODY" | jq -e 'type == "object"' >/dev/null 2>&1; then
  PROBE_BODY="$(
    printf '%s\n' "$PROBE_BODY" |
      sed -E '/^[0-9A-Fa-f]+$/d' |
      tr -d '\n'
  )"
fi

if ! printf '%s' "$PROBE_BODY" | jq -e 'type == "object"' >/dev/null 2>&1; then
  STDERR_LOG="$(tail -c 8000 "$WORK/mihomo.stderr.log" 2>/dev/null || true)"
  BODY="$(jq -cn \
    --arg version "$VERSION" \
    --arg raw "$PROBE_BODY" \
    --arg stderr "$STDERR_LOG" \
    --argjson elapsed "$ELAPSED_MS" \
    --argjson meta "$META" \
    '{ok:false,mihomo_version:$version,error:"invalid_group_delay_response",elapsed_ms:$elapsed,raw:$raw,stderr:$stderr,meta:$meta}')"
  respond 500 "$BODY"
fi

SUMMARY="$(
  printf '%s' "$PROBE_BODY" |
    jq -c \
      --arg version "$VERSION" \
      --argjson elapsed "$ELAPSED_MS" \
      --argjson meta "$META" '
      . as $delays |
      [
        to_entries[]
        | select(
            (.value | type) == "number"
            and .value > 0
          )
      ] as $alive |
      ($alive | sort_by(.value)) as $sorted |
      {
        ok: true,
        mihomo_version: $version,
        elapsed_ms: $elapsed,
        requested: ($meta.requested // null),
        selected: ($meta.selected // null),
        converted: ($meta.converted // null),
        conversion_failed: ($meta.conversion_failed // null),
        protocols_selected: ($meta.protocols_selected // {}),
        alive: ($alive | length),
        dead_or_timeout: (($meta.converted // 0) - ($alive | length)),
        fastest: ($sorted[0:20]),
        delays: $delays
      }'
)"

respond 200 "$SUMMARY"
