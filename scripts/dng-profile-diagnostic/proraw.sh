#!/bin/zsh
# ProRAW variant of run.sh: the image is tiled in SubIFD, so the payload hash covers every tile.
set -euo pipefail
original=$1; work=$2; mkdir -p "$work"
payload() { local offs=(${(z)"$(exiftool -m -b -SubIFD:TileOffsets "$1")"}) cnts=(${(z)"$(exiftool -m -b -SubIFD:TileByteCounts "$1")"}); for i in {1..${#offs}}; do head -c $((offs[i] + cnts[i])) "$1" | tail -c ${cnts[i]}; done | shasum -a 256 | cut -c1-16; }
ident() { exiftool -s3 -Make -Model -UniqueCameraModel "$1" | paste -sd/ -; }
cm2=$(exiftool -s3 -n -IFD0:ColorMatrix2 "$original" | awk '{ printf "%.6f %.6f %.6f", $1*1.15, $2*1.15, $3*1.15; for (i = 4; i <= 9; i++) printf " %s", $i }')
variants=(
  "00-control|"
  "01-noop-rewrite|-IFD0:AnalogBalance=2.080810547 1 1.763183594"
  "02-color-matrix2|-IFD0:ColorMatrix2=$cm2"
  "03-analog-balance|-IFD0:AnalogBalance=2.5 1 1.5"
  "04-as-shot-neutral|-IFD0:AsShotNeutral=0.8 1 1.2"
  "05-baseline-exposure|-IFD0:BaselineExposure=5.063241005"
  "06-tone-curve-linear|-IFD0:ProfileToneCurve=0 0 1 1"
  "07-gain-table-map-removed|-SubIFD:ProfileGainTableMap="
  "08-profile-name|-IFD0:ProfileName=DIAGNOSTIC TEST"
)
oh=$(payload "$original"); oi=$(ident "$original"); echo "payload $oh  camera $oi"
files=()
for v in "${variants[@]}"; do
  name=${v%%|*}; edit=${v#*|}; copy="$work/$name.dng"; cp "$original" "$copy"
  [[ -n "$edit" ]] && exiftool -q -m -overwrite_original -n "$edit" "$copy"
  h=$(payload "$copy"); i=$(ident "$copy"); tag=${${edit%%=*}#-}
  echo "$name  $([[ $h == $oh ]] && echo 'payload ok' || echo 'PAYLOAD CHANGED')  $([[ $i == $oi ]] || echo 'IDENTITY CHANGED')  ${tag:+$tag now: $(exiftool -m -s3 -n "-$tag" "$copy" | cut -c1-60)}"
  files+=("$copy")
done
swift "${0:A:h}/compare.swift" "${SCALE:-1}" "${files[@]}"
