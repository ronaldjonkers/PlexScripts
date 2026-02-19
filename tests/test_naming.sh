#!/usr/bin/env bash
# tests/test_naming.sh - Unit tests for naming logic
# Run: bash tests/test_naming.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "${PROJECT_DIR}/lib/utils.sh"
source "${PROJECT_DIR}/lib/naming.sh"

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

echo "=== Testing strip_media_tags ==="

assert_eq "Strip .resolution.bitrate suffix" \
    "Movie Name (2013)" \
    "$(strip_media_tags "Movie Name (2013).2160p.12mb")"

assert_eq "Strip trailing resolution with space" \
    "Hansel Gretel Witch Hunters (2013)" \
    "$(strip_media_tags "Hansel Gretel Witch Hunters (2013) 2160p")"

assert_eq "Strip trailing resolution with dot" \
    "Movie Name (2020)" \
    "$(strip_media_tags "Movie Name (2020).1080p")"

assert_eq "Strip both resolution tag and suffix" \
    "Movie Name (2013)" \
    "$(strip_media_tags "Movie Name (2013) 2160p.2160p.12mb")"

assert_eq "No tags to strip" \
    "Clean Movie Name (2019)" \
    "$(strip_media_tags "Clean Movie Name (2019)")"

assert_eq "Strip 720p suffix" \
    "Old Movie (1995)" \
    "$(strip_media_tags "Old Movie (1995).720p.3mb")"

assert_eq "Series episode name preserved" \
    "Breaking Bad S01E01 Pilot" \
    "$(strip_media_tags "Breaking Bad S01E01 Pilot")"

assert_eq "Series with existing tags" \
    "Show S02E05 Title" \
    "$(strip_media_tags "Show S02E05 Title.1080p.6mb")"

assert_eq "Strip 480p" \
    "Low Res Movie (2000)" \
    "$(strip_media_tags "Low Res Movie (2000) 480p")"

echo ""
echo "=== Testing generate_filename ==="

# Set required globals
VB2160=12000; VB1080=6000; VB720=3000

assert_eq "Movie: clean name + tags" \
    "/movies/Hansel Gretel Witch Hunters (2013).2160p.12mb.mkv" \
    "$(generate_filename "/movies/Hansel Gretel Witch Hunters (2013).mkv" "2160p" "12000" "movies")"

assert_eq "Movie: fix duplicate resolution bug" \
    "/movies/Hansel Gretel Witch Hunters (2013).2160p.12mb.mkv" \
    "$(generate_filename "/movies/Hansel Gretel Witch Hunters (2013) 2160p.mkv" "2160p" "12000" "movies")"

assert_eq "Movie: re-tag existing tagged file" \
    "/movies/Movie Name (2020).1080p.6mb.mkv" \
    "$(generate_filename "/movies/Movie Name (2020).2160p.20mb.mkv" "1080p" "6000" "movies")"

assert_eq "Series: add resolution tag" \
    "/tv/Show S01E01 Pilot.1080p.6mb.mkv" \
    "$(generate_filename "/tv/Show S01E01 Pilot.mp4" "1080p" "6000" "series")"

assert_eq "Series: re-tag with new resolution" \
    "/tv/Show S01E01 Pilot.720p.3mb.mkv" \
    "$(generate_filename "/tv/Show S01E01 Pilot.1080p.6mb.mkv" "720p" "3000" "series")"

assert_eq "Deep path preserved" \
    "/media/tv/Show/Season 01/S01E03 Title.2160p.12mb.mkv" \
    "$(generate_filename "/media/tv/Show/Season 01/S01E03 Title.avi" "2160p" "12000" "series")"

assert_eq "Movie with spaces in path" \
    "/media/My Movies/The Matrix (1999).1080p.6mb.mkv" \
    "$(generate_filename "/media/My Movies/The Matrix (1999).mkv" "1080p" "6000" "movies")"

echo ""
echo "=== Testing is_already_tagged ==="

is_already_tagged "Movie.2160p.12mb.mkv" && r="true" || r="false"
assert_eq "Tagged file detected" "true" "$r"

is_already_tagged "Movie.mkv" && r="true" || r="false"
assert_eq "Untagged file detected" "false" "$r"

is_already_tagged "Show S01E01.1080p.6mb.mkv" && r="true" || r="false"
assert_eq "Tagged series file detected" "true" "$r"

is_already_tagged "Show S01E01.mp4" && r="true" || r="false"
assert_eq "Untagged series file detected" "false" "$r"

echo ""
echo "=== Testing resolution_label ==="

assert_eq "4K width"  "2160p" "$(resolution_label "3840")"
assert_eq "2.5K+ width" "2160p" "$(resolution_label "2560")"
assert_eq "1080p width" "1080p" "$(resolution_label "1920")"
assert_eq "1600+ width" "1080p" "$(resolution_label "1700")"
assert_eq "720p width"  "720p"  "$(resolution_label "1280")"
assert_eq "900+ width"  "720p"  "$(resolution_label "960")"
assert_eq "SD width"    "480p"  "$(resolution_label "640")"
assert_eq "Empty width" "720p"  "$(resolution_label "")"

echo ""
echo "=== Testing bitrate_needs_encoding ==="

# Target 3000, tolerance 5% → threshold = 3150
# Only encode if actual > 3150

assert_eq "Way above target → encode" \
    "1" "$(bitrate_needs_encoding 5000 3000 5)"

assert_eq "Slightly above tolerance → encode" \
    "1" "$(bitrate_needs_encoding 3200 3000 5)"

assert_eq "At tolerance boundary → no encode" \
    "0" "$(bitrate_needs_encoding 3150 3000 5)"

assert_eq "At target → no encode" \
    "0" "$(bitrate_needs_encoding 3000 3000 5)"

assert_eq "Below target → no encode" \
    "0" "$(bitrate_needs_encoding 2000 3000 5)"

assert_eq "Way below target → no encode" \
    "0" "$(bitrate_needs_encoding 500 3000 5)"

assert_eq "Zero measured → no encode" \
    "0" "$(bitrate_needs_encoding 0 3000 5)"

assert_eq "4K above target → encode" \
    "1" "$(bitrate_needs_encoding 20000 12000 5)"

assert_eq "4K at target → no encode" \
    "0" "$(bitrate_needs_encoding 12000 12000 5)"

assert_eq "4K below target → no encode" \
    "0" "$(bitrate_needs_encoding 8000 12000 5)"

echo ""
echo "=========================================="
echo "Results: $PASS passed, $FAIL failed"
echo "=========================================="

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
