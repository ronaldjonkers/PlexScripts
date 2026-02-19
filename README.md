# Media Manager

Automatic video encoding and renaming service for your media library. Continuously watches directories for video files, encodes them to your preferred quality, and renames them with a clean, consistent format.

Built for **Plex**, **Jellyfin**, **Emby**, or any media server that benefits from standardized file naming.

## Features

- **Continuous directory watching** — runs as a background service, scanning for new/unprocessed files
- **Smart encoding** — uses HandBrake with hardware acceleration (VideoToolbox on macOS) and x265 software fallback
- **Intelligent renaming** — clean `Title (Year).Resolution.Bitrate.mkv` format for movies, `Show S01E01 Title.Resolution.Bitrate.mkv` for series
- **Auto-detection** — automatically detects whether a directory contains movies or TV series
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
│   └── naming.sh               # File naming & media type detection
├── config/
│   └── media-manager.conf.example  # Example configuration
├── service/
│   ├── com.media-manager.plist     # macOS LaunchAgent template
│   └── media-manager.service       # Linux systemd unit template
└── tests/
    └── test_naming.sh          # Unit tests for naming logic
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
DELETE_ORIGINALS="no"   # Delete source files after encoding

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
4. **Analyze** — Resolution, bitrate, duration, and audio streams are read via `ffprobe`
5. **Decide** — If the current bitrate is within ±5% of the target: rename only. If the estimated output would be ≥98% of the source: rename only. Otherwise: encode.
6. **Encode** — Uses HandBrake with VideoToolbox (macOS HW) or x265 (software fallback). All audio tracks and subtitles are preserved.
7. **Rename** — Output is named with the clean format including resolution and bitrate
8. **Repeat** — Waits for the configured interval, then scans again

## Media Type Detection

When a directory is set to `auto`, the service detects the media type by:

1. Looking for `Season XX` subdirectories → **series**
2. Looking for `SxxExx` patterns in filenames → **series**
3. Default → **movies**

## Running Tests

```bash
bash tests/test_naming.sh
```

## License

MIT

## Version

1.0.0 — See [CHANGELOG.md](CHANGELOG.md) for history.
