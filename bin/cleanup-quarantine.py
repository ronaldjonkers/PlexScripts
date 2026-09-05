#!/usr/bin/env python3
"""Ruim vervangen bestanden op uit de .beschadigd-geen-audio quarantaine.

Een quarantainebestand wordt pas verwijderd wanneer de bibliotheek een
gezonde vervanger bevat:
  - afleveringen: zelfde serie-map + zelfde SxxEyy, met minstens 1 audiotrack
  - films: zelfde "Titel (Jaar)" (tags genegeerd) ergens in de filmmappen,
    met minstens 1 audiotrack

Bijbehorende ondertitel-sidecars in de quarantaine gaan mee weg. Lege mappen
worden opgeruimd. Herdraaibaar: run hem gerust elke dag terwijl de downloads
binnenkomen.

Gebruik: python3 bin/cleanup-quarantine.py [--dry-run]
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
import unicodedata
from pathlib import Path

QUARANTINES = [Path("/Volumes/Plex/.beschadigd-geen-audio"),
               Path("/Volumes/4KMovies/.beschadigd-geen-audio")]
MOVIE_DIRS = [Path("/Volumes/Plex/Films"), Path("/Volumes/4KMovies")]
SERIES_DIR = Path("/Volumes/Plex/TVSeries")

VIDEO_EXTS = {".mkv", ".mp4", ".m4v", ".avi", ".mov", ".wmv"}
SIDECAR_EXTS = {".srt", ".sub", ".idx", ".ass", ".ssa", ".vtt", ".smi", ".sup"}
EP_RE = re.compile(r"[Ss](\d{1,2})[Ee](\d{1,3})")
TAG_RE = re.compile(r"\.(2160p|1080p|720p|480p)\.\d+mb$", re.I)
RES_RE = re.compile(r"([. ](2160p|1080p|720p|480p))+$", re.I)


def norm_movie(stem: str) -> str:
    s = TAG_RE.sub("", stem)
    s = RES_RE.sub("", s)
    s = unicodedata.normalize("NFKD", s).encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]+", " ", s).strip()


def iter_videos(root: Path):
    for p in root.rglob("*"):
        if p.is_file() and p.suffix.lower() in VIDEO_EXTS \
                and not any(part.startswith(".") for part in p.relative_to(root).parts[:-1]):
            yield p


def has_audio(path: Path) -> bool:
    try:
        out = subprocess.run(
            ["ffprobe", "-v", "error", "-select_streams", "a",
             "-show_entries", "stream=index", "-of", "csv=p=0", "--", str(path)],
            capture_output=True, text=True, timeout=60)
        return bool(out.stdout.strip())
    except (subprocess.SubprocessError, OSError):
        return False


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    # Index van de huidige bibliotheek
    movies: dict[str, Path] = {}
    for root in MOVIE_DIRS:
        if root.is_dir():
            for p in iter_videos(root):
                movies.setdefault(norm_movie(p.stem), p)

    episodes: dict[tuple[str, int, int], Path] = {}
    if SERIES_DIR.is_dir():
        for p in iter_videos(SERIES_DIR):
            m = EP_RE.search(p.name)
            if m:
                serie = p.relative_to(SERIES_DIR).parts[0].lower()
                episodes.setdefault((serie, int(m.group(1)), int(m.group(2))), p)

    deleted = kept = 0
    freed = 0
    checked_ok: dict[Path, bool] = {}

    for q in QUARANTINES:
        if not q.is_dir():
            continue
        for p in sorted(q.rglob("*")):
            if not p.is_file() or p.suffix.lower() not in VIDEO_EXTS:
                continue
            rel = p.relative_to(q)
            replacement = None
            if rel.parts[0] == "TVSeries":
                m = EP_RE.search(p.name)
                if m and len(rel.parts) > 1:
                    replacement = episodes.get(
                        (rel.parts[1].lower(), int(m.group(1)), int(m.group(2))))
            else:
                replacement = movies.get(norm_movie(p.stem))

            if replacement is None:
                kept += 1
                continue
            if replacement not in checked_ok:
                checked_ok[replacement] = has_audio(replacement)
            if not checked_ok[replacement]:
                print(f"[HOUD] vervanger heeft geen audio?! {replacement.name}")
                kept += 1
                continue

            size = p.stat().st_size
            # de video plus zijn ondertitel-sidecars (zelfde stam)
            targets = [p] + [sc for sc in p.parent.iterdir()
                             if sc.is_file() and sc.suffix.lower() in SIDECAR_EXTS
                             and sc.name.startswith(p.stem)]
            if args.dry_run:
                print(f"[DRY] {rel}  (vervangen door: {replacement.name})")
            else:
                for t in targets:
                    try:
                        t.unlink()
                    except OSError as exc:
                        print(f"[FOUT] kon niet verwijderen: {t}: {exc}")
            deleted += 1
            freed += size

    # lege mappen opruimen
    if not args.dry_run:
        for q in QUARANTINES:
            if q.is_dir():
                for d in sorted((d for d in q.rglob("*") if d.is_dir()),
                                key=lambda x: len(x.parts), reverse=True):
                    try:
                        d.rmdir()
                    except OSError:
                        pass

    print(f"\nKLAAR: {deleted} vervangen bestanden "
          f"{'zouden worden ' if args.dry_run else ''}verwijderd "
          f"({freed / 1024**3:.1f} GB vrijgemaakt), {kept} wachten nog op vervanging")
    return 0


if __name__ == "__main__":
    sys.exit(main())
