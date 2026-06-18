#!/usr/bin/env bash
# Generates a Dreame vacuum voice_pack.tar.gz using a local Piper TTS model.
# Audio spec confirmed from existing GLaDOS pack: Ogg Vorbis, mono, 16 kHz, ~100 kbps.
# Uses python3 -m piper (piper-tts pip package) which bundles onnxruntime — no
# dylib headaches from the standalone macOS binary release.
set -euo pipefail

# Ensure Homebrew (Apple Silicon + Intel) is in PATH so ffmpeg is found.
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODEL="$SCRIPT_DIR/piper/en_US-trump-high.onnx"
CSV="$SCRIPT_DIR/sound_list.csv"
OUTPUT_DIR="$SCRIPT_DIR/output"
PACK_OUT="$SCRIPT_DIR/voice_pack.tar.gz"

# ---- Dependency checks --------------------------------------------------------
python3 -m piper --help &>/dev/null || {
    echo "ERROR: piper-tts not installed. Run: pip3 install piper-tts"
    exit 1
}
[[ -f "$MODEL" ]] || {
    echo "ERROR: model file not found at: $MODEL"
    exit 1
}
command -v ffmpeg &>/dev/null || {
    echo "ERROR: ffmpeg not found. Install with: brew install ffmpeg"
    exit 1
}
command -v oggenc &>/dev/null || {
    echo "ERROR: oggenc not found. Install with: brew install vorbis-tools"
    exit 1
}
[[ -f "$CSV" ]] || {
    echo "ERROR: sound_list.csv not found at: $CSV"
    exit 1
}

mkdir -p "$OUTPUT_DIR"

# ---- Temp files (raw piper output + loudnorm-processed; cleaned up on exit) --
TMP_WAV=$(mktemp /tmp/dreame_XXXXXX.wav)
TMP_NORM=$(mktemp /tmp/dreame_norm_XXXXXX.wav)
trap 'rm -f "$TMP_WAV" "$TMP_NORM"' EXIT

# ---- Audio settings (matched to GLaDOS pack output) -------------------------
SAMPLE_RATE=16000
BITRATE=100        # kbps — used by oggenc --bitrate
LOUDNORM="loudnorm=I=-14:LRA=1:dual_mono=true:tp=-1"

# ---- Main generation loop ---------------------------------------------------
generated_files=()
total=0
errors=()

echo "============================================"
echo "  Dreame Trump Voice Pack Builder"
echo "============================================"
echo "  Model  : $MODEL"
echo "  Output : $OUTPUT_DIR"
echo "============================================"
echo ""

while IFS=$'\t' read -r id text; do
    # Text normalization: TTS reads "3D" poorly (already replaced in CSV, kept as safety net)
    text="${text//3D/Three-D}"

    ogg_out="$OUTPUT_DIR/${id}.ogg"
    printf '[%3s] %s\n' "$id" "${text:0:80}"

    # Step 1: Piper TTS → WAV (python3 -m piper reads from stdin)
    if ! printf '%s\n' "$text" \
            | python3 -m piper \
                --model "$MODEL" \
                --output_file "$TMP_WAV" \
                2>/dev/null; then
        echo "       WARNING: piper failed for ID $id — skipping"
        errors+=("$id")
        continue
    fi

    # Step 2: FFmpeg loudnorm → normalised WAV at 16 kHz mono
    if ! ffmpeg -y \
            -i "$TMP_WAV" \
            -filter:a "$LOUDNORM" \
            -ar "$SAMPLE_RATE" \
            -ac 1 \
            "$TMP_NORM" \
            -loglevel error; then
        echo "       WARNING: ffmpeg failed for ID $id — skipping"
        errors+=("$id")
        continue
    fi

    # Step 3: oggenc → Ogg Vorbis ~100 kbps (identical spec to the GLaDOS pack)
    if ! oggenc "$TMP_NORM" --output "$ogg_out" --bitrate "$BITRATE" 2>/dev/null; then
        echo "       WARNING: oggenc failed for ID $id — skipping"
        errors+=("$id")
        continue
    fi

    generated_files+=("${id}.ogg")
    (( total++ )) || true

done < <(python3 -c "
import csv, sys
with open('${CSV}') as f:
    for row in csv.reader(f):
        if len(row) >= 2 and row[0].strip().endswith('.ogg'):
            idn = row[0].strip()[:-4]
            if idn.isdigit():
                # tab-separated so bash can split on IFS=\t
                print(idn + '\t' + row[1].strip())
")

# ---- Package ----------------------------------------------------------------
echo ""
echo "Generated $total audio clips."

if [[ ${#errors[@]} -gt 0 ]]; then
    echo "WARNING: ${#errors[@]} ID(s) failed: ${errors[*]}"
fi

if [[ $total -eq 0 ]]; then
    echo "ERROR: no clips were generated — aborting packaging"
    exit 1
fi

echo "Packaging $PACK_OUT ..."

# Files are stored flat at the archive root (no subdirectory), matching the
# format the Dreame robot and Valetudo/HA add-on expect.
(cd "$OUTPUT_DIR" && tar -czf "$PACK_OUT" "${generated_files[@]}")

SIZE=$(stat -f%z "$PACK_OUT")
MD5=$(md5 -q "$PACK_OUT")

echo ""
echo "============================================"
echo "  Done: voice_pack.tar.gz"
printf   "  Size : %s bytes\n" "$SIZE"
printf   "  MD5  : %s\n" "$MD5"
echo "============================================"
echo ""
echo "Dreame HA add-on / Valetudo settings:"
echo "  Language Code : TRUMP"
echo "  URL           : <host the file and paste the URL here>"
echo "  File size     : $SIZE"
echo "  MD5 hash      : $MD5"
echo ""
echo "Or copy files directly to the robot:"
echo "  scp output/*.ogg root@<ROBOT_IP>:/data/personalized_voice/TRUMP/"
