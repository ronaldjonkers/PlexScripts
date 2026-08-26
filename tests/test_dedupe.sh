#!/usr/bin/env bash
# tests/test_dedupe.sh - Unit tests for duplicate detection and resolution
# Run: bash tests/test_dedupe.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "${PROJECT_DIR}/lib/utils.sh"
source "${PROJECT_DIR}/lib/naming.sh"
source "${PROJECT_DIR}/lib/dedupe.sh"

VB2160=12000; VB1080=6000; VB720=3000; TOL_PCT=5

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

TMP="$(mktemp -d "${TMPDIR:-/tmp}/mm-dedupe-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# Silence the library logging during tests
log_info() { :; }
log_warn() { :; }
log_error() { :; }
log_ok()   { :; }
log_skip() { :; }
log_sep()  { :; }

# Stubbed media probing: quality is looked up from a "path -> width:kbps" table
declare STUB_TABLE=""
stub_media() { STUB_TABLE="${STUB_TABLE}${1}|${2}:${3}"$'\n'; }
_stub_field() {
    local f="$1" idx="$2"
    echo "$STUB_TABLE" | grep -F "${f}|" | head -n1 | sed 's/.*|//' | cut -d: -f"$idx"
}
media_width()          { local v; v="$(_stub_field "$1" 1)"; echo "${v:-0}"; }
effective_video_kbps() { local v; v="$(_stub_field "$1" 2)"; echo "${v:-0}"; }

echo "=== Testing find_tagged_siblings ==="

mkdir -p "$TMP/Classics"
: > "$TMP/Classics/Fantasia (1940).mkv"
: > "$TMP/Classics/Fantasia (1940).1080p.6mb.mkv"
: > "$TMP/Classics/Fantasia (1940).en.sub"
: > "$TMP/Classics/Fantasia (1940).nl.srt"
: > "$TMP/Classics/Other Movie (1950).mkv"

assert_eq "Finds the tagged copy of the same title" \
    "$TMP/Classics/Fantasia (1940).1080p.6mb.mkv" \
    "$(find_tagged_siblings "$TMP/Classics/Fantasia (1940).mkv")"

assert_eq "No siblings for a title without a tagged copy" \
    "" \
    "$(find_tagged_siblings "$TMP/Classics/Other Movie (1950).mkv")"

: > "$TMP/Classics/Two Tags (2001).1080p.6mb.mkv"
: > "$TMP/Classics/Two Tags (2001).720p.3mb.mkv"
assert_eq "Tagged file finds its other tagged copy" \
    "$TMP/Classics/Two Tags (2001).720p.3mb.mkv" \
    "$(find_tagged_siblings "$TMP/Classics/Two Tags (2001).1080p.6mb.mkv")"

# Titles with glob characters must not be expanded as patterns
: > "$TMP/Classics/Movie [Directors Cut] (1999).mkv"
: > "$TMP/Classics/Movie [Directors Cut] (1999).1080p.6mb.mkv"
assert_eq "Brackets in the title are treated literally" \
    "$TMP/Classics/Movie [Directors Cut] (1999).1080p.6mb.mkv" \
    "$(find_tagged_siblings "$TMP/Classics/Movie [Directors Cut] (1999).mkv")"

echo ""
echo "=== Testing pick_best ==="

stub_media "/m/a.mkv" 1920 5000
stub_media "/m/b.mkv" 3840 9000
assert_eq "Higher resolution wins" "2" "$(pick_best "/m/a.mkv" "/m/b.mkv")"

stub_media "/m/c.mkv" 1920 5800
stub_media "/m/d.mkv" 1920 12000
assert_eq "Within-policy bitrate beats oversized" "1" "$(pick_best "/m/c.mkv" "/m/d.mkv")"

stub_media "/m/e.mkv" 1920 4000
stub_media "/m/f.mkv" 1920 5800
assert_eq "Both within policy: higher bitrate wins" "2" "$(pick_best "/m/e.mkv" "/m/f.mkv")"

stub_media "/m/g.mkv" 1920 15000
stub_media "/m/h.mkv" 1920 9000
assert_eq "Both oversized: better source wins" "1" "$(pick_best "/m/g.mkv" "/m/h.mkv")"

stub_media "/m/i.mkv" 1920 5000
stub_media "/m/j.mkv" 1920 5000
assert_eq "Tie keeps the file already in place" "2" "$(pick_best "/m/i.mkv" "/m/j.mkv")"

echo ""
echo "=== Testing handle_duplicate ==="

DUPLICATE_ACTION="keep_best"
mkdir -p "$TMP/dup"
printf 'identical content' > "$TMP/dup/A.mkv"
printf 'identical content' > "$TMP/dup/A.1080p.6mb.mkv"
handle_duplicate "$TMP/dup/A.mkv" "$TMP/dup/A.1080p.6mb.mkv" && r="continue" || r="stop"
assert_eq "Identical copies: existing tagged file wins" "stop" "$r"
[ -e "$TMP/dup/A.mkv" ] && r="yes" || r="no"
assert_eq "Identical copies: untagged copy removed" "no" "$r"
[ -e "$TMP/dup/A.1080p.6mb.mkv" ] && r="yes" || r="no"
assert_eq "Identical copies: tagged copy kept" "yes" "$r"

printf 'source is better' > "$TMP/dup/B.mkv"
printf 'existing worse copy here' > "$TMP/dup/B.720p.3mb.mkv"
stub_media "$TMP/dup/B.mkv" 1920 5000
stub_media "$TMP/dup/B.720p.3mb.mkv" 1280 2000
handle_duplicate "$TMP/dup/B.mkv" "$TMP/dup/B.720p.3mb.mkv" && r="continue" || r="stop"
assert_eq "Better candidate survives" "continue" "$r"
[ -e "$TMP/dup/B.720p.3mb.mkv" ] && r="yes" || r="no"
assert_eq "Lesser existing copy removed" "no" "$r"

printf 'lesser source' > "$TMP/dup/C.mkv"
printf 'existing is much better here' > "$TMP/dup/C.1080p.6mb.mkv"
stub_media "$TMP/dup/C.mkv" 1280 2000
stub_media "$TMP/dup/C.1080p.6mb.mkv" 1920 5000
handle_duplicate "$TMP/dup/C.mkv" "$TMP/dup/C.1080p.6mb.mkv" && r="continue" || r="stop"
assert_eq "Lesser candidate is dropped" "stop" "$r"
[ -e "$TMP/dup/C.mkv" ] && r="yes" || r="no"
assert_eq "Lesser candidate removed from disk" "no" "$r"

DUPLICATE_ACTION="trash"
printf 'quarantine me' > "$TMP/dup/D.mkv"
printf 'existing better copy here!' > "$TMP/dup/D.1080p.6mb.mkv"
stub_media "$TMP/dup/D.mkv" 1280 2000
stub_media "$TMP/dup/D.1080p.6mb.mkv" 1920 5000
handle_duplicate "$TMP/dup/D.mkv" "$TMP/dup/D.1080p.6mb.mkv" && r="continue" || r="stop"
assert_eq "trash: candidate is dropped" "stop" "$r"
[ -e "$TMP/dup/.duplicates/D.mkv" ] && r="yes" || r="no"
assert_eq "trash: loser moved to .duplicates" "yes" "$r"

DUPLICATE_ACTION="skip"
printf 'leave me alone' > "$TMP/dup/E.mkv"
printf 'and me too' > "$TMP/dup/E.1080p.6mb.mkv"
handle_duplicate "$TMP/dup/E.mkv" "$TMP/dup/E.1080p.6mb.mkv" && r="continue" || r="stop"
assert_eq "skip: nothing is processed" "stop" "$r"
[ -e "$TMP/dup/E.mkv" ] && [ -e "$TMP/dup/E.1080p.6mb.mkv" ] && r="both" || r="lost one"
assert_eq "skip: both files still there" "both" "$r"

echo ""
echo "=== Testing safe_move ==="

DUPLICATE_ACTION="keep_best"
mkdir -p "$TMP/mv"
printf 'x' > "$TMP/mv/F.mkv"
safe_move "$TMP/mv/F.mkv" "$TMP/mv/F.1080p.6mb.mkv" && r="moved" || r="not moved"
assert_eq "Free target: file is renamed" "moved" "$r"
[ -e "$TMP/mv/F.1080p.6mb.mkv" ] && [ ! -e "$TMP/mv/F.mkv" ] && r="yes" || r="no"
assert_eq "Free target: only the new name remains" "yes" "$r"

printf 'better source content' > "$TMP/mv/G.mkv"
printf 'worse' > "$TMP/mv/G.1080p.6mb.mkv"
stub_media "$TMP/mv/G.mkv" 1920 5000
stub_media "$TMP/mv/G.1080p.6mb.mkv" 1280 1000
safe_move "$TMP/mv/G.mkv" "$TMP/mv/G.1080p.6mb.mkv" && r="moved" || r="not moved"
assert_eq "Collision, source wins: rename happens" "moved" "$r"
assert_eq "Collision, source wins: content replaced" \
    "better source content" "$(cat "$TMP/mv/G.1080p.6mb.mkv")"

printf 'worse source' > "$TMP/mv/H.mkv"
printf 'better existing content here' > "$TMP/mv/H.1080p.6mb.mkv"
stub_media "$TMP/mv/H.mkv" 1280 1000
stub_media "$TMP/mv/H.1080p.6mb.mkv" 1920 5000
safe_move "$TMP/mv/H.mkv" "$TMP/mv/H.1080p.6mb.mkv" && r="moved" || r="not moved"
assert_eq "Collision, target wins: no rename" "not moved" "$r"
assert_eq "Collision, target wins: target untouched" \
    "better existing content here" "$(cat "$TMP/mv/H.1080p.6mb.mkv")"
[ -e "$TMP/mv/H.mkv" ] && r="yes" || r="no"
assert_eq "Collision, target wins: duplicate gone (no endless rename)" "no" "$r"

echo ""
echo "=== Testing tag helpers ==="

is_already_tagged "Movie.720p.3mb.mp4" && r="true" || r="false"
assert_eq "Tagged mp4 counts as tagged" "true" "$r"

is_already_tagged "Movie.1080p.6mb.mkv" && r="true" || r="false"
assert_eq "Tagged mkv counts as tagged" "true" "$r"

is_already_tagged "Movie.mkv" && r="true" || r="false"
assert_eq "Untagged file is not tagged" "false" "$r"

is_kept_original "Movie.original.mkv" && r="true" || r="false"
assert_eq "Parked original detected" "true" "$r"

is_kept_original "Movie.mkv" && r="true" || r="false"
assert_eq "Normal file is not a parked original" "false" "$r"

echo ""
echo "=== Testing generate_filename extension handling ==="

assert_eq "Rename-only keeps the source container" \
    "/movies/The Amazing Mr X (1948).720p.3mb.mp4" \
    "$(generate_filename "/movies/The Amazing Mr X (1948).mp4" "720p" "3000" "movies" "mp4")"

assert_eq "Encode output is mkv by default" \
    "/movies/The Amazing Mr X (1948).720p.3mb.mkv" \
    "$(generate_filename "/movies/The Amazing Mr X (1948).mp4" "720p" "3000" "movies")"

echo ""
echo "=========================================="
echo "Results: $PASS passed, $FAIL failed"
echo "=========================================="

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
