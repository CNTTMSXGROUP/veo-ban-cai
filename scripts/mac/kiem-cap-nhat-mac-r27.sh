#!/usr/bin/env bash
set -euo pipefail
qa="${1:?thư mục thử}"
[[ "${GITHUB_ACTIONS:-}" == true && "$qa" == "$RUNNER_TEMP/veo-qa-mac-cap-nhat" && "$(stat -f %Su /dev/console)" == runner ]]
proof="$qa/minh-chung"
scratch="$qa/lam"
data="$HOME/Library/Application Support/vn.msxgroup.phongdung"
cache="$HOME/Library/Caches/vn.msxgroup.phongdung/cap-nhat/ban-0.3.24.bin"
arch="$(uname -m)"
runtime_arch="$arch"
if [[ "$arch" == arm64 ]]; then runtime_arch=aarch64; fi
runtime="$data/phan-chay-$runtime_arch"
installed="$scratch/Vèo.app"
bin="$installed/Contents/MacOS/msx-phong-dung"
db="$data/phong-dung.db"
old="${2:?gói 0.3.23}"
new="${3:?gói r27}"
mode="${4:?cách cập nhật}"
app_pid='' server_pid='' proxy='' hosts_changed=''
fixture="$HOME/Documents/Veo kho Mac thu.mp4"
mkdir -p "$proof" "$scratch/nhac" "$scratch/ban-sao" "$scratch/kho-r27" "$qa/goi/runtime"
ui() { "$scratch/bam-cua-so" "$app_pid" "$@"; }
click() { ui click "$@"; sleep .25; }
capture() { ui capture "$proof/$1.png"; }
cleanup() {
  result=$?
  if [[ "$result" -ne 0 && -n "$app_pid" ]]; then
    ui dump 'lỗi' > "$proof/dieu-khien-khi-loi.txt" 2>/dev/null || true
    capture 'loi' || true
    for log in "$scratch"/veo-*.log; do
      if [[ -f "$log" ]]; then grep -E 'kiểm bản mới|khởi động|bo qua|phần chạy|Error|error' "$log" | tail -30 >> "$proof/veo-log.txt" || true; fi
    done
  fi
  if [[ -n "$app_pid" ]]; then kill "$app_pid" 2>/dev/null || true; fi
  if [[ -n "$server_pid" ]]; then kill "$server_pid" 2>/dev/null || true; fi
  if [[ -n "$proxy" ]]; then sudo networksetup -setsecurewebproxystate "$proxy" off || true; fi
  if [[ -n "$hosts_changed" ]]; then sudo cp "$scratch/hosts" /etc/hosts; fi
  if [[ -f "$scratch/server.log" ]]; then cp "$scratch/server.log" "$proof/may-chu-thu.log"; fi
  exit "$result"
}
trap cleanup EXIT
[[ ! -e "$data" && ! -e "$fixture" ]]
tar -xzf "$old" -C "$scratch"
codesign --verify --deep --strict "$installed"
[[ "$(lipo -archs "$bin")" == "$arch" ]]
version() { /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$installed/Contents/Info.plist"; }
hash() { shasum -a 256 "$1" | awk '{print $1}'; }
[[ "$(version)" == '0.3.23' ]]
old_binary="$(hash "$bin")"
cp "$installed/Contents/Resources/phan-chay.json" "$scratch/goi-cu.json"
tar -xOf "$new" 'Vèo.app/Contents/Resources/phan-chay.json' > "$scratch/goi-moi.json"
jq -sr 'map(.items) | add | unique_by(.tep)[] | [.tep,.sha256]|@tsv' "$scratch/goi-cu.json" "$scratch/goi-moi.json" > "$scratch/goi.tsv"
while IFS=$'\t' read -r name digest; do
  [[ "$name" =~ ^[a-z0-9-]+\.tar\.gz$ ]]
  if ! curl -fLsS --retry 1 --max-time 90 "https://github.com/$GITHUB_REPOSITORY/releases/download/phan-chay/$name" -o "$qa/goi/runtime/$name"; then
    gh release download veo-qa-mac-intel-20261126 -R "$GITHUB_REPOSITORY" --dir "$qa/goi/runtime" --pattern "$name"
  fi
  [[ "$(hash "$qa/goi/runtime/$name")" == "$digest" ]]
done < "$scratch/goi.tsv"
cp "$new" "$qa/goi/veo-r27.tar.gz"
feed() {
  jq -n --arg version "$1" --arg key "darwin-$runtime_arch" --rawfile sig "$new.sig" \
    '{version:$version,platforms:{($key):{signature:($sig|rtrimstr("\n")),url:"http://127.0.0.1:59343/veo-r27.tar.gz"}}}' > "$qa/goi/feed.tmp"
  mv "$qa/goi/feed.tmp" "$qa/goi/latest.json"
}
feed '0.3.23'
python3 -u -m http.server 59343 --bind 127.0.0.1 --directory "$qa/goi" > "$scratch/server.log" 2>&1 &
server_pid=$!
for try in {1..25}; do
  if curl -fs 'http://127.0.0.1:59343/latest.json' > /dev/null; then break; fi
  kill -0 "$server_pid"
  sleep .2
done
curl -fs 'http://127.0.0.1:59343/latest.json' >/dev/null
cp /etc/hosts "$scratch/hosts"
hosts_changed=true
printf '%s\n' '127.0.0.1 srrywxpcxqxuglvsjywg.supabase.co' '::1 srrywxpcxqxuglvsjywg.supabase.co' | sudo tee -a /etc/hosts >/dev/null
sudo dscacheutil -flushcache
sudo killall -HUP mDNSResponder
iface="$(route -n get default | awk '/interface:/ {print $2}')"
proxy="$(networksetup -listnetworkserviceorder | awk -v iface="$iface" '/^\([0-9]+\)/ { service=$0; sub(/^\([0-9]+\) /,"",service) } index($0,"Device: " iface ")") { print service; exit }')"
[[ -n "$proxy" ]]
networksetup -getsecurewebproxy "$proxy" | grep -Fx 'Enabled: No'
sudo networksetup -setsecurewebproxy "$proxy" 127.0.0.1 59344
sudo networksetup -setsecurewebproxystate "$proxy" on
mkdir -p "$data" "$HOME/Documents"
printf '[]\n' > "$scratch/nhac/kho-nhac.json"
(umask 077; printf '%s\n' '{"refresh":"veo-qa-khong-phai-token","id":"00000000-0000-4000-8000-000000000026","email":"veo-qa@example.invalid","ten":"Kho thử Mac"}' > "$data/dang-nhap.json")
cp "$qa/qa-upgrade-voice.mp4" "$fixture"
swiftc "$qa/bam-cua-so.swift" -o "$scratch/bam-cua-so"

# Giữ phiên và mẫu giọng trong máy ảo, kể cả khi bản cập nhật tự mở tiến trình.
export VEO_PHAN_CHAY_GOC='http://127.0.0.1:59343/runtime'
export DUNG_KHO_NHAC="$scratch/nhac" DUNG_CHEP_LOI=may DUNG_WHISPER_MODEL="$qa/ggml-base.en-q5_1.bin"
export HTTPS_PROXY='http://127.0.0.1:59344' NO_PROXY='127.0.0.1,localhost'
start_app() {
  PATH=/usr/bin:/bin:/usr/sbin:/sbin "$bin" > "$scratch/veo-$1.log" 2>&1 &
  app_pid=$!
  sleep 2
  kill -0 "$app_pid"
}
app_pids() {
  ps -axo pid=,command= | awk -v cmd="$bin" '{pid=$1; sub(/^[ ]*[0-9]+[ ]+/,""); if ($0==cmd || index($0,cmd " ")==1) print pid}'
}
quit_app() {
  ui key-app 12 cmd
  for try in {1..60}; do
    if [[ -z "$(app_pids)" ]]; then app_pid=''; return 0; fi
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
play() { ui wait 'Thành phẩm' 90; click 'Phát'; ui wait 'Dừng' 6; capture "$1"; click 'Dừng'; }

start_app cu
ready 'Tìm video'
ui key-app 34 cmd
ui click-text 'Documents'
ui click-file 'Veo kho Mac thu*'
click 'Open'
ui wait 'Đã lưu dự án' 150
click 'Sửa tay'
click 'Hiệu ứng hình'
click 'Cả video'
click 'Đen trắng'
ui wait 'Cường độ mẫu màu' 15
capture '01-mau-ban-cu'
click 'Hoàn tác*'
click 'Làm lại*'
ui wait 'Cường độ mẫu màu' 12
click 'Tự động'
click 'Xuất video'
click '720p'
click 'Xuất 1 tệp'
play '02-phat-tu-ban-cu'
old_out="$(find "$data/du-an" -path '*/xuat/*.mp4' -type f)"
[[ -f "$old_out" ]]
old_hash="$(hash "$old_out")"
src_hash="$(hash "$fixture")"
cp "$old_out" "$proof/tu-0.3.23.mp4"
quit_app
snapshot > "$proof/lich-su-truoc.txt"
so_ban="$(sqlite3 -readonly "$db" 'SELECT count(*) FROM versions;')"
[[ "$so_ban" -ge 2 ]]
sqlite3 -readonly "$db" ".backup \"$scratch/ban-sao/phong-dung.db\""
[[ "$(sqlite3 -readonly "$scratch/ban-sao/phong-dung.db" 'PRAGMA integrity_check;')" == ok ]]
ditto "$data/du-an" "$scratch/ban-sao/du-an"

feed '0.3.24'
start_app doi
ready 'Cập nhật bản 0.3.24'
capture '03-goi-da-duoc-xac-minh'
[[ "$(hash "$cache")" == "$(hash "$new")" ]]
old_pid="$app_pid"
if [[ "$mode" == 'bam' ]]; then
  click 'Cập nhật bản 0.3.24'
else
  [[ "$mode" == 'thoat' ]]
  quit_app
fi
for try in {1..100}; do
  if [[ "$(version 2>/dev/null || true)" == '0.3.24' ]] && ! ps -p "$old_pid" >/dev/null 2>&1; then break; fi
  sleep .25
done
[[ "$(version)" == '0.3.24' ]]
codesign --verify --deep --strict "$installed"
worker="$(hash "$installed/Contents/Resources/worker/dung-app.mjs")"
[[ "$worker" == '2743e3bf2fe283e1c165ffda4e4abc1f96c51c3efc90c28a508cb81378736085' ]]
if [[ "$mode" == 'bam' ]]; then
  for try in {1..80}; do
    app_pid="$(app_pids)"
    if [[ -n "$app_pid" ]]; then break; fi
    sleep .25
  done
  [[ "$app_pid" =~ ^[0-9]+$ && "$app_pid" != "$old_pid" ]]
else
  [[ -z "$(app_pids)" ]]
  start_app r27
fi
ready 'Thành phẩm'
play '04-phat-ban-cu-trong-r27'
[[ ! -e "$cache" && "$(hash "$old_out")" == "$old_hash" && "$(hash "$fixture")" == "$src_hash" ]]
snapshot > "$proof/lich-su-sau.txt"
cmp "$proof/lich-su-truoc.txt" "$proof/lich-su-sau.txt"
click 'Xuất lại'
click '720p'
ui click-app 'Tên tệp'
ui key-app 0 cmd
printf '%s' 'Xuat lai r27' | pbcopy
ui paste-app 'Tên tệp'
ui key-app 48
click 'Xuất 1 tệp'
ui wait 'Thành phẩm' 120
new_out="$(find "$data/du-an" -path '*/xuat/*.mp4' -type f ! -path "$old_out")"
[[ -f "$new_out" ]]
new_hash="$(hash "$new_out")"
cp "$new_out" "$proof/tu-r27.mp4"
for t in '0.3.23' r27; do
  "$runtime/ffprobe" -v error -show_entries stream=codec_name,width,height,avg_frame_rate,nb_frames -of json "$proof/tu-$t.mp4" > "$proof/video-$t.json"
  jq -e '.streams | any(.codec_name=="h264" and .width==720 and .height==1280 and .avg_frame_rate=="30/1" and (.nb_frames|tonumber)>0)' "$proof/video-$t.json" >/dev/null
  jq -e '.streams | any(.codec_name=="aac")' "$proof/video-$t.json" >/dev/null
done
cmp "$proof/video-0.3.23.json" "$proof/video-r27.json"
quit_app
start_app mo-lai-r27
ready 'Thành phẩm'
play '05-phat-mp4-r27-sau-khi-mo-lai'
[[ "$(hash "$new_out")" == "$new_hash" && "$(hash "$old_out")" == "$old_hash" ]]
quit_app

# Giữ bản đã nâng ở chỗ riêng, rồi phục hồi đúng đường dẫn kho thử mà bản cũ đã lưu.
mv "$installed" "$scratch/ban-r27.app"
mv "$data/du-an" "$db" "$scratch/kho-r27/"
for ext in shm wal; do if [[ -f "$db-$ext" ]]; then mv "$db-$ext" "$scratch/kho-r27/"; fi; done
ditto "$scratch/ban-sao/du-an" "$data/du-an"
cp "$scratch/ban-sao/phong-dung.db" "$db"
tar -xzf "$old" -C "$scratch"
[[ "$(version)" == '0.3.23' && "$(hash "$bin")" == "$old_binary" ]]
feed '0.3.23'
start_app quay-lui
ready 'Thành phẩm'
play '06-phat-tu-ban-sao-sau-quay-lui'
[[ "$(hash "$old_out")" == "$old_hash" && "$(hash "$scratch/kho-r27/${new_out#"$data/"}")" == "$new_hash" ]]
snapshot > "$proof/lich-su-quay-lui.txt"
cmp "$proof/lich-su-truoc.txt" "$proof/lich-su-quay-lui.txt"
[[ "$(sqlite3 -readonly "$db" 'PRAGMA integrity_check;')" == ok ]]
[[ "$(grep -c 'GET /veo-r27.tar.gz HTTP' "$scratch/server.log")" == 1 ]]
quit_app
jq -n --arg os "$(sw_vers -productVersion)" --arg chip "$arch" --arg mode "$mode" --arg worker "$worker" \
  --arg package "$(hash "$new")" --arg old "$old_hash" --arg new "$new_hash" --argjson versions "$so_ban" \
  '{macOS:$os,chip:$chip,cachCapNhat:$mode,tu:"0.3.23",den:"0.3.24",workerSha256:$worker,goiSha256:$package,shaVideoCu:$old,shaVideoMoi:$new,soBanSua:$versions,baoToanKho:true,moLaiPhat:true,quayLuiBangBanSao:true}' |
  tee "$proof/ket-qua.json"
