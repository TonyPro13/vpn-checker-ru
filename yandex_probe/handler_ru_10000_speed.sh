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
SPEED_MIN_MBPS=5
SPEED_URL_BASE="https://speed.cloudflare.com/__down"
GEO_URL="https://ipwho.is/?fields=ip,success,country,country_code,city,flag"
GEO_FALLBACK_URL=""
GEO_TIMEOUT_SECONDS=6

SUBSCRIPTION_BUCKET="${SUBSCRIPTION_BUCKET:-tony-vpn-subscription-2026}"
SUBSCRIPTION_OBJECT="${SUBSCRIPTION_OBJECT:-subscription.txt}"
SUBSCRIPTION_URL="https://storage.yandexcloud.net/${SUBSCRIPTION_BUCKET}/${SUBSCRIPTION_OBJECT}"
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

  FINAL_COUNT_PRE_GEO="$(jq 'length' "$FINAL_KEYS_FILE")"
  printf '[]\n' >"$GEO_RESULTS_FILE"

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

  cleanup_mihomo
else
  SPEED_ELAPSED_MS=0
  SPEED_WORKERS=0
  GEO_WORKERS=0
  GEO_ELAPSED_MS=0
  GEO_RESULTS_FILE="$BASE_WORK/geo_results.json"
  printf '[]\n' >"$GEO_RESULTS_FILE"
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
  --slurpfile geo_results "$GEO_RESULTS_FILE" '
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
    ) as $geo_pass_sorted
  | (
      reduce $geo_pass_sorted[] as $item (
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
  | ($naming.items) as $final_survivors
  | (($after_speed|length) - ($geo_pass_sorted|length)) as $removed_geo_failed
  | ([$survivors[] | select(.speed_test_ok != true)] | length) as $removed_speed_failed
  | ([$survivors[] | select(.speed_test_ok == true and (.speed_mbps // 0) < $speed_min_mbps)] | length) as $removed_below_threshold
  | {
      ok:true,
      mihomo_version:$version,
      location:"yandex_ru",
      stage:"ru_mihomo_speed_ipwho_geo_strict_unique_naming",
      ranking_rule:"strict speed gate first, then ranking only by RU latency",
      strategy:"RU delay -> strict speed gate -> ipwho.is exit geolocation -> strict geo gate -> naming",
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
      geo:{
        provider:"ipwho.is",
        endpoint:$geo_url,
        fallback:null,
        concurrency:$geo_concurrency,
        timeout_seconds:$geo_timeout_seconds,
        elapsed_ms:$geo_elapsed,
        attempted:($after_speed|length),
        success_complete:($final_survivors|length),
        removed_geo_failed:$removed_geo_failed,
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
# Publish the final subscription to Yandex Object Storage.
# Safety rule: never replace the last-known-good subscription
# with an empty or failed build.
# ------------------------------------------------------------

FINAL_COUNT="$(jq -r '.geo.final_count // 0' "$SUMMARY_FILE")"
NAMING_FAILED="$(jq -r '.naming.naming_failed // 0' "$SUMMARY_FILE")"

if [[ "$FINAL_COUNT" -le 0 ]]; then
  BODY="$(jq -cn \
    --arg bucket "$SUBSCRIPTION_BUCKET" \
    --arg object "$SUBSCRIPTION_OBJECT" \
    '{ok:false,error:"publication_skipped_empty_subscription",bucket:$bucket,object:$object,last_good_subscription_preserved:true}')"
  respond_json 500 "$BODY"
fi

if [[ "$NAMING_FAILED" -ne 0 ]]; then
  BODY="$(jq -cn \
    --argjson naming_failed "$NAMING_FAILED" \
    '{ok:false,error:"publication_skipped_naming_failed",naming_failed:$naming_failed,last_good_subscription_preserved:true}')"
  respond_json 500 "$BODY"
fi

SUBSCRIPTION_FILE="$BASE_WORK/subscription.txt"
jq -r '.subscription_text // empty' "$SUMMARY_FILE" >"$SUBSCRIPTION_FILE"

if [[ ! -s "$SUBSCRIPTION_FILE" ]]; then
  BODY='{"ok":false,"error":"publication_subscription_file_empty","last_good_subscription_preserved":true}'
  respond_json 500 "$BODY"
fi

# Ensure there is exactly one trailing newline.
python3 - "$SUBSCRIPTION_FILE" <<'PY'
from pathlib import Path
import sys

p = Path(sys.argv[1])
data = p.read_bytes().rstrip(b"\r\n") + b"\n"
p.write_bytes(data)
PY
NORMALIZE_STATUS=$?

if [[ "$NORMALIZE_STATUS" -ne 0 || ! -s "$SUBSCRIPTION_FILE" ]]; then
  BODY="$(jq -cn \
    --argjson exit_status "$NORMALIZE_STATUS" \
    '{ok:false,error:"publication_subscription_normalize_failed",exit_status:$exit_status,last_good_subscription_preserved:true}')"
  respond_json 500 "$BODY"
fi

SUBSCRIPTION_LINES="$(grep -cve '^[[:space:]]*$' "$SUBSCRIPTION_FILE" || true)"
if [[ "$SUBSCRIPTION_LINES" -ne "$FINAL_COUNT" ]]; then
  BODY="$(jq -cn \
    --argjson expected "$FINAL_COUNT" \
    --argjson actual "$SUBSCRIPTION_LINES" \
    '{ok:false,error:"publication_line_count_mismatch",expected:$expected,actual:$actual,last_good_subscription_preserved:true}')"
  respond_json 500 "$BODY"
fi

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

UPLOAD_RESPONSE="$BASE_WORK/storage_put_response.txt"
UPLOAD_STDERR="$BASE_WORK/storage_put.stderr.log"

UPLOAD_HTTP="$(
  curl -sS \
    --connect-timeout 5 \
    --max-time 30 \
    --request PUT \
    --header "Authorization: Bearer ${IAM_TOKEN}" \
    --header "Content-Type: text/plain; charset=utf-8" \
    --header "Cache-Control: no-cache, max-age=0, must-revalidate" \
    --upload-file "$SUBSCRIPTION_FILE" \
    --output "$UPLOAD_RESPONSE" \
    --write-out '%{http_code}' \
    "$SUBSCRIPTION_URL" \
    2>"$UPLOAD_STDERR"
)"
UPLOAD_STATUS=$?

# Forget the token as soon as the authenticated request is complete.
unset IAM_TOKEN
TOKEN_JSON=""

if [[ "$UPLOAD_STATUS" -ne 0 || "$UPLOAD_HTTP" != "200" ]]; then
  UPLOAD_ERROR="$(tail -c 4000 "$UPLOAD_STDERR" 2>/dev/null || true)"
  UPLOAD_BODY="$(tail -c 4000 "$UPLOAD_RESPONSE" 2>/dev/null || true)"
  BODY="$(jq -cn \
    --argjson exit_status "$UPLOAD_STATUS" \
    --arg http_status "$UPLOAD_HTTP" \
    --arg detail "$UPLOAD_ERROR" \
    --arg response "$UPLOAD_BODY" \
    --arg url "$SUBSCRIPTION_URL" \
    '{ok:false,error:"publication_object_storage_put_failed",exit_status:$exit_status,http_status:$http_status,detail:$detail,response:$response,url:$url,last_good_subscription_preserved:true}')"
  respond_json 500 "$BODY"
fi

# Public read verification. This confirms both the bucket setting and
# that clients will receive exactly the bytes we just published.
VERIFY_FILE="$BASE_WORK/subscription.public.verify.txt"
VERIFY_STDERR="$BASE_WORK/subscription.public.verify.stderr.log"

VERIFY_HTTP="$(
  curl -sS \
    --connect-timeout 5 \
    --max-time 30 \
    --header "Cache-Control: no-cache" \
    --output "$VERIFY_FILE" \
    --write-out '%{http_code}' \
    "${SUBSCRIPTION_URL}?verify=$(date +%s)" \
    2>"$VERIFY_STDERR"
)"
VERIFY_STATUS=$?

if [[ "$VERIFY_STATUS" -ne 0 || "$VERIFY_HTTP" != "200" ]]; then
  VERIFY_ERROR="$(tail -c 4000 "$VERIFY_STDERR" 2>/dev/null || true)"
  BODY="$(jq -cn \
    --argjson exit_status "$VERIFY_STATUS" \
    --arg http_status "$VERIFY_HTTP" \
    --arg detail "$VERIFY_ERROR" \
    --arg url "$SUBSCRIPTION_URL" \
    '{ok:false,error:"publication_public_read_verification_failed",exit_status:$exit_status,http_status:$http_status,detail:$detail,url:$url,object_was_uploaded:true}')"
  respond_json 500 "$BODY"
fi

if ! cmp -s "$SUBSCRIPTION_FILE" "$VERIFY_FILE"; then
  BODY="$(jq -cn \
    --arg url "$SUBSCRIPTION_URL" \
    '{ok:false,error:"publication_public_content_mismatch",url:$url,object_was_uploaded:true}')"
  respond_json 500 "$BODY"
fi

SUBSCRIPTION_BYTES="$(wc -c <"$SUBSCRIPTION_FILE" | tr -d ' ')"
SUBSCRIPTION_SHA256="$(sha256sum "$SUBSCRIPTION_FILE" | awk '{print $1}')"
PUBLISHED_AT="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"

SUMMARY_UPDATED="$BASE_WORK/summary.published.json"
jq \
  --arg bucket "$SUBSCRIPTION_BUCKET" \
  --arg object "$SUBSCRIPTION_OBJECT" \
  --arg url "$SUBSCRIPTION_URL" \
  --arg published_at "$PUBLISHED_AT" \
  --arg sha256 "$SUBSCRIPTION_SHA256" \
  --argjson bytes "$SUBSCRIPTION_BYTES" \
  --argjson lines "$SUBSCRIPTION_LINES" \
  '. + {
    publication:{
      ok:true,
      bucket:$bucket,
      object:$object,
      url:$url,
      published_at_utc:$published_at,
      http_status:200,
      public_read_verified:true,
      lines:$lines,
      bytes:$bytes,
      sha256:$sha256,
      cache_control:"no-cache, max-age=0, must-revalidate"
    }
  }' \
  "$SUMMARY_FILE" >"$SUMMARY_UPDATED"

PUBLISH_SUMMARY_STATUS=$?
if [[ "$PUBLISH_SUMMARY_STATUS" -ne 0 || ! -s "$SUMMARY_UPDATED" ]]; then
  BODY="$(jq -cn \
    --argjson exit_status "$PUBLISH_SUMMARY_STATUS" \
    --arg url "$SUBSCRIPTION_URL" \
    '{ok:false,error:"publication_summary_update_failed",exit_status:$exit_status,url:$url,object_was_uploaded:true}')"
  respond_json 500 "$BODY"
fi

mv "$SUMMARY_UPDATED" "$SUMMARY_FILE"

echo "Published subscription: url=$SUBSCRIPTION_URL lines=$SUBSCRIPTION_LINES bytes=$SUBSCRIPTION_BYTES sha256=$SUBSCRIPTION_SHA256" >&2

respond_file 200 "$SUMMARY_FILE"
