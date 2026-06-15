#!/usr/bin/env bash
#
# download_us_code.sh
#
# Downloads the entire United States Code in XML (USLM) bulk format from the
# official U.S. House of Representatives Office of the Law Revision Counsel
# bulk-data repository:
#
#     https://uscode.house.gov/download/download.shtml
#
# The script scrapes the official download page for the *current release point*,
# discovers every per-title XML ZIP file (and the combined "uscAll" archive),
# downloads them all into ~/Downloads/USCode/, and logs progress to both the
# console and a timestamped log file.
#
# Re-running the script is safe: already-downloaded files are skipped unless the
# release point on the server has changed.
#
# Usage:
#     ./download_us_code.sh
#
set -uo pipefail

# --------------------------------------------------------------------------- #
# Configuration
# --------------------------------------------------------------------------- #
BASE_URL="https://uscode.house.gov/download"
DOWNLOAD_PAGE="${BASE_URL}/download.shtml"
DEST_DIR="${HOME}/Downloads/USCode"
LOG_FILE="${DEST_DIR}/download_us_code.log"
USER_AGENT="Mozilla/5.0 (compatible; us-code-bulk-downloader/1.0)"

# Per-file download retry settings.
MAX_RETRIES=4
CONNECT_TIMEOUT=30

# --------------------------------------------------------------------------- #
# Logging helpers
# --------------------------------------------------------------------------- #
log() {
    # Writes a timestamped message to stdout and to the log file.
    local msg
    msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo "${msg}"
    # Append to the log file (the directory is guaranteed to exist by main()).
    echo "${msg}" >> "${LOG_FILE}"
}

die() {
    log "ERROR: $*"
    exit 1
}

# --------------------------------------------------------------------------- #
# Pre-flight checks
# --------------------------------------------------------------------------- #
command -v curl >/dev/null 2>&1 || { echo "curl is required but not installed." >&2; exit 1; }

# --------------------------------------------------------------------------- #
# Download a single URL with retries and exponential backoff.
#   $1 = absolute URL
#   $2 = destination file path
# --------------------------------------------------------------------------- #
download_file() {
    local url="$1"
    local dest="$2"
    local attempt=1
    local delay=2

    while [ "${attempt}" -le "${MAX_RETRIES}" ]; do
        # Download to a temporary file, then move into place on success so we
        # never leave a half-written file that looks complete.
        if curl -fsSL \
                --user-agent "${USER_AGENT}" \
                --connect-timeout "${CONNECT_TIMEOUT}" \
                --retry 0 \
                -o "${dest}.part" \
                "${url}"; then
            mv -f "${dest}.part" "${dest}"
            return 0
        fi

        rm -f "${dest}.part"
        log "  attempt ${attempt}/${MAX_RETRIES} failed for $(basename "${dest}"); retrying in ${delay}s..."
        sleep "${delay}"
        attempt=$((attempt + 1))
        delay=$((delay * 2))
    done

    return 1
}

# --------------------------------------------------------------------------- #
# Main
# --------------------------------------------------------------------------- #
main() {
    mkdir -p "${DEST_DIR}" || { echo "Could not create ${DEST_DIR}" >&2; exit 1; }

    log "============================================================"
    log "US Code XML bulk download starting"
    log "Source page : ${DOWNLOAD_PAGE}"
    log "Destination : ${DEST_DIR}"
    log "Log file    : ${LOG_FILE}"
    log "============================================================"

    # ------------------------------------------------------------------ #
    # 1. Fetch the download page so we can discover the current release point.
    # ------------------------------------------------------------------ #
    local page
    page="$(mktemp)"
    trap 'rm -f "${page}"' EXIT

    log "Fetching download page to discover current release point..."
    if ! curl -fsSL --user-agent "${USER_AGENT}" \
              --connect-timeout "${CONNECT_TIMEOUT}" \
              -o "${page}" "${DOWNLOAD_PAGE}"; then
        die "Could not fetch ${DOWNLOAD_PAGE}"
    fi

    # ------------------------------------------------------------------ #
    # 2. Extract every per-title XML ZIP path, e.g.
    #        releasepoints/us/pl/119/95/xml_usc26@119-95.zip
    #    plus the combined archive (xml_uscAll@...). We keep them sorted and
    #    unique. uscAll is downloaded last so the per-title files come first.
    # ------------------------------------------------------------------ #
    local links
    links="$(grep -oiE 'releasepoints/us/pl/[0-9]+/[0-9]+/xml_usc[0-9A-Za-z]*@[0-9]+-[0-9]+\.zip' "${page}" \
              | sort -u)"

    [ -n "${links}" ] || die "No XML title ZIP links found on the download page. The page layout may have changed."

    local release_point
    release_point="$(printf '%s\n' "${links}" | head -1 | grep -oE '@[0-9]+-[0-9]+' | tr -d '@')"
    local total
    total="$(printf '%s\n' "${links}" | wc -l | tr -d ' ')"

    log "Current release point: ${release_point}"
    log "Discovered ${total} XML ZIP archives to download."
    log "------------------------------------------------------------"

    # ------------------------------------------------------------------ #
    # 3. Download each archive.
    # ------------------------------------------------------------------ #
    local count=0 ok=0 skipped=0 failed=0
    local failed_files=""

    while IFS= read -r rel; do
        [ -n "${rel}" ] || continue
        count=$((count + 1))
        local fname url dest
        fname="$(basename "${rel}")"
        url="${BASE_URL}/${rel}"
        dest="${DEST_DIR}/${fname}"

        if [ -s "${dest}" ]; then
            log "[${count}/${total}] SKIP  ${fname} (already downloaded)"
            skipped=$((skipped + 1))
            continue
        fi

        log "[${count}/${total}] GET   ${fname}"
        if download_file "${url}" "${dest}"; then
            local size
            size="$(du -h "${dest}" 2>/dev/null | cut -f1)"
            log "[${count}/${total}] OK    ${fname} (${size})"
            ok=$((ok + 1))
        else
            log "[${count}/${total}] FAIL  ${fname} after ${MAX_RETRIES} attempts"
            failed=$((failed + 1))
            failed_files="${failed_files} ${fname}"
        fi
    done <<< "${links}"

    # ------------------------------------------------------------------ #
    # 4. Summary.
    # ------------------------------------------------------------------ #
    log "------------------------------------------------------------"
    log "Download complete."
    log "  Release point : ${release_point}"
    log "  Total archives: ${total}"
    log "  Downloaded    : ${ok}"
    log "  Skipped       : ${skipped}"
    log "  Failed        : ${failed}"
    log "  Location      : ${DEST_DIR}"
    if [ "${failed}" -gt 0 ]; then
        log "  Failed files  :${failed_files}"
        log "============================================================"
        exit 1
    fi
    log "============================================================"
}

main "$@"
