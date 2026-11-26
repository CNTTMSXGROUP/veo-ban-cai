#!/usr/bin/env bash
sync="$HOME/Documents/Google Drive q8l5"
[[ ! -e "$sync" ]]
mkdir -p "$HOME/Documents"
ditto "$VEO_QA_DRIVE_NHAN/drive" "$sync"
index="$(find "$sync" -name veo.json -type f -print)"
[[ -f "$index" ]]
name="$(jq -er .name "$index")"
[[ "$name" == 'Nguon Quay Drive (Drive)' ]]
original="$(jq -er '.plan.sources[0].original' "$index")"
count="$(jq -er 'select(.plan.canvas=="ngang") | .files | length' "$index")"
source_hash="$(jq -er --arg original "$original" '.files[] | select(.path==$original) | .sha' "$index")"
[[ "$source_hash" == '8fab1f85c19ded469f3c06b8c81890ac8e2447946ed4ec38b2d78d70ec5bec28' ]]
[[ "$(shasum -a 256 "$(dirname "$index")/$original" | awk '{print $1}')" == "$source_hash" ]]

click 'Chỗ lưu'
click 'Chọn thư mục Drive…'
ui click-text 'Documents'
ui click-file 'Google Drive q8l5*'
ui click 'Open'
ui wait 'Google Drive q8l5' 20
click 'Kiểm tra tư liệu'
ui wait "Đủ $count tệp trên máy này" 75
capture '01-kiem-tu-lieu-tu-drive'
mv "$sync" "$scratch/thu-muc-drive-da-ngat"
click 'Làm mới'
ui wait 'Không mở được thư mục Drive.*' 30
capture '02-da-kiem-khi-thu-muc-ngat'
click 'Mở bản sao'
ui wait 'Đã tạo dự án từ Drive trong danh sách Đang làm.' 45
ui key-app 53
ui wait 'Xuất video' 85
ui wait "$name" 15
if ui wait "$name (Drive)" 1 2>/dev/null; then
  echo 'Tên dự án lặp hậu tố (Drive).' >&2
  exit 1
fi
capture '03-du-an-windows-tren-mac'
click 'Xuất video'
click '720p'
click 'Xuất 1 tệp'
ui wait 'Thành phẩm' 120
output="$(find "$data/du-an" -path '*/xuat/*.mp4' -type f -print)"
[[ -f "$output" && -s "$output" ]]
mp4="$proof/Thanh-pham-Mac.mp4"
cp -p "$output" "$mp4"
hash="$(shasum -a 256 "$output" | awk '{print $1}')"
"$runtime/ffprobe" -v error -show_entries stream=codec_name,width,height,avg_frame_rate,nb_frames -of json "$mp4" > "$proof/mp4.json"
jq -e '.streams | any(.codec_name=="h264" and .width==1280 and .height==720 and .nb_frames=="120" and .avg_frame_rate=="30/1") and any(.codec_name=="aac")' "$proof/mp4.json" >/dev/null
for x in 52 1228; do
  "$runtime/ffmpeg" -v error -ss 1 -i "$mp4" -vf "format=rgb24,crop=1:1:$x:350" -frames:v 1 -f rawvideo "$scratch/mau-$x.rgb"
done
read -r r1 g1 b1 < <(od -An -tu1 "$scratch/mau-52.rgb")
read -r r2 g2 b2 < <(od -An -tu1 "$scratch/mau-1228.rgb")
[[ "$r1" -ge 220 && "$g1" -le 25 && "$b1" -le 25 && "$r2" -le 25 && "$g2" -le 25 && "$b2" -ge 220 ]]
python3 - "$data/du-an" "$source_hash" <<'PY'
from pathlib import Path
import hashlib
import sys

root = Path(sys.argv[1])
assert any(hashlib.sha256(p.read_bytes()).hexdigest() == sys.argv[2]
           for p in root.rglob('*.mp4') if p.is_file() and not p.is_symlink()), 'Kho Mac thiếu clip quay gốc.'
PY
ui key-app 12 cmd
if ! await_stop; then
  ui key-app 13 cmd
  await_stop
fi
start_app mo-lai
ui wait 'Thành phẩm' 85
ui wait "$name" 15
ui click 'Phát'
ui wait 'Dừng' 10
capture '04-phat-mp4-sau-khi-mo-lai'
[[ "$(shasum -a 256 "$output" | awk '{print $1}')" == "$hash" ]]
jq -n --arg mac "$(sw_vers -productVersion)" --arg chip "$arch" --arg worker "$worker" --arg name "$name" \
  --arg original "$source_hash" --arg output "$hash" --arg bundle "$VEO_QA_DRIVE_RETURN_SHA" \
  --argjson count "$count" --slurpfile video "$proof/mp4.json" \
  '{macOS:$mac,chip:$chip,source:"854de70ab15ae0c843e967a13830672413297fb5",workerSha256:$worker,projectName:$name,
    sha256NhanQuaDrive:$bundle,sourceClipSha256:$original,outputSha256:$output,mediaCount:$count,video:$video[0].streams,
    restoredOffline:true,playedAfterRestart:true,keptBothEdges:true}' | tee "$proof/ket-qua.json"
