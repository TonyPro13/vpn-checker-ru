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
SPEED_MIN_MBPS=3
SPEED_URL_BASE="https://speed.cloudflare.com/__down"
GEO_URL="https://ipwho.is/?fields=ip,success,country,country_code,city,flag"
GEO_FALLBACK_URL=""
GEO_TIMEOUT_SECONDS=6
FINAL_DELAY_URL="https://cp.cloudflare.com"
FINAL_DELAY_TIMEOUT_SECONDS=5

SUBSCRIPTION_BUCKET="${SUBSCRIPTION_BUCKET:-tony-vpn-subscription-2026}"
SUBSCRIPTION_TXT_OBJECT="${SUBSCRIPTION_TXT_OBJECT:-subscription.txt}"
SUBSCRIPTION_YAML_OBJECT="${SUBSCRIPTION_YAML_OBJECT:-subscription.yaml}"
SUBSCRIPTION_HIDDIFY_OBJECT="${SUBSCRIPTION_HIDDIFY_OBJECT:-subscription-hiddify.txt}"
SUBSCRIPTION_TXT_URL="https://storage.yandexcloud.net/${SUBSCRIPTION_BUCKET}/${SUBSCRIPTION_TXT_OBJECT}"
SUBSCRIPTION_YAML_URL="https://storage.yandexcloud.net/${SUBSCRIPTION_BUCKET}/${SUBSCRIPTION_YAML_OBJECT}"
SUBSCRIPTION_HIDDIFY_URL="https://storage.yandexcloud.net/${SUBSCRIPTION_BUCKET}/${SUBSCRIPTION_HIDDIFY_OBJECT}"
IAM_METADATA_URL="http://169.254.169.254/computeMetadata/v1/instance/service-accounts/default/token"

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
  SPEED_WORKERS="$SPEED_CONCURRENCY"
  if [[ "$ALIVE_COUNT" -lt "$SPEED_WORKERS" ]]; then
    SPEED_WORKERS="$ALIVE_COUNT"
  fi

  SPEED_CONFIG="$BASE_WORK/speed_config.yaml"
  SPEED_JOBS="$BASE_WORK/speed_jobs.json"
  SPEED_WORK="$BASE_WORK/speed_runtime"

  mkdir -p "$SPEED_WORK"

  jq -cn \
    --argjson workers "$SPEED_WORKERS" \
    --slurpfile alive "$ALIVE_ARRAY_FILE" \
    --slurpfile defs "$PROXY_DEFS" '
    ($alive[0] // []) as $alive
    | ($defs[0] // {}) as $defs
    | ($alive | map(.key)) as $names
    | {
        "allow-lan": false,
        "mode": "rule",
        "log-level": "warning",
        "ipv6": false,
        "external-controller": "127.0.0.1:9090",
        "proxies": [
          $alive[]
          | $defs[.key]
          | select(. != null)
        ],
        "proxy-groups": [
          range(0; $workers) as $i
          | {
              name:("SPEED-" + (($i+1)|tostring)),
              type:"select",
              proxies:$names
            }
        ],
        "listeners": [
          range(0; $workers) as $i
          | {
              name:("speed-in-" + (($i+1)|tostring)),
              type:"mixed",
              listen:"127.0.0.1",
              port:(20000 + $i),
              udp:false,
              proxy:("SPEED-" + (($i+1)|tostring))
            }
        ],
        "rules":["MATCH,DIRECT"]
      }' >"$SPEED_CONFIG"

  jq -cn \
    --slurpfile alive "$ALIVE_ARRAY_FILE" '
    ($alive[0] // [])
    | map({key:.key})' >"$SPEED_JOBS"

  echo "Speed stage v2: alive=$ALIVE_COUNT workers=$SPEED_WORKERS bytes_each=$SPEED_BYTES" >&2

  set +e
  "$MIHOMO_BIN" -t -d "$SPEED_WORK" -f "$SPEED_CONFIG" \
    >"$BASE_WORK/speed_validate.stdout.log" \
    2>"$BASE_WORK/speed_validate.stderr.log"
  SPEED_VALIDATE_STATUS=$?
  set -e

  if [[ "$SPEED_VALIDATE_STATUS" -ne 0 ]]; then
    VALIDATE_STDOUT="$(tail -c 12000 "$BASE_WORK/speed_validate.stdout.log" 2>/dev/null || true)"
    VALIDATE_STDERR="$(tail -c 12000 "$BASE_WORK/speed_validate.stderr.log" 2>/dev/null || true)"
    BODY="$(jq -cn \
      --argjson exit_status "$SPEED_VALIDATE_STATUS" \
      --arg stdout "$VALIDATE_STDOUT" \
      --arg stderr "$VALIDATE_STDERR" \
      '{ok:false,error:"speed_config_validation_failed",exit_status:$exit_status,stdout:$stdout,stderr:$stderr}')"
    respond_json 500 "$BODY"
  fi

  cleanup_mihomo

  "$MIHOMO_BIN" -d "$SPEED_WORK" -f "$SPEED_CONFIG" \
    >"$BASE_WORK/speed_mihomo.stdout.log" \
    2>"$BASE_WORK/speed_mihomo.stderr.log" &
  MIHOMO_PID=$!

  SPEED_READY=0
  for _ in $(seq 1 150); do
    if (echo >/dev/tcp/127.0.0.1/9090) >/dev/null 2>&1 && \
       (echo >/dev/tcp/127.0.0.1/20000) >/dev/null 2>&1; then
      SPEED_READY=1
      break
    fi
    if ! kill -0 "$MIHOMO_PID" 2>/dev/null; then
      break
    fi
    sleep 0.1
  done

  if [[ "$SPEED_READY" != "1" ]]; then
    STDOUT_LOG="$(tail -c 12000 "$BASE_WORK/speed_mihomo.stdout.log" 2>/dev/null || true)"
    STDERR_LOG="$(tail -c 12000 "$BASE_WORK/speed_mihomo.stderr.log" 2>/dev/null || true)"
    BODY="$(jq -cn \
      --arg stdout "$STDOUT_LOG" \
      --arg stderr "$STDERR_LOG" \
      '{ok:false,error:"speed_mihomo_not_ready",stdout:$stdout,stderr:$stderr}')"
    respond_json 500 "$BODY"
  fi

  SPEED_START_MS="$(date +%s%3N)"
  SPEED_URL="${SPEED_URL_BASE}?bytes=${SPEED_BYTES}&measId=${REQUEST_ID:-manual}"

  "$SPEED_BIN" \
    --jobs "$SPEED_JOBS" \
    --url "$SPEED_URL" \
    --controller "http://127.0.0.1:9090" \
    --group-prefix "SPEED-" \
    --base-port 20000 \
    --bytes "$SPEED_BYTES" \
    --concurrency "$SPEED_WORKERS" \
    --timeout "${SPEED_TIMEOUT_SECONDS}s" \
    >"$SPEED_RESULTS_FILE"

  SPEED_STATUS=$?
  SPEED_END_MS="$(date +%s%3N)"
  SPEED_ELAPSED_MS=$((SPEED_END_MS - SPEED_START_MS))

  if [[ "$SPEED_STATUS" -ne 0 ]] || ! jq -e 'type=="array"' "$SPEED_RESULTS_FILE" >/dev/null 2>&1; then
    cleanup_mihomo
    BODY="$(jq -cn \
      --argjson exit_status "$SPEED_STATUS" \
      '{ok:false,error:"speed_probe_failed",exit_status:$exit_status}')"
    respond_json 500 "$BODY"
  fi

  FINAL_KEYS_FILE="$BASE_WORK/final_keys.json"
  GEO_RESULTS_FILE="$BASE_WORK/geo_results.json"

  jq -cn \
    --argjson min_mbps "$SPEED_MIN_MBPS" \
    --slurpfile alive "$ALIVE_ARRAY_FILE" \
    --slurpfile speed "$SPEED_RESULTS_FILE" '
    ($alive[0] // []) as $alive
    | ($speed[0] // []) as $speed
    | INDEX($speed[]; .key) as $idx
    | [
        $alive[]
        | . as $a
        | ($idx[$a.key] // {}) as $s
        | select(($s.ok // false) == true and ($s.mbps // 0) >= $min_mbps)
        | {key:$a.key}
      ]' >"$FINAL_KEYS_FILE"

CASCADE_RESULTS_FILE="$BASE_WORK/cascade_results.json"
CASCADE_KEYS_FILE="$BASE_WORK/cascade_keys.json"
CASCADE_INPUT_COUNT="$(jq 'length' "$FINAL_KEYS_FILE")"

printf '[]\n' >"$CASCADE_RESULTS_FILE"
printf '[]\n' >"$CASCADE_KEYS_FILE"

if [[ "$CASCADE_INPUT_COUNT" -gt 0 ]]; then
  CASCADE_WORKERS="$SPEED_WORKERS"
  if [[ "$CASCADE_INPUT_COUNT" -lt "$CASCADE_WORKERS" ]]; then
    CASCADE_WORKERS="$CASCADE_INPUT_COUNT"
  fi

  echo "Cascade stage: input=$CASCADE_INPUT_COUNT workers=$CASCADE_WORKERS" >&2
  CASCADE_START_MS="$(date +%s%3N)"

  "$SPEED_BIN" \
    --mode cascade \
    --jobs "$FINAL_KEYS_FILE" \
    --controller "http://127.0.0.1:9090" \
    --group-prefix "SPEED-" \
    --base-port 20000 \
    --concurrency "$CASCADE_WORKERS" \
    >"$CASCADE_RESULTS_FILE" 2>"$BASE_WORK/cascade.stderr.log"

  CASCADE_STATUS=$?
if [[ -s "$BASE_WORK/cascade.stderr.log" ]]; then
  echo "=== cascade stderr ===" >&2
  cat "$BASE_WORK/cascade.stderr.log" >&2
  echo "=== end cascade stderr ===" >&2
fi
  CASCADE_END_MS="$(date +%s%3N)"

  if [[ "$CASCADE_STATUS" -ne 0 ]] || ! jq -e 'type=="array"' "$CASCADE_RESULTS_FILE" >/dev/null 2>&1; then
    cleanup_mihomo
    BODY="$(jq -cn --argjson exit_status "$CASCADE_STATUS" \
      '{"ok":false,"error":"cascade_probe_failed","exit_status":$exit_status}')"
    respond_json 500 "$BODY"
  fi

  jq -c '
    [
      .[]
      | select((.cascade_ok // false) == true)
      | {key:.key}
    ]
  ' "$CASCADE_RESULTS_FILE" >"$CASCADE_KEYS_FILE"

  CASCADE_PASSED_COUNT="$(jq 'length' "$CASCADE_KEYS_FILE")"
  CASCADE_ELAPSED_MS=$((CASCADE_END_MS - CASCADE_START_MS))

  echo "Cascade stage complete: input=$CASCADE_INPUT_COUNT passed=$CASCADE_PASSED_COUNT removed=$((CASCADE_INPUT_COUNT-CASCADE_PASSED_COUNT)) elapsed_ms=$CASCADE_ELAPSED_MS" >&2
  jq -r '[.[] | if (.cascade_ok // false) then "passed" else (.failed_stage // "unknown") end] | sort | group_by(.) | .[] | "Cascade result: \(.[0]\)=\(length\)"' "$CASCADE_RESULTS_FILE" >&2
else
  CASCADE_WORKERS=0
  CASCADE_PASSED_COUNT=0
  CASCADE_ELAPSED_MS=0
fi
  FINAL_COUNT_PRE_GEO="$(jq 'length' "$CASCADE_KEYS_FILE")"
  printf '[]\n' >"$GEO_RESULTS_FILE"
  FINAL_DELAY_WORKERS=0
  FINAL_DELAY_PASSED_COUNT=0
  FINAL_DELAY_ELAPSED_MS=0
  FINAL_DELAY_RESULTS_FILE="$BASE_WORK/final_delay_results.json"
  printf '[]\n' >"$FINAL_DELAY_RESULTS_FILE"

  if [[ "$FINAL_COUNT_PRE_GEO" -gt 0 ]]; then
    GEO_WORKERS="$SPEED_WORKERS"
    if [[ "$FINAL_COUNT_PRE_GEO" -lt "$GEO_WORKERS" ]]; then
      GEO_WORKERS="$FINAL_COUNT_PRE_GEO"
    fi

    echo "Geo stage: final=$FINAL_COUNT_PRE_GEO workers=$GEO_WORKERS provider=ipwho.is" >&2

    GEO_START_MS="$(date +%s%3N)"

    "$SPEED_BIN" \
      --mode geo \
      --jobs "$FINAL_KEYS_FILE" \
      --url "$GEO_URL" \
      --fallback-url "$GEO_FALLBACK_URL" \
      --controller "http://127.0.0.1:9090" \
      --group-prefix "SPEED-" \
      --base-port 20000 \
      --concurrency "$GEO_WORKERS" \
      --timeout "${GEO_TIMEOUT_SECONDS}s" \
      >"$GEO_RESULTS_FILE"

    GEO_STATUS=$?
    GEO_END_MS="$(date +%s%3N)"
    GEO_ELAPSED_MS=$((GEO_END_MS - GEO_START_MS))

    if [[ "$GEO_STATUS" -ne 0 ]] || ! jq -e 'type=="array"' "$GEO_RESULTS_FILE" >/dev/null 2>&1; then
      cleanup_mihomo
      BODY="$(jq -cn \
        --argjson exit_status "$GEO_STATUS" \
        '{ok:false,error:"geo_probe_failed",exit_status:$exit_status}')"
      respond_json 500 "$BODY"
    fi
  else
    GEO_WORKERS=0
    GEO_ELAPSED_MS=0
  fi

FINAL_DELAY_RESULTS_FILE="$BASE_WORK/final_delay_results.json"
FINAL_DELAY_KEYS_FILE="$BASE_WORK/final_delay_keys.json"

jq -c '
  INDEX(.[]; .key) as $geo
  | [
      inputs[]
      | ($geo[.key] // {}) as $g
      | select(($g.ok // false) == true)
      | select(($g.ip // "") | length > 0)
      | select(($g.country // "") | length > 0)
      | select(($g.country_code // "") | length > 0)
      | select(($g.city // "") | length > 0)
      | select((($g.country_code // "") | ascii_upcase) != "RU")
      | select((($g.country_code // "") | ascii_upcase) != "UA")
      | select((($g.country // "") | ascii_downcase) != "russia")
      | select((($g.country // "") | ascii_downcase) != "russian federation")
      | select((($g.country // "") | ascii_downcase) != "ukraine")
      | {key:.key}
    ]
' "$GEO_RESULTS_FILE" "$CASCADE_KEYS_FILE" >"$FINAL_DELAY_KEYS_FILE"
FINAL_DELAY_INPUT_COUNT="$(jq 'length' "$FINAL_DELAY_KEYS_FILE")"
printf '[]\n' >"$FINAL_DELAY_RESULTS_FILE"

if [[ "$FINAL_DELAY_INPUT_COUNT" -gt 0 ]]; then
  FINAL_DELAY_WORKERS="$SPEED_WORKERS"
  if [[ "$FINAL_DELAY_INPUT_COUNT" -lt "$FINAL_DELAY_WORKERS" ]]; then
    FINAL_DELAY_WORKERS="$FINAL_DELAY_INPUT_COUNT"
  fi

  echo "Final RU delay stage: input=$FINAL_DELAY_INPUT_COUNT workers=$FINAL_DELAY_WORKERS url=$FINAL_DELAY_URL" >&2
  FINAL_DELAY_START_MS="$(date +%s%3N)"

  "$SPEED_BIN" \
    --mode delay \
    --jobs "$FINAL_DELAY_KEYS_FILE" \
    --url "$FINAL_DELAY_URL" \
    --controller "http://127.0.0.1:9090" \
    --concurrency "$FINAL_DELAY_WORKERS" \
    --timeout "$FINAL_DELAY_TIMEOUT_SECONDS"s \
    >"$FINAL_DELAY_RESULTS_FILE"

  FINAL_DELAY_STATUS=$?
  FINAL_DELAY_END_MS="$(date +%s%3N)"
  FINAL_DELAY_ELAPSED_MS=$((FINAL_DELAY_END_MS - FINAL_DELAY_START_MS))

  if [[ "$FINAL_DELAY_STATUS" -ne 0 ]] || ! jq -e 'type=="array"' "$FINAL_DELAY_RESULTS_FILE" >/dev/null 2>&1; then
    cleanup_mihomo
    BODY="$(jq -cn --argjson exit_status "$FINAL_DELAY_STATUS" \
      '{ok:false,error:"final_delay_probe_failed",exit_status:$exit_status}')"
    respond_json 500 "$BODY"
  fi

  FINAL_DELAY_PASSED_COUNT="$(jq '[.[] | select((.ok // false) == true)] | length' "$FINAL_DELAY_RESULTS_FILE")"
  echo "Final RU delay stage complete: input=$FINAL_DELAY_INPUT_COUNT passed=$FINAL_DELAY_PASSED_COUNT removed=$((FINAL_DELAY_INPUT_COUNT-FINAL_DELAY_PASSED_COUNT)) elapsed_ms=$FINAL_DELAY_ELAPSED_MS" >&2
else
  FINAL_DELAY_WORKERS=0
  FINAL_DELAY_PASSED_COUNT=0
  FINAL_DELAY_ELAPSED_MS=0
fi
  cleanup_mihomo
else
  SPEED_ELAPSED_MS=0
  SPEED_WORKERS=0
  GEO_WORKERS=0
  GEO_ELAPSED_MS=0
  GEO_RESULTS_FILE="$BASE_WORK/geo_results.json"
  printf '[]\n' >"$GEO_RESULTS_FILE"
  FINAL_DELAY_WORKERS=0
  FINAL_DELAY_PASSED_COUNT=0
  FINAL_DELAY_ELAPSED_MS=0
  FINAL_DELAY_RESULTS_FILE="$BASE_WORK/final_delay_results.json"
  printf '[]\n' >"$FINAL_DELAY_RESULTS_FILE"
fi

FUNCTION_END_MS="$(date +%s%3N)"
FUNCTION_ELAPSED_MS=$((FUNCTION_END_MS - FUNCTION_START_MS))

SUMMARY_FILE="$BASE_WORK/summary.json"

jq -cn \
  --arg version "$VERSION" \
  --arg speed_url "$SPEED_URL_BASE" \
  --arg geo_url "$GEO_URL" \
  --argjson function_elapsed "$FUNCTION_ELAPSED_MS" \
  --argjson ru_filter_elapsed "$RU_FILTER_ELAPSED_MS" \
  --argjson speed_elapsed "$SPEED_ELAPSED_MS" \
  --argjson speed_bytes "$SPEED_BYTES" \
  --argjson speed_concurrency "$SPEED_WORKERS" \
  --argjson speed_timeout_seconds "$SPEED_TIMEOUT_SECONDS" \
  --argjson speed_min_mbps "$SPEED_MIN_MBPS" \
  --argjson geo_elapsed "$GEO_ELAPSED_MS" \
  --argjson geo_concurrency "$GEO_WORKERS" \
  --argjson geo_timeout_seconds "$GEO_TIMEOUT_SECONDS" \
  --slurpfile meta "$META" \
  --slurpfile manifest "$MANIFEST" \
  --slurpfile mapping "$MAPPING" \
  --slurpfile alive_nodes "$ALIVE_ARRAY_FILE" \
  --slurpfile chunks "$CHUNKS_ARRAY_FILE" \
  --slurpfile speed_results "$SPEED_RESULTS_FILE" \
  --slurpfile geo_results "$GEO_RESULTS_FILE" \
--slurpfile final_delay "$FINAL_DELAY_RESULTS_FILE" \
  '
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

  def regular_named_uri($uri; $name):
    (($uri // "") | split("#")[0])
    + "#"
    + ($name | @uri);

  def vmess_named_uri($uri; $name):
    try (
      (($uri | split("#")[0] | sub("^vmess://"; ""))
        | @base64d
        | fromjson
        | .ps = $name
        | tojson
        | @base64) as $payload
      | ("vmess://" + $payload)
    ) catch null;

  ($meta[0] // {}) as $meta
  | ($manifest[0] // {}) as $manifest
  | ($mapping[0] // {}) as $mapping
  | ($alive_nodes[0] // []) as $alive_nodes
  | ($chunks[0] // []) as $chunks
  | ($speed_results[0] // []) as $speed_results
  | ($geo_results[0] // []) as $geo_results
  | INDEX($speed_results[]; .key) as $speed_index
  | INDEX($geo_results[]; .key) as $geo_index
  | INDEX($final_delay[0][]; .key) as $final_delay_index
  | (
      $alive_nodes
      | map(
          . as $alive
          | ($mapping[$alive.key] // {}) as $m
          | ($speed_index[$alive.key] // {}) as $s
        | ($final_delay_index[$alive.key] // {}) as $fd
          | {
              key:$alive.key,
              ru_delay_ms:$alive.value,
          ru_delay_first_ms:$alive.value,
          ru_delay_final_ms:(if (($fd.ok // false) == true and (($fd.total_ms // 0) > 0)) then $fd.total_ms else null end),
          ru_delay_avg_ms:(if (($fd.ok // false) == true and (($fd.total_ms // 0) > 0)) then (($alive.value + $fd.total_ms) / 2) else null end),
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
  | (
      $survivors
      | map(select(.speed_test_ok == true and (.speed_mbps // 0) >= $speed_min_mbps))
    ) as $after_speed
  | (
      $after_speed
      | map(
          . as $s
          | ($geo_index[$s.key] // {}) as $g
          | ($g.flag // "🌐") as $flag
          | ($g.country // "") as $country
          | ($g.country_code // "") as $country_code
          | ($g.city // "") as $city
          | ($g.ip // "") as $exit_ip
          | (($s.protocol // "unknown") | ascii_upcase) as $type
          | (
              ($g.ok // false) == true
              and ($exit_ip|length) > 0
              and ($country|length) > 0
              and ($country_code|length) > 0
              and ($city|length) > 0
              and $exit_ip != "Unknown"
              and $country != "Unknown"
              and $city != "Unknown"
            ) as $geo_complete
          | (
              if $geo_complete
              then ($flag + " " + $country + " " + $city + " | " + $type + " | " + $exit_ip)
              else null
              end
            ) as $base_display_name
          | . + {
              geo_ok:$geo_complete,
              exit_ip:(if ($exit_ip|length)>0 then $exit_ip else null end),
              country:(if ($country|length)>0 then $country else null end),
              country_code:(if ($country_code|length)>0 then $country_code else null end),
              city:(if ($city|length)>0 then $city else null end),
              flag:$flag,
              geo_source:($g.source // null),
              geo_error:($g.error // null),
              base_display_name:$base_display_name
            }
        )
      | map(select(.geo_ok == true))
      | sort_by(.ru_delay_ms)
    ) as $geo_complete_sorted
  | (
      $geo_complete_sorted
      | map(
          select(
            (
              ((.country_code // "") | ascii_upcase) != "RU"
              and ((.country_code // "") | ascii_upcase) != "UA"
              and ((.country // "") | ascii_downcase) != "russia"
              and ((.country // "") | ascii_downcase) != "russian federation"
              and ((.country // "") | ascii_downcase) != "ukraine"
            )
          )
        )
    ) as $geo_allowed_sorted
  | (
      $geo_allowed_sorted
      | map(select(.ru_delay_final_ms != null and .ru_delay_avg_ms != null))
      | sort_by(.ru_delay_avg_ms)
    ) as $final_delay_sorted
  | (
      reduce $final_delay_sorted[] as $item (
        {counts:{}, items:[], duplicate_suffixes_added:0, vmess_ps_rewritten:0, naming_failed:0};
        ($item.base_display_name) as $base
        | ((.counts[$base] // 0) + 1) as $seq
        | .counts[$base] = $seq
        | (
            $base
            + (if $seq > 1 then (" | " + ($seq|tostring)) else "" end)
          ) as $display_name
        | (
            if ($item.protocol // "") == "vmess"
            then vmess_named_uri($item.uri; $display_name)
            else regular_named_uri($item.uri; $display_name)
            end
          ) as $named_uri
        | if $named_uri == null or ($named_uri|length) == 0 then
            .naming_failed += 1
          else
            .items += [
              $item
              | del(.base_display_name)
              | . + {
                  display_name:$display_name,
                  named_uri:$named_uri,
                  name_sequence:$seq
                }
            ]
            | if $seq > 1 then .duplicate_suffixes_added += 1 else . end
            | if ($item.protocol // "") == "vmess" then .vmess_ps_rewritten += 1 else . end
          end
      )
    ) as $naming
  | ($naming.items[0:1000]) as $final_survivors
  | (($after_speed|length) - ($geo_complete_sorted|length)) as $removed_geo_failed
  | (
      [$geo_complete_sorted[]
       | select(
           ((.country_code // "") | ascii_upcase) == "RU"
           or ((.country // "") | ascii_downcase) == "russia"
           or ((.country // "") | ascii_downcase) == "russian federation"
         )]
      | length
    ) as $removed_country_ru
  | (
      [$geo_complete_sorted[]
       | select(
           ((.country_code // "") | ascii_upcase) == "UA"
           or ((.country // "") | ascii_downcase) == "ukraine"
         )]
      | length
    ) as $removed_country_ua
  | (($geo_complete_sorted|length) - ($geo_allowed_sorted|length)) as $removed_country_excluded
  | ([$survivors[] | select(.speed_test_ok != true)] | length) as $removed_speed_failed
  | ([$survivors[] | select(.speed_test_ok == true and (.speed_mbps // 0) < $speed_min_mbps)] | length) as $removed_below_threshold
  | {
      ok:true,
      mihomo_version:$version,
      location:"yandex_ru",
      stage:"ru_mihomo_speed_ipwho_geo_strict_country_exclusion_unique_naming",
      ranking_rule:"strict speed gate first, then ranking only by RU latency",
      strategy:"RU delay -> strict speed gate -> ipwho.is exit geolocation -> strict geo gate -> exclude RU/UA exits -> naming",
      speed_filter_rule:{
        strict:true,
        min_mbps:$speed_min_mbps,
        failed_test:"remove",
        below_threshold:"remove",
        retry:false
      },
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
      strict_filter_result:{
        ru_alive:($survivors|length),
        removed_speed_failed:$removed_speed_failed,
        removed_below_5_mbps:$removed_below_threshold,
        after_speed_count:($after_speed|length)
      },
      geo_filter_rule:{
        strict:true,
        require_exit_ip:true,
        require_country:true,
        require_country_code:true,
        require_city:true,
        failed_or_incomplete:"remove",
        retry:false
      },
      country_exclusion_rule:{
        strict:true,
        excluded_country_codes:["RU","UA"],
        excluded_countries:["Russia","Russian Federation","Ukraine"],
        action:"remove_before_naming_and_publication"
      },
      geo:{
        provider:"ipwho.is",
        endpoint:$geo_url,
        fallback:null,
        concurrency:$geo_concurrency,
        timeout_seconds:$geo_timeout_seconds,
        elapsed_ms:$geo_elapsed,
        attempted:($after_speed|length),
        success_complete:($geo_complete_sorted|length),
        removed_geo_failed:$removed_geo_failed,
        removed_country_excluded:$removed_country_excluded,
        removed_country_ru:$removed_country_ru,
        removed_country_ua:$removed_country_ua,
        after_country_exclusion:($geo_allowed_sorted|length),
        final_count:($final_survivors|length)
      },
      naming:{
        format:"FLAG Country City | TYPE | EXIT_IP",
        unique_names:true,
        duplicate_suffixes_added:$naming.duplicate_suffixes_added,
        vmess_ps_rewritten:$naming.vmess_ps_rewritten,
        naming_failed:$naming.naming_failed
      },
      final_fastest_20:($final_survivors[0:20]),
      chunks:$chunks,
      final_survivors:$final_survivors,
      final_named_uris:($final_survivors | map(.named_uri)),
      subscription_text:($final_survivors | map(.named_uri) | join("\n"))
    }' >"$SUMMARY_FILE"

SUMMARY_STATUS=$?
if [[ "$SUMMARY_STATUS" -ne 0 || ! -s "$SUMMARY_FILE" ]]; then
  BODY="$(jq -cn \
    --argjson status "$SUMMARY_STATUS" \
    '{ok:false,error:"summary_generation_failed",jq_exit_status:$status}')"
  respond_json 500 "$BODY"
fi

# ------------------------------------------------------------
# Publish final subscriptions to Yandex Object Storage.
# RU/UA exit nodes have already been removed before this point.
#
# subscription.yaml        = Mihomo profile
# subscription.txt         = current raw/named URI list for Lxbox
# subscription-hiddify.txt = separately sanitized URI list for Hiddify
#
# Safety:
# - never publish an empty result;
# - build YAML from the exact Mihomo-validated proxy definitions;
# - validate the final YAML with Mihomo itself before upload;
# - verify both public objects byte-for-byte after upload.
# ------------------------------------------------------------

FINAL_COUNT="$(jq -r '.geo.final_count // 0' "$SUMMARY_FILE")"
NAMING_FAILED="$(jq -r '.naming.naming_failed // 0' "$SUMMARY_FILE")"

if [[ "$FINAL_COUNT" -le 0 ]]; then
  BODY="$(jq -cn \
    --arg bucket "$SUBSCRIPTION_BUCKET" \
    '{ok:false,error:"publication_skipped_empty_subscription",bucket:$bucket,last_good_subscription_preserved:true}')"
  respond_json 500 "$BODY"
fi

if [[ "$NAMING_FAILED" -ne 0 ]]; then
  BODY="$(jq -cn \
    --argjson naming_failed "$NAMING_FAILED" \
    '{ok:false,error:"publication_skipped_naming_failed",naming_failed:$naming_failed,last_good_subscription_preserved:true}')"
  respond_json 500 "$BODY"
fi

TXT_FILE="$BASE_WORK/subscription.txt"
YAML_FILE="$BASE_WORK/subscription.yaml"

jq -r '.subscription_text // empty' "$SUMMARY_FILE" >"$TXT_FILE"

if [[ ! -s "$TXT_FILE" ]]; then
  BODY='{"ok":false,"error":"publication_txt_empty","last_good_subscription_preserved":true}'
  respond_json 500 "$BODY"
fi

# Exactly one trailing newline for raw URI subscription.
python3 - "$TXT_FILE" <<'PY'
from pathlib import Path
import sys

p = Path(sys.argv[1])
p.write_bytes(p.read_bytes().rstrip(b"\r\n") + b"\n")
PY
NORMALIZE_STATUS=$?

if [[ "$NORMALIZE_STATUS" -ne 0 || ! -s "$TXT_FILE" ]]; then
  BODY="$(jq -cn \
    --argjson exit_status "$NORMALIZE_STATUS" \
    '{ok:false,error:"publication_txt_normalize_failed",exit_status:$exit_status,last_good_subscription_preserved:true}')"
  respond_json 500 "$BODY"
fi

TXT_LINES="$(grep -cve '^[[:space:]]*$' "$TXT_FILE" || true)"
if [[ "$TXT_LINES" -ne "$FINAL_COUNT" ]]; then
  BODY="$(jq -cn \
    --argjson expected "$FINAL_COUNT" \
    --argjson actual "$TXT_LINES" \
    '{ok:false,error:"publication_txt_line_count_mismatch",expected:$expected,actual:$actual,last_good_subscription_preserved:true}')"
  respond_json 500 "$BODY"
fi

# Build a Hiddify-specific share-link subscription.
#
# The semantic rules mirror the old vpn-subscription engine adapters:
# - only fields actually consumed by the protocol/transport are retained;
# - raw -> tcp;
# - gRPC keeps serviceName but drops unrelated path/host fields;
# - WS keeps path + host;
# - HTTP Upgrade keeps path + host;
# - XHTTP keeps path + host + mode (+ valid extra payload);
# - packetEncoding / packet-encoding is not emitted for VLESS/VMess because
#   the old Xray adapter never consumed it;
# - allowInsecure/insecure/skip-cert-verify is NOT emitted for
#   VLESS/Trojan/VMess Hiddify links;
# - Hysteria2 normalizes that semantic flag to sing-box-style insecure=1;
# - unknown query fields are dropped instead of being passed to Hiddify.
#
# The original subscription.txt and Mihomo YAML are untouched.
HIDDIFY_FILE="$BASE_WORK/subscription-hiddify.txt"
HIDDIFY_STATS_FILE="$BASE_WORK/hiddify-stats.json"

python3 - "$SUMMARY_FILE" "$HIDDIFY_FILE" "$HIDDIFY_STATS_FILE" <<'PY'
from __future__ import annotations

import base64
import json
import sys
from collections import Counter
from pathlib import Path
from urllib.parse import parse_qsl, quote

summary_path = Path(sys.argv[1])
out_path = Path(sys.argv[2])
stats_path = Path(sys.argv[3])

summary = json.loads(summary_path.read_text(encoding="utf-8"))
nodes = summary.get("final_survivors") or []

TRUTHY = {"1", "true", "yes", "on"}

def first(pairs, *names, default=""):
    for name in names:
        for k, v in pairs:
            if k == name:
                return v
    return default

def truthy(pairs, *names):
    return str(first(pairs, *names, default="")).strip().lower() in TRUTHY

def split_uri(uri: str):
    no_fragment = uri.split("#", 1)[0]
    if "?" in no_fragment:
        base, query = no_fragment.split("?", 1)
    else:
        base, query = no_fragment, ""
    return base, parse_qsl(query, keep_blank_values=True)

def named(base: str, query_pairs, display_name: str):
    query = ""
    if query_pairs:
        # Encode values safely while keeping protocol field names readable.
        parts = []
        for k, v in query_pairs:
            parts.append(f"{quote(str(k), safe='-._~')}={quote(str(v), safe='-._~,:/@[]{}')}")
        query = "?" + "&".join(parts)
    return base + query + "#" + quote(display_name, safe="")

def normalized_network(pairs):
    network = (first(pairs, "type", default="tcp") or "tcp").strip().lower()
    if network in {"raw", "none", ""}:
        return "tcp"
    return network

def normalized_security(pairs):
    security = (first(pairs, "security", default="none") or "none").strip().lower()
    if security in {"false", "0", "off", "no", ""}:
        return "none"
    return security

def transport_pairs(pairs, network):
    out = [("type", network)]
    if network == "ws":
        out.append(("path", first(pairs, "path", default="/") or "/"))
        host = first(pairs, "host", default="")
        if host:
            out.append(("host", host))
    elif network == "grpc":
        service = first(pairs, "serviceName", "service_name", default="")
        if service:
            out.append(("serviceName", service))
    elif network == "httpupgrade":
        out.append(("path", first(pairs, "path", default="/") or "/"))
        host = first(pairs, "host", default="")
        if host:
            out.append(("host", host))
    elif network == "xhttp":
        out.append(("path", first(pairs, "path", default="/") or "/"))
        host = first(pairs, "host", default="")
        if host:
            out.append(("host", host))
        mode = first(pairs, "mode", default="auto") or "auto"
        out.append(("mode", mode))
        extra = first(pairs, "extra", default="")
        if extra:
            try:
                parsed = json.loads(extra)
                if isinstance(parsed, dict):
                    out.append(("extra", json.dumps(parsed, ensure_ascii=False, separators=(",", ":"))))
            except Exception:
                pass
        elif first(pairs, "x_padding_bytes", "xPaddingBytes", default=""):
            out.append((
                "x_padding_bytes",
                first(pairs, "x_padding_bytes", "xPaddingBytes", default=""),
            ))
    # For tcp/http/h2/http2 and unknown-but-already-tested transport values
    # we keep only type, matching the old Xray adapter's effective input.
    return out

def clean_vless_or_trojan(uri, display_name, scheme):
    base, pairs = split_uri(uri)
    network = normalized_network(pairs)
    security = normalized_security(pairs)

    out = []

    if scheme == "vless":
        encryption = first(pairs, "encryption", default="none") or "none"
        # Current Hiddify/sing-box does not support non-default VLESS encryption.
        # Do not silently change such a node into another connection.
        if encryption.lower() != "none":
            return None, "vless_nondefault_encryption"
        out.append(("encryption", "none"))

        flow = first(pairs, "flow", default="")
        if flow:
            out.append(("flow", flow))

    if security != "none":
        out.append(("security", security))

    if security in {"tls", "reality"}:
        sni = first(pairs, "sni", default="")
        if sni:
            out.append(("sni", sni))
        fp = first(pairs, "fp", default="")
        if fp:
            out.append(("fp", fp))
        alpn = first(pairs, "alpn", default="")
        if alpn:
            out.append(("alpn", alpn))

    if security == "reality":
        pbk = first(pairs, "pbk", default="")
        if pbk:
            out.append(("pbk", pbk))
        sid = first(pairs, "sid", default="")
        if sid:
            out.append(("sid", sid))
        spx = first(pairs, "spx", default="")
        if spx:
            out.append(("spx", spx))

    out.extend(transport_pairs(pairs, network))
    return named(base, out, display_name), None

def b64decode_loose(s: str) -> bytes:
    s = s.strip()
    s += "=" * (-len(s) % 4)
    return base64.urlsafe_b64decode(s.encode())

def clean_vmess(uri, display_name):
    raw = uri[len("vmess://"):].split("#", 1)[0]
    try:
        src = json.loads(b64decode_loose(raw).decode("utf-8"))
    except Exception:
        return None, "vmess_decode_failed"

    for required in ("add", "port", "id"):
        if not src.get(required):
            return None, f"vmess_missing_{required}"

    network = str(src.get("net", "tcp") or "tcp").strip().lower()
    if network in {"raw", "none", ""}:
        network = "tcp"

    tls_value = str(src.get("tls", "") or "")
    out = {
        "v": str(src.get("v", "2") or "2"),
        "ps": display_name,
        "add": src["add"],
        "port": str(src["port"]),
        "id": src["id"],
        "aid": str(src.get("aid", 0) or 0),
        "scy": src.get("scy", "auto") or "auto",
        "net": network,
    }

    if tls_value:
        out["tls"] = tls_value

    if tls_value.lower() == "tls":
        for k in ("sni", "fp", "alpn"):
            if src.get(k):
                out[k] = src[k]

    if network == "ws":
        out["path"] = src.get("path", "/") or "/"
        if src.get("host"):
            out["host"] = src["host"]
    elif network == "grpc":
        service = src.get("serviceName", src.get("service_name", ""))
        if service:
            out["serviceName"] = service
    elif network == "httpupgrade":
        out["path"] = src.get("path", "/") or "/"
        if src.get("host"):
            out["host"] = src["host"]
    elif network == "xhttp":
        out["path"] = src.get("path", "/") or "/"
        if src.get("host"):
            out["host"] = src["host"]
        out["mode"] = src.get("mode", "auto") or "auto"

    # Deliberately omit:
    # allowInsecure / insecure / skip-cert-verify,
    # packetEncoding / packet-encoding,
    # unknown source-specific JSON keys.
    payload = json.dumps(out, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    encoded = base64.urlsafe_b64encode(payload).decode("ascii").rstrip("=")
    return "vmess://" + encoded, None

def clean_ss(uri, display_name):
    base, pairs = split_uri(uri)
    # The old Xray SS adapter uses only method/password/server/port and does not
    # consume SIP002 plugin query fields. Do not publish a broken stripped plugin
    # node to Hiddify: skip it if an actual non-empty query is present.
    meaningful = [(k, v) for k, v in pairs if k or v]
    if meaningful:
        return None, "ss_query_requires_unsupported_extension"
    return named(base, [], display_name), None

def clean_hysteria2(uri, display_name):
    base, pairs = split_uri(uri)
    if base.startswith("hy2://"):
        base = "hysteria2://" + base[len("hy2://"):]

    out = []
    sni = first(pairs, "sni", default="")
    if sni:
        out.append(("sni", sni))

    # Preserve the semantic TLS-insecure bit in sing-box/Hysteria2 form while
    # removing allowInsecure itself.
    if truthy(pairs, "insecure", "allowInsecure"):
        out.append(("insecure", "1"))

    alpn = first(pairs, "alpn", default="")
    if alpn:
        out.append(("alpn", alpn))

    fp = first(pairs, "fp", default="")
    if fp:
        out.append(("fp", fp))

    up = first(pairs, "upmbps", default="")
    down = first(pairs, "downmbps", default="")
    if up:
        out.append(("upmbps", up))
    if down:
        out.append(("downmbps", down))

    obfs = first(pairs, "obfs", default="")
    if obfs:
        out.append(("obfs", obfs))
        obfs_password = first(pairs, "obfs-password", "obfs_password", default="")
        if obfs_password:
            out.append(("obfs-password", obfs_password))

    return named(base, out, display_name), None

def clean_node(item):
    uri = str(item.get("uri") or "").strip()
    display_name = str(item.get("display_name") or "").strip()
    if not uri or not display_name or "://" not in uri:
        return None, "missing_uri_or_name"

    scheme = uri.split("://", 1)[0].lower()
    if scheme in {"vless", "trojan"}:
        return clean_vless_or_trojan(uri, display_name, scheme)
    if scheme == "vmess":
        return clean_vmess(uri, display_name)
    if scheme == "ss":
        return clean_ss(uri, display_name)
    if scheme in {"hysteria2", "hy2"}:
        return clean_hysteria2(uri, display_name)
    return None, "unsupported_protocol"

lines = []
reasons = Counter()
protocols = Counter()

for item in nodes:
    uri = str(item.get("uri") or "")
    scheme = uri.split("://", 1)[0].lower() if "://" in uri else "unknown"
    cleaned, reason = clean_node(item)
    if cleaned:
        lines.append(cleaned)
        protocols[scheme] += 1
    else:
        reasons[reason or "unknown"] += 1

# Preserve final RU-latency ordering: nodes are already sorted in final_survivors.
out_path.write_text(
    "\n".join(lines) + ("\n" if lines else ""),
    encoding="utf-8",
)

stats = {
    "input_final_nodes": len(nodes),
    "published": len(lines),
    "skipped": len(nodes) - len(lines),
    "protocols_published": dict(sorted(protocols.items())),
    "skip_reasons": dict(sorted(reasons.items())),
    "policy": (
        "semantic allowlist based on vpn-subscription Xray/sing-box adapters; "
        "Hiddify-only removal of unsupported extra URI fields"
    ),
}
stats_path.write_text(
    json.dumps(stats, ensure_ascii=False, separators=(",", ":")),
    encoding="utf-8",
)

if not lines:
    raise SystemExit("no Hiddify-compatible nodes were generated")
PY
HIDDIFY_BUILD_STATUS=$?

if [[ "$HIDDIFY_BUILD_STATUS" -ne 0 || ! -s "$HIDDIFY_FILE" || ! -s "$HIDDIFY_STATS_FILE" ]]; then
  BODY="$(jq -cn \
    --argjson exit_status "$HIDDIFY_BUILD_STATUS" \
    '{ok:false,error:"publication_hiddify_build_failed",exit_status:$exit_status,last_good_subscription_preserved:true}')"
  respond_json 500 "$BODY"
fi

HIDDIFY_LINES="$(grep -cve '^[[:space:]]*$' "$HIDDIFY_FILE" || true)"
HIDDIFY_SKIPPED="$(jq -r '.skipped // 0' "$HIDDIFY_STATS_FILE")"

# Build a real Mihomo YAML profile from the exact sanitized proxy
# definitions that were already accepted by Mihomo during the build.
# Flow-style JSON mappings are valid YAML and preserve nested proxy fields.
python3 - "$SUMMARY_FILE" "$PROXY_DEFS" "$YAML_FILE" <<'PY'
import copy
import json
import sys
from pathlib import Path

summary_path = Path(sys.argv[1])
defs_path = Path(sys.argv[2])
out_path = Path(sys.argv[3])

summary = json.loads(summary_path.read_text(encoding="utf-8"))
proxy_defs = json.loads(defs_path.read_text(encoding="utf-8"))
survivors = summary.get("final_survivors") or []

if not survivors:
    raise SystemExit("no final survivors")

proxies = []
names = []

for item in survivors:
    key = item.get("key")
    display_name = item.get("display_name")
    if not key or not display_name:
        raise SystemExit(f"missing key/display_name: {key!r}")

    original = proxy_defs.get(key)
    if not isinstance(original, dict):
        raise SystemExit(f"proxy definition missing for {key}")

    proxy = copy.deepcopy(original)
    proxy["name"] = display_name
    proxies.append(proxy)
    names.append(display_name)

if len(names) != len(set(names)):
    raise SystemExit("duplicate final proxy names")

# A complete Mihomo profile:
# AUTO measures from the actual client device and automatically chooses
# the lowest-latency currently working proxy. VPN defaults to AUTO but
# still allows manual selection in clients that expose the group.
auto_group = {
    "name": "AUTO",
    "type": "url-test",
    "proxies": names,
    "url": "https://cp.cloudflare.com",
    "interval": 300,
    "tolerance": 50,
    "lazy": True,
}
vpn_group = {
    "name": "VPN",
    "type": "select",
    "proxies": ["AUTO"] + names,
}

with out_path.open("w", encoding="utf-8", newline="\n") as f:
    f.write("# Auto-generated by vpn-checker-ru\n")
    f.write("# Do not edit manually: this file is replaced on every successful refresh.\n")
    f.write("mode: rule\n")
    f.write("log-level: warning\n")
    f.write("ipv6: true\n")
    f.write("unified-delay: true\n")
    f.write("tcp-concurrent: true\n")
    f.write("\nproxies:\n")
    for proxy in proxies:
        f.write("  - ")
        f.write(json.dumps(proxy, ensure_ascii=False, separators=(",", ":")))
        f.write("\n")

    f.write("\nproxy-groups:\n")
    for group in (auto_group, vpn_group):
        f.write("  - ")
        f.write(json.dumps(group, ensure_ascii=False, separators=(",", ":")))
        f.write("\n")

    f.write("\nrules:\n")
    f.write("  - MATCH,VPN\n")
PY
YAML_BUILD_STATUS=$?

if [[ "$YAML_BUILD_STATUS" -ne 0 || ! -s "$YAML_FILE" ]]; then
  BODY="$(jq -cn \
    --argjson exit_status "$YAML_BUILD_STATUS" \
    '{ok:false,error:"publication_yaml_build_failed",exit_status:$exit_status,last_good_subscription_preserved:true}')"
  respond_json 500 "$BODY"
fi

# Validate exactly what users will download.
YAML_VALIDATE_DIR="$BASE_WORK/yaml_validate"
mkdir -p "$YAML_VALIDATE_DIR"
YAML_VALIDATE_OUT="$BASE_WORK/yaml_validate.stdout.log"
YAML_VALIDATE_ERR="$BASE_WORK/yaml_validate.stderr.log"

"$MIHOMO_BIN" -t -d "$YAML_VALIDATE_DIR" -f "$YAML_FILE" \
  >"$YAML_VALIDATE_OUT" 2>"$YAML_VALIDATE_ERR"
YAML_VALIDATE_STATUS=$?

if [[ "$YAML_VALIDATE_STATUS" -ne 0 ]]; then
  VALIDATION_DETAIL="$(
    {
      cat "$YAML_VALIDATE_OUT" 2>/dev/null || true
      cat "$YAML_VALIDATE_ERR" 2>/dev/null || true
    } | tail -c 6000
  )"
  BODY="$(jq -cn \
    --argjson exit_status "$YAML_VALIDATE_STATUS" \
    --arg detail "$VALIDATION_DETAIL" \
    '{ok:false,error:"publication_yaml_mihomo_validation_failed",exit_status:$exit_status,detail:$detail,last_good_subscription_preserved:true}')"
  respond_json 500 "$BODY"
fi

# Get one short-lived IAM token for both uploads.
TOKEN_STDERR="$BASE_WORK/iam_token.stderr.log"
TOKEN_JSON="$(
  curl -fsS \
    --connect-timeout 2 \
    --max-time 8 \
    --header "Metadata-Flavor: Google" \
    "$IAM_METADATA_URL" \
    2>"$TOKEN_STDERR"
)"
TOKEN_STATUS=$?

if [[ "$TOKEN_STATUS" -ne 0 ]]; then
  TOKEN_ERROR="$(tail -c 4000 "$TOKEN_STDERR" 2>/dev/null || true)"
  BODY="$(jq -cn \
    --argjson exit_status "$TOKEN_STATUS" \
    --arg detail "$TOKEN_ERROR" \
    '{ok:false,error:"publication_iam_token_request_failed",exit_status:$exit_status,detail:$detail,last_good_subscription_preserved:true}')"
  respond_json 500 "$BODY"
fi

IAM_TOKEN="$(printf '%s' "$TOKEN_JSON" | jq -r '.access_token // empty' 2>/dev/null || true)"
if [[ -z "$IAM_TOKEN" ]]; then
  BODY='{"ok":false,"error":"publication_iam_token_missing","last_good_subscription_preserved":true}'
  respond_json 500 "$BODY"
fi

publish_and_verify() {
  local src_file="$1"
  local public_url="$2"
  local content_type="$3"
  local label="$4"

  local upload_response="$BASE_WORK/${label}.put.response"
  local upload_stderr="$BASE_WORK/${label}.put.stderr"
  local upload_http
  local upload_status

  upload_http="$(
    curl -sS \
      --connect-timeout 5 \
      --max-time 30 \
      --request PUT \
      --header "Authorization: Bearer ${IAM_TOKEN}" \
      --header "Content-Type: ${content_type}" \
      --header "Cache-Control: no-cache, max-age=0, must-revalidate" \
      --upload-file "$src_file" \
      --output "$upload_response" \
      --write-out '%{http_code}' \
      "$public_url" \
      2>"$upload_stderr"
  )"
  upload_status=$?

  if [[ "$upload_status" -ne 0 || "$upload_http" != "200" ]]; then
    local detail response
    detail="$(tail -c 4000 "$upload_stderr" 2>/dev/null || true)"
    response="$(tail -c 4000 "$upload_response" 2>/dev/null || true)"
    BODY="$(jq -cn \
      --arg label "$label" \
      --argjson exit_status "$upload_status" \
      --arg http_status "$upload_http" \
      --arg detail "$detail" \
      --arg response "$response" \
      --arg url "$public_url" \
      '{ok:false,error:"publication_object_storage_put_failed",label:$label,exit_status:$exit_status,http_status:$http_status,detail:$detail,response:$response,url:$url}')"
    respond_json 500 "$BODY"
  fi

  local verify_file="$BASE_WORK/${label}.public.verify"
  local verify_stderr="$BASE_WORK/${label}.verify.stderr"
  local verify_http
  local verify_status

  verify_http="$(
    curl -sS \
      --connect-timeout 5 \
      --max-time 30 \
      --header "Cache-Control: no-cache" \
      --output "$verify_file" \
      --write-out '%{http_code}' \
      "${public_url}?verify=$(date +%s%N)" \
      2>"$verify_stderr"
  )"
  verify_status=$?

  if [[ "$verify_status" -ne 0 || "$verify_http" != "200" ]]; then
    local detail
    detail="$(tail -c 4000 "$verify_stderr" 2>/dev/null || true)"
    BODY="$(jq -cn \
      --arg label "$label" \
      --argjson exit_status "$verify_status" \
      --arg http_status "$verify_http" \
      --arg detail "$detail" \
      --arg url "$public_url" \
      '{ok:false,error:"publication_public_read_verification_failed",label:$label,exit_status:$exit_status,http_status:$http_status,detail:$detail,url:$url,object_was_uploaded:true}')"
    respond_json 500 "$BODY"
  fi

  if ! cmp -s "$src_file" "$verify_file"; then
    BODY="$(jq -cn \
      --arg label "$label" \
      --arg url "$public_url" \
      '{ok:false,error:"publication_public_content_mismatch",label:$label,url:$url,object_was_uploaded:true}')"
    respond_json 500 "$BODY"
  fi
}

# Mihomo YAML is primary. Raw TXT is retained for other compatible clients.
publish_and_verify \
  "$YAML_FILE" \
  "$SUBSCRIPTION_YAML_URL" \
  "application/yaml; charset=utf-8" \
  "yaml"

publish_and_verify \
  "$TXT_FILE" \
  "$SUBSCRIPTION_TXT_URL" \
  "text/plain; charset=utf-8" \
  "txt"

publish_and_verify \
  "$HIDDIFY_FILE" \
  "$SUBSCRIPTION_HIDDIFY_URL" \
  "text/plain; charset=utf-8" \
  "hiddify"

unset IAM_TOKEN
TOKEN_JSON=""

YAML_BYTES="$(wc -c <"$YAML_FILE" | tr -d ' ')"
YAML_SHA256="$(sha256sum "$YAML_FILE" | awk '{print $1}')"
TXT_BYTES="$(wc -c <"$TXT_FILE" | tr -d ' ')"
TXT_SHA256="$(sha256sum "$TXT_FILE" | awk '{print $1}')"
HIDDIFY_BYTES="$(wc -c <"$HIDDIFY_FILE" | tr -d ' ')"
HIDDIFY_SHA256="$(sha256sum "$HIDDIFY_FILE" | awk '{print $1}')"
PUBLISHED_AT="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"

SUMMARY_UPDATED="$BASE_WORK/summary.published.json"
jq \
  --arg bucket "$SUBSCRIPTION_BUCKET" \
  --arg yaml_object "$SUBSCRIPTION_YAML_OBJECT" \
  --arg yaml_url "$SUBSCRIPTION_YAML_URL" \
  --arg yaml_sha256 "$YAML_SHA256" \
  --arg txt_object "$SUBSCRIPTION_TXT_OBJECT" \
  --arg txt_url "$SUBSCRIPTION_TXT_URL" \
  --arg txt_sha256 "$TXT_SHA256" \
  --arg hiddify_object "$SUBSCRIPTION_HIDDIFY_OBJECT" \
  --arg hiddify_url "$SUBSCRIPTION_HIDDIFY_URL" \
  --arg hiddify_sha256 "$HIDDIFY_SHA256" \
  --argjson hiddify_lines "$HIDDIFY_LINES" \
  --argjson hiddify_skipped "$HIDDIFY_SKIPPED" \
  --slurpfile hiddify_stats "$HIDDIFY_STATS_FILE" \
  --arg published_at "$PUBLISHED_AT" \
  --argjson final_count "$FINAL_COUNT" \
  --argjson yaml_bytes "$YAML_BYTES" \
  --argjson txt_bytes "$TXT_BYTES" \
  --argjson hiddify_bytes "$HIDDIFY_BYTES" \
  '. + {
    publication:{
      ok:true,
      bucket:$bucket,
      published_at_utc:$published_at,
      primary_format:"mihomo_yaml",
      mihomo:{
        object:$yaml_object,
        url:$yaml_url,
        http_status:200,
        public_read_verified:true,
        mihomo_validation:true,
        proxies:$final_count,
        bytes:$yaml_bytes,
        sha256:$yaml_sha256
      },
      raw_uri:{
        object:$txt_object,
        url:$txt_url,
        http_status:200,
        public_read_verified:true,
        target:"Lxbox",
        lines:$final_count,
        bytes:$txt_bytes,
        sha256:$txt_sha256
      },
      hiddify:{
        object:$hiddify_object,
        url:$hiddify_url,
        http_status:200,
        public_read_verified:true,
        target:"Hiddify",
        input_final_nodes:$final_count,
        lines:$hiddify_lines,
        skipped:$hiddify_skipped,
        bytes:$hiddify_bytes,
        sha256:$hiddify_sha256,
        conversion:($hiddify_stats[0] // {})
      },
      cache_control:"no-cache, max-age=0, must-revalidate"
    }
  }' \
  "$SUMMARY_FILE" >"$SUMMARY_UPDATED"

PUBLISH_SUMMARY_STATUS=$?
if [[ "$PUBLISH_SUMMARY_STATUS" -ne 0 || ! -s "$SUMMARY_UPDATED" ]]; then
  BODY="$(jq -cn \
    --argjson exit_status "$PUBLISH_SUMMARY_STATUS" \
    --arg yaml_url "$SUBSCRIPTION_YAML_URL" \
    '{ok:false,error:"publication_summary_update_failed",exit_status:$exit_status,yaml_url:$yaml_url,objects_were_uploaded:true}')"
  respond_json 500 "$BODY"
fi

mv "$SUMMARY_UPDATED" "$SUMMARY_FILE"

echo "Published Mihomo YAML: url=$SUBSCRIPTION_YAML_URL proxies=$FINAL_COUNT bytes=$YAML_BYTES sha256=$YAML_SHA256" >&2
echo "Published raw URI TXT (Lxbox): url=$SUBSCRIPTION_TXT_URL lines=$FINAL_COUNT bytes=$TXT_BYTES sha256=$TXT_SHA256" >&2
echo "Published Hiddify TXT: url=$SUBSCRIPTION_HIDDIFY_URL lines=$HIDDIFY_LINES skipped=$HIDDIFY_SKIPPED bytes=$HIDDIFY_BYTES sha256=$HIDDIFY_SHA256" >&2

respond_file 200 "$SUMMARY_FILE"
