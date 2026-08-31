# Changelog

All notable changes to this project will be documented in this file.
Format follows [Semantic Versioning](https://semver.org/).

## [1.2.0] - 2026-08-31

### Added
- **`fix-names` command** — repairs damaged library filenames in one pass, with `--dry-run`
  preview, an optional directory argument, and `--no-tmdb` to skip API verification.
  Renames go through the collision-safe dedupe path, so external subtitles travel along.
- **TMDb title verification** — movie titles are parsed from the filename, looked up on
  The Movie Database, and replaced by the official title (`Hansel  Gretel Witch Hunters (2013)`
  → `Hansel & Gretel - Witch Hunters (2013)`). Only confident matches are accepted
  (year-anchored search + similarity check); unrecognized titles get mechanical fixes only.
  Configure `TMDB_API_TOKEN` in the new gitignored `.env` (see `.env.example`).
- `lib/fix_filename.py` — shared name repair logic (stdlib only, no pip dependencies)
- `tests/test_fixnames.sh` — 18 offline tests for the repair logic

### Fixed
- **Double spaces restored to `" - "`** — earlier renaming collapsed `" - "` into `"  "`,
  breaking Plex matching. Both the scan loop and `fix-names` now repair this.
- **Abbreviations get their dots back** — `R I P D` → `R.I.P.D.`, `S W A T` → `S.W.A.T.`
  (two or more consecutive single capital letters)
- **Duplicate resolution tags fully stripped** — `Movie.2160p.2160p.mkv` and
  `Movie.2160p.12mb.2160p.12mb.mkv` no longer keep a stray resolution in the name;
  `strip_media_tags` now strips repeated tags until stable
- Year extraction no longer eats a title's trailing dot (`R.I.P.D. (2013)` keeps its dot)

## [1.1.0] - 2026-08-26

### Fixed
- **Endless renames / duplicate files** — renaming used `mv -n`, which silently does nothing when the
  target already exists. The source kept its old name, so every scan logged the same `[RENAME]` again
  and the library filled up with duplicate pairs. Every collision is now resolved explicitly.
- Rename-only passes keep the source container (`.mp4` stays `.mp4`) instead of being relabelled as
  `.mkv` without remuxing
- `is_already_tagged()` now recognises tagged files in any container, not just `.mkv`
- With `DELETE_ORIGINALS="no"` an encoded source is parked as `Name.original.ext`, so it is no longer
  re-encoded on every single scan

### Added
- **External subtitles follow the video** — `.srt`/`.sub`/`.idx`/… sidecars are renamed along with
  the file on rename and after encoding, and are rescued from a duplicate before it is cleaned up,
  so Plex never ends up with orphaned subtitles. Configurable via `SIDECAR_EXTS`.
- `lib/dedupe.sh` — duplicate detection and resolution:
  identical content via a cheap size + head/tail fingerprint, quality ranking by
  resolution → bitrate policy compliance → bitrate
- `DUPLICATE_ACTION` setting: `keep_best` (delete lesser copy, default), `trash` (move it to a
  `.duplicates` folder) or `skip` (only warn)
- Duplicates between two already-tagged copies of the same title are resolved as well
- Hidden directories (such as `.duplicates`) are pruned from scans
- `tests/test_dedupe.sh` — 46 tests for duplicate detection, ranking, disposal, safe renaming and
  subtitle sidecar handling

## [1.0.4] - 2026-02-19

### Fixed
- **Only encode when bitrate is too HIGH** — files at or below target bitrate are now skipped
  (previously files with lower bitrate than target were also re-encoded, causing quality loss)
- Replaced `bitrate_within_tolerance()` with `bitrate_needs_encoding()` for clear one-directional check

### Changed
- Clearer decision logging: shows exactly why a file is encoded, skipped, or renamed
  - `Bitrate already at or below target (2000 <= 3000 kbps)`
  - `Bitrate within 5% tolerance of target`
  - `Bitrate 5000 kbps exceeds target 3000 kbps by >5% → encoding`
- Added 10 new tests for encoding decision logic (38 total, all passing)

## [1.0.3] - 2026-02-19

### Fixed
- Auto-detect and repair broken HandBrakeCLI library dependencies (e.g. missing `svt-av1`)
- Preflight now hard-stops if HandBrakeCLI is broken instead of scanning thousands of files with guaranteed failures
- `install.sh` explicitly installs `svt-av1` and verifies HandBrakeCLI works after install

### Changed
- Rename logging now shows clear `from → to` format for every rename operation
- Preflight auto-repairs via `brew reinstall svt-av1 handbrake` on macOS

## [1.0.2] - 2026-02-19

### Added
- `--verbose` / `-V` CLI flag for real-time HandBrakeCLI output when running manually
- Usage examples in `--help` output
- Verbose mode indicator in startup log

## [1.0.1] - 2026-02-19

### Fixed
- HandBrakeCLI errors now captured and shown in logs instead of suppressed (`>/dev/null 2>&1`)
- Failed encode output (last 20 lines) is displayed to aid debugging (e.g. `Abort trap: 6`)
- Stale/partial output files cleaned up on encode failure

### Added
- HandBrakeCLI preflight version check at service startup
- `_run_handbrake()` helper with temp log capture and error reporting
- `check_handbrake()` function for startup diagnostics

## [1.0.0] - 2026-02-19

### Added
- Complete rewrite as a background service with continuous directory watching
- Cross-platform support (macOS + Linux)
- Interactive installer with OS detection and dependency management
- Quality preset selection (7 presets + custom)
- Multiple watch directory support with per-directory media type configuration
- Auto-detection of movies vs TV series (Season folders, SxxExx patterns)
- Resolution tag in both movie and series filenames
- LaunchAgent (macOS) and systemd (Linux) service integration
- Lock file management to prevent multiple instances
- File age check to skip files still being written
- Comprehensive test suite for naming logic
- Single-line install, upgrade, and uninstall commands

### Fixed
- Duplicate resolution in movie filenames (e.g. "Movie 2160p.2160p.12mb.mkv" → "Movie.2160p.12mb.mkv")
- Cross-platform `stat` compatibility (macOS vs Linux)

### Changed
- Unified movies and series processing into a single service
- MKV output format for all files (previously series used .mp4)
- Improved resolution detection margins for cropped content
