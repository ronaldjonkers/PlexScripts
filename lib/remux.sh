#!/usr/bin/env bash
# lib/remux.sh - Container detection and lossless repair for Media Manager
#
# Problem this solves: an old rename-only pass relabelled .mp4 files as .mkv
# without remuxing. Plex is told "Matroska", finds MP4 data (with mov_text
# subtitles and the audio track before the video track) and refuses Direct
# Play. The video and audio streams themselves are fine.
#
# The repair is a lossless remux: every stream is bit-for-bit copied into a
# real MKV — zero quality loss, no re-encode. Only mov_text subtitles are
# converted to SRT tracks (plain text, embedded in the MKV), because mov_text
# is not valid inside Matroska. The result replaces the original atomically
# after a duration check.

# Actual container of a file, from its magic bytes (cheap: reads 12 bytes).
# Returns: mp4 | mkv | other
detect_container() {
    local magic
    magic="$(head -c 12 -- "$1" 2>/dev/null | od -An -tx1 | tr -d ' \n')"
    case "$magic" in
        *66747970*) echo "mp4" ;;   # "ftyp" box at offset 4
        1a45dfa3*)  echo "mkv" ;;   # EBML header
        *)          echo "other" ;;
    esac
}

# True when the extension lies about the container and a remux would fix it.
# Only flags combinations we can repair losslessly; "other" is left alone.
needs_remux() {
    local f="$1" ext real
    ext="$(echo "${f##*.}" | tr '[:upper:]' '[:lower:]')"
    case "$ext" in
        mkv|mp4|m4v) ;;
        *) return 1 ;;
    esac
    real="$(detect_container "$f")"
    case "${ext}:${real}" in
        mkv:mp4|mp4:mkv|m4v:mkv) return 0 ;;
        *) return 1 ;;
    esac
}

# Losslessly remux a mislabeled file into a real MKV with the same stem.
# On success REMUXED_FILE holds the (possibly renamed) path and 0 is returned.
# The temp file lives in a hidden directory so scans never pick it up.
remux_mislabeled() {
    local f="$1"
    local dir base stem real tmpdir tmp target errlog

    dir="$(dirname "$f")"
    base="$(basename "$f")"
    stem="${base%.*}"
    real="$(detect_container "$f")"
    target="${dir}/${stem}.mkv"
    tmpdir="${dir}/.remuxtmp.scan"
    tmp="${tmpdir}/${stem}.mkv"
    errlog="${tmpdir}/${stem}.err"
    REMUXED_FILE="$f"

    # Never silently clobber an existing sibling (e.g. "X.mp4" next to a real
    # "X.mkv") — leave both for the dedupe pass to resolve first.
    if [ "$f" != "$target" ] && [ -e "$target" ]; then
        log_warn "  [REMUX] Target already exists, skipping: $(basename "$target")"
        return 1
    fi

    mkdir -p "$tmpdir" 2>/dev/null || {
        log_warn "  [REMUX] Cannot create temp dir in: $dir"
        return 1
    }
    rm -f -- "$tmp"

    log_info "  [REMUX] ${base}: extension says ${base##*.}, data is ${real} → rebuilding as real MKV (lossless)"

    # MP4 sources carry mov_text subtitles → convert to SRT tracks.
    # Real-MKV sources (named .mp4) already have MKV-valid subtitles → copy.
    local subargs=(-c:s srt)
    [ "$real" = "mkv" ] && subargs=(-c:s copy)

    if ! ffmpeg -nostdin -v error -i "$f" -map '0:v' -map '0:a' -map '0:s?' \
            -c copy "${subargs[@]}" "$tmp" </dev/null 2>"$errlog"; then
        # Some subtitle streams are broken or empty — retry without them
        rm -f -- "$tmp"
        if ffmpeg -nostdin -v error -i "$f" -map '0:v' -map '0:a' -sn \
                -c copy "$tmp" </dev/null 2>>"$errlog"; then
            log_warn "  [REMUX] Subtitle streams could not be converted, dropped: $base"
        else
            log_warn "  [REMUX] Failed: $base ($(tail -1 "$errlog" 2>/dev/null))"
            rm -f -- "$tmp" "$errlog"; rmdir "$tmpdir" 2>/dev/null
            return 1
        fi
    fi

    # Verify: the copy must have the same duration as the source (±2s)
    local d1 d2 diff
    d1="$(get_duration_secs "$f")"
    d2="$(get_duration_secs "$tmp")"
    diff=$(( d1 > d2 ? d1 - d2 : d2 - d1 ))
    if [ "$d1" -le 0 ] || [ "$d2" -le 0 ] || [ "$diff" -gt 2 ]; then
        log_warn "  [REMUX] Duration mismatch (${d1}s vs ${d2}s), keeping original: $base"
        rm -f -- "$tmp" "$errlog"; rmdir "$tmpdir" 2>/dev/null
        return 1
    fi

    # Atomic replace; a .mp4-named original is removed after its .mkv lands
    if ! mv -f -- "$tmp" "$target"; then
        log_warn "  [REMUX] Could not move repaired file into place: $base"
        rm -f -- "$tmp" "$errlog"; rmdir "$tmpdir" 2>/dev/null
        return 1
    fi
    [ "$f" != "$target" ] && rm -f -- "$f"
    rm -f -- "$errlog"; rmdir "$tmpdir" 2>/dev/null

    log_ok "  [REMUX] Repaired: $(basename "$target")"
    REMUXED_FILE="$target"
    return 0
}
