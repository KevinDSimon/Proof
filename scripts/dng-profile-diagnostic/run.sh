#!/bin/zsh
# Finds out which color tags in a DNG Core Image's RAW decoder actually uses.
#
#   [DECODER_VERSION=9.dng] scripts/dng-profile-diagnostic/run.sh <original.dng> [work-dir] [scaleFactor]
#
# Copies the original into work-dir, changes one color tag per copy with ExifTool, checks that
# each copy keeps the same RAW pixel payload and camera identity, then decodes every copy with
# CIRAWFilter (compare.swift) and compares the pixel buffers with the unmodified control.
# The original is only read. Needs exiftool and the Swift toolchain.
set -euo pipefail

original=${1:?usage: run.sh <original.dng> [work-dir] [scaleFactor]}
work=${2:-$(mktemp -d)}
scale=${3:-0.25}
here=${0:A:h}
mkdir -p "$work"

identity="1 0 0 0 1 0 0 0 1"
# Strong edits on purpose: if the decoder reads a tag at all, the render should move clearly.
calib="1.25 0 0 0 1 0 0 0 0.8"
# A forward matrix whose rows still sum to D50 white, so neutrals stay neutral but colors move.
forward="0.2 0.6 0.1642 0.1 0.8 0.1 0 0.1 0.7249"
desaturate="0 0 1 0 0 1 0 0 1 0 0 1 0 0 1 0 0 1"   # 3x2x1 table: hue shift 0, saturation 0, value 1
brighten_curve="0 0 0.25 0.6 1 1"
scale_first_row() { exiftool -s3 -n "-IFD0:$1" "$original" | awk '{ printf "%.6f %.6f %.6f", $1*1.15, $2*1.15, $3*1.15; for (i = 4; i <= 9; i++) printf " %s", $i }'; }

# name | ExifTool arguments | what it tests
variants=(
  "00-control||unmodified copy"
  "01-noop-rewrite|-IFD0:CameraCalibration1=$identity|rewrite with an identical value (file rewrite only)"
  "02-camera-calibration1|-IFD0:CameraCalibration1=$calib|calibration under illuminant A"
  "03-camera-calibration2|-IFD0:CameraCalibration2=$calib|calibration under D65"
  "04-color-matrix1|-IFD0:ColorMatrix1=$(scale_first_row ColorMatrix1)|color matrix under illuminant A"
  "05-color-matrix2|-IFD0:ColorMatrix2=$(scale_first_row ColorMatrix2)|color matrix under D65"
  "06-forward-matrices-added|-IFD0:ForwardMatrix1=$forward|-IFD0:ForwardMatrix2=$forward|forward matrices (absent in original)"
  "07-look-table|-IFD0:ProfileLookTableData=$desaturate|profile look table (saturation to 0)"
  "08-hue-sat-map-added|-IFD0:ProfileHueSatMapDims=3 2 1|-IFD0:ProfileHueSatMapData1=$desaturate|-IFD0:ProfileHueSatMapData2=$desaturate|hue/sat map (absent in original)"
  "09-tone-curve-added|-IFD0:ProfileToneCurve=$brighten_curve|profile tone curve (absent in original)"
  "10-as-shot-neutral|-IFD0:AsShotNeutral=0.35 1 0.55|per-shot white balance"
  "11-baseline-exposure|-IFD0:BaselineExposure=1|baseline exposure +1 EV (sanity check)"
  "12-profile-name|-IFD0:ProfileName=DIAGNOSTIC TEST|profile name only"
  "13-calibration1-and-matrix2|-IFD0:CameraCalibration1=$calib|-IFD0:ColorMatrix2=$(scale_first_row ColorMatrix2)|calibration under A plus matrix under D65 (does a non-identity calibration switch the decoder to the file's matrices?)"
)

raw_hash() {
  local offset count
  offset=$(exiftool -s3 -n -IFD0:StripOffsets "$1")
  count=$(exiftool -s3 -n -IFD0:StripByteCounts "$1")
  head -c $((offset + count)) "$1" | tail -c "$count" | shasum -a 256 | cut -c1-16
}
identity_of() { exiftool -s3 -IFD0:Make -IFD0:Model -IFD0:UniqueCameraModel "$1" | paste -sd'/' -; }

original_hash=$(raw_hash "$original")
original_identity=$(identity_of "$original")
echo "Original: $original"
echo "  RAW payload sha256 (first 16): $original_hash   camera: $original_identity"
echo "  Work dir: $work"
echo

files=()
for entry in "${variants[@]}"; do
  parts=("${(@s:|:)entry}")
  name=$parts[1]; note=$parts[-1]; edits=("${(@)parts[2,-2]}")
  copy="$work/$name.dng"
  cp "$original" "$copy"
  if [[ -n "${edits[1]:-}" ]]; then
    exif_args=()
    for e in "${edits[@]}"; do exif_args+=("$e"); done
    if ! exiftool -q -overwrite_original -n "${exif_args[@]}" "$copy"; then
      echo "$name: UNTESTED (ExifTool could not write: ${edits[*]})"; rm -f "$copy"; continue
    fi
  fi
  hash=$(raw_hash "$copy"); ident=$(identity_of "$copy")
  check="payload ok"
  [[ "$hash" == "$original_hash" ]] || check="PAYLOAD CHANGED"
  [[ "$ident" == "$original_identity" ]] || check="$check, IDENTITY CHANGED"
  printf '%-28s %-18s %s\n' "$name" "$check" "$note"
  for e in "${edits[@]}"; do
    [[ -z "$e" ]] && continue
    tag=${${e%%=*}#-}
    printf '%-28s   %s = %s\n' "" "$tag" "$(exiftool -s3 -n "-$tag" "$copy")"
  done
  files+=("$copy")
done
echo

swift "$here/compare.swift" "$scale" "${files[@]}"
