#!/usr/bin/env bash
# tests/test_remux.sh - Unit tests for container detection and lossless repair
# Run: bash tests/test_remux.sh
# Needs ffmpeg (generates tiny real MP4/MKV files to test against).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "${PROJECT_DIR}/lib/utils.sh"
source "${PROJECT_DIR}/lib/remux.sh"

PASS=0
FAIL=0

assert_eq() {
    local test_name="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  ✓ PASS: $test_name"
        PASS=$(( PASS + 1 ))
    else
        echo "  ✗ FAIL: $test_name"
        echo "    Expected: $expected"
        echo "    Actual:   $actual"
        FAIL=$(( FAIL + 1 ))
    fi
}

command -v ffmpeg >/dev/null 2>&1 || { echo "ffmpeg not found — skipping"; exit 0; }

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# Tiny real MP4 (with a mov_text subtitle) and a tiny real MKV
ffmpeg -v error -f lavfi -i "testsrc=duration=2:size=128x72:rate=10" \
    -f lavfi -i "sine=duration=2" \
    -f srt -i <(printf '1\n00:00:00,000 --> 00:00:01,000\nhoi\n') \
    -map 0:v -map 1:a -map 2:s -c:v libx264 -preset ultrafast -c:a aac -c:s mov_text \
    -shortest "${TMP_DIR}/real.mp4" </dev/null
ffmpeg -v error -i "${TMP_DIR}/real.mp4" -map '0:v' -map '0:a' -c copy -sn \
    "${TMP_DIR}/real.mkv" </dev/null

echo "=== Testing detect_container ==="

assert_eq "MP4 detected" "mp4" "$(detect_container "${TMP_DIR}/real.mp4")"
assert_eq "MKV detected" "mkv" "$(detect_container "${TMP_DIR}/real.mkv")"
echo "not a video" > "${TMP_DIR}/text.mkv"
assert_eq "Garbage detected as other" "other" "$(detect_container "${TMP_DIR}/text.mkv")"

echo ""
echo "=== Testing needs_remux ==="

needs_remux "${TMP_DIR}/real.mp4" && r="true" || r="false"
assert_eq "Real MP4 named .mp4 → no remux" "false" "$r"

needs_remux "${TMP_DIR}/real.mkv" && r="true" || r="false"
assert_eq "Real MKV named .mkv → no remux" "false" "$r"

cp "${TMP_DIR}/real.mp4" "${TMP_DIR}/fake.mkv"
needs_remux "${TMP_DIR}/fake.mkv" && r="true" || r="false"
assert_eq "MP4 named .mkv → remux needed" "true" "$r"

cp "${TMP_DIR}/real.mkv" "${TMP_DIR}/fake.mp4"
needs_remux "${TMP_DIR}/fake.mp4" && r="true" || r="false"
assert_eq "MKV named .mp4 → remux needed" "true" "$r"

needs_remux "${TMP_DIR}/text.mkv" && r="true" || r="false"
assert_eq "Unreadable data → left alone" "false" "$r"

echo ""
echo "=== Testing remux_mislabeled (MP4 in .mkv coat) ==="

remux_mislabeled "${TMP_DIR}/fake.mkv" >/dev/null && r="true" || r="false"
assert_eq "Remux succeeds" "true" "$r"
assert_eq "Result is a real MKV" "mkv" "$(detect_container "${TMP_DIR}/fake.mkv")"
assert_eq "REMUXED_FILE points at repaired file" "${TMP_DIR}/fake.mkv" "$REMUXED_FILE"

subs="$(ffprobe -v error -select_streams s -show_entries stream=codec_name -of csv=p=0 "${TMP_DIR}/fake.mkv")"
assert_eq "mov_text subtitle became embedded SRT" "subrip" "$subs"

order="$(ffprobe -v error -show_entries stream=codec_type -of csv=p=0 "${TMP_DIR}/fake.mkv" | paste -sd, -)"
assert_eq "Video track first" "video,audio,subtitle" "$order"

[ -d "${TMP_DIR}/.remuxtmp.scan" ] && r="true" || r="false"
assert_eq "Temp dir cleaned up" "false" "$r"

echo ""
echo "=== Testing remux_mislabeled (MKV in .mp4 coat) ==="

# The repaired fake.mkv still exists → the .mp4 must NOT clobber it
remux_mislabeled "${TMP_DIR}/fake.mp4" >/dev/null && r="true" || r="false"
assert_eq "Existing .mkv sibling is never clobbered" "false" "$r"
[ -f "${TMP_DIR}/fake.mp4" ] && r="true" || r="false"
assert_eq "Source left in place when target exists" "true" "$r"

rm -f "${TMP_DIR}/fake.mkv"
remux_mislabeled "${TMP_DIR}/fake.mp4" >/dev/null && r="true" || r="false"
assert_eq "Remux succeeds" "true" "$r"
assert_eq "New file has .mkv extension" "${TMP_DIR}/fake_mkv_exists" "$([ -f "${TMP_DIR}/fake.mkv" ] && echo "${TMP_DIR}/fake_mkv_exists")"
[ -f "${TMP_DIR}/fake.mp4" ] && r="true" || r="false"
assert_eq "Old .mp4-named file removed" "false" "$r"

echo ""
echo "=========================================="
echo "Results: $PASS passed, $FAIL failed"
echo "=========================================="

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
