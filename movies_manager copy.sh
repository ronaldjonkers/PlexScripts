#!/bin/bash
# Movie Manager - v28 (macOS Bash 3.2 compatible)
# - FIX: Volledige structuur hersteld om 'command not found' te voorkomen
# - FIX: HandBrake vreet stdin niet meer leeg
# - Hernoemt film naar: Naam.Resolutie.Bitrate.mkv
# - SRT files worden NIET hernoemd

set -euo pipefail
export LC_ALL=C

# ---------- Instellingen ----------
VT_PRESET=${VT_PRESET:-quality}
X265_PRESET=${X265_PRESET:-slow}
TOL_PCT=${TOL_PCT:-5}

# ---------- Binaries ----------
need() { command -v "$1" >/dev/null 2>&1 || { echo "FOUT: $1 niet gevonden in PATH"; exit 1; }; }
need HandBrakeCLI
need ffprobe
if command -v python3 >/dev/null 2>&1; then PY=python3; else echo "FOUT: python3 is vereist"; exit 1; fi

ts() { date "+%Y-%m-%d %H:%M:%S"; }

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

generate_new_name() {
  local f="$1" res="$2" vb="$3"
  local dir base mb
  dir="$(dirname "$f")"
  base="$(basename "$f")"
  base="${base%.*}"
  base="$(echo "$base" | sed -E 's/\.(2160p|1080p|720p|480p)\.[0-9]+mb$//')"
  mb=$(( (vb + 500) / 1000 ))
  echo "${dir}/${base}.${res}.${mb}mb.mkv"
}

choose_profile() {
  echo "Kies een kwaliteitsprofiel voor films:"
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

encode_one() {
  local src="$1" vb="$2" out="$3"
  echo "[$(ts)]   [ENC] VideoToolbox naar $(basename "$out")"
  if HandBrakeCLI -i "$src" -o "$out" \
      --format mkv \
      -e vt_h265_10bit --vb "$vb" --encoder-preset "$VT_PRESET" \
      --all-audio --aencoder copy \
      --all-subtitles --subtitle-burned=none \
      < /dev/null >/dev/null 2>&1; then
    echo "[$(ts)]   [OK] Klaar"
    return 0
  fi
  echo "[$(ts)]   [WARN] VT faalde, probeer x265"
  if HandBrakeCLI -i "$src" -o "$out" \
      --format mkv \
      -e x265 --vb "$vb" --two-pass --turbo \
      --encoder-profile main10 --encoder-preset "$X265_PRESET" \
      --all-audio --aencoder copy \
      --all-subtitles --subtitle-burned=none \
      < /dev/null >/dev/null 2>&1; then
    echo "[$(ts)]   [OK] x265 gereed"
    return 0
  fi
  return 1
}

process_one() {
  local file="$1" do_delete="$2"
  [ -f "$file" ] || return 0
  echo "[$(ts)] ----------------------------------------------------------------"
  echo "[$(ts)] Film: $file"
  local geom w res target_vb
  geom="$(wh "$file")" || geom="0x0"
  w="$(printf '%s' "${geom%x*}" | tr -cd '0-9')"
  if [ -n "$w" ] && [ "$w" -ge 2500 ]; then res=2160p
  elif [ -n "$w" ] && [ "$w" -ge 1600 ]; then res=1080p
  else res=720p; fi
  case "$res" in
    2160p) target_vb=$VB2160;;
    1080p) target_vb=$VB1080;;
    *)     target_vb=$VB720;;
  esac
  local out; out="$(generate_new_name "$file" "$res" "$target_vb")"
  local v_meas; v_meas="$(video_kbps_measured "$file")"
  if [ "$(percent_diff_ok "$v_meas" "$target_vb" "$TOL_PCT")" = "1" ]; then
    if [ "$file" != "$out" ]; then
      echo "[$(ts)]   [RENAME] Alleen hernoemen"
      mv -n -- "$file" "$out"
    fi
    return 0
  fi
  local dur secs a_kbps src_bytes limit est
  dur="$(dur_secs "$file")"; a_kbps="$(audio_sum_kbps "$file")"
  src_bytes="$(stat_bytes "$file")"; limit=$(( src_bytes * 98 / 100 ))
  est="$(estimate_bytes "$target_vb" "$a_kbps" "$dur")"
  if [ "$est" -ge "$limit" ]; then
    echo "[$(ts)]   [SKIP] Alleen hernoemen"
    if [ "$file" != "$out" ]; then mv -n -- "$file" "$out"; fi
    return 0
  fi
  if encode_one "$file" "$target_vb" "$out"; then
    if [ "$do_delete" = "y" ] || [ "$do_delete" = "Y" ]; then
      if [ "$file" != "$out" ]; then rm -f -- "$file"; fi
    fi
  fi
}

# ---------- MAIN EXECUTION ----------
choose_profile
read -p "Bron bestand of map (films): " -r SRC
SRC=$(printf '%s' "$SRC" | sed -E 's/[[:space:]]+$//')
read -p "Origineel verwijderen na succesvolle conversie? [y/N]: " -r DEL

echo "[$(ts)] === Movie Manager v28 start ==="

if [ -d "$SRC" ]; then
  while IFS= read -r -d '' f <&3; do
    process_one "$f" "$DEL"
  done 3< <(find "$SRC" -type f \( -iname "*.mp4" -o -iname "*.mkv" -o -iname "*.mov" -o -iname "*.avi" \) -print0)
elif [ -f "$SRC" ]; then
  process_one "$SRC" "$DEL"
fi

echo "[$(ts)] === Klaar ==="