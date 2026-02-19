# Changelog

All notable changes to this project will be documented in this file.
Format follows [Semantic Versioning](https://semver.org/).

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
