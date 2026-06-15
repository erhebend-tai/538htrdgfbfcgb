#!/usr/bin/env bash
#
# download_loc_classification.sh
#
# Downloads all freely available Library of Congress Classification (LCC)
# schedules and saves them as PDFs into ~/Downloads/LOC_Classification/.
#
# WHAT IS ACTUALLY FREE
# ---------------------
# The Library of Congress sells the *full* classification schedules through its
# Classification Web subscription service and as printed volumes; those full
# schedules are NOT freely downloadable. What the LOC publishes for free is the
# "LC Classification Outline" -- one PDF per main class (A through Z) hosted at:
#
#   https://www.loc.gov/aba/cataloging/classification/lcco/lcco_<class>.pdf
#
# (linked from https://www.loc.gov/aba/cataloging/classification/ and discoverable
# via the catalog at https://catalog.loc.gov). This script downloads that complete
# set of freely available outline schedules.
#
# Usage:
#   ./download_loc_classification.sh
#
set -u

# ----------------------------------------------------------------------------
# Configuration
# ----------------------------------------------------------------------------
BASE_URL="https://www.loc.gov/aba/cataloging/classification/lcco"
DEST_DIR="${HOME}/Downloads/LOC_Classification"
LOG_FILE="${DEST_DIR}/download.log"
USER_AGENT="Mozilla/5.0 (compatible; LOC-Classification-Downloader/1.0)"
MAX_RETRIES=4
CONNECT_TIMEOUT=30
MAX_TIME=300

# Map of LCC outline file slug -> human-readable class description.
# Note: class E-F (History of the Americas) is published as a single combined
# file (lcco_ef.pdf); the LOC does not provide separate lcco_e/lcco_f outlines.
SCHEDULES=(
  "a|A - General Works"
  "b|B - Philosophy, Psychology, Religion"
  "c|C - Auxiliary Sciences of History"
  "d|D - World History (except America)"
  "ef|E-F - History of the Americas"
  "g|G - Geography, Anthropology, Recreation"
  "h|H - Social Sciences"
  "j|J - Political Science"
  "k|K - Law"
  "l|L - Education"
  "m|M - Music"
  "n|N - Fine Arts"
  "p|P - Language and Literature"
  "q|Q - Science"
  "r|R - Medicine"
  "s|S - Agriculture"
  "t|T - Technology"
  "u|U - Military Science"
  "v|V - Naval Science"
  "z|Z - Bibliography, Library Science, Information Resources"
)

# ----------------------------------------------------------------------------
# Logging helper: writes a timestamped line to both stdout and the log file.
# ----------------------------------------------------------------------------
log() {
  local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
  echo "$msg"
  echo "$msg" >> "$LOG_FILE"
}

# ----------------------------------------------------------------------------
# Download a single PDF with retries and basic validation.
# Args: $1 = remote filename, $2 = destination path, $3 = description
# Returns: 0 = downloaded, 1 = failed, 2 = skipped (not available / not a PDF)
# ----------------------------------------------------------------------------
download_pdf() {
  local fname="$1" dest="$2" desc="$3"
  local url="${BASE_URL}/${fname}"
  local attempt=1 delay=2 http_code

  while [ "$attempt" -le "$MAX_RETRIES" ]; do
    log "  -> Attempt ${attempt}/${MAX_RETRIES}: ${url}"
    http_code=$(curl -sSL \
      --user-agent "$USER_AGENT" \
      --connect-timeout "$CONNECT_TIMEOUT" \
      --max-time "$MAX_TIME" \
      -o "$dest" \
      -w "%{http_code}" \
      "$url" 2>>"$LOG_FILE")
    local curl_rc=$?

    if [ "$curl_rc" -eq 0 ] && [ "$http_code" = "200" ]; then
      # Verify we actually received a PDF, not an HTML error page.
      if [ -s "$dest" ] && head -c 5 "$dest" | grep -q '%PDF'; then
        local size
        size=$(wc -c < "$dest" | tr -d ' ')
        log "  OK: ${desc} (${size} bytes) -> ${dest}"
        return 0
      else
        log "  WARN: ${fname} returned HTTP 200 but content is not a PDF; discarding."
        rm -f "$dest"
        return 2
      fi
    elif [ "$http_code" = "404" ]; then
      log "  SKIP: ${fname} not available (HTTP 404)."
      rm -f "$dest"
      return 2
    else
      log "  FAIL: ${fname} (curl rc=${curl_rc}, http=${http_code}). Retrying in ${delay}s."
      rm -f "$dest"
      sleep "$delay"
      delay=$((delay * 2))
      attempt=$((attempt + 1))
    fi
  done

  log "  ERROR: Giving up on ${fname} after ${MAX_RETRIES} attempts."
  return 1
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------
mkdir -p "$DEST_DIR"
: > "$LOG_FILE"   # start a fresh log for this run

log "=============================================================="
log "Library of Congress Classification (LCC) Outline downloader"
log "Source : ${BASE_URL}/"
log "Target : ${DEST_DIR}"
log "Items  : ${#SCHEDULES[@]} freely available class schedules"
log "=============================================================="

ok=0
skip=0
fail=0

for entry in "${SCHEDULES[@]}"; do
  slug="${entry%%|*}"
  desc="${entry#*|}"
  fname="lcco_${slug}.pdf"
  dest="${DEST_DIR}/${fname}"

  log "Downloading ${desc}"
  download_pdf "$fname" "$dest" "$desc"
  case $? in
    0) ok=$((ok + 1)) ;;
    2) skip=$((skip + 1)) ;;
    *) fail=$((fail + 1)) ;;
  esac
done

log "=============================================================="
log "Done. Downloaded: ${ok}  Skipped: ${skip}  Failed: ${fail}"
log "Files saved in: ${DEST_DIR}"
log "Log file: ${LOG_FILE}"
log "=============================================================="

# Exit non-zero only if something genuinely failed (a skip is not a failure).
if [ "$fail" -gt 0 ]; then
  exit 1
fi
exit 0
