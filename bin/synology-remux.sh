#!/bin/bash
# synology-remux.sh — standalone lossless container repair, made to run ON the
# Synology NAS itself (local disk I/O instead of SMB = many times faster).
#
# What it fixes: files renamed .mkv that are really MP4 (breaks Plex Direct
# Play), and .mp4/.m4v files that are really Matroska. Streams are bit-for-bit
# copied into a real MKV — no re-encode, zero quality loss. mov_text subtitles
# become embedded SRT tracks. Output is duration-verified before it atomically
# replaces the original.
#
# Usage (on the NAS, via SSH):
#   bash synology-remux.sh --dry-run     # preview only, changes nothing
#   bash synology-remux.sh               # repair everything
#   bash synology-remux.sh /volume1/x    # repair specific directories instead
#
# Run it detached so it survives an SSH disconnect:
#   nohup bash synology-remux.sh > /tmp/remux.log 2>&1 &
#   tail -f /tmp/remux.log
#
# Requires ffmpeg + ffprobe on the NAS (Package Center / SynoCommunity).

set -u

# ---------- Mappen (PAS DEZE AAN naar de lokale paden op je Synology) ----------
# Dit zijn de 3 mappen uit config/media-manager.conf, zoals ze op de NAS heten.
HARDCODED_DIRS=(
    "/volume1/Plex/Films"
    "/volume1/4KMovies"
    "/volume1/Plex/TVSeries"
)

DRY_RUN=0
DIRS=()
for arg in "$@"; do
    case "$arg" in
        --dry-run|-n) DRY_RUN=1 ;;
        *) DIRS+=( "$arg" ) ;;
    esac
done
[ "${#DIRS[@]}" -eq 0 ] && DIRS=( "${HARDCODED_DIRS[@]}" )

missing=0
for d in "${DIRS[@]}"; do
    if [ ! -d "$d" ]; then
        echo "FOUT: map bestaat niet: $d" >&2
        missing=1
    fi
done
if [ "$missing" = 1 ]; then
    echo "Pas HARDCODED_DIRS bovenin dit script aan naar de juiste paden op je NAS." >&2
    exit 1
fi

# ---------- Find ffmpeg/ffprobe ----------
find_bin() {
    local name="$1" cand
    command -v "$name" 2>/dev/null && return 0
    for cand in /usr/local/bin/"$name" /opt/bin/"$name" \
                /var/packages/ffmpeg*/target/bin/"$name" \
                /var/packages/VideoStation/target/bin/"$name"; do
        [ -x "$cand" ] && { echo "$cand"; return 0; }
    done
    return 1
}
FFMPEG="$(find_bin ffmpeg)"  || { echo "FOUT: ffmpeg niet gevonden. Installeer ffmpeg (Package Center of SynoCommunity)." >&2; exit 1; }
FFPROBE="$(find_bin ffprobe)" || { echo "FOUT: ffprobe niet gevonden (hoort bij ffmpeg)." >&2; exit 1; }

ts() { date "+%Y-%m-%d %H:%M:%S"; }
log() { echo "[$(ts)] $*"; }

# ---------- Container detection (12-byte magic read) ----------
detect_container() {
    local magic
    magic="$(head -c 12 -- "$1" 2>/dev/null | od -An -tx1 | tr -d ' \n')"
    case "$magic" in
        *66747970*) echo "mp4" ;;   # "ftyp" box
        1a45dfa3*)  echo "mkv" ;;   # EBML header
        *)          echo "other" ;;
    esac
}

duration_secs() {
    local d
    d="$("$FFPROBE" -v error -show_entries format=duration -of csv=p=0 -- "$1" 2>/dev/null | cut -d. -f1)"
    case "$d" in (*[!0-9]*|"") echo 0 ;; (*) echo "$d" ;; esac
}

DONE=0; FAILED=0; SKIPPED=0; SUBSDROPPED=0; CHECKED=0

repair_file() {
    local f="$1" ext real
    ext="$(echo "${f##*.}" | tr 'A-Z' 'a-z')"
    real="$(detect_container "$f")"
    case "${ext}:${real}" in
        mkv:mp4|mp4:mkv|m4v:mkv) ;;
        *) return 0 ;;   # extension matches reality (or unreadable) — leave it
    esac

    local dir base stem target tmpdir tmp
    dir="$(dirname "$f")"
    base="$(basename "$f")"
    stem="${base%.*}"
    target="${dir}/${stem}.mkv"

    if [ "$DRY_RUN" = 1 ]; then
        log "[DRY] $base (is ${real}) → echte MKV"
        DONE=$((DONE+1))
        return 0
    fi

    if [ "$f" != "$target" ] && [ -e "$target" ]; then
        log "[SKIP] doel bestaat al: $(basename "$target")"
        SKIPPED=$((SKIPPED+1))
        return 0
    fi

    tmpdir="${dir}/.remuxtmp.syno"
    tmp="${tmpdir}/${stem}.mkv"
    mkdir -p "$tmpdir" || { log "[FAIL] geen tmpdir in: $dir"; FAILED=$((FAILED+1)); return 1; }
    rm -f -- "$tmp"

    log "[BEZIG] $base (is ${real}) → remuxen..."

    # MP4-bron: mov_text-subs → SRT-tracks in de MKV. MKV-bron: subs kopiëren.
    local subcodec="srt"
    [ "$real" = "mkv" ] && subcodec="copy"

    if ! "$FFMPEG" -nostdin -v error -i "$f" -map '0:v' -map '0:a' -map '0:s?' \
            -c copy -c:s "$subcodec" "$tmp" </dev/null 2>"${tmpdir}/err.log"; then
        rm -f -- "$tmp"
        if "$FFMPEG" -nostdin -v error -i "$f" -map '0:v' -map '0:a' -sn \
                -c copy "$tmp" </dev/null 2>>"${tmpdir}/err.log"; then
            SUBSDROPPED=$((SUBSDROPPED+1))
            log "[WARN] subs niet meegenomen: $base"
        else
            log "[FAIL] remux mislukt: $base ($(tail -1 "${tmpdir}/err.log" 2>/dev/null))"
            rm -f -- "$tmp" "${tmpdir}/err.log"; rmdir "$tmpdir" 2>/dev/null
            FAILED=$((FAILED+1)); return 1
        fi
    fi

    # Verificatie: zelfde duur (±2s) als de bron, anders origineel behouden
    local d1 d2 diff
    d1="$(duration_secs "$f")"; d2="$(duration_secs "$tmp")"
    diff=$(( d1 > d2 ? d1 - d2 : d2 - d1 ))
    if [ "$d1" -le 0 ] || [ "$d2" -le 0 ] || [ "$diff" -gt 2 ]; then
        log "[FAIL] duurverschil (${d1}s vs ${d2}s), origineel behouden: $base"
        rm -f -- "$tmp" "${tmpdir}/err.log"; rmdir "$tmpdir" 2>/dev/null
        FAILED=$((FAILED+1)); return 1
    fi

    if mv -f -- "$tmp" "$target"; then
        [ "$f" != "$target" ] && rm -f -- "$f"
        DONE=$((DONE+1))
        log "[OK] $base → echte MKV"
    else
        log "[FAIL] terugplaatsen mislukt: $base"
        rm -f -- "$tmp"
        FAILED=$((FAILED+1))
    fi
    rm -f -- "${tmpdir}/err.log"; rmdir "$tmpdir" 2>/dev/null
}

# ---------- Main ----------
log "Lossless container-reparatie gestart (dry-run: $DRY_RUN)"
log "ffmpeg: $FFMPEG"
for d in "${DIRS[@]}"; do
    log "Map: $d"
done

for d in "${DIRS[@]}"; do
    log "=== Bezig met: $d ==="
    while IFS= read -r -d '' f; do
        CHECKED=$((CHECKED+1))
        [ $(( CHECKED % 500 )) -eq 0 ] && log "... $CHECKED bestanden gecontroleerd, $DONE gerepareerd"
        repair_file "$f"
    done < <(find "$d" -type d -name ".*" -prune -o \
        -type f \( -iname "*.mkv" -o -iname "*.mp4" -o -iname "*.m4v" \) -print0 2>/dev/null)
done

log "KLAAR: $CHECKED gecontroleerd, $DONE gerepareerd, $FAILED mislukt, $SKIPPED overgeslagen, $SUBSDROPPED zonder subs"
[ "$FAILED" -eq 0 ] && exit 0 || exit 1
