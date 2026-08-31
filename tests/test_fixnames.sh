#!/usr/bin/env bash
# tests/test_fixnames.sh - Unit tests for the fix-names logic
# Run: bash tests/test_fixnames.sh
# All tests run offline (NO_TMDB=1); TMDb itself is exercised manually via
# `media-manager fix-names --dry-run`.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "${PROJECT_DIR}/lib/utils.sh"
source "${PROJECT_DIR}/lib/naming.sh"
source "${PROJECT_DIR}/lib/dedupe.sh"
source "${PROJECT_DIR}/lib/fixnames.sh"

export NO_TMDB=1

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

fixpy() {
    python3 "${PROJECT_DIR}/lib/fix_filename.py" "$@"
}

echo "=== Testing fix_filename.py (mechanical, movies) ==="

assert_eq "Abbreviation restored, tag kept" \
    "cleaned	R.I.P.D. - 2 - Rise of the Damned (2022).1080p.6mb.mkv" \
    "$(fixpy "R I P D - 2 - Rise of the Damned (2022).1080p.6mb.mkv" movies)"

assert_eq "Double space becomes ' - '" \
    "cleaned	Movie - Subtitle (2020).mkv" \
    "$(fixpy "Movie  Subtitle (2020).mkv" movies)"

assert_eq "Duplicate bare resolution removed (untagged file)" \
    "cleaned	Movie Name (2022).mkv" \
    "$(fixpy "Movie Name (2022).2160p.2160p.mkv" movies)"

assert_eq "Duplicate resolution before tag removed" \
    "cleaned	Movie Name (2022).2160p.12mb.mkv" \
    "$(fixpy "Movie Name (2022).2160p.2160p.12mb.mkv" movies)"

assert_eq "Duplicated full tag collapses to one" \
    "cleaned	Movie Name (2022).2160p.12mb.mkv" \
    "$(fixpy "Movie Name (2022).2160p.12mb.2160p.12mb.mkv" movies)"

assert_eq "Correct name reported unchanged" \
    "unchanged	Clean Movie (2019).1080p.6mb.mkv" \
    "$(fixpy "Clean Movie (2019).1080p.6mb.mkv" movies)"

assert_eq "Dotted abbreviation left alone" \
    "unchanged	R.I.P.D. (2013).1080p.6mb.mkv" \
    "$(fixpy "R.I.P.D. (2013).1080p.6mb.mkv" movies)"

assert_eq "mp4 container preserved" \
    "cleaned	Movie - Subtitle (2020).720p.3mb.mp4" \
    "$(fixpy "Movie  Subtitle (2020).720p.3mb.mp4" movies)"

echo ""
echo "=== Testing fix_filename.py (series, mechanical only) ==="

assert_eq "Series double space repaired" \
    "cleaned	Show S01E01 - Title.720p.3mb.mkv" \
    "$(fixpy "Show S01E01  Title.720p.3mb.mkv" series)"

assert_eq "Series clean name unchanged" \
    "unchanged	Show S01E01 Pilot.1080p.6mb.mkv" \
    "$(fixpy "Show S01E01 Pilot.1080p.6mb.mkv" series)"

echo ""
echo "=== Testing fix_filename.py --clean ==="

assert_eq "--clean repairs stem" \
    "S.W.A.T. - Firefight (2011)" \
    "$(fixpy --clean "S W A T  Firefight (2011)")"

assert_eq "--clean identity on good stem" \
    "The Matrix (1999)" \
    "$(fixpy --clean "The Matrix (1999)")"

echo ""
echo "=== Testing fs_sanitize (TMDb title → filename) ==="

assert_eq "Colon becomes ' - '" \
    "R.I.P.D. 2 - Rise of the Damned" \
    "$(python3 -c "
import sys; sys.path.insert(0, '${PROJECT_DIR}/lib')
import fix_filename
print(fix_filename.fs_sanitize('R.I.P.D. 2: Rise of the Damned'))
")"

assert_eq "Illegal filesystem characters stripped" \
    "Whats Up Doc" \
    "$(python3 -c "
import sys; sys.path.insert(0, '${PROJECT_DIR}/lib')
import fix_filename
print(fix_filename.fs_sanitize('What\\'s* Up? \"Doc\"'.replace(chr(39),'')))
")"

echo ""
echo "=== Testing fix_one_name (real files) ==="

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# Rename with subtitle sidecar following along
touch "${TMP_DIR}/R I P D - 2 - Rise of the Damned (2022).1080p.6mb.mkv"
touch "${TMP_DIR}/R I P D - 2 - Rise of the Damned (2022).1080p.6mb.nl.srt"
fix_one_name "${TMP_DIR}/R I P D - 2 - Rise of the Damned (2022).1080p.6mb.mkv" movies false >/dev/null

[ -f "${TMP_DIR}/R.I.P.D. - 2 - Rise of the Damned (2022).1080p.6mb.mkv" ] && r="true" || r="false"
assert_eq "Video renamed on disk" "true" "$r"

[ -f "${TMP_DIR}/R.I.P.D. - 2 - Rise of the Damned (2022).1080p.6mb.nl.srt" ] && r="true" || r="false"
assert_eq "Subtitle sidecar followed the rename" "true" "$r"

# Dry run must not touch anything
touch "${TMP_DIR}/Movie  Subtitle (2020).mkv"
fix_one_name "${TMP_DIR}/Movie  Subtitle (2020).mkv" movies true >/dev/null
[ -f "${TMP_DIR}/Movie  Subtitle (2020).mkv" ] && r="true" || r="false"
assert_eq "Dry run leaves file untouched" "true" "$r"

# Unchanged file is left alone
touch "${TMP_DIR}/Clean Movie (2019).1080p.6mb.mkv"
fix_one_name "${TMP_DIR}/Clean Movie (2019).1080p.6mb.mkv" movies false >/dev/null
[ -f "${TMP_DIR}/Clean Movie (2019).1080p.6mb.mkv" ] && r="true" || r="false"
assert_eq "Correct name stays in place" "true" "$r"

echo ""
echo "=========================================="
echo "Results: $PASS passed, $FAIL failed"
echo "=========================================="

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
