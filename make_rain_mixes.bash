#!/usr/bin/env bash
set -euo pipefail

# --- config you can tweak ----------------------------------------------------

# Clean-up stage
LOWPASS_HZ=12000         # keep highs natural; 10000–13000 is a good range
DENOISE_NF=-20           # afftdn noise floor (dB). -25 stronger, -15 gentler
CLEAN_BITRATE=256k

# Pink-noise bed
PINK_WEIGHT=0.30         # 0.2 subtle • 0.3 natural • 0.4 thick

# Room feel (very gentle echo for patio reflections)
# aecho = in_gain:out_gain:delays(ms):decays
ECHO_ON=1                # 1 = enable, 0 = disable
ECHO_PARAMS="0.6:0.8:120:0.3"

# Loop splice
XFADE_SECONDS=3          # 2–5s triangular crossfade end->start

# Final loudness + codec
FINAL_BITRATE=256k
SAMPLE_RATE=44100        # keep consistent across outputs

# Phone mix (narrower band, kinder to tiny drivers)
PHONE_LOWPASS=9000
PHONE_HIGHPASS=200
PHONE_BITRATE=160k

# Sub/room mix (mild bass lift; furniture already helps)
BASS_GAIN_DB=6           # try 3–8 dB
BASS_FREQ=80             # Hz center
BASS_WIDTH=1.5           # Q-ish width (higher = wider)
ROOM_LOWPASS=12000

# Optional distant storm undertone
RUMBLE_ON=0              # 1 = create rumble variant
RUMBLE_FREQ=40           # Hz (felt, not heard)
RUMBLE_LEVEL=0.02        # 0.01–0.03 is subtle
RUMBLE_WEIGHT=0.30       # mix level vs rain track

# --- sanity checks -----------------------------------------------------------

if ! command -v ffmpeg >/dev/null 2>&1 || ! command -v ffprobe >/dev/null 2>&1; then
  echo "Please install ffmpeg (and ffprobe)."
  exit 1
fi

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <input-audio-file>"
  exit 1
fi

IN="$1"
if [[ ! -f "$IN" ]]; then
  echo "Input file not found: $IN"
  exit 1
fi

# Derive names
BASE="${IN%.*}"
OUT_DIR="${BASE}_renders"
mkdir -p "$OUT_DIR"

# Duration (seconds, rounded up) for generated pink noise / rumble
DUR_RAW="$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$IN")"
DUR="${DUR_RAW%.*}"
if [[ -z "${DUR}" || "${DUR}" -le 0 ]]; then DUR=3720; fi  # fallback ~62m

# --- 1) Clean: low-pass + gentle denoise ------------------------------------

CLEAN="${OUT_DIR}/rain_clean.mp3"
echo ">> Cleaning -> $CLEAN"
ffmpeg -y -i "$IN" -ar "$SAMPLE_RATE" \
  -af "lowpass=f=${LOWPASS_HZ},afftdn=nf=${DENOISE_NF}" \
  -map_metadata 0 -c:a libmp3lame -b:a "$CLEAN_BITRATE" "$CLEAN" >/dev/null

# --- 2) Layer: pink noise bed + optional gentle echo ------------------------

MIX="${OUT_DIR}/rain_mixed.mp3"
ECHO_FILTER=""
if [[ "$ECHO_ON" -eq 1 ]]; then
  ECHO_FILTER=",aecho=${ECHO_PARAMS}"
fi

echo ">> Adding pink-noise bed (weight=${PINK_WEIGHT}) -> $MIX"
ffmpeg -y -i "$CLEAN" -filter_complex \
  "anoisesrc=color=pink:duration=${DUR}:sample_rate=${SAMPLE_RATE}[p];[0][p]amix=inputs=2:weights=1 ${PINK_WEIGHT},volume=1.0${ECHO_FILTER}" \
  -ar "$SAMPLE_RATE" -map_metadata 0 -c:a libmp3lame -b:a "$FINAL_BITRATE" "$MIX" >/dev/null

# --- 3) Seamless splice: end -> start crossfade ------------------------------

LOOP="${OUT_DIR}/rain_loop.mp3"
echo ">> Making seamless loop (acrossfade ${XFADE_SECONDS}s) -> $LOOP"
ffmpeg -y -i "$MIX" -ar "$SAMPLE_RATE" \
  -af "acrossfade=d=${XFADE_SECONDS}:o=0:c1=tri:c2=tri" \
  -map_metadata 0 -c:a libmp3lame -b:a "$FINAL_BITRATE" "$LOOP" >/dev/null

# --- 4) Normalize overall loudness ------------------------------------------

FINAL="${OUT_DIR}/rain_final.mp3"
echo ">> Loudness normalize -> $FINAL"
ffmpeg -y -i "$LOOP" -ar "$SAMPLE_RATE" \
  -af "loudnorm" \
  -map_metadata 0 -c:a libmp3lame -b:a "$FINAL_BITRATE" "$FINAL" >/dev/null

# --- 5) Phone-friendly export -----------------------------------------------

PHONE="${OUT_DIR}/rain_phone.mp3"
echo ">> Phone mix (HP ${PHONE_HIGHPASS}Hz, LP ${PHONE_LOWPASS}Hz) -> $PHONE"
ffmpeg -y -i "$FINAL" -ar "$SAMPLE_RATE" \
  -af "highpass=f=${PHONE_HIGHPASS},lowpass=f=${PHONE_LOWPASS}" \
  -map_metadata 0 -c:a libmp3lame -b:a "$PHONE_BITRATE" "$PHONE" >/dev/null

# --- 6) Sub/room-friendly export --------------------------------------------

ROOM="${OUT_DIR}/rain_room.mp3"
echo ">> Room mix (bass +${BASS_GAIN_DB}dB @${BASS_FREQ}Hz) -> $ROOM"
ffmpeg -y -i "$FINAL" -ar "$SAMPLE_RATE" \
  -af "bass=g=${BASS_GAIN_DB}:f=${BASS_FREQ}:w=${BASS_WIDTH},lowpass=f=${ROOM_LOWPASS}" \
  -map_metadata 0 -c:a libmp3lame -b:a "$FINAL_BITRATE" "$ROOM" >/dev/null

# --- 7) Optional distant-storm undertone ------------------------------------

if [[ "$RUMBLE_ON" -eq 1 ]]; then
  RUMBLE="${OUT_DIR}/lowrumble.wav"
  STORM="${OUT_DIR}/rain_distantstorm.mp3"
  echo ">> Generating distant rumble (${RUMBLE_FREQ}Hz) -> mixing to $STORM"
  ffmpeg -y -f lavfi -i "sine=frequency=${RUMBLE_FREQ}:duration=${DUR}:sample_rate=${SAMPLE_RATE}" \
    -filter:a "volume=${RUMBLE_LEVEL}" -ar "$SAMPLE_RATE" "$RUMBLE" >/dev/null

  ffmpeg -y -i "$ROOM" -i "$RUMBLE" -filter_complex \
    "[0][1]amix=inputs=2:weights=1 ${RUMBLE_WEIGHT},volume=1.0" \
    -ar "$SAMPLE_RATE" -map_metadata 0 -c:a libmp3lame -b:a "$FINAL_BITRATE" "$STORM" >/dev/null
fi

echo "Done. Files in: $OUT_DIR"
ls -lh "$OUT_DIR"

