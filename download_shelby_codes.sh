#!/usr/bin/env bash
#
# download_shelby_codes.sh
# -----------------------------------------------------------------------------
# Scrapes and downloads publicly available Shelby County, Tennessee government
# "codes" -- police / public-safety, fire, ambulance / EMS, and hospital /
# health-related ordinances and documents -- from official public sources and
# saves everything, organized by category, under:
#
#       ~/Downloads/ShelbyCountyCodes/
#
# Sources attempted (all public, official):
#   * Municode Code of Ordinances API  (library.municode.com / api.municode.com)
#   * www.shelbycountytn.gov           (Shelby County government / Document Center)
#   * www.shelby-sheriff.org           (Shelby County Sheriff's Office)
#   * www.shelbytnhealth.com           (Shelby County Health Department)
#   * www.shelbytnso.com               (Sheriff's Office alt domain, if reachable)
#   * www.memphis.gov                  (City of Memphis, if reachable)
#
# Notes / honesty:
#   - Only PUBLICLY available pages and documents are fetched. No logins, no
#     paywalled or restricted content, no credential use.
#   - Some hosts may be blocked by your network policy or be temporarily down;
#     those are skipped and logged rather than causing the run to fail.
#   - "Hospital codes" in the sense of internal hospital emergency codes
#     (e.g. "Code Blue") are generally NOT published by government bodies, so
#     that folder collects whatever hospital/health-related ordinances and
#     documents the official sources do publish. This is noted in the summary.
#
# Usage:
#   ./download_shelby_codes.sh
# -----------------------------------------------------------------------------

set -uo pipefail

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
BASE_DIR="${HOME}/Downloads/ShelbyCountyCodes"
UA="Mozilla/5.0 (compatible; ShelbyCodeArchiver/1.0; public-records-archival)"
CURL=(curl -sSL --retry 3 --retry-delay 2 --max-time 60 -A "$UA")
SLEEP_BETWEEN="0.4"     # be polite between requests

# Category subdirectories
CATEGORIES=(police fire ambulance hospital municipal_code)

# Keyword routing: which categories a heading / filename / link belongs to.
# (case-insensitive, matched as extended regex)
RE_POLICE='police|sheriff|public safety|law enforcement|9-?1-?1|patrol|deputy|crime|jail|detention|arrest|warrant'
RE_FIRE='fire|arson|hazmat|hazardous material|burn permit|fire prevention|fire protection|fire code|emergency management'
RE_AMBULANCE='ambulance|emergency medical|\bems\b|paramedic|emergency medical services|first responder|emergency transport'
RE_HOSPITAL='hospital|health department|public health|medical examiner|trauma|code blue|epidemic|communicable|clinic|infectious'

# -----------------------------------------------------------------------------
# Setup
# -----------------------------------------------------------------------------
mkdir -p "$BASE_DIR"
for c in "${CATEGORIES[@]}"; do mkdir -p "${BASE_DIR}/${c}"; done
LOG="${BASE_DIR}/_run.log"
MANIFEST="${BASE_DIR}/_manifest.tsv"
: > "$LOG"
printf "category\tsource\tfilename\n" > "$MANIFEST"

log()  { printf '%s\n' "$*" | tee -a "$LOG" >&2; }
note() { printf '%s\n' "$*" >> "$LOG"; }

# sanitize a string into a safe filename
slug() {
    printf '%s' "$1" \
        | tr '[:upper:]' '[:lower:]' \
        | sed -E 's/[^a-z0-9]+/_/g; s/^_+//; s/_+$//' \
        | cut -c1-120
}

# record a saved file in the manifest
record() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$MANIFEST"; }

# return space-separated list of categories a piece of text belongs to
categorize() {
    local text="$1" cats=""
    shopt -s nocasematch
    [[ "$text" =~ $RE_POLICE    ]] && cats+="police "
    [[ "$text" =~ $RE_FIRE      ]] && cats+="fire "
    [[ "$text" =~ $RE_AMBULANCE ]] && cats+="ambulance "
    [[ "$text" =~ $RE_HOSPITAL  ]] && cats+="hospital "
    shopt -u nocasematch
    printf '%s' "$cats"
}

# check host reachability (DNS + TCP) before crawling
host_up() {
    local url="$1"
    local code
    code=$("${CURL[@]}" -o /dev/null -w '%{http_code}' --max-time 20 "$url" 2>/dev/null)
    [[ "$code" =~ ^[23] ]]
}

# =============================================================================
# PART 1 -- Municode Code of Ordinances (the core legal "codes")
# =============================================================================
fetch_municode() {
    local api="https://api.municode.com"
    log ""
    log "==== [1/2] Municode Code of Ordinances (Shelby County, TN) ===="

    if ! host_up "$api/Clients/name?clientName=Shelby%20County&stateAbbr=TN"; then
        log "  ! Municode API not reachable -- skipping."
        return
    fi

    # Resolve client -> product -> latest job dynamically (no hard-coded IDs).
    local client_id product_id job_id
    client_id=$("${CURL[@]}" "$api/Clients/name?clientName=Shelby%20County&stateAbbr=TN" 2>/dev/null | jq -r '.ClientID // empty')
    [[ -z "$client_id" ]] && { log "  ! Could not resolve Municode client id."; return; }
    product_id=$("${CURL[@]}" "$api/ClientContent/$client_id" 2>/dev/null \
                  | jq -r '.codes[]? | select(.productName|test("Code of Ordinances";"i")) | .productId' | head -1)
    [[ -z "$product_id" ]] && { log "  ! Could not resolve Municode product id."; return; }
    job_id=$("${CURL[@]}" "$api/Jobs/latest/$product_id" 2>/dev/null | jq -r '.Id // empty')
    [[ -z "$job_id" ]] && { log "  ! Could not resolve Municode job id."; return; }
    log "  client=$client_id product=$product_id job=$job_id"

    # Top-level table of contents (chapters / parts).
    local toc
    toc=$("${CURL[@]}" "$api/CodesToc?jobId=$job_id&productId=$product_id" 2>/dev/null)
    [[ -z "$toc" ]] && { log "  ! Empty TOC."; return; }

    # Iterate over each top-level node, pull full content (with children).
    local saved=0
    while IFS=$'\t' read -r node_id heading; do
        [[ -z "$node_id" || "$node_id" == "$product_id" ]] && continue

        local content title_slug outfile
        content=$("${CURL[@]}" \
            "$api/CodesContent?jobId=$job_id&productId=$product_id&nodeId=${node_id}&showChildren=true" 2>/dev/null)
        # require some real document text
        [[ -z "$content" ]] && { sleep "$SLEEP_BETWEEN"; continue; }

        title_slug=$(slug "$heading")
        [[ -z "$title_slug" ]] && title_slug=$(slug "$node_id")

        # Build a readable standalone HTML file from the JSON doc chunks.
        outfile="${BASE_DIR}/municipal_code/${title_slug}.html"
        {
            printf '<!DOCTYPE html><html><head><meta charset="utf-8">'
            printf '<title>%s -- Code of Shelby County, TN</title></head><body>\n' "$heading"
            printf '<h1>%s</h1>\n' "$heading"
            printf '<p><em>Source: Municode Code of Ordinances, Shelby County, Tennessee. Retrieved %s.</em></p>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
            printf '%s' "$content" | jq -r '.Docs[]? | "<section><h2>" + (.Title // "") + "</h2>" + (.Content // "") + "</section>"' 2>/dev/null
            printf '\n</body></html>\n'
        } > "$outfile"

        # skip if nothing meaningful was written
        if [[ $(wc -c < "$outfile") -lt 200 ]]; then rm -f "$outfile"; sleep "$SLEEP_BETWEEN"; continue; fi

        record "municipal_code" "municode:$heading" "$(basename "$outfile")"
        saved=$((saved+1))

        # Route copies into topical folders based on the heading AND on the
        # individual section titles inside the chapter.
        local cats; cats=$(categorize "$heading")
        # also inspect section titles within this chapter for category hits
        local sect_titles
        sect_titles=$(printf '%s' "$content" | jq -r '[.Docs[]?.Title] | join(" ")' 2>/dev/null)
        cats="$cats $(categorize "$sect_titles")"
        for c in $(printf '%s' "$cats" | tr ' ' '\n' | sort -u); do
            [[ -z "$c" ]] && continue
            cp -f "$outfile" "${BASE_DIR}/${c}/${title_slug}.html"
            record "$c" "municode:$heading" "${title_slug}.html"
        done

        note "  saved chapter: $heading -> [${cats// /, }]"
        sleep "$SLEEP_BETWEEN"
    done < <(printf '%s' "$toc" | jq -r '.Children[]? | "\(.Id)\t\(.Heading)"')

    log "  Municode: saved $saved code sections."
}

# =============================================================================
# PART 2 -- Official agency websites: harvest published PDFs / documents
# =============================================================================
# Crawl a seed page one level deep, find document links (.pdf and CivicPlus
# /DocumentCenter/View/ links), categorize by link text + url, and download.
harvest_site() {
    local label="$1" base="$2"; shift 2
    local seeds=("$@")

    log ""
    log "---- $label ($base) ----"
    if ! host_up "$base"; then
        log "  ! $base not reachable (blocked by network policy or offline) -- skipped."
        return
    fi

    local downloaded=0 seen_tmp; seen_tmp=$(mktemp)

    for seed in "${seeds[@]}"; do
        local page
        page=$("${CURL[@]}" "$seed" 2>/dev/null)
        [[ -z "$page" ]] && continue

        # Extract candidate document links with their anchor text.
        # Output lines:  URL<TAB>anchor-text
        printf '%s' "$page" \
          | grep -oiE '<a[^>]+href="[^"]+"[^>]*>[^<]*' \
          | sed -E 's/.*href="([^"]+)"[^>]*>(.*)/\1\t\2/I' \
          | while IFS=$'\t' read -r href text; do
                # Normalize to absolute URL
                case "$href" in
                    http*) url="$href" ;;
                    //*)   url="https:$href" ;;
                    /*)    url="${base%/}$href" ;;
                    *)     continue ;;
                esac
                # Only documents: explicit PDFs or CivicPlus document center views
                if ! printf '%s' "$url" | grep -qiE '\.pdf($|\?)|/DocumentCenter/View/'; then
                    continue
                fi
                printf '%s\t%s\n' "$url" "$text"
            done | sort -u >> "$seen_tmp"
        sleep "$SLEEP_BETWEEN"
    done

    # Download each unique document into its category folder(s).
    while IFS=$'\t' read -r url text; do
        [[ -z "$url" ]] && continue
        local cats; cats=$(categorize "$text $url")
        # If no category keyword matched, file it under municipal_code as misc
        [[ -z "${cats// /}" ]] && continue   # skip clearly-unrelated docs

        # derive a filename
        local fname
        fname=$(printf '%s' "$url" | sed -E 's/\?.*$//; s#.*/##')
        [[ "$fname" != *.pdf ]] && fname="$(slug "${text:-$fname}").pdf"
        fname="$(slug "$label")_$(slug "${fname%.pdf}").pdf"

        local got=0
        for c in $(printf '%s' "$cats" | tr ' ' '\n' | sort -u); do
            [[ -z "$c" ]] && continue
            local out="${BASE_DIR}/${c}/${fname}"
            if [[ ! -f "$out" ]]; then
                if "${CURL[@]}" -o "$out" "$url" 2>/dev/null && [[ -s "$out" ]] \
                   && file "$out" 2>/dev/null | grep -qiE 'pdf|document'; then
                    record "$c" "$label:$url" "$fname"
                    got=1
                else
                    rm -f "$out"
                fi
            else
                got=1
            fi
        done
        [[ $got -eq 1 ]] && { downloaded=$((downloaded+1)); note "  doc: $text -> [${cats// /, }]"; }
        sleep "$SLEEP_BETWEEN"
    done < "$seen_tmp"

    rm -f "$seen_tmp"
    log "  $label: downloaded $downloaded document(s)."
}

# =============================================================================
# Run
# =============================================================================
log "Shelby County, TN public codes archiver"
log "Output: $BASE_DIR"
log "Started: $(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Part 1: the legal codes themselves
fetch_municode

# Part 2: agency document libraries
log ""
log "==== [2/2] Official agency document libraries ===="

harvest_site "ShelbyCountyGov" "https://www.shelbycountytn.gov" \
    "https://www.shelbycountytn.gov/" \
    "https://www.shelbycountytn.gov/156/Fire-Department" \
    "https://www.shelbycountytn.gov/DocumentCenter" \
    "https://www.shelbycountytn.gov/Archive.aspx"

harvest_site "SheriffOffice" "https://www.shelby-sheriff.org" \
    "https://www.shelby-sheriff.org/" \
    "https://www.shelby-sheriff.org/documents.php"

harvest_site "HealthDept" "https://www.shelbytnhealth.com" \
    "https://www.shelbytnhealth.com/" \
    "https://www.shelbytnhealth.com/DocumentCenter" \
    "https://www.shelbytnhealth.com/Archive.aspx"

# Best-effort: alternate / additional domains named in the request.
harvest_site "ShelbyTNSO" "https://www.shelbytnso.com" \
    "https://www.shelbytnso.com/"

harvest_site "MemphisGov" "https://www.memphis.gov" \
    "https://www.memphis.gov/" \
    "https://www.memphis.gov/police/" \
    "https://www.memphis.gov/fire/"

# =============================================================================
# Finalize -- per-category provenance README + cross-routing
# =============================================================================
finalize_categories() {
    # Shelby County EMS / ambulance service is operated by the Shelby County
    # Fire Department; there is no standalone "ambulance ordinance" in the
    # published Code of Ordinances. Surface the Fire/EMS dispatch material here
    # so the folder reflects the real (public) source of authority.
    local f
    for f in "${BASE_DIR}/fire/"*dispatch* "${BASE_DIR}/fire/"*ems* "${BASE_DIR}/fire/"*emergency_medical*; do
        [[ -f "$f" ]] || continue
        cp -f "$f" "${BASE_DIR}/ambulance/$(basename "$f")"
        record "ambulance" "cross-routed-from-fire" "$(basename "$f")"
    done

    cat > "${BASE_DIR}/police/README.txt" <<'EOF'
POLICE / LAW-ENFORCEMENT CODES -- Shelby County, TN
Public sources: Municode Code of Ordinances (esp. Chapter 34 - Public Safety,
incl. 9-1-1 / non-emergency call regulations and law-enforcement data
provisions) and published Shelby County Sheriff's Office documents.
Note: "police 10-codes"/radio signal codes are operational and not published
as part of the public municipal code.
EOF

    cat > "${BASE_DIR}/fire/README.txt" <<'EOF'
FIRE CODES -- Shelby County, TN
Public sources: Municode Code of Ordinances Chapter 22 - Fire Prevention and
Protection (and related building/waste chapters), plus Shelby County Fire
Department documents. The county adopts editions of the International Fire Code
by reference within Chapter 22.
EOF

    cat > "${BASE_DIR}/ambulance/README.txt" <<'EOF'
AMBULANCE / EMS CODES -- Shelby County, TN
There is no standalone "ambulance ordinance" in the published Shelby County
Code of Ordinances. Emergency Medical Services in unincorporated Shelby County
are provided by the SHELBY COUNTY FIRE DEPARTMENT and are governed by:
  * the Fire chapter of the county code (see ../fire/), and
  * Tennessee state EMS regulations (TN Dept. of Health, Office of EMS), which
    are administered at the STATE level, not as a county code.
Any Fire-Department EMS / dispatch documents found publicly are cross-listed
here for convenience.
EOF

    cat > "${BASE_DIR}/hospital/README.txt" <<'EOF'
HOSPITAL / PUBLIC-HEALTH CODES -- Shelby County, TN
Public sources: hospital/health-related provisions of the Municode Code of
Ordinances and Shelby County Health Department documents.
Note: internal hospital emergency codes (e.g. "Code Blue", "Code Red") are
facility operational procedures and are NOT published by government agencies,
so they are not available from these official public sources.
EOF
}
finalize_categories

# =============================================================================
# Summary
# =============================================================================
log ""
log "==== Summary ===="
total=0
for c in "${CATEGORIES[@]}"; do
    n=$(find "${BASE_DIR}/${c}" -type f 2>/dev/null | wc -l | tr -d ' ')
    total=$((total+n))
    log "  ${c}: ${n} file(s)"
done
log "  TOTAL: ${total} file(s)"
log ""
log "Manifest: $MANIFEST"
log "Log:      $LOG"
log "Finished: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
log ""
log "Note: internal hospital emergency codes (e.g. 'Code Blue') are not"
log "published by government agencies; the 'hospital' folder contains the"
log "hospital/health-related ordinances and public documents that ARE public."
