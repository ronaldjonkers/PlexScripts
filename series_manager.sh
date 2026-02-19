#!/bin/bash
# TV Series Manager – v23 (macOS Bash 3.2 compatible)
# - Converteert naar MKV (behoudt alle audio + subs)
# - Variabele voor logbestanden toegevoegd (standaard uit)
# - Ruime marges voor resolutie herkenning (voorkomt 1080p -> 720p fouten)

set -euo pipefail
export LC_ALL=C

# ---------- Instellingen ----------
ENABLE_LOGGING=false             # Zet op true om een logbestand op te slaan
VT_PRESET=${VT_PRESET:-quality}  # VideoToolbox preset: fast|balanced|quality
X265_PRESET=${X265_PRESET:-slow} # software fallback
NO_BLOAT_RATIO=${NO_BLOAT_RATIO:-0.98}
TOL_PCT=${TOL_PCT:-5}

# ---------- Binaries ----------
need() { command -v "$1" >/dev/null 2>&1 || { echo "FOUT: $1 niet gevonden in PATH"; exit 1; }; }
need HandBrakeCLI
need ffprobe
if command -v python3 >/dev/null 2>&1; then PY=python3; else echo "FOUT: python3 is vereist"; exit 1; fi

ts() { date "+%Y-%m-%d %H:%M:%S"; }

# Logging helper
log_msg() {
    local msg="$1"
    local target_log="$2"
    echo "$msg"
    if [ "$ENABLE_LOGGING" = true ]; then
        echo "$msg" >> "$target_log"
    fi
}

# ---------- Hulp-functies ----------
stat_bytes() { /usr/bin/stat -f %z -- "$1"; }

wh() {
  ffprobe -v error -select_streams v:0 -show_entries stream=width,height \
    -of csv=p=0:s=x -- "$1" 2>/dev/null | head -n1
}

dur_secs() {
  local d
  d=$(ffprobe -v error -show_entries format=duration -of default=nokey=1:noprint_wrappers=1 -- "$1" 2>/dev/null | head -n1)
  DUR_STR="$d" "$PY" - <<'PY'
import os, math
s=os.environ.get("DUR_STR","").strip()
try:
    v=float(s)
    print(int(v+0.5))
except:
    print(0)
PY
}

audio_sum_kbps() {
  local sum=0 line kb
  while IFS= read -r line; do
    kb=$(echo "$line" | tr -cd '0-9')
    if [ -n "$kb" ]; then
      sum=$(( sum + kb/1000 ))
    fi
  done < <(ffprobe -v error -select_streams a -show_entries stream=bit_rate -of default=nokey=1:noprint_wrappers=1 -- "$1" 2>/dev/null || true)
  [ "$sum" -le 0 ] && sum=256
  echo "$sum"
}

video_kbps_measured() {
  local f="$1" vkb a_kb cont
  vkb=$(ffprobe -v error -select_streams v:0 -show_entries stream=bit_rate -of default=nokey=1:noprint_wrappers=1 -- "$f" 2>/dev/null | head -n1 | tr -cd '0-9')
  if [ -n "$vkb" ] && [ "$vkb" -gt 0 ]; then
    echo $(( vkb/1000 ))
    return
  fi
  a_kb=$(audio_sum_kbps "$f")
  cont=$(ffprobe -v error -show_entries format=bit_rate -of default=nokey=1:noprint_wrappers=1 -- "$f" 2>/dev/null | head -n1 | tr -cd '0-9')
  if [ -n "$cont" ] && [ "$cont" -gt 0 ]; then
    local total=$(( cont/1000 ))
    local vk=$(( total - a_kb ))
    [ "$vk" -lt 500 ] && vk=500
    echo "$vk"; return
  fi
  echo 0
}

percent_diff_ok() {
  local actual="$1" target="$2" tol="$3"
  if [ "$actual" -le 0 ] || [ "$target" -le 0 ]; then echo 0; return; fi
  local pct=$("$PY" - <<PY
a=${actual}; t=${target}
print(int((abs(a-t)*100.0/t)+0.5))
PY
)
  [ "$pct" -le "$tol" ] && echo 1 || echo 0
}

estimate_bytes() {
  local vb="$1" ab="$2" dur="$3"
  "$PY" - <<PY
vb=${vb}; ab=${ab}; d=${dur}
tot_kbps = (vb if vb>0 else 0) + (ab if ab>0 else 0)
print(int(tot_kbps*1000.0*d/8.0))
PY
}

b2mb() { echo $(( (${1:-0} / 1024) / 1024 )); }

append_tag_to_name() {
  local f="$1" res="$2" mb="$3"
  local dir base ext
  dir="$(dirname "$f")"; base="$(basename "$f")"
  base="${base%.*}"
  # Verwijder oude tags (mp4 en mkv)
  base="$(echo "$base" | sed -E 's/\.(2160p|1080p|720p|480p)\.[0-9]+mb$//')"
  echo "${dir}/${base}.${res}.${mb}mb.mkv"
}

# ---------- Profielkeuze ----------
choose_profile() {
  echo "Kies een kwaliteitsprofiel:"
  echo "  1) UltraSaver    (2160p=7   Mbps, 1080p=3,    720p=1)"
  echo "  2) DataDiet      (2160p=8   Mbps, 1080p=4,    720p=1.5)"
  echo "  3) StreamSaver   (2160p=10 Mbps, 1080p=5,    720p=2.5)"
  echo "  4) Netflix-ish   (2160p=12 Mbps, 1080p=6,    720p=3)"
  echo "  5) CrispCable    (2160p=16 Mbps, 1080p=8,    720p=4)"
  echo "  6) ArchivalLite (2160p=20 Mbps, 1080p=10,  720p=5)"
  echo "  7) MaxPunch      (2160p=24 Mbps, 1080p=12,  720p=6)"
  read -p "Maak een keuze [1-7]: " -r choice
  case "$choice" in
    1) PNAME="UltraSaver";   VB2160=7000;  VB1080=3000; VB720=1000 ;;
    2) PNAME="DataDiet";     VB2160=8000;  VB1080=4000; VB720=1500 ;;
    3) PNAME="StreamSaver";  VB2160=10000; VB1080=5000; VB720=2500 ;;
    4) PNAME="Netflix-ish";  VB2160=12000; VB1080=6000; VB720=3000 ;;
    5) PNAME="CrispCable";   VB2160=16000; VB1080=8000; VB720=4000 ;;
    6) PNAME="ArchivalLite"; VB2160=20000; VB1080=10000; VB720=5000 ;;
    7) PNAME="MaxPunch";     VB2160=24000; VB1080=12000; VB720=6000 ;;
    *) echo "Ongeldige keuze"; exit 1;;
  esac
  echo "[$(ts)] Profiel: ${PNAME}"
}

# ---------- Encode ----------
encode_one() {
  local src="$1" vb="$2" out="$3" logf="$4"
  log_msg "[$(ts)]   [ENC] VT 10-bit naar $(basename "$out")" "$logf"
  
  if HandBrakeCLI -i "$src" -o "$out" \
      --format mkv \
      -e vt_h265_10bit --vb "$vb" --encoder-preset "$VT_PRESET" \
      --all-audio --aencoder copy \
      --all-subtitles --subtitle-burned=none \
      >>"$logf" 2>&1 </dev/null; then
    log_msg "[$(ts)]   [OK] VT gereed" "$logf"
    return 0
  fi

  log_msg "[$(ts)]   [WARN] VT faalde, probeer x265" "$logf"
  if HandBrakeCLI -i "$src" -o "$out" \
      --format mkv \
      -e x265 --vb "$vb" --two-pass --turbo \
      --encoder-profile main10 --encoder-preset "$X265_PRESET" \
      --all-audio --aencoder copy \
      --all-subtitles --subtitle-burned=none \
      >>"$logf" 2>&1 </dev/null; then
    log_msg "[$(ts)]   [OK] x265 gereed" "$logf"
    return 0
  fi

  log_msg "[$(ts)]   [ERR] Encode mislukt" "$logf"
  return 1
}

# ---------- Verwerking ----------
process_one() {
  local file="$1" do_delete="$2" LOGFILE="$3"
  [ -f "$file" ] || return 0

  log_msg "[$(ts)] ----------------------------------------------------------------" "$LOGFILE"
  log_msg "[$(ts)] Bestand: $file" "$LOGFILE"

  local geom w h
  geom="$(wh "$file")" || geom="0x0"
  if printf '%s' "$geom" | grep -q 'x'; then
    w="${geom%x*}"; h="${geom#*x}"
  else
    set -- $geom
    w="${1:-0}"; h="${2:-0}"
  fi
  w="$(printf '%s' "$w" | tr -cd '0-9')"
  
  # Resolutie bepalen met ruime marges voor gecropte content
  local res
  if [ -n "$w" ] && [ "$w" -ge 2500 ]; then res=2160p
  elif [ -n "$w" ] && [ "$w" -ge 1600 ]; then res=1080p
  elif [ -n "$w" ] && [ "$w" -ge 900 ]; then res=720p
  else res=480p
  fi

  local target_vb
  case "$res" in
    2160p) target_vb=$VB2160;;
    1080p) target_vb=$VB1080;;
    720p)  target_vb=$VB720;;
    *)     target_vb=$VB720;;
  esac

  local dur secs; secs="$(dur_secs "$file")"
  local v_meas a_kbps
  v_meas="$(video_kbps_measured "$file")"
  a_kbps="$(audio_sum_kbps "$file")"

  # Al goed?
  if [ "$(percent_diff_ok "$v_meas" "$target_vb" "$TOL_PCT")" = "1" ]; then
    local mb=$(( (target_vb + 500) / 1000 ))
    local newname; newname="$(append_tag_to_name "$file" "$res" "$mb")"
    if [ "$newname" != "$file" ]; then
      log_msg "[$(ts)]   [RENAME] naar $(basename "$newname")" "$LOGFILE"
      mv -n -- "$file" "$newname"
    else
      log_msg "[$(ts)]   [SKIP] Al goed en naam klopt" "$LOGFILE"
    fi
    return 0
  fi

  local src_bytes limit est out mb
  src_bytes="$(stat_bytes "$file")"
  limit=$(( src_bytes * 98 / 100 ))
  est="$(estimate_bytes "$target_vb" "$a_kbps" "$secs")"
  
  mb=$(( (target_vb + 500) / 1000 ))
  out="$(append_tag_to_name "$file" "$res" "$mb")"

  if [ "$est" -ge "$limit" ]; then
    log_msg "[$(ts)]   [SKIP] No-bloat: schatting te groot, alleen hernoemen" "$LOGFILE"
    if [ "$out" != "$file" ]; then
      mv -n -- "$file" "$out"
    fi
    return 0
  fi

  if encode_one "$file" "$target_vb" "$out" "$LOGFILE"; then
    if [ "$do_delete" = "y" ] || [ "$do_delete" = "Y" ]; then
      log_msg "[$(ts)]   [DEL] Origineel verwijderd" "$LOGFILE"
      rm -f -- "$file"
    fi
  else
    return 1
  fi
}

# ---------- MAIN ----------
choose_profile
read -p "Bron bestand of map (recursief): " -r SRC
SRC=$(printf '%s' "$SRC" | sed -E 's/[[:space:]]+$//')
read -p "Origineel verwijderen na succesvolle conversie? [y/N]: " -r DEL

ROOT="$SRC"
[ -f "$SRC" ] && ROOT="$(dirname "$SRC")"
LOGFILE="${ROOT%/}/tvseries_manager_v23.log"

if [ "$ENABLE_LOGGING" = true ]; then
    : > "$LOGFILE"
fi

log_msg "[$(ts)] === TV Series Manager v23 start ===" "$LOGFILE"

if [ -d "$SRC" ]; then
  find "$SRC" -type f \( -iname "*.mp4" -o -iname "*.mkv" -o -iname "*.mov" -o -iname "*.avi" \) -print0 | \
  while IFS= read -r -d '' f; do
    process_one "$f" "$DEL" "$LOGFILE"
  done
elif [ -f "$SRC" ]; then
  process_one "$SRC" "$DEL" "$LOGFILE"
else
  echo "[$(ts)] Niet gevonden: $SRC"
  exit 1
fi

log_msg "[$(ts)] === Klaar ===" "$LOGFILE"