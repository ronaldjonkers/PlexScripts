#!/usr/bin/env python3
"""Zoek en download NZB's voor missende serie-afleveringen via NZBGeek.

Leest een schadelijst (formaat van logs/herdownload-series.txt):

    Serie Naam
      S01: E01-E24
      S02: E01, E05-E08

en zoekt per seizoen:
  1. een COMPLEET SEASON PACK zodra er >= PACK_THRESHOLD afleveringen missen
     (voorkeur: 2160p > 1080p; BluRay > WEB; releasegroep iVy krijgt bonus)
  2. anders LOSSE AFLEVERINGEN (voorkeur: 2160p > 1080p; groep MeGusta bonus —
     die rips zijn al goed gecomprimeerd)

Gevonden NZB's worden in OUTPUT_DIR geschreven; breng die zelf naar de
downloadserver. Een state-bestand maakt het script herstartbaar: afgehandelde
seizoenen worden overgeslagen, dus je kunt hem gerust vaker draaien.

Gebruik:
  python3 bin/series-redownload.py [--dry-run] [--list PAD] [--serie "Naam"]

Config via .env (of omgeving): NZBGEEK_API_KEY (verplicht), NZBGEEK_BASE_URL.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
import unicodedata
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from collections import defaultdict
from pathlib import Path

PROJECT_DIR = Path(__file__).resolve().parent.parent
DEFAULT_LIST = PROJECT_DIR / "logs" / "herdownload-series.txt"
OUTPUT_DIR = Path(os.environ.get("NZB_SERIES_OUTPUT", str(Path.home() / "Downloads" / "nzb-series")))
STATE_FILE = OUTPUT_DIR / ".state.json"
REPORT_FILE = OUTPUT_DIR / "rapport.txt"

PACK_THRESHOLD = int(os.environ.get("PACK_THRESHOLD", "3"))  # >= zoveel missend -> season pack
REQUEST_DELAY = 1.2   # seconden tussen API-calls (netjes voor NZBGeek)
CATEGORIES = "5040,5045"  # TV HD + TV UHD
REJECT_TERMS = ("sample", "subpack", "extras only", "3d.")
USER_AGENT = "bluray-tracker/1.0"

GROUP_PACK_BONUS = {"ivy": 80}
GROUP_EP_BONUS = {"megusta": 80}


def load_env() -> None:
    env = PROJECT_DIR / ".env"
    if env.is_file():
        for line in env.read_text().splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, _, v = line.partition("=")
                os.environ.setdefault(k.strip(), v.strip())


def parse_damage_list(path: Path) -> dict[str, dict[int, list[int]]]:
    series: dict[str, dict[int, list[int]]] = defaultdict(dict)
    current = None
    for raw in path.read_text(encoding="utf-8").splitlines():
        if not raw.strip() or raw.startswith("Totaal:"):
            continue
        m = re.match(r"^\s+S(\d+): (.+)$", raw)
        if m and current:
            eps: list[int] = []
            for part in m.group(2).split(","):
                part = part.strip()
                r = re.match(r"^E(\d+)-E(\d+)$", part)
                if r:
                    eps.extend(range(int(r.group(1)), int(r.group(2)) + 1))
                else:
                    r = re.match(r"^E(\d+)$", part)
                    if r:
                        eps.append(int(r.group(1)))
            series[current][int(m.group(1))] = sorted(set(eps))
        elif not raw.startswith(" "):
            current = raw.strip()
    return dict(series)


def clean_query(title: str) -> str:
    t = unicodedata.normalize("NFKD", title).encode("ascii", "ignore").decode()
    t = re.sub(r"\((?:19|20)\d{2}\)|\(US\)|\(UK\)", " ", t)   # jaartal/land-suffix weg
    t = t.replace("&", "and")
    return re.sub(r"[^A-Za-z0-9]+", " ", t).strip()


def api(params: dict[str, str]) -> list[dict]:
    base = os.environ.get("NZBGEEK_BASE_URL", "https://api.nzbgeek.info").rstrip("/")
    params = {**params, "apikey": os.environ["NZBGEEK_API_KEY"], "o": "xml", "limit": "100"}
    url = f"{base}/api?" + urllib.parse.urlencode(params)
    for attempt in range(3):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
            with urllib.request.urlopen(req, timeout=30) as resp:
                data = resp.read()
            root = ET.fromstring(data)
            if root.tag == "error":
                raise RuntimeError(f"NZBGeek: {root.get('description', 'onbekende fout')}")
            items = []
            for item in root.iter("item"):
                row = {"title": item.findtext("title") or "", "link": item.findtext("link") or ""}
                for attr in item.iter("{http://www.newznab.com/DTD/2010/feeds/attributes/}attr"):
                    row[attr.get("name", "")] = attr.get("value", "")
                items.append(row)
            time.sleep(REQUEST_DELAY)
            return items
        except (urllib.error.URLError, ET.ParseError, OSError) as exc:
            if attempt == 2:
                raise RuntimeError(f"NZBGeek onbereikbaar: {exc}") from exc
            time.sleep(5 * (attempt + 1))
    return []


def resolution_of(name: str) -> str:
    n = name.lower()
    for res in ("2160p", "1080p", "720p"):
        if res in n:
            return res
    return ""


def score(name: str, size: int, group_bonus: dict[str, int]) -> int:
    n = name.lower()
    if any(term in n for term in REJECT_TERMS):
        return -1
    s = {"2160p": 300, "1080p": 200, "720p": 50, "": 0}[resolution_of(n)]
    if "bluray" in n or "blu-ray" in n or "bdrip" in n:
        s += 100
    elif "web" in n:
        s += 40
    if re.search(r"x265|hevc|h\.?265", n):
        s += 20
    for group, bonus in group_bonus.items():
        if re.search(rf"[-.]{group}\b", n):
            s += bonus
    if size and size < 100 * 1024 * 1024:  # verdacht klein
        s -= 200
    return s


def normalize_release(s: str) -> str:
    s = unicodedata.normalize("NFKD", s).encode("ascii", "ignore").decode().lower()
    s = re.sub(r"[._\-]+", " ", s)
    s = re.sub(r"\b(19|20)\d{2}\b", " ", s)   # jaartallen tellen niet mee
    return re.sub(r"\s+", " ", s).strip()


# Alles vóór de seizoensmarkering moet de serienaam zelf zijn — anders matcht
# "Dexter" ook "Dexter.Resurrection" of "the.tourist...dexterous...".
def release_matches_series(release: str, query: str) -> bool:
    m = re.search(r"\bs\d{1,2}(e\d{1,3})?\b|\bseason[ .]?\d", release, re.I)
    prefix = release[: m.start()] if m else release
    prefix = normalize_release(prefix)
    want = normalize_release(query)
    if prefix == want:
        return True
    if prefix.startswith(want + " "):
        rest = prefix[len(want):].strip()
        # korte landsuffix/afko mag ("us", "uk", "md"), een andere titel niet
        return rest in {"us", "uk", "md", "usa"} or len(rest) <= 3
    return False


def is_season_pack(name: str, season: int) -> bool:
    n = name.lower()
    if re.search(rf"s{season:02d}e\d", n):
        return False
    return bool(
        re.search(rf"\bs{season:02d}\b", n)
        or re.search(rf"season[ .]{season}\b", n)
        or "complete" in n
    )


def matches_episode(name: str, season: int, ep: int) -> bool:
    return bool(re.search(rf"s{season:02d}e{ep:02d}\b", name, re.I))


def fetch_nzb(link: str, dest: Path) -> bool:
    try:
        req = urllib.request.Request(link, headers={"User-Agent": USER_AGENT})
        with urllib.request.urlopen(req, timeout=60) as resp:
            content = resp.read()
        if b"<nzb" not in content[:2048].lower():
            return False
        dest.write_bytes(content)
        time.sleep(REQUEST_DELAY)
        return True
    except (urllib.error.URLError, OSError):
        return False


def safe_name(value: str) -> str:
    return re.sub(r'[\\/:*?"<>|\x00-\x1f]+', "_", value).strip(" .")[:200]


def handle_season(serie: str, season: int, eps: list[int], dry: bool, report: list[str],
                  query_override: str | None = None) -> str:
    query = query_override or clean_query(serie)
    want_pack = len(eps) >= PACK_THRESHOLD

    if want_pack:
        items = api({"t": "tvsearch", "q": query, "season": str(season), "cat": CATEGORIES})
        packs = [i for i in items
                 if is_season_pack(i["title"], season)
                 and release_matches_series(i["title"], query)]
        if not packs:
            items = api({"t": "search", "q": f"{query} S{season:02d}", "cat": CATEGORIES})
            packs = [i for i in items
                     if is_season_pack(i["title"], season)
                     and release_matches_series(i["title"], query)]
        packs.sort(key=lambda i: score(i["title"], int(i.get("size", 0) or 0), GROUP_PACK_BONUS),
                   reverse=True)
        packs = [p for p in packs if score(p["title"], int(p.get("size", 0) or 0), GROUP_PACK_BONUS) > 0]
        if packs:
            best = packs[0]
            gb = int(best.get("size", 0) or 0) / 1024**3
            label = f"{serie} - S{season:02d} [PACK] {best['title'][:80]} ({gb:.1f} GB)"
            if dry:
                report.append(f"[DRY-PACK] {label}")
                return "pack"
            dest = OUTPUT_DIR / safe_name(f"{serie} - S{season:02d} - {best['title']}.nzb")
            if fetch_nzb(best["link"], dest):
                report.append(f"[PACK] {label}")
                return "pack"
            report.append(f"[FOUT] pack-download mislukt: {label}")

    # losse afleveringen (fallback of klein gat)
    got, missing = 0, []
    for ep in eps:
        items = api({"t": "tvsearch", "q": query, "season": str(season), "ep": str(ep),
                     "cat": CATEGORIES})
        cands = [i for i in items if matches_episode(i["title"], season, ep)
                 and release_matches_series(i["title"], query)]
        cands.sort(key=lambda i: score(i["title"], int(i.get("size", 0) or 0), GROUP_EP_BONUS),
                   reverse=True)
        cands = [c for c in cands if score(c["title"], int(c.get("size", 0) or 0), GROUP_EP_BONUS) > 0]
        if not cands:
            missing.append(ep)
            continue
        best = cands[0]
        if dry:
            report.append(f"[DRY-EP] {serie} S{season:02d}E{ep:02d}: {best['title'][:80]}")
            got += 1
            continue
        dest = OUTPUT_DIR / safe_name(f"{serie} - S{season:02d}E{ep:02d} - {best['title']}.nzb")
        if fetch_nzb(best["link"], dest):
            got += 1
        else:
            missing.append(ep)
    if missing:
        report.append(f"[GAT] {serie} S{season:02d}: geen release voor "
                      + ", ".join(f"E{e:02d}" for e in missing))
    if got:
        report.append(f"[EPS] {serie} S{season:02d}: {got} losse afleveringen")
    return "eps" if got else "none"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--list", type=Path, default=DEFAULT_LIST)
    ap.add_argument("--serie", help="alleen deze serie (substringmatch)")
    ap.add_argument("--query", help="afwijkende zoekterm (samen met --serie)")
    args = ap.parse_args()

    load_env()
    if not os.environ.get("NZBGEEK_API_KEY"):
        print("FOUT: NZBGEEK_API_KEY ontbreekt in .env", file=sys.stderr)
        return 1

    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    state: dict[str, str] = {}
    if STATE_FILE.is_file():
        state = json.loads(STATE_FILE.read_text())

    series = parse_damage_list(args.list)
    if args.serie:
        series = {k: v for k, v in series.items() if args.serie.lower() in k.lower()}
    total = sum(len(v) for v in series.values())

    report: list[str] = []
    done = 0
    try:
        for serie in sorted(series, key=str.lower):
            for season, eps in sorted(series[serie].items()):
                key = f"{serie}|S{season:02d}"
                done += 1
                if state.get(key) in ("pack", "eps"):
                    continue
                print(f"[{done}/{total}] {serie} S{season:02d} ({len(eps)} afl. missend)...",
                      flush=True)
                try:
                    outcome = handle_season(serie, season, eps, args.dry_run, report,
                                            args.query)
                except RuntimeError as exc:
                    report.append(f"[FOUT] {serie} S{season:02d}: {exc}")
                    print(f"  fout: {exc}", flush=True)
                    continue
                if not args.dry_run:
                    state[key] = outcome
                    STATE_FILE.write_text(json.dumps(state, indent=1))
    finally:
        REPORT_FILE.write_text("\n".join(report) + "\n", encoding="utf-8")
        packs = sum(1 for r in report if r.startswith("[PACK]") or r.startswith("[DRY-PACK]"))
        gaps = sum(1 for r in report if r.startswith("[GAT]"))
        print(f"\nKLAAR: {packs} season packs, "
              f"{sum(1 for r in report if '[EPS]' in r or '[DRY-EP]' in r)} losse-aflevering-regels, "
              f"{gaps} gaten. Rapport: {REPORT_FILE}")
        print(f"NZB's staan in: {OUTPUT_DIR}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
