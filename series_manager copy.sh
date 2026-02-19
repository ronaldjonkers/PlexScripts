#!/bin/bash
# TV Series Manager – v21 (macOS Bash 3.2 compatible)
# - Converteert afleveringen naar vaste video-bitrate per resolutie (profielen)
# - Resolutie blijft gelijk aan bron (geen up/downscale)
# - ALLE audio + subtitles 1:1 kopiëren (MKV container) maar extensie .mp4 (zoals gevraagd)
# - Herbenoemt bestanden naar: "<basename>.<res>.<mb>mb.mp4"
# - Slaat conversie over als huidige video-bitrate al binnen ±5% van target ligt (rename only)
# - Eén grote log in de opgegeven root map
# - Recursief door submappen
#
# Vereist: HandBrakeCLI, ffprobe (ffmpeg), python3

set -euo pipefail
export LC_ALL=C

# ---------- Instellingen ----------
VT_PRESET=${VT_PRESET:-quality}   # VideoToolbox preset: fast|balanced|quality
X265_PRESET=${X265_PRESET:-slow}  # software fallback

# Skip conversie als verwachte totale outputgrootte >= NO_BLOAT_RATIO * bron
NO_BLOAT_RATIO=${NO_BLOAT_RATIO:-0.98}

# Tolerantie voor "al goed": ±5%
TOL_PCT=${TOL_PCT:-5}

# ---------- Binaries ----------
need() { command -v "$1" >/dev/null 2>&1 || { echo "FOUT: $1 niet gevonden in PATH"; exit 1; }; }
need HandBrakeCLI
need ffprobe
if command -v python3 >/dev/null 2>&1; then PY=python3; else echo "FOUT: python3 is vereist"; exit 1; fi

ts() { date "+%Y-%m-%d %H:%M:%S"; }

# ---------- Hulp-functies ----------
# Lees bytes
stat_bytes() { /usr/bin/stat -f %z -- "$1"; }

# Breedte/hoogte lezen (robust)
wh() {
  ffprobe -v error -select_streams v:0 -show_entries stream=width,height \
    -of csv=p=0:s=x -- "$1" 2>/dev/null | head -n1
}

# Duur in seconden (afgerond)
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

# Som audio bitrates (kbps); fallback 256 als onbekend
audio_sum_kbps() {
  local sum=0 line kb
  while IFS= read -r line; do
    kb=$(echo "$line" | tr -cd '0-9')
    if [ -n "$kb" ]; then
      # ffprobe geeft bps; converteer naar kbps
      sum=$(( sum + kb/1000 ))
    fi
  done < <(ffprobe -v error -select_streams a -show_entries stream=bit_rate -of default=nokey=1:noprint_wrappers=1 -- "$1" 2>/dev/null || true)
  [ "$sum" -le 0 ] && sum=256
  echo "$sum"
}

# Video bitrate (kbps) meten van v:0; fallback container - audio
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

# Resolutie label op basis van breedte
res_label_from_w() {
  local w="$1"
  if [ "$w" -ge 3800 ]; then echo 2160p; return; fi
  if [ "$w" -ge 1900 ]; then echo 1080p; return; fi
  if [ "$w" -ge 1260 ]; then echo 720p; return; fi
  echo 480p
}

# % verschil binnen toleranties?
percent_diff_ok() {
  local actual="$1" target="$2" tol="$3"
  if [ "$actual" -le 0 ] || [ "$target" -le 0 ]; then echo 0; return; fi
  local diff=$(( actual>target ? actual-target : target-actual ))
  local pct=$("$PY" - <<PY
a=${actual}; t=${target}
print(int((abs(a-t)*100.0/t)+0.5))
PY
)
  [ "$pct" -le "$tol" ] && echo 1 || echo 0
}

# Bytes schatting vanuit (vb + ab) * duur
estimate_bytes() {
  local vb="$1" ab="$2" dur="$3"
  "$PY" - <<PY
vb=${vb}; ab=${ab}; d=${dur}
tot_kbps = (vb if vb>0 else 0) + (ab if ab>0 else 0)
print(int(tot_kbps*1000.0*d/8.0))
PY
}

b2mb() { echo $(( (${1:-0} / 1024) / 1024 )); }

# Plak tag op naam: <base>.<RES>.<MB>mb.mp4 (eerst bestaande tags verwijderen)
append_tag_to_name() {
  local f="$1" res="$2" mb="$3"
  local dir base ext
  dir="$(dirname "$f")"; base="$(basename "$f")"
  ext="${base##*.}"; base="${base%.*}"
  # verwijder eventuele .1080p.8mb suffix
  base="$(echo "$base" | sed -E 's/\.(2160p|1080p|720p|480p)\.[0-9]+mb$//')"
  echo "${dir}/${base}.${res}.${mb}mb.mp4"
}

# ---------- Profielkeuze ----------
choose_profile() {
  echo "Kies een kwaliteitsprofiel:"
  echo "  1) UltraSaver   (2160p=7  Mbps, 1080p=3,   720p=1)"
  echo "  2) DataDiet     (2160p=8  Mbps, 1080p=4,   720p=1.5)"
  echo "  3) StreamSaver  (2160p=10 Mbps, 1080p=5,   720p=2.5)"
  echo "  4) Netflix-ish  (2160p=12 Mbps, 1080p=6,   720p=3)"
  echo "  5) CrispCable   (2160p=16 Mbps, 1080p=8,   720p=4)"
  echo "  6) ArchivalLite (2160p=20 Mbps, 1080p=10,  720p=5)"
  echo "  7) MaxPunch     (2160p=24 Mbps, 1080p=12,  720p=6)"
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
  echo "[$(ts)] Profiel: ${PNAME} (2160p=${VB2160}kbps, 1080p=${VB1080}kbps, 720p=${VB720}kbps)"
}

# ---------- Encode ----------
encode_one() {
  local src="$1" vb="$2" out="$3" logf="$4"
  echo "[$(ts)]   [ENC] VT 10-bit → $(basename "$out")" | tee -a "$logf"
  # Probeer VideoToolbox
  if HandBrakeCLI -i "$src" -o "$out" \
      --format mkv \
      -e vt_h265_10bit --vb "$vb" --encoder-preset "$VT_PRESET" \
      --all-audio --aencoder copy \
      --all-subtitles --subtitle-burned=none \
      >>"$logf" 2>&1 </dev/null; then
    echo "[$(ts)]   [OK] VT gereed" | tee -a "$logf"
    return 0
  fi
  echo "[$(ts)]   [WARN] VT faalde → x265" | tee -a "$logf"
  # Fallback x265
  if HandBrakeCLI -i "$src" -o "$out" \
      --format mkv \
      -e x265 --vb "$vb" --two-pass --turbo \
      --encoder-profile main10 --encoder-preset "$X265_PRESET" \
      --all-audio --aencoder copy \
      --all-subtitles --subtitle-burned=none \
      >>"$logf" 2>&1 </dev/null; then
    echo "[$(ts)]   [OK] x265 gereed" | tee -a "$logf"
    return 0
  fi
  echo "[$(ts)]   [ERR] x265 ook gefaald" | tee -a "$logf"
  return 1
}

# ---------- Verwerking van één bestand ----------
process_one() {
  local file="$1" do_delete="$2" LOGFILE="$3"
  [ -f "$file" ] || return 0

  echo "[$(ts)] ----------------------------------------------------------------" | tee -a "$LOGFILE"
  echo "[$(ts)] Bestand: $file" | tee -a "$LOGFILE"

  # Lees w,h en duur
  local geom w h
  geom="$(wh "$file")" || geom="0x0"
  # geom als "WIDTHxHEIGHT"
  if printf '%s' "$geom" | grep -q 'x'; then
    w="${geom%x*}"; h="${geom#*x}"
  else
    # fallback: probeer spaties
    set -- $geom
    w="${1:-0}"; h="${2:-0}"
  fi
  w="$(printf '%s' "$w" | tr -cd '0-9')"
  h="$(printf '%s' "$h" | tr -cd '0-9')"

  local dur secs; secs="$(dur_secs "$file")"
  echo "[$(ts)]   Bron: ${w}x${h} → ?, duur ${secs}s" | tee -a "$LOGFILE"

  # Resolutie label
  local res
  if [ -n "$w" ] && [ "$w" -ge 3800 ]; then res=2160p
  elif [ -n "$w" ] && [ "$w" -ge 1900 ]; then res=1080p
  elif [ -n "$w" ] && [ "$w" -ge 1260 ]; then res=720p
  else res=480p
  fi

  # Target vb
  local target_vb
  case "$res" in
    2160p) target_vb=$VB2160;;
    1080p) target_vb=$VB1080;;
    720p)  target_vb=$VB720;;
    *)     target_vb=$VB720;;
  esac

  local v_meas a_kbps
  v_meas="$(video_kbps_measured "$file")"
  a_kbps="$(audio_sum_kbps "$file")"
  echo "[$(ts)]   Bron label: ${res} | Target video bitrate: ${target_vb} kbps (gemeten ~${v_meas} kbps)" | tee -a "$LOGFILE"

  # Al goed? binnen ±TOL_PCT
  if [ "$(percent_diff_ok "$v_meas" "$target_vb" "$TOL_PCT")" = "1" ]; then
    local mb=$(( (target_vb + 500) / 1000 ))
    local newname; newname="$(append_tag_to_name "$file" "$res" "$mb")"
    if [ "$newname" != "$file" ]; then
      echo "[$(ts)]   [RENAME] → $(basename "$newname")" | tee -a "$LOGFILE"
      mv -n -- "$file" "$newname"
    else
      echo "[$(ts)]   [SKIP] Al goed + naam oké" | tee -a "$LOGFILE"
    fi
    return 0
  fi

  # No-bloat check (schatting vs bron)
  local src_bytes limit est out mb
  src_bytes="$(stat_bytes "$file")"
  limit=$(( src_bytes * 98 / 100 ))
  est="$(estimate_bytes "$target_vb" "$a_kbps" "$secs")"
  echo "[$(ts)]   [Plan] target=${target_vb}kbps | est=$(b2mb "$est")MB | src=$(b2mb "$src_bytes")MB | limit=$(b2mb "$limit")MB" | tee -a "$LOGFILE"

  mb=$(( (target_vb + 500) / 1000 ))
  out="$(append_tag_to_name "$file" "$res" "$mb")"

  if [ "$est" -ge "$limit" ]; then
    echo "[$(ts)]   [SKIP] No-bloat: schatting ≥ ${NO_BLOAT_RATIO}× bron → alleen hernoemen" | tee -a "$LOGFILE"
    if [ "$out" != "$file" ]; then
      echo "[$(ts)]   [RENAME] → $(basename "$out")" | tee -a "$LOGFILE"
      mv -n -- "$file" "$out"
    fi
    return 0
  fi

  # Encode
  if encode_one "$file" "$target_vb" "$out" "$LOGFILE"; then
    # Optioneel origineel verwijderen
    if [ "$do_delete" = "y" ] || [ "$do_delete" = "Y" ]; then
      echo "[$(ts)]   [DEL] Origineel verwijderd" | tee -a "$LOGFILE"
      rm -f -- "$file"
    else
      echo "[$(ts)]   [KEEP] Origineel bewaard" | tee -a "$LOGFILE"
    fi
  else
    echo "[$(ts)]   [ERR] Encode mislukt" | tee -a "$LOGFILE"
    return 1
  fi
}

# ---------- MAIN ----------
choose_profile
read -p "Bron bestand of map (recursief): " -r SRC
SRC=$(printf '%s' "$SRC" | sed -E 's/[[:space:]]+$//')
read -p "Origineel verwijderen na succesvolle conversie? [y/N]: " -r DEL

# Log in root map (indien map), anders in huidige dir
ROOT="$SRC"
[ -f "$SRC" ] && ROOT="$(dirname "$SRC")"
LOGFILE="${ROOT%/}/tvseries_manager_v21.log"

echo "[$(ts)] === TV Series Manager v21 start (PROFILE=${PNAME}; TOL=${TOL_PCT}%; NO_BLOAT=${NO_BLOAT_RATIO}) ===" | tee -a "$LOGFILE"

if [ -d "$SRC" ]; then
  echo "[$(ts)] Verwerken map: ${SRC} (recursief)" | tee -a "$LOGFILE"
  # Gebruik find -print0 en lees met while
  find "$SRC" -type f \( -iname "*.mp4" -o -iname "*.mkv" -o -iname "*.mov" \) -print0 | \
  while IFS= read -r -d '' f; do
    process_one "$f" "$DEL" "$LOGFILE"
  done
elif [ -f "$SRC" ]; then
  process_one "$SRC" "$DEL" "$LOGFILE"
else
  echo "[$(ts)] Niet gevonden: $SRC" | tee -a "$LOGFILE"
  exit 1
fi

echo "[$(ts)] === Klaar ===" | tee -a "$LOGFILE"