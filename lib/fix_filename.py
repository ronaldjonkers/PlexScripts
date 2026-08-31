#!/usr/bin/env python3
"""Compute the corrected basename for a media file.

Repairs the damage older versions of this tool (and sloppy sources) left in
filenames, because Plex matches movies on the exact "Title (Year)" stem:

  - " - " that collapsed into a double space:  "Movie  Subtitle" -> "Movie - Subtitle"
  - dotted abbreviations that lost their dots: "R I P D"         -> "R.I.P.D."
  - duplicated resolution tags:                "Movie.2160p.2160p.mkv" -> "Movie.mkv"

When a TMDb API token is available the movie title is verified against TMDb and
replaced by the official title, so the name is guaranteed to be recognisable.

Usage:
  fix_filename.py --clean STEM             mechanical cleanup of a stem, prints result
  fix_filename.py BASENAME MEDIA_TYPE      full fix, prints "STATUS<TAB>NEW_BASENAME"
                                           STATUS: tmdb | cleaned | unchanged

Environment:
  TMDB_API_TOKEN        TMDb v4 read access token (Bearer). Empty = mechanical only.
  TMDB_LANGUAGE         default en-US
  TMDB_TIMEOUT_SECONDS  default 20
  TMDB_MAX_RETRIES      default 2
  NO_TMDB               set to 1 to skip TMDb even when a token is present
  TMDB_CACHE_FILE       JSON cache file, reused across invocations of one run
"""

from __future__ import annotations

import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from difflib import SequenceMatcher

TMDB_BASE_URL = os.environ.get("TMDB_BASE_URL", "https://api.themoviedb.org/3")

RES_TOKENS = r"(?:2160p|1080p|720p|480p)"
# Our own tag: ".1080p.6mb" — kept verbatim through a rename.
TAG_RE = re.compile(r"\.(" + RES_TOKENS + r")\.(\d+)mb$", re.IGNORECASE)


def split_basename(basename: str) -> tuple[str, str, str]:
    """Split "Title (Year).1080p.6mb.mkv" into (stem, tag, ext).

    Any duplicated resolution/bitrate tags are dropped here, so
    "Movie.2160p.2160p.mkv" comes back as ("Movie", "", "mkv").
    """
    stem, _, ext = basename.rpartition(".")
    if not stem:
        stem, ext = ext, ""

    tag = ""
    m = TAG_RE.search(stem)
    if m:
        tag = m.group(0)
        stem = stem[: m.start()]

    # Strip every leftover resolution/bitrate token still glued to the end
    # (the "2160p.2160p" and "1080p.6mb.1080p.6mb" family of accidents).
    pattern_full = re.compile(r"(?:[. ]" + RES_TOKENS + r"\.\d+mb)+$", re.IGNORECASE)
    pattern_bare = re.compile(r"(?:[. ]" + RES_TOKENS + r")+$", re.IGNORECASE)
    while True:
        new = pattern_full.sub("", stem)
        new = pattern_bare.sub("", new)
        if new == stem:
            break
        stem = new

    return stem.rstrip(" ."), tag, ext


def extract_year(stem: str) -> tuple[str, str | None]:
    """Pull a trailing "(1999)" off the stem. Returns (title, year|None)."""
    # Only whitespace may sit before "(Year)" — a dot belongs to the title
    # ("R.I.P.D. (2013)" must keep its final dot).
    m = re.search(r"\s*\((\d{4})\)\s*$", stem)
    if m:
        return stem[: m.start()], m.group(1)
    return stem, None


def mechanical_clean(title: str) -> str:
    """Deterministic repairs that need no API."""
    t = title
    # A double space is a " - " that lost its hyphen.
    t = re.sub(r" {2,}", " - ", t)
    # "R I P D" / "S W A T": >=2 consecutive single capital letters -> dotted.
    t = re.sub(
        r"\b[A-Z](?: [A-Z]){1,}\b(?![A-Za-z])",
        lambda m: ".".join(m.group().split()) + ".",
        t,
    )
    # Collapse separator pile-ups the repairs above may have produced.
    t = re.sub(r"(?: - ){2,}", " - ", t)
    t = re.sub(r" {2,}", " ", t)
    t = re.sub(r"[ \-]+$", "", t)
    return t.strip()


def clean_stem(stem: str) -> str:
    """Mechanical cleanup of a full stem, keeping a trailing (Year) intact."""
    title, year = extract_year(stem)
    title = mechanical_clean(title)
    return f"{title} ({year})" if year else title


def fs_sanitize(title: str) -> str:
    """Make a TMDb title safe as a filename (SMB/Windows-safe too)."""
    t = title.replace(": ", " - ").replace(":", "-")
    t = re.sub(r'[\\/*?"<>|]', "", t)
    return re.sub(r"\s+", " ", t).strip()


def _norm(s: str) -> str:
    return re.sub(r"[^a-z0-9]+", " ", s.lower()).strip()


class TMDb:
    def __init__(self) -> None:
        self.token = os.environ.get("TMDB_API_TOKEN", "").strip()
        self.language = os.environ.get("TMDB_LANGUAGE", "en-US").strip() or "en-US"
        try:
            self.timeout = float(os.environ.get("TMDB_TIMEOUT_SECONDS", "20"))
        except ValueError:
            self.timeout = 20.0
        try:
            self.retries = int(os.environ.get("TMDB_MAX_RETRIES", "2"))
        except ValueError:
            self.retries = 2
        self.cache_file = os.environ.get("TMDB_CACHE_FILE", "")
        self.cache: dict[str, list | None] = {}
        if self.cache_file and os.path.isfile(self.cache_file):
            try:
                with open(self.cache_file, "r", encoding="utf-8") as fh:
                    self.cache = json.load(fh)
            except (OSError, ValueError):
                self.cache = {}

    @property
    def enabled(self) -> bool:
        return bool(self.token) and os.environ.get("NO_TMDB", "") != "1"

    def _save_cache(self) -> None:
        if not self.cache_file:
            return
        try:
            with open(self.cache_file, "w", encoding="utf-8") as fh:
                json.dump(self.cache, fh)
        except OSError:
            pass

    def _search(self, params: dict[str, str]) -> list[dict]:
        url = f"{TMDB_BASE_URL}/search/movie?" + urllib.parse.urlencode(params)
        req = urllib.request.Request(
            url,
            headers={
                "Authorization": f"Bearer {self.token}",
                "Accept": "application/json",
            },
        )
        last_exc: Exception | None = None
        for attempt in range(self.retries + 1):
            try:
                with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                    payload = json.load(resp)
                results = payload.get("results", [])
                return results if isinstance(results, list) else []
            except (urllib.error.URLError, ValueError, OSError) as exc:
                last_exc = exc
                if attempt < self.retries:
                    time.sleep(1.0 * (attempt + 1))
        raise RuntimeError(f"TMDb search failed: {last_exc}")

    def lookup(self, title: str, year: str | None) -> tuple[str, str] | None:
        """Return (official_title, year) for the best TMDb match, or None."""
        key = f"{_norm(title)}|{year or ''}"
        if key in self.cache:
            hit = self.cache[key]
            return (hit[0], hit[1]) if hit else None

        params = {
            "query": title,
            "language": self.language,
            "include_adult": "false",
        }
        used_year = False
        results: list[dict] = []
        if year:
            results = self._search({**params, "primary_release_year": year})
            used_year = bool(results)
        if not results:
            results = self._search(params)

        best = self._pick(results, title, year, used_year)
        self.cache[key] = list(best) if best else None
        self._save_cache()
        return best

    def _pick(
        self, results: list[dict], title: str, year: str | None, used_year: bool
    ) -> tuple[str, str] | None:
        query_norm = _norm(title)
        best: tuple[float, str, str] | None = None
        for r in results[:10]:
            release_year = (r.get("release_date") or "")[:4]
            for cand in (r.get("title"), r.get("original_title")):
                if not cand:
                    continue
                score = SequenceMatcher(None, query_norm, _norm(cand)).ratio()
                if best is None or score > best[0]:
                    best = (score, r.get("title") or cand, release_year or (year or ""))
        if best is None:
            return None
        score, official, release_year = best
        # Year-anchored searches may accept fuzzier titles; a year-less or
        # fallback search must be near-certain before we rename anything.
        threshold = 0.60 if used_year else 0.90
        if score < threshold:
            return None
        if not release_year:
            if not year:
                return None
            release_year = year
        return official, release_year


def fix_basename(basename: str, media_type: str) -> tuple[str, str]:
    stem, tag, ext = split_basename(basename)
    suffix = f"{tag}.{ext}" if ext else tag

    if media_type != "movies":
        new_stem = clean_stem(stem)
        new_basename = f"{new_stem}{suffix}"
        status = "unchanged" if new_basename == basename else "cleaned"
        return status, new_basename

    title, year = extract_year(stem)
    title = mechanical_clean(title)
    status = "cleaned"

    tmdb = TMDb()
    if tmdb.enabled and title:
        try:
            hit = tmdb.lookup(title, year)
        except RuntimeError as exc:
            print(f"warning: {exc}", file=sys.stderr)
            hit = None
        if hit:
            title = fs_sanitize(hit[0])
            year = hit[1] or year
            status = "tmdb"

    new_stem = f"{title} ({year})" if year else title
    new_basename = f"{new_stem}{suffix}"
    if new_basename == basename:
        status = "unchanged"
    return status, new_basename


def main(argv: list[str]) -> int:
    if len(argv) == 3 and argv[1] == "--clean":
        print(clean_stem(argv[2]))
        return 0
    if len(argv) == 3:
        status, new_basename = fix_basename(argv[1], argv[2])
        print(f"{status}\t{new_basename}")
        return 0
    print(__doc__.strip(), file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
