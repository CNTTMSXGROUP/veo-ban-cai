#!/usr/bin/env bash
set -euo pipefail
qa="${1:?thư mục thử}"
[[ "${GITHUB_ACTIONS:-}" == true && "$qa" == "$RUNNER_TEMP/veo-qa-doi-chieu-intel" && "$(stat -f %Su /dev/console)" == runner ]]
[[ "$(uname -m)" == x86_64 ]]
sysctl -n machdep.cpu.brand_string | grep -Fi Intel

proof="$qa/minh-chung"
data="$HOME/Library/Application Support/vn.msxgroup.phongdung"
runtime="$data/phan-chay-x86_64"
db="$data/phong-dung.db"
fixture="$HOME/Documents/Veo kho Mac thu.mp4"
snapshot_dir="$qa/ban-sao"
old="$qa/cong-khai/Vèo.app"
diagnostic="$qa/chan-doan/Vèo.app"
r27="$qa/r27/Vèo.app"
app_pid='' server_pid='' proxy='' hosts_changed=''
mkdir -p "$proof" "$snapshot_dir" "$qa/goi" "$qa/nhac" "$qa/cong-khai" "$qa/chan-doan" "$qa/r27"
[[ ! -e "$data" && ! -e "$fixture" ]]

ui() { "$qa/bam-cua-so" "$app_pid" "$@"; }
click() { ui click "$@"; sleep .25; }
capture() { ui capture "$proof/$1.png"; }
hash() { shasum -a 256 "$1" | awk '{print $1}'; }
cleanup() {
  local status=$?
  if [[ "$status" != 0 && -n "$app_pid" ]]; then
    ui dump 'lỗi' > "$proof/dieu-khien-khi-loi.txt" 2>/dev/null || true
    capture 'loi' || true
  fi
  if [[ -n "$app_pid" ]]; then kill "$app_pid" 2>/dev/null || true; fi
  if [[ -n "$server_pid" ]]; then kill "$server_pid" 2>/dev/null || true; fi
  if [[ -n "$proxy" ]]; then sudo networksetup -setsecurewebproxystate "$proxy" off || true; fi
  if [[ -n "$hosts_changed" ]]; then sudo cp "$qa/hosts" /etc/hosts; fi
  if [[ "$status" != 0 ]]; then
    for log in "$qa"/veo-*.log; do
      if [[ -f "$log" ]]; then grep -E 'khởi động|phần chạy|Error|error' "$log" | tail -25 >> "$proof/veo-log.txt" || true; fi
    done
  fi
  exit "$status"
}
trap cleanup EXIT

tar -xzf "$qa/Veo_0.3.23_x64.app.tar.gz" -C "$qa/cong-khai"
tar -xzf "$qa/Veo-QA-mac-x64_0.3.23-chan-doan-quay-lui.app.tar.gz" -C "$qa/chan-doan"
tar -xzf "$qa/Veo-QA-mac-x64_0.3.24-r27.app.tar.gz" -C "$qa/r27"
for app in "$old" "$diagnostic" "$r27"; do
  codesign --verify --deep --strict "$app"
  [[ "$(lipo -archs "$app/Contents/MacOS/msx-phong-dung")" == x86_64 ]]
done
for app in "$old" "$diagnostic"; do
  [[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")" == 0.3.23 ]]
done
[[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$r27/Contents/Info.plist")" == 0.3.24 ]]
old_worker="$(hash "$old/Contents/Resources/worker/dung-app.mjs")"
new_worker="$(hash "$r27/Contents/Resources/worker/dung-app.mjs")"
[[ "$old_worker" == "$(hash "$diagnostic/Contents/Resources/worker/dung-app.mjs")" ]]
[[ "$new_worker" == '2743e3bf2fe283e1c165ffda4e4abc1f96c51c3efc90c28a508cb81378736085' ]]

jq -sr 'map(.items) | add | unique_by(.tep)[] | [.tep,.sha256]|@tsv' "$old/Contents/Resources/phan-chay.json" "$r27/Contents/Resources/phan-chay.json" > "$qa/goi.tsv"
while IFS=$'\t' read -r name digest; do
  [[ "$name" =~ ^[a-z0-9-]+\.tar\.gz$ ]]
  if ! curl -fLsS --retry 1 --max-time 90 "https://github.com/$GITHUB_REPOSITORY/releases/download/phan-chay/$name" -o "$qa/goi/$name"; then
    gh release download veo-qa-mac-intel-20261126 -R "$GITHUB_REPOSITORY" --dir "$qa/goi" --pattern "$name"
  fi
  [[ "$(hash "$qa/goi/$name")" == "$digest" ]]
done < "$qa/goi.tsv"
python3 -u -m http.server 59343 --bind 127.0.0.1 --directory "$qa/goi" > "$qa/server.log" 2>&1 &
server_pid=$!
for try in {1..25}; do
  if curl -fs 'http://127.0.0.1:59343/' > /dev/null; then break; fi
  kill -0 "$server_pid"
  sleep .2
done
curl -fs 'http://127.0.0.1:59343/' >/dev/null
cp /etc/hosts "$qa/hosts"
hosts_changed=true
printf '%s\n' '127.0.0.1 srrywxpcxqxuglvsjywg.supabase.co' '::1 srrywxpcxqxuglvsjywg.supabase.co' | sudo tee -a /etc/hosts >/dev/null
sudo dscacheutil -flushcache
sudo killall -HUP mDNSResponder
iface="$(route -n get default | awk '/interface:/ {print $2}')"
service="$(networksetup -listnetworkserviceorder | awk -v iface="$iface" '/^\([0-9]+\)/ { service=$0; sub(/^\([0-9]+\) /,"",service) } index($0,"Device: " iface ")") { print service; exit }')"
[[ -n "$service" ]]
networksetup -getsecurewebproxy "$service" | grep -Fx 'Enabled: No'
proxy="$service"
sudo networksetup -setsecurewebproxy "$proxy" 127.0.0.1 59344
sudo networksetup -setsecurewebproxystate "$proxy" on
scutil --proxy | grep -Eq 'HTTPSProxy +: 127\.0\.0\.1'

mkdir -p "$data" "$HOME/Documents"
printf '[]\n' > "$qa/nhac/kho-nhac.json"
(umask 077; printf '%s\n' '{"refresh":"veo-qa-khong-phai-token","id":"00000000-0000-4000-8000-000000000026","email":"veo-qa@example.invalid","ten":"Kho thử Mac"}' > "$data/dang-nhap.json")
cp "$qa/qa-upgrade-voice.mp4" "$fixture"
swiftc "$qa/bam-cua-so.swift" -o "$qa/bam-cua-so"
export VEO_PHAN_CHAY_GOC='http://127.0.0.1:59343'
export DUNG_KHO_NHAC="$qa/nhac" DUNG_CHEP_LOI=may DUNG_WHISPER_MODEL="$qa/ggml-base.en-q5_1.bin"
export HTTPS_PROXY='http://127.0.0.1:59344' NO_PROXY='127.0.0.1,localhost'

start_app() {
  [[ -z "$app_pid" ]]
  PATH=/usr/bin:/bin:/usr/sbin:/sbin "$1/Contents/MacOS/msx-phong-dung" > "$qa/veo-$2.log" 2>&1 &
  app_pid=$!
  sleep 2
  kill -0 "$app_pid"
}
quit_app() {
  ui key-app 12 cmd
  for try in {1..60}; do
    if ! kill -0 "$app_pid" 2>/dev/null; then
      wait "$app_pid"
      app_pid=''
      return 0
    fi
    sleep .25
  done
  echo 'Cửa sổ chưa thoát sau Command-Q.' >&2
  return 1
}
ready() {
  for try in {1..64}; do
    if ui wait 'Dùng ngay' .5 2>/dev/null; then
      ui enter-app 'Dùng ngay' 2 || ui key-app 36
      if ui wait 'Dùng ngay' .5 2>/dev/null; then ui key-app 53; fi
      sleep .4
    fi
    if ui wait "$1" 1 2>/dev/null; then return; fi
  done
  ui wait "$1" 1
}
snapshot() {
  sqlite3 -readonly "$db" 'SELECT id,name,head FROM projects ORDER BY id; SELECT project_id,n,label FROM versions ORDER BY project_id,n;'
}
restore() {
  local out="$qa/kho-$1"
  [[ -z "$app_pid" && ! -e "$out" ]]
  mkdir "$out"
  mv "$data/du-an" "$db" "$out/"
  for ext in shm wal; do if [[ -f "$db-$ext" ]]; then mv "$db-$ext" "$out/"; fi; done
  ditto "$snapshot_dir/du-an" "$data/du-an"
  cp "$snapshot_dir/phong-dung.db" "$db"
  [[ "$(sqlite3 -readonly "$db" 'PRAGMA integrity_check;')" == ok ]]
  snapshot | cmp "$proof/lich-su-truoc.txt" -
}
open_archived() {
  ready 'Lưu trữ · 1'
  capture "$1"
  ui enter-app 'Lưu trữ · 1'
}
play() { ui wait 'Thành phẩm' 70; click 'Phát'; ui wait 'Dừng' 6; capture "$1"; click 'Dừng'; }

start_app "$old" kho-trong
ready 'Tìm video'
capture '01-kho-trong-trong-ban-cong-khai'
for try in {1..65}; do
  if jq -e --slurpfile source "$old/Contents/Resources/phan-chay.json" '. == ($source[0].items | map({key:.ten,value:.sha256}) | from_entries)' "$runtime/.da-cai.json" >/dev/null 2>&1; then break; fi
  sleep 1
done
jq -e --slurpfile source "$old/Contents/Resources/phan-chay.json" '. == ($source[0].items | map({key:.ten,value:.sha256}) | from_entries)' "$runtime/.da-cai.json" >/dev/null
quit_app

# Tạo tư liệu thử bằng đúng phần dựng của bản công khai. Các lần mở và phát đều qua cửa sổ Vèo.
VEO_QA_DATA="$data" VEO_QA_CLIP="$fixture" "$runtime/node" "$qa/tao-kho-0323.mjs" "$runtime" "$qa"
old_out="$(find "$data/du-an" -path '*/xuat/*.mp4' -type f)"
[[ -f "$old_out" ]]
old_hash="$(hash "$old_out")"
cp "$old_out" "$proof/tu-0.3.23.mp4"
snapshot > "$proof/lich-su-truoc.txt"
count="$(sqlite3 -readonly "$db" 'SELECT count(*) FROM versions;')"
[[ "$count" == 6 ]]
sqlite3 -readonly "$db" ".backup \"$snapshot_dir/phong-dung.db\""
ditto "$data/du-an" "$snapshot_dir/du-an"
[[ "$(sqlite3 -readonly "$snapshot_dir/phong-dung.db" 'PRAGMA integrity_check;')" == ok ]]

start_app "$old" goi-cong-khai
open_archived '02-kho-0.3.23-truoc-khi-mo'
public_play=false
white_level=0
if ui wait 'Thành phẩm' 22; then
  play '03-ban-cong-khai-phat-duoc'
  public_play=true
else
  kill -0 "$app_pid"
  ui dump 'cửa sổ bản công khai' > "$proof/dieu-khien-ban-cong-khai.txt"
  capture '03-khung-ban-cong-khai'
  white_level="$("$runtime/ffmpeg" -v error -i "$proof/03-khung-ban-cong-khai.png" -vf 'crop=iw*0.6:ih*0.6,scale=1:1,format=gray' -frames:v 1 -f rawvideo - | od -An -t u1 | tr -d '[:space:]')"
  [[ "$white_level" =~ ^[0-9]+$ ]]
fi
quit_app
[[ "$(hash "$old_out")" == "$old_hash" ]]
echo "Bản 0.3.23 công khai phát được: $public_play. Độ sáng vùng giữa: $white_level."

restore cong-khai
start_app "$diagnostic" ban-chan-doan
open_archived '04-mo-kho-trong-ban-chan-doan'
if ui wait 'Chẩn đoán giao diện*' 25; then
  capture '05-loi-js-ban-chan-doan'
else
  capture '05-khung-ban-chan-doan'
fi
ui dump 'chẩn đoán giao diện' > "$proof/loi-js.txt"
shader_error=false
if grep -qi 'shaderSource.*WebGLShader\|WebGLShader.*shaderSource' "$proof/loi-js.txt"; then shader_error=true; fi
quit_app
[[ "$(hash "$old_out")" == "$old_hash" ]]
echo "Bản chẩn đoán ghi được lỗi cấp shader: $shader_error."

restore chan-doan
start_app "$r27" kho-phuc-r27
open_archived '06-mo-cung-kho-trong-r27'
play '07-phat-mp4-cu-trong-r27'
snapshot > "$proof/lich-su-r27.txt"
cmp "$proof/lich-su-truoc.txt" "$proof/lich-su-r27.txt"
[[ "$(hash "$old_out")" == "$old_hash" ]]
click 'Xuất lại'
click '720p'
ui click-app 'Tên tệp'
ui key-app 0 cmd
printf '%s' 'Phuc hoi Intel r27' | pbcopy
ui paste-app 'Tên tệp'
ui key-app 48
click 'Xuất 1 tệp'
ui wait 'Đang làm · 1' 120
ui enter-app 'Đang làm · 1'
ui wait 'Thành phẩm' 120
new_out="$(find "$data/du-an" -path '*/xuat/*.mp4' -type f ! -path "$old_out")"
[[ -f "$new_out" ]]
new_hash="$(hash "$new_out")"
cp "$new_out" "$proof/xuat-lai-trong-r27.mp4"
"$runtime/ffprobe" -v error -show_entries stream=codec_name,width,height,avg_frame_rate,nb_frames -of json "$new_out" > "$proof/video-r27.json"
jq -e '.streams | any(.codec_name=="h264" and .width==720 and .height==1280 and .avg_frame_rate=="30/1" and .nb_frames=="273")' "$proof/video-r27.json" >/dev/null
jq -e '.streams | any(.codec_name=="aac")' "$proof/video-r27.json" >/dev/null
quit_app
start_app "$r27" mo-lai-r27
ready 'Thành phẩm'
play '08-phat-sau-khi-khoi-dong-lai'
quit_app
[[ "$(hash "$old_out")" == "$old_hash" && "$(hash "$new_out")" == "$new_hash" ]]
[[ "$(sqlite3 -readonly "$db" 'PRAGMA integrity_check;')" == ok ]]
jq -n --arg os "$(sw_vers -productVersion)" --arg oldWorker "$old_worker" --arg newWorker "$new_worker" \
  --arg sample "$(hash "$fixture")" --arg oldMP4 "$old_hash" --arg newMP4 "$new_hash" --argjson count "$count" \
  --argjson publicPlay "$public_play" --argjson white "$white_level" --argjson shader "$shader_error" \
  '{macOS:$os,chip:"x86_64",workerCu:$oldWorker,workerR27:$newWorker,shaNguon:$sample,shaVideoCu:$oldMP4,shaVideoMoi:$newMP4,soBanSua:$count,banCongKhaiPhatMP4:$publicPlay,doSangGiuaCuaSoBanCongKhai:$white,chanDoanShaderSource:$shader,r27MoDungKho:true,r27PhatMP4Cu:true,r27XuatVaMoLaiMP4Moi:true}' | tee "$proof/ket-qua.json"
