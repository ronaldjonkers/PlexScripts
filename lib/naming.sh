#!/usr/bin/env bash
# lib/naming.sh - File naming and media type detection for Media Manager
# Fixes: duplicate resolution in filenames (e.g. "Movie 2160p.2160p.12mb.mkv"),
# double spaces that used to be " - ", and abbreviations that lost their dots
# ("R I P D" → "R.I.P.D."). The heavy lifting lives in lib/fix_filename.py so
# the scan loop and the fix-names command share one implementation.

# Detect if a directory contains TV series or movies
# Returns: "series" or "movies"
# Detection logic:
#   1. Look for SxxExx patterns in filenames
#   2. Look for "Season" folders
#   3. Default to movies
detect_media_type() {
    local dir="$1"
    [ -d "$dir" ] || { echo "movies"; return; }

    # Check for Season folders
    if find "$dir" -maxdepth 2 -type d -iname "Season *" 2>/dev/null | head -1 | grep -q .; then
        echo "series"
        return
    fi

    # Check for SxxExx patterns in filenames
    if find "$dir" -maxdepth 3 -type f \( -iname "*.mkv" -o -iname "*.mp4" -o -iname "*.avi" -o -iname "*.mov" \) -print0 2>/dev/null \
        | xargs -0 -I{} basename "{}" 2>/dev/null \
        | grep -qiE '[Ss][0-9]{1,2}[Ee][0-9]{1,2}'; then
        echo "series"
        return
    fi

    echo "movies"
}

# Strip resolution and bitrate tags from a base filename
# Handles:
#   "Movie Name (2013) 2160p"           → "Movie Name (2013)"
#   "Movie Name (2013).2160p.12mb"      → "Movie Name (2013)"
#   "Movie Name.1080p.6mb"              → "Movie Name"
#   "Show S01E01.720p.3mb"              → "Show S01E01"
#   "Movie Name 1080p"                  → "Movie Name"
strip_media_tags() {
    local base="$1"
    # Steps 1+2: Remove .RES.XXmb suffixes (our own tagging format) and bare
    # trailing resolution tags, repeated until stable — "Movie.2160p.2160p"
    # and "Movie.2160p.12mb.2160p" must lose every copy
    local prev=""
    while [ "$base" != "$prev" ]; do
        prev="$base"
        base="$(echo "$base" | sed -E 's/(\.(2160p|1080p|720p|480p)\.[0-9]+mb)+$//')"
        base="$(echo "$base" | sed -E 's/([. ](2160p|1080p|720p|480p))+$//')"
    done
    # Step 3: Remove common quality tags that might be in source filenames
    base="$(echo "$base" | sed -E 's/[. ](BluRay|BRRip|WEBRip|WEB-DL|HDRip|DVDRip|REMUX|HEVC|x264|x265|H\.?264|H\.?265|AAC|DTS|10bit|HDR|SDR|DDP5\.?1|DD5\.?1|Atmos)//gI')"
    echo "$base"
}

# Mechanical title repair, shared with the fix-names command:
#   "Movie  Subtitle"  → "Movie - Subtitle"   (double space = lost " - ")
#   "R I P D - 2"      → "R.I.P.D. - 2"       (abbreviations get their dots back)
# A trailing "(Year)" is preserved. Falls back to the input if python3 fails.
clean_title() {
    local stem="$1" cleaned
    cleaned="$(python3 "${PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/lib/fix_filename.py" --clean "$stem" 2>/dev/null)" || cleaned=""
    [ -n "$cleaned" ] && echo "$cleaned" || echo "$stem"
}

# Generate the correct output filename
# Movies:  "Title (Year).Resolution.Bitrate_mb.mkv"
# Series:  "Show S01E01 Episode.Resolution.Bitrate_mb.mkv"
# Args: source_file resolution target_vb_kbps media_type [extension]
# The extension defaults to mkv (what the encoder writes). Rename-only paths pass
# the source extension, so an .mp4 is not relabelled as .mkv without remuxing.
generate_filename() {
    local f="$1" res="$2" vb="$3" media_type="$4" ext="${5:-mkv}"
    local dir base mb

    dir="$(dirname "$f")"
    base="$(basename "$f")"
    # Remove extension
    base="${base%.*}"

    # Strip existing resolution and bitrate tags
    base="$(strip_media_tags "$base")"

    # Clean up trailing dots/spaces
    base="$(echo "$base" | sed -E 's/[. ]+$//')"

    # Repair double spaces and dotted abbreviations
    base="$(clean_title "$base")"

    # Calculate MB label from kbps
    mb=$(( (vb + 500) / 1000 ))

    echo "${dir}/${base}.${res}.${mb}mb.${ext}"
}
