#!/usr/bin/env bash
# lib/fixnames.sh - Repair existing library filenames (fix-names command)
#
# Problem this solves: earlier renaming passes damaged titles in ways Plex can
# no longer match — " - " collapsed into a double space, dotted abbreviations
# lost their dots ("R.I.P.D." → "R I P D"), and some files ended up with the
# resolution twice ("….2160p.2160p.mkv").
#
# fix-names walks the library once and repairs every video basename:
#   1. mechanical fixes (lib/fix_filename.py): double spaces → " - ",
#      "R I P D" → "R.I.P.D.", duplicated resolution tags removed
#   2. movies are verified against TMDb: the official title (and year) replaces
#      the parsed one, so Plex recognition is guaranteed. Needs TMDB_API_TOKEN
#      (put it in .env); without a token only the mechanical fixes run.
#
# Renames go through safe_move, so collisions are resolved by the dedupe logic
# and external subtitles travel along with the video.

# Fix a single file. Args: file media_type dry_run(true|false)
# Uses: FIXNAMES_CACHE (TMDb response cache for this run)
fix_one_name() {
    local f="$1" type="$2" dry="$3"
    local base dir result status newbase target

    base="$(basename "$f")"
    dir="$(dirname "$f")"

    result="$(TMDB_CACHE_FILE="${FIXNAMES_CACHE:-}" \
        python3 "${PROJECT_DIR}/lib/fix_filename.py" "$base" "$type")" || {
        log_warn "  [NAME] Could not analyze: $base"
        return 1
    }

    local tab=$'\t'
    status="${result%%${tab}*}"
    newbase="${result#*${tab}}"

    if [ "$status" = "unchanged" ] || [ -z "$newbase" ] || [ "$newbase" = "$base" ]; then
        return 0
    fi

    local why="cleaned up"
    [ "$status" = "tmdb" ] && why="verified via TMDb"

    if [ "$dry" = "true" ]; then
        log_info "  [DRY] $base"
        log_info "    →   $newbase  ($why)"
        return 0
    fi

    target="${dir}/${newbase}"
    log_info "  [NAME] Fixing ($why):"
    safe_move "$f" "$target"
}

# Walk one directory and fix every video filename in it.
# Args: dir media_type dry_run
fix_names_in_dir() {
    local dir="$1" type="$2" dry="$3"
    local count=0 f

    log_info "Checking names in: $dir (type: $type)"

    while IFS= read -r -d '' f; do
        # Parked originals keep their name; they are invisible to Plex anyway
        if is_kept_original "$f"; then
            continue
        fi
        fix_one_name "$f" "$type" "$dry" || continue
        count=$(( count + 1 ))
    done < <(find "$dir" \
        -type d -name ".*" -prune -o \
        -type f \( -iname "*.mp4" -o -iname "*.mkv" -o -iname "*.mov" -o -iname "*.avi" -o -iname "*.m4v" -o -iname "*.wmv" \) -print0 2>/dev/null)

    log_info "Checked $count files in $dir"
}

# Entry point for the fix-names command.
# Args: dry_run(true|false) [path]
# Without a path every configured watch directory is processed.
run_fix_names() {
    local dry="$1" only_path="${2:-}"

    if [ -n "${TMDB_API_TOKEN:-}" ] && [ "${NO_TMDB:-}" != "1" ]; then
        if [ "${TMDB_VERIFY_ALL:-}" = "1" ]; then
            log_info "TMDb verification: enabled for ALL movies (${TMDB_LANGUAGE:-en-US})"
        else
            log_info "TMDb verification: enabled for damaged names only (${TMDB_LANGUAGE:-en-US})"
        fi
    else
        log_warn "TMDb verification: DISABLED — mechanical fixes only"
        log_warn "Set TMDB_API_TOKEN in ${PROJECT_DIR}/.env to verify titles against TMDb"
    fi
    [ "$dry" = "true" ] && log_info "Dry run: nothing will be renamed"

    # One TMDb cache per run: every title is looked up at most once
    FIXNAMES_CACHE="$(mktemp /tmp/media-manager-tmdb.XXXXXX 2>/dev/null || echo "/tmp/media-manager-tmdb.$$")"
    export FIXNAMES_CACHE

    if [ -n "$only_path" ]; then
        if [ ! -d "$only_path" ]; then
            log_error "Not a directory: $only_path"
            rm -f "$FIXNAMES_CACHE"
            return 1
        fi
        fix_names_in_dir "$only_path" "$(detect_media_type "$only_path")" "$dry"
    else
        local entry dir type
        for entry in "${WATCH_DIRS[@]}"; do
            dir="$(echo "$entry" | cut -d'|' -f1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
            type="$(echo "$entry" | cut -d'|' -f2 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
            if [ ! -d "$dir" ]; then
                log_warn "Directory not found, skipping: $dir"
                continue
            fi
            if [ "$type" = "auto" ] || [ -z "$type" ]; then
                type="$(detect_media_type "$dir")"
            fi
            fix_names_in_dir "$dir" "$type" "$dry"
        done
    fi

    rm -f "$FIXNAMES_CACHE"
    log_info "Name check complete"
}
