#!/usr/bin/env bash
# Chạy từ kịch bản cài DMG và bộ chạy trên máy GitHub, đã có cửa sổ Vèo thật.
bam() { ui enter-app "$1" 5 || click "$1"; sleep 0.25; }
dien() {
  printf '%s' "$2" | /usr/bin/pbcopy
  ui replace-app "$1"
  sleep 0.25
}
chon() { click "$1"; thay "$2" 5; click "$2"; }
thay() { ui wait "$1" "${2:-24}"; }
thay_gia() {
  thay 'Duyệt nội dung gửi Google Cloud'
  ui wait "Ước tính $1*" 2 || thay "$1*"
}
mo_canh() { click 'Storyboard'; click 'Tạo clip bằng AI'; thay 'Model tạo clip'; }
mo_lai() {
  ui key-app 12 cmd
  if ! await_stop; then
    ui key-app 13 cmd
    await_stop
  fi
  start_app "$1"
}

ffmpeg="$runtime/ffmpeg"
ffprobe="$runtime/ffprobe"
mkdir -p "$HOME/Documents"
for name in A B; do
  [[ ! -e "$HOME/Documents/Anh Veo $name.png" ]]
  color=red
  if [[ "$name" == B ]]; then color=green; fi
  "$ffmpeg" -v error -f lavfi -i "color=$color:s=320x180" -frames:v 1 -threads 1 "$HOME/Documents/Anh Veo $name.png"
done
"$ffmpeg" -v error -f lavfi -i 'color=blue:s=640x360:r=30:d=4' -an -c:v libx264 -threads 1 "$proof/clip-cloud-thu.mp4"
VEO_QA_CLOUD_PROXY=1 "$runtime/node" "$qa/veo-lite-cloud-thu.cjs" "$scratch" "$proof" > "$proof/cloud-thu.log" 2>&1 &
cloud_pid=$!
for try in {1..25}; do
  if [[ -s "$scratch/cloud-ready.txt" ]]; then break; fi
  kill -0 "$cloud_pid"
  sleep 0.2
done
[[ -s "$scratch/cloud-ready.txt" ]]

click 'Tạo mới'
click 'Từ ý tưởng / Storyboard'
dien 'Tên video' 'QA Veo Lite'
dien 'Chữ cảnh 1' 'Desk light'
thay 'QA Veo Lite'
click 'Dựng video'
thay 'Xuất video' 100
mo_canh
click 'Model tạo clip'
thay 'Veo 3.1 Lite · Thử nghiệm'
ui dump 'menu model' > "$proof/cay-tro-nang-menu-model.txt"
capture '00-menu-model-mac'
click 'Veo 3.1 Fast'
for name in A B; do
  click 'Nhập ảnh'
  ui click-text 'Documents'
  ui click-file "Anh Veo $name*"
  click 'Open'
  thay "Bỏ ảnh Anh Veo $name.png"
done
chon 'Model tạo clip' 'Veo 3.1 Lite · Thử nghiệm'
thay 'Bỏ bớt ảnh để còn tối đa*'
dien 'Mô tả hình ảnh và chuyển động' 'A slow camera move across the opening frame.'
capture '01-doi-sang-lite-voi-hai-anh'
chon 'Model tạo clip' 'Veo 3.1 Fast'
thay 'Bỏ ảnh Anh Veo A.png'
thay 'Bỏ ảnh Anh Veo B.png'
bam 'Bỏ ảnh Anh Veo B.png'
chon 'Model tạo clip' 'Veo 3.1 Lite · Thử nghiệm'
thay 'Bỏ ảnh Anh Veo A.png'

bam 'Kết nối Veo qua Google Cloud*'
dien 'ID dự án Google Cloud' 'veo-lite-qa'
dien 'Ngân sách ước tính mỗi ngày (USD)' '0.11'
bam 'Dùng phiên Google Cloud'
ui wait 'Phiên Google Cloud creator@example.invalid*' 3 || thay 'creator@example.invalid*'
echo 'Đã kết nối phiên thử và nhập hạn mức 0,11 USD.'
chon 'Độ phân giải clip' '1080p'
bam 'Xem trước và duyệt'
thay 'Ảnh mở đầu sẽ gửi'
thay_gia '0,32'
capture '02-lite-1080p-co-tieng'
bam 'Sửa yêu cầu'
chon 'Độ phân giải clip' '720p'
bam 'Tạo tiếng cùng clip Veo'
bam 'Xem trước và duyệt'
thay_gia '0,12'
thay 'Vượt ngân sách ước tính còn lại hôm nay.'
[[ ! -e "$proof/luot-google-cloud.jsonl" ]]
capture '03-chan-vuot-ngan-sach'

bam 'Sửa yêu cầu'
dien 'Ngân sách ước tính mỗi ngày (USD)' '0.12'
bam 'Dùng phiên Google Cloud'
thay 'Kết nối Veo qua Google Cloud · còn 0,12*'
bam 'Xem trước và duyệt'
thay_gia '0,12'
bam 'Gửi tạo cảnh'
thay 'Có biên nhận, có thể tải lại*' 55
capture '04-giu-ma-sau-loi-503'
photo="$(find "$data/du-an" -path '*/xem/anh-gui-*.jpg' -type f -print)"
[[ -f "$photo" ]]
image_sha="$(shasum -a 256 "$photo" | awk '{print $1}')"
jq -es --arg sha "$image_sha" 'length == 2 and .[0].action == "submit" and .[0].imageSha256 == $sha and .[1].status == 503' "$proof/luot-google-cloud.jsonl" > /dev/null

mo_lai tai-clip
thay 'Xuất video' 85
mo_canh
bam 'Tải lại clip đã tạo'
thay 'Đã vào kho tư liệu*' 65
capture '05-tai-lai-clip'
bam 'Dùng cho cảnh 1'
thay 'Tạo bản dựng mới'
bam 'Tạo bản dựng mới'
thay 'Xuất video' 100
click 'Xuất video'
click '720p'
click 'Xuất 1 tệp'
thay 'Thành phẩm' 120
output="$(find "$data/du-an" -path '*/xuat/*.mp4' -type f -print)"
[[ -f "$output" && -s "$output" ]]
cp "$output" "$proof/Thanh-pham.mp4"
hash="$(shasum -a 256 "$output" | awk '{print $1}')"
"$ffprobe" -v error -select_streams v:0 -show_entries stream=codec_name,width,height,avg_frame_rate,nb_frames -of json "$output" > "$proof/mp4.json"
jq -e '.streams[0] | .codec_name == "h264" and .nb_frames == "120" and .avg_frame_rate == "30/1" and .width == 1280 and .height == 720' "$proof/mp4.json" > /dev/null
"$ffmpeg" -v error -ss 1 -i "$output" -vf 'format=rgb24,crop=1:1:640:360' -frames:v 1 -f rawvideo "$scratch/mau.rgb"
read -r red green blue < <(od -An -tu1 "$scratch/mau.rgb")
[[ "$blue" -ge 225 && "$red" -le 25 && "$green" -le 25 ]]

mo_lai phat-thanh-pham
thay 'Thành phẩm' 85
click 'Phát'
thay 'Dừng' 8
capture '06-phat-thanh-pham-sau-khi-mo-lai'
[[ "$(shasum -a 256 "$output" | awk '{print $1}')" == "$hash" ]]
jq -es 'length == 3 and .[2].action == "poll" and .[2].status == 200 and .[1].operation == .[2].operation' "$proof/luot-google-cloud.jsonl" > /dev/null
jq -n --arg os "$(sw_vers -productVersion)" --arg chip "$arch" --arg output "$hash" --arg worker "$worker" \
  --arg dmg "$expected_dmg" --slurpfile cloud "$proof/luot-google-cloud.jsonl" --slurpfile video "$proof/mp4.json" \
  '{macOS:$os,chip:$chip,source:"a5c83fc344e43d056eb2cb191f5365bbb759f2f1",workerSha256:$worker,dmgSha256:$dmg,
    cloudFixture:true,budgetBlocked:true,quote720SilentCents:12,quote1080WithAudioCents:32,restoredSameReceipt:true,playedAfterRestart:true,
    outputSha256:$output,video:$video[0].streams[0],cloud:$cloud}' | tee "$proof/ket-qua.json"
