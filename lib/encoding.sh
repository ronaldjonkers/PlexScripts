#!/usr/bin/env bash
# lib/encoding.sh - Encoding logic for Media Manager
# Supports VideoToolbox (macOS HW) with x265 software fallback

# Encode a single file with HandBrakeCLI
# Args: source_file target_bitrate output_file
encode_file() {
    local src="$1" vb="$2" out="$3"
    local vt_preset="${VT_PRESET:-quality}"
    local x265_preset="${X265_PRESET:-slow}"
    local os
    os="$(detect_os)"

    # Try VideoToolbox on macOS first
    if [ "$os" = "macos" ]; then
        log_info "  [ENC] VideoToolbox H.265 10-bit → $(basename "$out")"
        if HandBrakeCLI -i "$src" -o "$out" \
            --format mkv \
            -e vt_h265_10bit --vb "$vb" --encoder-preset "$vt_preset" \
            --all-audio --aencoder copy \
            --all-subtitles --subtitle-burned=none \
            < /dev/null >/dev/null 2>&1; then
            log_ok "  VideoToolbox encode complete"
            return 0
        fi
        log_warn "  VideoToolbox failed, falling back to x265"
    fi

    # Software x265 fallback (works on both macOS and Linux)
    log_info "  [ENC] x265 software encode → $(basename "$out")"
    if HandBrakeCLI -i "$src" -o "$out" \
        --format mkv \
        -e x265 --vb "$vb" --two-pass --turbo \
        --encoder-profile main10 --encoder-preset "$x265_preset" \
        --all-audio --aencoder copy \
        --all-subtitles --subtitle-burned=none \
        < /dev/null >/dev/null 2>&1; then
        log_ok "  x265 encode complete"
        return 0
    fi

    log_error "  Encoding failed for $(basename "$src")"
    return 1
}

# Process a single media file: analyze, rename, encode if needed
# Args: file_path media_type(movies|series)
process_file() {
    local file="$1"
    local media_type="$2"
    local delete_original="${DELETE_ORIGINALS:-no}"
    local tol="${TOL_PCT:-5}"

    [ -f "$file" ] || return 0

    log_sep
    log_info "Processing: $file"

    # Get video properties
    local geom w res target_vb
    geom="$(get_resolution "$file")" || geom="0x0"
    w="${geom%x*}"
    w="$(printf '%s' "$w" | tr -cd '0-9')"
    [ -z "$w" ] && w=0

    res="$(resolution_label "$w")"
    target_vb="$(target_bitrate "$res")"

    # Generate output filename
    local out
    out="$(generate_filename "$file" "$res" "$target_vb" "$media_type")"

    # Measure current bitrate
    local v_meas
    v_meas="$(get_video_kbps "$file")"

    log_info "  Resolution: ${res} | Measured: ${v_meas} kbps | Target: ${target_vb} kbps"

    # Already within tolerance? Just rename
    if [ "$(bitrate_within_tolerance "$v_meas" "$target_vb" "$tol")" = "1" ]; then
        if [ "$file" != "$out" ]; then
            log_info "  [RENAME] → $(basename "$out")"
            mv -n -- "$file" "$out"
        else
            log_skip "  Already correct name and bitrate"
        fi
        return 0
    fi

    # No-bloat check: skip encoding if output would be >= 98% of source
    local dur a_kbps src_bytes limit est
    dur="$(get_duration_secs "$file")"
    a_kbps="$(get_audio_kbps "$file")"
    src_bytes="$(stat_bytes "$file")"
    limit=$(( src_bytes * 98 / 100 ))
    est="$(estimate_output_bytes "$target_vb" "$a_kbps" "$dur")"

    if [ "$est" -ge "$limit" ]; then
        log_skip "  No-bloat: estimated output >= 98% of source, rename only"
        if [ "$out" != "$file" ]; then
            mv -n -- "$file" "$out"
        fi
        return 0
    fi

    # Encode
    if encode_file "$file" "$target_vb" "$out"; then
        if [ "$delete_original" = "yes" ] || [ "$delete_original" = "y" ]; then
            if [ "$file" != "$out" ] && [ -f "$out" ]; then
                log_info "  [DEL] Removed original"
                rm -f -- "$file"
            fi
        fi
    else
        # Clean up failed output
        [ -f "$out" ] && [ "$file" != "$out" ] && rm -f -- "$out"
        return 1
    fi
}
