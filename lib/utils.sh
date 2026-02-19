#!/usr/bin/env bash
# lib/utils.sh - Shared utility functions for Media Manager
# Cross-platform (macOS + Linux) compatible

# Timestamp for logging
ts() { date "+%Y-%m-%d %H:%M:%S"; }

# Logging
log_info()  { echo "[$(ts)] [INFO]  $*"; }
log_warn()  { echo "[$(ts)] [WARN]  $*"; }
log_error() { echo "[$(ts)] [ERROR] $*"; }
log_ok()    { echo "[$(ts)] [OK]    $*"; }
log_skip()  { echo "[$(ts)] [SKIP]  $*"; }
log_sep()   { echo "[$(ts)] ----------------------------------------------------------------"; }

# Check if a binary exists
need() {
    command -v "$1" >/dev/null 2>&1 || {
        log_error "$1 not found in PATH"
        return 1
    }
}

# Detect OS: returns "macos" or "linux"
detect_os() {
    case "$(uname -s)" in
        Darwin) echo "macos" ;;
        Linux)  echo "linux" ;;
        *)      echo "unknown" ;;
    esac
}

# Cross-platform file size in bytes
stat_bytes() {
    local os
    os="$(detect_os)"
    if [ "$os" = "macos" ]; then
        /usr/bin/stat -f %z -- "$1" 2>/dev/null
    else
        stat -c %s -- "$1" 2>/dev/null
    fi
}

# Video width x height (e.g. "1920x1080")
get_resolution() {
    ffprobe -v error -select_streams v:0 -show_entries stream=width,height \
        -of csv=p=0:s=x -- "$1" 2>/dev/null | head -n1
}

# Duration in seconds (rounded)
get_duration_secs() {
    local d
    d=$(ffprobe -v error -show_entries format=duration \
        -of default=nokey=1:noprint_wrappers=1 -- "$1" 2>/dev/null | head -n1)
    python3 -c "
try:
    v = float('${d}'.strip())
    print(int(v + 0.5))
except:
    print(0)
"
}

# Sum of all audio stream bitrates in kbps; fallback 256
get_audio_kbps() {
    local sum=0 line kb
    while IFS= read -r line; do
        kb=$(echo "$line" | tr -cd '0-9')
        if [ -n "$kb" ] && [ "$kb" -gt 0 ]; then
            sum=$(( sum + kb / 1000 ))
        fi
    done < <(ffprobe -v error -select_streams a \
        -show_entries stream=bit_rate \
        -of default=nokey=1:noprint_wrappers=1 -- "$1" 2>/dev/null || true)
    [ "$sum" -le 0 ] && sum=256
    echo "$sum"
}

# Video bitrate in kbps from stream or container fallback
get_video_kbps() {
    local f="$1" vkb a_kb cont
    vkb=$(ffprobe -v error -select_streams v:0 \
        -show_entries stream=bit_rate \
        -of default=nokey=1:noprint_wrappers=1 -- "$f" 2>/dev/null | head -n1 | tr -cd '0-9')
    if [ -n "$vkb" ] && [ "$vkb" -gt 0 ]; then
        echo $(( vkb / 1000 ))
        return
    fi
    a_kb=$(get_audio_kbps "$f")
    cont=$(ffprobe -v error -show_entries format=bit_rate \
        -of default=nokey=1:noprint_wrappers=1 -- "$f" 2>/dev/null | head -n1 | tr -cd '0-9')
    if [ -n "$cont" ] && [ "$cont" -gt 0 ]; then
        local total=$(( cont / 1000 ))
        local vk=$(( total - a_kb ))
        [ "$vk" -lt 500 ] && vk=500
        echo "$vk"
        return
    fi
    echo 0
}

# Resolution label from width (with generous margins for cropped content)
resolution_label() {
    local w="$1"
    w="$(printf '%s' "$w" | tr -cd '0-9')"
    [ -z "$w" ] && { echo "720p"; return; }
    if [ "$w" -ge 2500 ]; then echo "2160p"
    elif [ "$w" -ge 1600 ]; then echo "1080p"
    elif [ "$w" -ge 900 ]; then echo "720p"
    else echo "480p"
    fi
}

# Target video bitrate for a resolution label
target_bitrate() {
    local res="$1"
    case "$res" in
        2160p) echo "$VB2160" ;;
        1080p) echo "$VB1080" ;;
        720p)  echo "$VB720"  ;;
        *)     echo "$VB720"  ;;
    esac
}

# Check if bitrate is above target + tolerance (returns 1=needs encoding, 0=ok)
# Only encode when bitrate is TOO HIGH. Never encode when bitrate is at or below target.
bitrate_needs_encoding() {
    local actual="$1" target="$2" tol="${3:-5}"
    if [ "$actual" -le 0 ] || [ "$target" -le 0 ]; then
        echo 0
        return
    fi
    # Calculate how much % above target the actual bitrate is
    local pct_above
    pct_above=$(python3 -c "a=${actual}; t=${target}; pct=((a-t)*100.0/t); print(int(pct+0.5) if pct>0 else 0)")
    # Only encode if actual is more than tol% ABOVE target
    [ "$pct_above" -gt "$tol" ] && echo 1 || echo 0
}

# Estimate output file size in bytes from bitrates and duration
estimate_output_bytes() {
    local vb="$1" ab="$2" dur="$3"
    python3 -c "
vb=${vb}; ab=${ab}; d=${dur}
tot_kbps = (vb if vb > 0 else 0) + (ab if ab > 0 else 0)
print(int(tot_kbps * 1000.0 * d / 8.0))
"
}

# Check if a file is a video file by extension
is_video_file() {
    local ext="${1##*.}"
    ext="$(echo "$ext" | tr '[:upper:]' '[:lower:]')"
    case "$ext" in
        mp4|mkv|mov|avi|wmv|flv|webm|m4v) return 0 ;;
        *) return 1 ;;
    esac
}

# Check if a file has already been processed (has our naming tag)
is_already_tagged() {
    local base
    base="$(basename "$1")"
    echo "$base" | grep -qE '\.(2160p|1080p|720p|480p)\.[0-9]+mb\.mkv$'
}
