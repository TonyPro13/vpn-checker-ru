#!/bin/bash
set -uo pipefail

cat >/dev/null || true

ROOT="$(cd "$(dirname "$0")" && pwd)"
BASE_WORK="/tmp/mihomo-ru-speed-${REQUEST_ID:-manual}"
MIHOMO_BIN="$ROOT/mihomo"
SPEED_BIN="$ROOT/speed_probe"
MANIFEST="$ROOT/manifest.json"
META="$ROOT/meta.json"
MAPPING="$ROOT/mapping.json"
PROXY_DEFS="$ROOT/proxy_defs.json"

SPEED_BYTES=524288
SPEED_CONCURRENCY=8
SPEED_TIMEOUT_SECONDS=8
SPEED_URL_BASE="https://speed.cloudflare.com/__down"

rm -rf "$BASE_WORK"
mkdir -p "$BASE_WORK"

respond_file() {
  local status="$1"
  local body_file="$2"
  jq -cn \
    --argjson status "$status" \
    --rawfile body "$body_file" \
    '{statusCode:$status,body:$body}'
  exit 0
}

respond_json() {
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
  respond_json 500 "$BODY"
fi

if [[ ! -x "$SPEED_BIN" ]]; then
  BODY='{"ok":false,"error":"speed_probe_binary_missing"}'
  respond_json 500 "$BODY"
fi

VERSION="$(printf '%s' "$VERSION_OUTPUT" | head -n 1)"
FUNCTION_START_MS="$(date +%s%3N)"
RU_FILTER_START_MS="$FUNCTION_START_MS"

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
    respond_json 500 "$BODY"
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
    respond_json 500 "$BODY"
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

RU_FILTER_END_MS="$(date +%s%3N)"
RU_FILTER_ELAPSED_MS=$((RU_FILTER_END_MS - RU_FILTER_START_MS))

ALIVE_ARRAY_FILE="$BASE_WORK/alive.json"
CHUNKS_ARRAY_FILE="$BASE_WORK/chunks.json"

if [[ -s "$ALIVE_JSONL" ]]; then
  jq -sc 'sort_by(.value)' "$ALIVE_JSONL" >"$ALIVE_ARRAY_FILE"
else
  printf '[]\n' >"$ALIVE_ARRAY_FILE"
fi

jq -sc '.' "$CHUNKS_JSONL" >"$CHUNKS_ARRAY_FILE"

ALIVE_COUNT="$(jq 'length' "$ALIVE_ARRAY_FILE")"

SPEED_RESULTS_FILE="$BASE_WORK/speed_results.json"
printf '[]\n' >"$SPEED_RESULTS_FILE"

if [[ "$ALIVE_COUNT" -gt 0 ]]; then
  SPEED_CONFIG="$BASE_WORK/speed_config.yaml"
  SPEED_JOBS="$BASE_WORK/speed_jobs.json"
  SPEED_WORK="$BASE_WORK/speed_runtime"

  mkdir -p "$SPEED_WORK"

  jq -cn \
    --slurpfile alive "$ALIVE_ARRAY_FILE" \
    --slurpfile defs "$PROXY_DEFS" '
    ($alive[0] // []) as $alive
    | ($defs[0] // {}) as $defs
    | {
        "allow-lan": false,
        "mode": "rule",
        "log-level": "warning",
        "ipv6": false,
        "proxies": [
          $alive[]
          | $defs[.key]
          | select(. != null)
        ],
        "listeners": [
          range(0; ($alive|length)) as $i
          | {
              name:("speed-in-" + (($i+1)|tostring)),
              type:"mixed",
              listen:"127.0.0.1",
              port:(20000 + $i),
              udp:false,
              proxy:$alive[$i].key
            }
        ],
        "rules":["MATCH,DIRECT"]
      }' >"$SPEED_CONFIG"

  jq -cn \
    --slurpfile alive "$ALIVE_ARRAY_FILE" '
    ($alive[0] // []) as $alive
    | [
        range(0; ($alive|length)) as $i
        | {
            key:$alive[$i].key,
            port:(20000 + $i)
          }
      ]' >"$SPEED_JOBS"

  echo "Speed stage: alive=$ALIVE_COUNT listeners=$(jq '.listeners|length' "$SPEED_CONFIG") concurrency=$SPEED_CONCURRENCY bytes_each=$SPEED_BYTES" >&2

  if ! "$MIHOMO_BIN" -t -f "$SPEED_CONFIG" >"$BASE_WORK/speed_validate.stdout.log" 2>"$BASE_WORK/speed_validate.stderr.log"; then
    STDERR_LOG="$(tail -c 12000 "$BASE_WORK/speed_validate.stderr.log" 2>/dev/null || true)"
    BODY="$(jq -cn \
      --arg stderr "$STDERR_LOG" \
      '{ok:false,error:"speed_config_validation_failed",stderr:$stderr}')"
    respond_json 500 "$BODY"
  fi

  cleanup_mihomo

  "$MIHOMO_BIN" -d "$SPEED_WORK" -f "$SPEED_CONFIG" \
    >"$BASE_WORK/speed_mihomo.stdout.log" \
    2>"$BASE_WORK/speed_mihomo.stderr.log" &
  MIHOMO_PID=$!

  SPEED_READY=0
  for _ in $(seq 1 150); do
    if (echo >/dev/tcp/127.0.0.1/20000) >/dev/null 2>&1; then
      SPEED_READY=1
      break
    fi
    if ! kill -0 "$MIHOMO_PID" 2>/dev/null; then
      break
    fi
    sleep 0.1
  done

  if [[ "$SPEED_READY" != "1" ]]; then
    STDERR_LOG="$(tail -c 12000 "$BASE_WORK/speed_mihomo.stderr.log" 2>/dev/null || true)"
    BODY="$(jq -cn \
      --arg stderr "$STDERR_LOG" \
      '{ok:false,error:"speed_mihomo_not_ready",stderr:$stderr}')"
    respond_json 500 "$BODY"
  fi

  SPEED_START_MS="$(date +%s%3N)"

  SPEED_URL="${SPEED_URL_BASE}?bytes=${SPEED_BYTES}&measId=${REQUEST_ID:-manual}"

  "$SPEED_BIN" \
    --jobs "$SPEED_JOBS" \
    --url "$SPEED_URL" \
    --bytes "$SPEED_BYTES" \
    --concurrency "$SPEED_CONCURRENCY" \
    --timeout "${SPEED_TIMEOUT_SECONDS}s" \
    >"$SPEED_RESULTS_FILE"

  SPEED_STATUS=$?
  SPEED_END_MS="$(date +%s%3N)"
  SPEED_ELAPSED_MS=$((SPEED_END_MS - SPEED_START_MS))

  cleanup_mihomo

  if [[ "$SPEED_STATUS" -ne 0 ]] || ! jq -e 'type=="array"' "$SPEED_RESULTS_FILE" >/dev/null 2>&1; then
    BODY="$(jq -cn \
      --argjson exit_status "$SPEED_STATUS" \
      '{ok:false,error:"speed_probe_failed",exit_status:$exit_status}')"
    respond_json 500 "$BODY"
  fi
else
  SPEED_ELAPSED_MS=0
fi

FUNCTION_END_MS="$(date +%s%3N)"
FUNCTION_ELAPSED_MS=$((FUNCTION_END_MS - FUNCTION_START_MS))

SUMMARY_FILE="$BASE_WORK/summary.json"

jq -cn \
  --arg version "$VERSION" \
  --arg speed_url "$SPEED_URL_BASE" \
  --argjson function_elapsed "$FUNCTION_ELAPSED_MS" \
  --argjson ru_filter_elapsed "$RU_FILTER_ELAPSED_MS" \
  --argjson speed_elapsed "$SPEED_ELAPSED_MS" \
  --argjson speed_bytes "$SPEED_BYTES" \
  --argjson speed_concurrency "$SPEED_CONCURRENCY" \
  --argjson speed_timeout_seconds "$SPEED_TIMEOUT_SECONDS" \
  --slurpfile meta "$META" \
  --slurpfile manifest "$MANIFEST" \
  --slurpfile mapping "$MAPPING" \
  --slurpfile alive_nodes "$ALIVE_ARRAY_FILE" \
  --slurpfile chunks "$CHUNKS_ARRAY_FILE" \
  --slurpfile speed_results "$SPEED_RESULTS_FILE" '
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
  | ($speed_results[0] // []) as $speed_results
  | INDEX($speed_results[]; .key) as $speed_index
  | (
      $alive_nodes
      | map(
          . as $alive
          | ($mapping[$alive.key] // {}) as $m
          | ($speed_index[$alive.key] // {}) as $s
          | {
              key:$alive.key,
              ru_delay_ms:$alive.value,
              protocol:($m.protocol // null),
              source_index:($m.source_index // null),
              selected_index:($m.selected_index // null),
              uri:($m.uri // null),
              speed_test_ok:($s.ok // false),
              speed_mbps:($s.mbps // null),
              speed_bytes:($s.bytes // 0),
              speed_total_ms:($s.total_ms // null),
              speed_ttfb_ms:($s.ttfb_ms // null),
              speed_body_ms:($s.body_ms // null),
              speed_http_status:($s.http_status // null),
              speed_error:($s.error // null)
            }
        )
    ) as $survivors
  | ($survivors | map(.ru_delay_ms)) as $latency_vals
  | ($survivors | map(select(.speed_test_ok == true) | .speed_mbps) | sort) as $speed_vals
  | {
      ok:true,
      mihomo_version:$version,
      location:"yandex_ru",
      stage:"ru_mihomo_plus_speed_measurement",
      ranking_rule:"speed is measurement only; no speed threshold applied in this run",
      strategy:"RU delay batches of 1000, then immediate speed measurement on RU-alive",
      function_elapsed_ms:$function_elapsed,
      ru_filter_elapsed_ms:$ru_filter_elapsed,
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
        min:(if ($latency_vals|length)>0 then ($latency_vals|min) else null end),
        p50:pct($latency_vals;0.50),
        p90:pct($latency_vals;0.90),
        max:(if ($latency_vals|length)>0 then ($latency_vals|max) else null end),
        average:(if ($latency_vals|length)>0 then (($latency_vals|add)/($latency_vals|length)) else null end)
      },
      speed_test:{
        url:$speed_url,
        bytes_per_proxy:$speed_bytes,
        concurrency:$speed_concurrency,
        timeout_seconds:$speed_timeout_seconds,
        elapsed_ms:$speed_elapsed,
        attempted:($survivors|length),
        measured_ok:([$survivors[] | select(.speed_test_ok == true)]|length),
        failed:([$survivors[] | select(.speed_test_ok != true)]|length),
        mbps:{
          min:(if ($speed_vals|length)>0 then ($speed_vals|min) else null end),
          p10:pct($speed_vals;0.10),
          p25:pct($speed_vals;0.25),
          p50:pct($speed_vals;0.50),
          p75:pct($speed_vals;0.75),
          p90:pct($speed_vals;0.90),
          max:(if ($speed_vals|length)>0 then ($speed_vals|max) else null end),
          average:(if ($speed_vals|length)>0 then (($speed_vals|add)/($speed_vals|length)) else null end)
        },
        distribution:{
          lt_1:([$speed_vals[] | select(. < 1)]|length),
          gte_1_lt_2:([$speed_vals[] | select(. >= 1 and . < 2)]|length),
          gte_2_lt_5:([$speed_vals[] | select(. >= 2 and . < 5)]|length),
          gte_5_lt_10:([$speed_vals[] | select(. >= 5 and . < 10)]|length),
          gte_10_lt_20:([$speed_vals[] | select(. >= 10 and . < 20)]|length),
          gte_20_lt_50:([$speed_vals[] | select(. >= 20 and . < 50)]|length),
          gte_50:([$speed_vals[] | select(. >= 50)]|length)
        }
      },
      fastest_latency_20:($survivors[0:20]),
      chunks:$chunks,
      survivors:$survivors
    }' >"$SUMMARY_FILE"

SUMMARY_STATUS=$?
if [[ "$SUMMARY_STATUS" -ne 0 || ! -s "$SUMMARY_FILE" ]]; then
  BODY="$(jq -cn \
    --argjson status "$SUMMARY_STATUS" \
    '{ok:false,error:"summary_generation_failed",jq_exit_status:$status}')"
  respond_json 500 "$BODY"
fi

respond_file 200 "$SUMMARY_FILE"
