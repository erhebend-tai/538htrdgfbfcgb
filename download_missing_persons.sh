#!/usr/bin/env bash
#
# download_missing_persons.sh
#
# Downloads current missing-persons data snapshots from official / public
# sources and stores organized JSON + CSV files, grouped by country, with
# timestamped filenames.
#
# Priority order:
#   1) USA           - NamUs public API, NCMEC public data, state AMBER feeds
#   2) UK / Britain  - UK missing persons public appeals (Missing People)
#   3) International  - Interpol public notices (yellow = missing persons)
#
# All sources are PUBLIC. The script is read-only with respect to those
# services (HTTP GET/POST search queries only) and writes only into
# ~/Downloads/MissingPersons/.
#
# Every fetch is best-effort: a source that is unreachable, rate-limited, or
# blocked by a network / WAF policy is logged and skipped without aborting the
# run. A partial snapshot is still useful, so the script always exits 0.

set -uo pipefail

# ----------------------------------------------------------------------------
# Configuration
# ----------------------------------------------------------------------------
BASE_DIR="${HOME}/Downloads/MissingPersons"
TS="$(date +%Y%m%d_%H%M%S)"
UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) MissingPersonsSnapshot/1.1"
CURL_TIMEOUT=60          # max seconds per request
CURL_RETRY=2             # network-error retries (curl --retry)
PAGE_LIMIT=50            # safety cap on pages per paginated source
LOG=""                   # set after BASE_DIR is created

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------
log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo "$msg"
    [[ -n "$LOG" ]] && echo "$msg" >> "$LOG"
}

# fetch_get <url> <output_file> [extra curl args...]
# Returns 0 on HTTP 2xx with a non-empty body; otherwise logs, deletes any
# non-2xx body (so stray 404/403 HTML pages are not left behind), returns 1.
fetch_get() {
    local url="$1" out="$2"; shift 2
    local code
    code="$(curl -sS -L \
        --max-time "$CURL_TIMEOUT" \
        --retry "$CURL_RETRY" --retry-delay 2 \
        -A "$UA" \
        -w '%{http_code}' \
        -o "$out" \
        "$@" \
        "$url" 2>>"$LOG")" || true
    if [[ "$code" =~ ^2 ]] && [[ -s "$out" ]]; then
        log "  OK   ($code) -> $(basename "$out")"
        return 0
    fi
    log "  FAIL ($code) <- $url"
    rm -f "$out"
    return 1
}

# fetch_post <url> <output_file> <json_body> [extra curl args...]
fetch_post() {
    local url="$1" out="$2" body="$3"; shift 3
    local code
    code="$(curl -sS -L \
        --max-time "$CURL_TIMEOUT" \
        --retry "$CURL_RETRY" --retry-delay 2 \
        -A "$UA" \
        -H 'Content-Type: application/json' \
        -H 'Accept: application/json' \
        -X POST \
        --data "$body" \
        -w '%{http_code}' \
        -o "$out" \
        "$@" \
        "$url" 2>>"$LOG")" || true
    if [[ "$code" =~ ^2 ]] && [[ -s "$out" ]]; then
        log "  OK   ($code) -> $(basename "$out")"
        return 0
    fi
    log "  FAIL ($code) <- $url"
    rm -f "$out"
    return 1
}

# valid_json <file> -> 0 if file parses as JSON
valid_json() { jq -e . "$1" >/dev/null 2>&1; }

# json_to_csv <input.json> <output.csv> <jq_rows_filter>
# The jq filter must emit an array of flat-ish objects. Columns are the union
# of all keys; nested values are JSON-encoded. Writes a header even if there
# are zero data rows, so an empty-but-valid result is still recorded.
json_to_csv() {
    local in="$1" out="$2" filter="$3"
    if ! valid_json "$in"; then
        log "  skip CSV (not valid JSON): $(basename "$in")"
        return 1
    fi
    if jq -r "($filter) as \$rows
        | ((\$rows | map(keys) | add | unique) // []) as \$cols
        | if (\$cols | length) == 0 then empty
          else (\$cols),
               (\$rows[] | [ .[ \$cols[] ] | if . == null then \"\" else tostring end ])
          end
        | @csv" "$in" > "$out" 2>>"$LOG" && [[ -s "$out" ]]; then
        log "  CSV  -> $(basename "$out") ($(($(wc -l < "$out") - 1)) data rows)"
    else
        log "  no CSV (zero rows / no parseable records): $(basename "$in")"
        rm -f "$out"
    fi
}

# ----------------------------------------------------------------------------
# Setup
# ----------------------------------------------------------------------------
mkdir -p "$BASE_DIR"/{USA,UK,International,_logs}
LOG="${BASE_DIR}/_logs/run_${TS}.log"
: > "$LOG"

log "=============================================================="
log "Missing Persons snapshot run"
log "Timestamp : $TS"
log "Output dir: $BASE_DIR"
log "=============================================================="

OK=0
FAIL=0
mark() { if [[ "$1" -eq 0 ]]; then OK=$((OK+1)); else FAIL=$((FAIL+1)); fi; }

# ============================================================================
# 1) USA
# ============================================================================
log ""
log "### 1) USA ###################################################"
USA_DIR="${BASE_DIR}/USA"

# --- 1a. NamUs - National Missing and Unidentified Persons System ----------
# Public search API. Empty predicates => all cases; paged via skip/take.
log "[USA] NamUs missing persons (namus.gov public API)"
NAMUS_RAW="${USA_DIR}/namus_missing_persons_${TS}.json"
NAMUS_PROJ='["namus2Number","firstName","lastName","computedMissingMinAge","dateOfLastContact","cityOfLastContact","countyDisplayNameOfLastContact"]'
namus_pages=()
skip=0; take=1000; namus_total=-1
for ((p=0; p<PAGE_LIMIT; p++)); do
    # NamUs caps this search endpoint's result window at 10000 records; stop
    # cleanly there rather than triggering an expected HTTP 400.
    if [[ "$skip" -ge 10000 ]]; then
        log "  NamUs 10000-record result window reached; stopping pagination"
        break
    fi
    tmp="$(mktemp)"
    body="{\"take\":${take},\"skip\":${skip},\"projections\":${NAMUS_PROJ},\"predicates\":[],\"orderProperty\":\"namus2Number\",\"orderDirection\":\"ascending\"}"
    if ! fetch_post "https://www.namus.gov/api/CaseSets/NamUs/MissingPersons/Search" "$tmp" "$body"; then
        rm -f "$tmp"; break
    fi
    if ! valid_json "$tmp"; then rm -f "$tmp"; break; fi
    [[ "$namus_total" -lt 0 ]] && namus_total="$(jq -r '.count // 0' "$tmp")" \
        && log "  NamUs reports ${namus_total} total records"
    got="$(jq -r '.results | length' "$tmp")"
    namus_pages+=("$tmp")
    skip=$((skip+take))
    [[ "$got" -lt "$take" ]] && break
    [[ "$skip" -ge "$namus_total" ]] && break
done
if [[ "${#namus_pages[@]}" -gt 0 ]]; then
    jq -s '{count: (.[0].count // 0), results: (map(.results // []) | add)}' "${namus_pages[@]}" > "$NAMUS_RAW" 2>>"$LOG"
    rm -f "${namus_pages[@]}"
    json_to_csv "$NAMUS_RAW" "${USA_DIR}/namus_missing_persons_${TS}.csv" '.results'
    mark 0
else
    mark 1
fi

# --- 1b. NCMEC - National Center for Missing & Exploited Children ----------
# Public open-search API used by missingkids.org. Paged via totalPages.
log "[USA] NCMEC missing children (api.missingkids.org public data)"
NCMEC_RAW="${USA_DIR}/ncmec_missing_children_${TS}.json"
ncmec_pages=(); ncmec_tp=1
for ((p=1; p<=PAGE_LIMIT; p++)); do
    tmp="$(mktemp)"
    body="{\"caseType\":null,\"firstName\":null,\"lastName\":null,\"missCountry\":\"US\",\"searchInternational\":false,\"page\":${p}}"
    if ! fetch_post "https://api.missingkids.org/missingkids/servlet/JSONDataServlet?action=publicSearch&searchLang=en_US" "$tmp" "$body"; then
        rm -f "$tmp"; break
    fi
    if ! valid_json "$tmp"; then rm -f "$tmp"; break; fi
    if [[ "$p" -eq 1 ]]; then
        ncmec_tp="$(jq -r '.totalPages // 1' "$tmp")"
        (( ncmec_tp > PAGE_LIMIT )) && ncmec_tp=$PAGE_LIMIT
        log "  NCMEC reports $(jq -r '.totalRecords // "?"' "$tmp") records across ${ncmec_tp} page(s)"
    fi
    ncmec_pages+=("$tmp")
    [[ "$p" -ge "$ncmec_tp" ]] && break
done
if [[ "${#ncmec_pages[@]}" -gt 0 ]]; then
    jq -s '{totalRecords: (.[0].totalRecords // 0), persons: (map(.persons // []) | add)}' "${ncmec_pages[@]}" > "$NCMEC_RAW" 2>>"$LOG"
    rm -f "${ncmec_pages[@]}"
    json_to_csv "$NCMEC_RAW" "${USA_DIR}/ncmec_missing_children_${TS}.csv" '.persons'
    mark 0
else
    mark 1
fi

# --- 1c. AMBER Alerts ------------------------------------------------------
# National AMBER alert feed (NCMEC) + NWS Common Alerting Protocol feed
# filtered to active Child Abduction Emergency events.
log "[USA] AMBER alert feeds"
AMBER_OK=1

AMBER_NCMEC="${USA_DIR}/amber_alerts_ncmec_${TS}.json"
if fetch_get "https://api.missingkids.org/missingkids/servlet/JSONDataServlet?action=amberAlert" "$AMBER_NCMEC"; then
    json_to_csv "$AMBER_NCMEC" "${USA_DIR}/amber_alerts_ncmec_${TS}.csv" \
        '(.persons // .alerts // [])'
    AMBER_OK=0
fi

AMBER_NWS="${USA_DIR}/amber_alerts_nws_cap_${TS}.json"
if fetch_get "https://api.weather.gov/alerts/active?event=Child%20Abduction%20Emergency" "$AMBER_NWS" \
        -H 'Accept: application/geo+json'; then
    json_to_csv "$AMBER_NWS" "${USA_DIR}/amber_alerts_nws_cap_${TS}.csv" \
        '[.features[]? | .properties | {id, areaDesc, sent, headline, description}]'
    AMBER_OK=0
fi
mark "$AMBER_OK"

# ============================================================================
# 2) UK / Britain
# ============================================================================
log ""
log "### 2) UK / Britain ##########################################"
UK_DIR="${BASE_DIR}/UK"

# UK missing persons public appeals. The official appeals are published by the
# Missing People charity (which also fronts missingpersons.police.uk content)
# via a public WordPress REST API ('missing_person' post type), paged with the
# X-WP-TotalPages header.
log "[UK] UK missing persons public appeals (missingpeople.org.uk)"
UK_RAW="${UK_DIR}/uk_missing_persons_appeals_${TS}.json"
UK_BASE="https://www.missingpeople.org.uk/wp-json/wp/v2/missing_person"
uk_pages=(); uk_tp=1
for ((p=1; p<=PAGE_LIMIT; p++)); do
    tmp="$(mktemp)"; hdr="$(mktemp)"
    code="$(curl -sS -L --max-time "$CURL_TIMEOUT" --retry "$CURL_RETRY" --retry-delay 2 \
        -A "$UA" -D "$hdr" -o "$tmp" -w '%{http_code}' \
        "${UK_BASE}?per_page=100&page=${p}&_fields=id,slug,date,modified,link,title,acf,status" 2>>"$LOG")" || true
    if [[ ! "$code" =~ ^2 ]] || [[ ! -s "$tmp" ]] || ! valid_json "$tmp"; then
        log "  FAIL ($code) page ${p}"; rm -f "$tmp" "$hdr"; break
    fi
    if [[ "$p" -eq 1 ]]; then
        uk_tp="$(grep -i '^x-wp-totalpages:' "$hdr" | tr -dc '0-9')"
        [[ -z "$uk_tp" ]] && uk_tp=1
        (( uk_tp > PAGE_LIMIT )) && uk_tp=$PAGE_LIMIT
        log "  OK   ($code) UK reports $(grep -i '^x-wp-total:' "$hdr" | tr -dc '0-9') appeals across ${uk_tp} page(s)"
    fi
    rm -f "$hdr"
    uk_pages+=("$tmp")
    [[ "$p" -ge "$uk_tp" ]] && break
done
if [[ "${#uk_pages[@]}" -gt 0 ]]; then
    jq -s 'add' "${uk_pages[@]}" > "$UK_RAW" 2>>"$LOG"
    rm -f "${uk_pages[@]}"
    json_to_csv "$UK_RAW" "${UK_DIR}/uk_missing_persons_appeals_${TS}.csv" \
        '[.[] | {id, slug, date, modified, status, link, name: (.title.rendered // ""), reference: (.acf.reference? // .acf.case_reference? // "")}]'
    mark 0
else
    mark 1
fi

# ============================================================================
# 3) International - Interpol
# ============================================================================
log ""
log "### 3) International (Interpol) ###############################"
INT_DIR="${BASE_DIR}/International"

# Interpol public Notices web service.
#   yellow = missing persons (primary)
#   red    = wanted persons (supplementary, for completeness)
# NOTE: ws-public.interpol.int sits behind an Akamai WAF that denies requests
# from many datacenter / cloud IP ranges (HTTP 403 "Access Denied"). This is an
# upstream access policy, not a bug here - the same call succeeds from an
# ordinary network. We do not attempt to evade the WAF; the failure is logged
# and skipped like any other unreachable source.
fetch_interpol_notices() {
    local kind="$1"                 # yellow | red
    local raw="${INT_DIR}/interpol_${kind}_notices_${TS}.json"
    local tmp page total_pages url
    local pagebodies=()
    log "[INT] Interpol ${kind} notices (ws-public.interpol.int)"

    page=1; total_pages=1
    while [[ "$page" -le "$total_pages" && "$page" -le "$PAGE_LIMIT" ]]; do
        tmp="$(mktemp)"
        url="https://ws-public.interpol.int/notices/v1/${kind}?page=${page}&resultPerPage=160"
        if ! fetch_get "$url" "$tmp" -H 'Accept: application/json' -H 'Referer: https://www.interpol.int/'; then
            rm -f "$tmp"; break
        fi
        if ! valid_json "$tmp"; then rm -f "$tmp"; break; fi
        if [[ "$page" -eq 1 ]]; then
            local total; total="$(jq -r '.total // 0' "$tmp")"
            total_pages=$(( (total + 159) / 160 ))
            (( total_pages < 1 )) && total_pages=1
            (( total_pages > PAGE_LIMIT )) && total_pages=$PAGE_LIMIT
            log "  ${kind}: ~${total} records across ${total_pages} page(s)"
        fi
        pagebodies+=("$tmp")
        page=$((page+1))
    done

    if [[ "${#pagebodies[@]}" -eq 0 ]]; then
        mark 1; return
    fi
    jq -s '{notices: ( map(._embedded.notices // []) | add )}' "${pagebodies[@]}" > "$raw" 2>>"$LOG"
    rm -f "${pagebodies[@]}"
    json_to_csv "$raw" "${INT_DIR}/interpol_${kind}_notices_${TS}.csv" \
        '[.notices[]? | {entity_id, name, forename, sex_id, date_of_birth, nationalities: ((.nationalities // []) | join("|")), place_of_birth}]'
    mark 0
}

fetch_interpol_notices "yellow"   # missing persons
fetch_interpol_notices "red"      # wanted (supplementary)

# ============================================================================
# Summary
# ============================================================================
log ""
log "=============================================================="
log "Run complete: ${OK} source group(s) OK, ${FAIL} failed/unreachable"
log "Files written under: $BASE_DIR"
log "=============================================================="

# Show this run's files for convenience.
log "Snapshot files:"
find "$BASE_DIR" -type f -name "*_${TS}.*" -printf '  %10s bytes  %p\n' 2>/dev/null \
    | sort -k3 | tee -a "$LOG"

# Exit 0 even if some sources failed - a partial snapshot is still useful.
exit 0
