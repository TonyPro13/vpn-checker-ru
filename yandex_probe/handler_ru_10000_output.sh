#!/bin/bash
set -uo pipefail

cat >/dev/null || true

ROOT="$(cd "$(dirname "$0")" && pwd)"
BASE_WORK="/tmp/mihomo-ru-output-${REQUEST_ID:-manual}"
MIHOMO_BIN="$ROOT/mihomo"
MANIFEST="$ROOT/manifest.json"
META="$ROOT/meta.json"
MAPPING="$ROOT/mapping.json"

rm -rf "$BASE_WORK"
mkdir -p "$BASE_WORK"

respond() {
  local status="$1"
  local body="$2"
  jq -cn --argjson status "$status" --arg body "$body" \
    '{statusCode:$status,body:$body}'
  exit 0
}

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
TOTAL_START_MS="$(date +%s%3N)"

ALIVE_JSONL="$BASE_WORK/alive.jsonl"
CHUNKS_JSONL="$BASE_WORK/chunks.jsonl"
: >"$ALIVE_JSONL"
: >"$CHUNKS_JSONL"

MIHOMO_PID=""

cleanup_mihomo() {
  if [[ -n "${MIHOMO_PID:-}" ]]; then
    kill "$MIHOMO_PID" 2>/dev/null || true
    wait "$MIHOMO_PID" 2>/dev/null || true
    MIHOMO_PID=""
  fi
}

cleanup() {
  cleanup_mihomo
}
trap cleanup EXIT

run_chunk() {
  local chunk_index="$1"
  local chunk_file="$2"
  local expected_count="$3"

  local work="$BASE_WORK/chunk_$(printf '%03d' "$chunk_index")"
  mkdir -p "$work"
  cp "$ROOT/$chunk_file" "$work/config.yaml"

  cleanup_mihomo

  "$MIHOMO_BIN" -d "$work" -f "$work/config.yaml" \
    >"$work/mihomo.stdout.log" \
    2>"$work/mihomo.stderr.log" &
  MIHOMO_PID=$!

  local ready=0
  for _ in $(seq 1 150); do
    if (echo >/dev/tcp/127.0.0.1/9090) >/dev/null 2>&1; then
      ready=1
      break
    fi
    if ! kill -0 "$MIHOMO_PID" 2>/dev/null; then
      break
    fi
    sleep 0.1
  done

  if [[ "$ready" != "1" ]]; then
    local stderr_log
    stderr_log="$(tail -c 12000 "$work/mihomo.stderr.log" 2>/dev/null || true)"
    BODY="$(jq -cn \
      --arg version "$VERSION" \
      --argjson chunk "$chunk_index" \
      --arg file "$chunk_file" \
      --arg stderr "$stderr_log" \
      '{ok:false,mihomo_version:$version,error:"controller_not_ready",chunk:$chunk,file:$file,stderr:$stderr}')"
    respond 500 "$BODY"
  fi

  local start_ms end_ms elapsed_ms
  start_ms="$(date +%s%3N)"

  local http_response
  http_response="$(
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

  end_ms="$(date +%s%3N)"
  elapsed_ms=$((end_ms - start_ms))

  local probe_body
  probe_body="$(
    printf '%s' "$http_response" |
      tr -d '\r' |
      awk 'found {print} /^$/ {found=1}'
  )"

  if ! printf '%s' "$probe_body" | jq -e 'type == "object"' >/dev/null 2>&1; then
    probe_body="$(
      printf '%s\n' "$probe_body" |
        sed -E '/^[0-9A-Fa-f]+$/d' |
        tr -d '\n'
    )"
  fi

  if ! printf '%s' "$probe_body" | jq -e 'type == "object"' >/dev/null 2>&1; then
    local stderr_log
    stderr_log="$(tail -c 12000 "$work/mihomo.stderr.log" 2>/dev/null || true)"
    BODY="$(jq -cn \
      --arg version "$VERSION" \
      --argjson chunk "$chunk_index" \
      --arg raw "$probe_body" \
      --arg stderr "$stderr_log" \
      '{ok:false,mihomo_version:$version,error:"invalid_group_delay_response",chunk:$chunk,raw:$raw,stderr:$stderr}')"
    respond 500 "$BODY"
  fi

  printf '%s' "$probe_body" |
    jq -c '
      to_entries[]
      | select((.value|type) == "number" and .value > 0)
      | {key:.key,value:.value}
    ' >>"$ALIVE_JSONL"

  local alive_count
  alive_count="$(
    printf '%s' "$probe_body" |
      jq '[
        to_entries[]
        | select((.value|type) == "number" and .value > 0)
      ] | length'
  )"

  jq -cn \
    --argjson chunk "$chunk_index" \
    --arg file "$chunk_file" \
    --argjson expected "$expected_count" \
    --argjson alive "$alive_count" \
    --argjson elapsed "$elapsed_ms" \
    '{
      chunk:$chunk,
      file:$file,
      checked:$expected,
      alive:$alive,
      dead_or_timeout:($expected-$alive),
      elapsed_ms:$elapsed
    }' >>"$CHUNKS_JSONL"

  echo "RU chunk $chunk_index: checked=$expected_count alive=$alive_count elapsed_ms=$elapsed_ms" >&2

  cleanup_mihomo
}

while IFS=$'\t' read -r chunk_index chunk_file chunk_count; do
  run_chunk "$chunk_index" "$chunk_file" "$chunk_count"
done < <(
  jq -r '.chunks[] | [.index,.file,.count] | @tsv' "$MANIFEST"
)

TOTAL_END_MS="$(date +%s%3N)"
TOTAL_ELAPSED_MS=$((TOTAL_END_MS - TOTAL_START_MS))

ALIVE_ARRAY_FILE="$BASE_WORK/alive.json"
CHUNKS_ARRAY_FILE="$BASE_WORK/chunks.json"
SUMMARY_FILE="$BASE_WORK/summary.json"

if [[ -s "$ALIVE_JSONL" ]]; then
  jq -sc 'sort_by(.value)' "$ALIVE_JSONL" >"$ALIVE_ARRAY_FILE"
else
  printf '[]\n' >"$ALIVE_ARRAY_FILE"
fi

jq -sc '.' "$CHUNKS_JSONL" >"$CHUNKS_ARRAY_FILE"

# IMPORTANT:
# mapping.json can be large (10k original URIs). Do not pass it to jq via
# --argjson: Linux limits the total argv size and that caused
# "/function/runtime/jq: Argument list too long".
# Read all large JSON values directly from files instead.
jq -cn \
  --arg version "$VERSION" \
  --argjson total_elapsed "$TOTAL_ELAPSED_MS" \
  --slurpfile meta "$META" \
  --slurpfile manifest "$MANIFEST" \
  --slurpfile mapping "$MAPPING" \
  --slurpfile alive_nodes "$ALIVE_ARRAY_FILE" \
  --slurpfile chunks "$CHUNKS_ARRAY_FILE" '
  def pct($a; $p):
    if ($a|length) == 0 then null
    elif ($a|length) == 1 then $a[0]
    else
      ((($a|length)-1) * $p) as $r
      | ($r|floor) as $lo
      | ($r|ceil) as $hi
      | if $lo == $hi then $a[$lo]
        else (($a[$lo] * ($hi-$r)) + ($a[$hi] * ($r-$lo)))
        end
    end;

  ($meta[0] // {}) as $meta
  | ($manifest[0] // {}) as $manifest
  | ($mapping[0] // {}) as $mapping
  | ($alive_nodes[0] // []) as $alive_nodes
  | ($chunks[0] // []) as $chunks
  | (
      $alive_nodes
      | map(
          . as $alive
          | ($mapping[$alive.key] // {}) as $m
          | {
              key:$alive.key,
              ru_delay_ms:$alive.value,
              protocol:($m.protocol // null),
              source_index:($m.source_index // null),
              selected_index:($m.selected_index // null),
              uri:($m.uri // null)
            }
        )
    ) as $survivors
  | ($survivors | map(.ru_delay_ms)) as $vals
  | {
      ok:true,
      mihomo_version:$version,
      location:"yandex_ru",
      stage:"ru_mihomo_filter",
      strategy:"sequential_chunks",
      chunk_size:$manifest.chunk_size,
      chunks_total:$manifest.chunks_total,
      function_elapsed_ms:$total_elapsed,
      requested:($meta.requested // null),
      pool_size:($meta.pool_size // null),
      selected:($meta.selected // null),
      converted_before_mihomo_validation:($meta.converted_before_mihomo_validation // null),
      converted:($meta.converted // null),
      conversion_failed:($meta.conversion_failed // null),
      mihomo_validation:($meta.mihomo_validation // {}),
      protocols_selected:($meta.protocols_selected // {}),
      alive:($survivors|length),
      dead_or_timeout:(($meta.converted // 0)-($survivors|length)),
      mapping_missing:([$survivors[] | select(.uri == null)] | length),
      latency_ms:{
        min:(if ($vals|length)>0 then ($vals|min) else null end),
        p50:pct($vals;0.50),
        p90:pct($vals;0.90),
        max:(if ($vals|length)>0 then ($vals|max) else null end),
        average:(if ($vals|length)>0 then (($vals|add)/($vals|length)) else null end)
      },
      fastest_20:($survivors[0:20]),
      chunks:$chunks,
      survivors:$survivors
    }' >"$SUMMARY_FILE"

SUMMARY_STATUS=$?
if [[ "$SUMMARY_STATUS" -ne 0 || ! -s "$SUMMARY_FILE" ]]; then
  BODY="$(jq -cn \
    --argjson status "$SUMMARY_STATUS" \
    '{ok:false,error:"summary_generation_failed",jq_exit_status:$status}')"
  respond 500 "$BODY"
fi

# Do not pass the large final body as --arg either. Read it from disk.
# Cloud Functions expects body to be a string in this raw integration shape.
jq -cn \
  --argjson status 200 \
  --rawfile body "$SUMMARY_FILE" \
  '{statusCode:$status,body:$body}'

exit 0
