# Media Manager

Automatic video encoding and renaming service for your media library. Continuously watches directories for video files, encodes them to your preferred quality, and renames them with a clean, consistent format.

Built for **Plex**, **Jellyfin**, **Emby**, or any media server that benefits from standardized file naming.

## Features

- **Continuous directory watching** — runs as a background service, scanning for new/unprocessed files
- **Smart encoding** — uses HandBrake with hardware acceleration (VideoToolbox on macOS) and x265 software fallback
- **Intelligent renaming** — clean `Title (Year).Resolution.Bitrate.mkv` format for movies, `Show S01E01 Title.Resolution.Bitrate.mkv` for series
- **Auto-detection** — automatically detects whether a directory contains movies or TV series
- **Duplicate resolution** — when the same title exists twice, the best copy keeps the tagged name and the other one is cleaned up
- **Subtitles follow the video** — external `.srt`/`.sub`/`.idx` sidecars are renamed along with the file, so Plex never loses them
- **No-bloat protection** — skips encoding if the output would be larger than the source
- **Bitrate tolerance** — skips encoding if the file is already within ±5% of the target bitrate
- **Multiple watch directories** — monitor as many directories as you need
- **7 quality presets + custom** — from UltraSaver to MaxPunch
- **Cross-platform** — macOS (with VideoToolbox HW acceleration) and Linux
- **Service integration** — LaunchAgent (macOS) or systemd (Linux) for auto-start at boot
- **Interactive installer** — guided setup for dependencies, quality, directories, and service

## File Naming Format

| Type | Format | Example |
|------|--------|---------|
| Movies | `Title (Year).Resolution.Bitrate.mkv` | `The Matrix (1999).1080p.6mb.mkv` |
| Series | `Show S01E01 Title.Resolution.Bitrate.mkv` | `Breaking Bad S01E01 Pilot.1080p.6mb.mkv` |

Resolution is always visible in the filename, allowing you to store multiple resolutions in the same directory.

## Quick Start

### One-Line Install

```bash
git clone https://github.com/ronaldjonkers/PlexScripts.git && cd PlexScripts && bash install.sh install
```

### Upgrade

```bash
cd PlexScripts && bash install.sh upgrade
```

### Uninstall

```bash
cd PlexScripts && bash install.sh uninstall
```

## Quality Presets

| # | Preset | 2160p (4K) | 1080p | 720p |
|---|--------|-----------|-------|------|
| 1 | UltraSaver | 7 Mbps | 3 Mbps | 1 Mbps |
| 2 | DataDiet | 8 Mbps | 4 Mbps | 1.5 Mbps |
| 3 | StreamSaver | 10 Mbps | 5 Mbps | 2.5 Mbps |
| 4 | Netflix-ish | 12 Mbps | 6 Mbps | 3 Mbps |
| 5 | CrispCable | 16 Mbps | 8 Mbps | 4 Mbps |
| 6 | ArchivalLite | 20 Mbps | 10 Mbps | 5 Mbps |
| 7 | MaxPunch | 24 Mbps | 12 Mbps | 6 Mbps |
| 8 | Custom | User-defined | User-defined | User-defined |

## Requirements

| Dependency | Purpose |
|-----------|---------|
| [HandBrakeCLI](https://handbrake.fr) | Video encoding (H.265/HEVC) |
| [ffmpeg/ffprobe](https://ffmpeg.org) | Media analysis (resolution, bitrate, duration) |
| [python3](https://python.org) | Numeric calculations |

All dependencies are automatically installed by `install.sh`.

## Project Structure

```
PlexScripts/
├── install.sh                  # Interactive installer/updater/uninstaller
├── README.md                   # This file
├── CHANGELOG.md                # Version history
├── .gitignore                  # Git ignore rules
├── bin/
│   └── media-manager           # Main service executable
├── lib/
│   ├── utils.sh                # Shared utilities (OS detection, ffprobe helpers)
│   ├── encoding.sh             # Encoding logic (VideoToolbox + x265)
│   ├── dedupe.sh               # Duplicate resolution & subtitle sidecars
│   └── naming.sh               # File naming & media type detection
├── config/
│   └── media-manager.conf.example  # Example configuration
├── service/
│   ├── com.media-manager.plist     # macOS LaunchAgent template
│   └── media-manager.service       # Linux systemd unit template
└── tests/
    ├── test_naming.sh          # Unit tests for naming logic
    └── test_dedupe.sh          # Unit tests for duplicate handling
```

## Configuration

Configuration is stored in `config/media-manager.conf` (created by the installer). Key settings:

```bash
# Quality profile
PROFILE_NAME="Netflix-ish"
VB2160=12000        # 4K target bitrate (kbps)
VB1080=6000         # 1080p target bitrate (kbps)
VB720=3000          # 720p target bitrate (kbps)

# Encoding
VT_PRESET="quality"     # VideoToolbox preset (macOS): fast|balanced|quality
X265_PRESET="slow"      # x265 software preset: fast|medium|slow|veryslow
TOL_PCT=5               # Skip encoding if bitrate is within ±5%

# File management
DELETE_ORIGINALS="no"           # Delete source files after encoding
DUPLICATE_ACTION="keep_best"    # Same title twice: keep_best | trash | skip
SIDECAR_EXTS="srt sub idx ass ssa vtt smi sup"   # Sidecars that follow a rename

# Service
SCAN_INTERVAL=300       # Seconds between scans

# Watch directories (path|type)
# Type: movies, series, or auto (auto-detect)
WATCH_DIRS=(
    "/Volumes/Media/Movies|movies"
    "/Volumes/Media/TV Shows|series"
    "/Volumes/Media/Downloads|auto"
)
```

## Usage

### Manual Commands

```bash
# Start the service (runs continuously)
./bin/media-manager start

# Run a single scan and exit
./bin/media-manager scan

# Start with verbose output (shows full HandBrakeCLI output)
./bin/media-manager start --verbose

# Single scan with verbose output (great for debugging)
./bin/media-manager scan -V

# Check if the service is running
./bin/media-manager status

# Stop the service
./bin/media-manager stop

# Use a custom config file
./bin/media-manager start -c /path/to/config.conf

# Show help
./bin/media-manager --help
```

> **Tip:** Use `--verbose` / `-V` when running manually to see the full HandBrakeCLI encoder output in real-time. Without it, encoder output is only shown (last 20 lines) when an encode fails.

### Service Management

**macOS (LaunchAgent):**
```bash
# Start
launchctl load ~/Library/LaunchAgents/com.media-manager.plist

# Stop
launchctl unload ~/Library/LaunchAgents/com.media-manager.plist
```

**Linux (systemd user service):**
```bash
# Start
systemctl --user start media-manager

# Stop
systemctl --user stop media-manager

# View logs
journalctl --user -u media-manager -f
```

## How It Works

1. **Scan** — The service recursively scans each configured watch directory for video files (`.mp4`, `.mkv`, `.mov`, `.avi`, `.m4v`, `.wmv`)
2. **Skip tagged** — Files already in our naming format (`Name.Resolution.Bitrate.mkv`) are skipped
3. **Skip active** — Files modified within the last 30 seconds are skipped (still being written/downloaded)
4. **Dedupe** — If the title already has a tagged copy, only the best copy survives (see below)
5. **Analyze** — Resolution, bitrate, duration, and audio streams are read via `ffprobe`
6. **Decide** — If the current bitrate is within ±5% of the target: rename only. If the estimated output would be ≥98% of the source: rename only. Otherwise: encode.
7. **Encode** — Uses HandBrake with VideoToolbox (macOS HW) or x265 (software fallback). All audio tracks and subtitles are preserved.
8. **Rename** — Output is named with the clean format including resolution and bitrate, and external subtitles are renamed along with it
9. **Repeat** — Waits for the configured interval, then scans again

## Duplicate Handling

A rename can collide with a file that is already there — for example `Movie (2020).mkv` and
`Movie (2020).1080p.6mb.mkv` both sitting in the same folder. Instead of leaving both behind,
the service picks a winner:

1. Byte-identical copies → the copy that already carries the tag is kept
2. Higher resolution wins
3. A copy within the bitrate policy beats an oversized copy
4. Otherwise the higher bitrate wins (better quality, or the better source for re-encoding)

What happens to the losing copy is set by `DUPLICATE_ACTION`:

| Value | Behaviour |
|-------|-----------|
| `keep_best` (default) | The lesser copy is deleted |
| `trash` | The lesser copy is moved to a `.duplicates` folder next to it |
| `skip` | Nothing is touched, a warning is logged |

Two tagged copies of the same title (e.g. `.1080p.6mb.mkv` next to `.720p.3mb.mkv`) are resolved
the same way. When `DELETE_ORIGINALS="no"`, an encoded source is renamed to `Name.original.ext`
so it is never picked up and re-encoded again.

## External Subtitles

Plex matches external subtitles on the filename stem, so a rename would orphan them:
`Fantasia (1940).nl.srt` no longer belongs to `Fantasia (1940).1080p.6mb.mkv`. Sidecars therefore
travel with the video everywhere it goes:

| Situation | What happens to the subtitles |
|-----------|-------------------------------|
| Rename | `Movie (2020).nl.srt` → `Movie (2020).1080p.6mb.nl.srt` |
| Encode | Re-attached to the encoded file (not to a kept original) |
| Duplicate cleaned up | Moved to the copy that survives, so they are never lost with it |
| Both copies have the same subtitle | The winner keeps its own; the redundant one follows `DUPLICATE_ACTION` |

Which files count as sidecars is set by `SIDECAR_EXTS` (default `srt sub idx ass ssa vtt smi sup`).
Add `nfo` there if you want metadata files to move along too.

## Media Type Detection

When a directory is set to `auto`, the service detects the media type by:

1. Looking for `Season XX` subdirectories → **series**
2. Looking for `SxxExx` patterns in filenames → **series**
3. Default → **movies**

## Running Tests

```bash
bash tests/test_naming.sh
bash tests/test_dedupe.sh
```

## License

MIT

## Version

1.1.0 — See [CHANGELOG.md](CHANGELOG.md) for history.
