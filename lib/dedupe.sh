#!/usr/bin/env bash
# lib/dedupe.sh - Duplicate detection and resolution for Media Manager
#
# Problem this solves: renaming "Movie (2020).mkv" → "Movie (2020).1080p.6mb.mkv"
# used to run through `mv -n`, which silently does nothing when the target already
# exists. The source kept its old name, so every scan logged the same [RENAME]
# again and the library slowly filled up with duplicate pairs.
#
# Now every collision is resolved: the best copy keeps the tagged name, the other
# one is disposed of according to DUPLICATE_ACTION.

# Regex for our own tagged filenames (any video container, not just mkv)
TAG_REGEX='\.(2160p|1080p|720p|480p)\.[0-9]+mb\.(mkv|mp4|mov|avi|m4v|wmv|webm|flv)$'

# "device:inode" identity of a file, used to detect hardlinks / same file
file_identity() {
    if [ "$(detect_os)" = "macos" ]; then
        /usr/bin/stat -f '%d:%i' -- "$1" 2>/dev/null
    else
        stat -c '%d:%i' -- "$1" 2>/dev/null
    fi
}

# True when both paths point at the exact same file on disk
same_file() {
    local a b
    a="$(file_identity "$1")"; b="$(file_identity "$2")"
    [ -n "$a" ] && [ "$a" = "$b" ]
}

_hash_stdin() {
    if command -v md5 >/dev/null 2>&1; then
        md5 -q
    else
        md5sum | cut -d' ' -f1
    fi
}

# Cheap content fingerprint: md5 of the first and last 4 MB.
# Full hashing multi-GB files over a network share is far too slow.
sample_hash() {
    { head -c 4194304 -- "$1"; tail -c 4194304 -- "$1"; } 2>/dev/null | _hash_stdin
}

# True when two files are byte-for-byte duplicates (same size + same fingerprint)
files_identical() {
    local sa sb
    sa="$(stat_bytes "$1")"; sb="$(stat_bytes "$2")"
    [ -n "$sa" ] && [ "$sa" = "$sb" ] || return 1
    [ "$(sample_hash "$1")" = "$(sample_hash "$2")" ]
}

# Video width in pixels (0 when unreadable)
media_width() {
    local geom w
    geom="$(get_resolution "$1")" || geom="0x0"
    w="${geom%x*}"
    w="$(printf '%s' "$w" | tr -cd '0-9')"
    [ -z "$w" ] && w=0
    echo "$w"
}

# Effective video bitrate in kbps, derived from real size and duration.
# More reliable than stream metadata when comparing two copies of the same title.
effective_video_kbps() {
    local f="$1" bytes dur audio
    bytes="$(stat_bytes "$f")"; [ -n "$bytes" ] || bytes=0
    dur="$(get_duration_secs "$f")"
    audio="$(get_audio_kbps "$f")"
    python3 -c "
b=${bytes}; d=${dur}; a=${audio}
print(0 if d <= 0 else max(0, int(b * 8.0 / 1000.0 / d - a)))
"
}

# Pick the better of two copies. Echoes "1" for the first file, "2" for the second.
# Ranking, in order:
#   1. higher resolution wins
#   2. a copy within the bitrate policy beats an oversized copy
#   3. higher bitrate wins (better quality, or the better source for re-encoding)
#   4. tie → "2", so the file that is already in place stays put
pick_best() {
    local a="$1" b="$2" tol="${TOL_PCT:-5}"
    local wa wb ra rb ka kb over_a over_b

    wa="$(media_width "$a")"; wb="$(media_width "$b")"
    ra="$(resolution_label "$wa")"; rb="$(resolution_label "$wb")"
    if [ "$ra" != "$rb" ]; then
        [ "$wa" -gt "$wb" ] && echo 1 || echo 2
        return
    fi

    ka="$(effective_video_kbps "$a")"; kb="$(effective_video_kbps "$b")"
    over_a="$(bitrate_needs_encoding "$ka" "$(target_bitrate "$ra")" "$tol")"
    over_b="$(bitrate_needs_encoding "$kb" "$(target_bitrate "$rb")" "$tol")"
    if [ "$over_a" != "$over_b" ]; then
        [ "$over_a" = "0" ] && echo 1 || echo 2
        return
    fi

    if [ "$ka" -gt "$kb" ]; then echo 1; else echo 2; fi
}

# Dispose of the losing copy according to DUPLICATE_ACTION.
# Returns 0 when the file is gone, 1 when it is still there.
dispose_duplicate() {
    local f="$1" reason="$2"
    local action="${DUPLICATE_ACTION:-keep_best}"

    case "$action" in
        trash|quarantine)
            local trash_dir target n=1
            trash_dir="$(dirname "$f")/.duplicates"
            if ! mkdir -p "$trash_dir" 2>/dev/null; then
                log_error "  [DUP] Cannot create $trash_dir — keeping $(basename "$f")"
                return 1
            fi
            target="${trash_dir}/$(basename "$f")"
            while [ -e "$target" ]; do
                target="${trash_dir}/$(basename "$f").${n}"
                n=$(( n + 1 ))
            done
            if mv -- "$f" "$target"; then
                log_info "  [DUP] Quarantined: $(basename "$f") (${reason})"
                return 0
            fi
            log_error "  [DUP] Failed to quarantine: $(basename "$f")"
            return 1
            ;;
        *)
            if rm -f -- "$f"; then
                log_info "  [DUP] Deleted: $(basename "$f") (${reason})"
                return 0
            fi
            log_error "  [DUP] Failed to delete: $(basename "$f")"
            return 1
            ;;
    esac
}

# Resolve a duplicate pair.
# Args: candidate (the file being processed) existing (the copy already in place)
# Returns 0 when the candidate survives and processing should continue,
#         1 when the existing copy wins (candidate disposed of, or both left alone).
handle_duplicate() {
    local candidate="$1" existing="$2"

    if same_file "$candidate" "$existing"; then
        return 0
    fi

    log_warn "  [DUP] $(basename "$candidate")  ↔  $(basename "$existing")"

    if [ "${DUPLICATE_ACTION:-keep_best}" = "skip" ]; then
        log_warn "  [DUP] DUPLICATE_ACTION=skip — leaving both files untouched"
        return 1
    fi

    # Byte-identical copies: keep the one already carrying the tag
    if files_identical "$candidate" "$existing"; then
        dispose_duplicate "$candidate" "identical to $(basename "$existing")" || return 1
        return 1
    fi

    if [ "$(pick_best "$candidate" "$existing")" = "1" ]; then
        log_info "  [DUP] Keeping $(basename "$candidate") (better quality)"
        dispose_duplicate "$existing" "lower quality than $(basename "$candidate")" || return 1
        return 0
    fi

    log_info "  [DUP] Keeping $(basename "$existing") (better quality)"
    dispose_duplicate "$candidate" "lower quality than $(basename "$existing")" || return 1
    return 1
}

# List already-tagged files that belong to the same title as the given file.
# Quoting "$base" keeps globbing characters in the title (brackets, etc.) literal.
find_tagged_siblings() {
    local f="$1"
    local dir base cand
    dir="$(dirname "$f")"
    base="$(basename "$f")"
    base="${base%.*}"
    base="$(strip_media_tags "$base")"
    base="$(echo "$base" | sed -E 's/[. ]+$//')"

    local restore_nullglob=0
    shopt -q nullglob || restore_nullglob=1
    shopt -s nullglob
    for cand in "${dir}/${base}".*; do
        [ -f "$cand" ] || continue
        [ "$cand" = "$f" ] && continue
        if echo "$(basename "$cand")" | grep -qEi "$TAG_REGEX"; then
            echo "$cand"
        fi
    done
    [ "$restore_nullglob" = "1" ] && shopt -u nullglob
    return 0
}

# Rename src → dst, resolving a collision if dst already exists.
# Returns 0 when the media now lives at dst, 1 when nothing was moved.
safe_move() {
    local src="$1" dst="$2"

    [ "$src" = "$dst" ] && return 0

    if [ -e "$dst" ]; then
        handle_duplicate "$src" "$dst" || return 1
    fi

    log_info "  [RENAME] $(basename "$src")"
    log_info "       →   $(basename "$dst")"
    if mv -- "$src" "$dst"; then
        return 0
    fi
    log_error "  Rename failed: $src → $dst"
    return 1
}

# Resolve duplicates for a file that already carries our tag (e.g. a title that
# ended up as both "Movie.1080p.6mb.mkv" and "Movie.720p.3mb.mkv").
dedupe_tagged_file() {
    local f="$1" sibling
    while IFS= read -r sibling; do
        [ -n "$sibling" ] || continue
        [ -f "$f" ] || return 0
        handle_duplicate "$f" "$sibling" || return 0
    done < <(find_tagged_siblings "$f")
    return 0
}
