#!/usr/bin/env bash
set -euo pipefail

qa="${1:?thư mục thử}"
expected_dmg="${2:?mã SHA-256 của DMG}"
[[ "${GITHUB_ACTIONS:-}" == true && "$(dirname "$qa")" == "$RUNNER_TEMP" && "$(stat -f %Su /dev/console)" == runner ]]
scratch="$qa/lam"
proof="$qa/minh-chung"
mkdir -p "$scratch/gan" "$scratch/nhac" "$qa/goi" "$proof"
case "$(uname -m)" in
  arm64) tag_arch=arm64; arch=arm64; runtime_arch=aarch64 ;;
  x86_64) tag_arch=x64; arch=x86_64; runtime_arch=x86_64 ;;
  *) exit 2 ;;
esac
tag=veo-qa-mac-intel-20261126
dmg="Veo-QA-mac-${tag_arch}_0.3.24-r27.dmg"
data="$HOME/Library/Application Support/vn.msxgroup.phongdung"
runtime="$data/phan-chay-$runtime_arch"
installed="$scratch/Vèo.app"
app_pid='' server_pid='' mounted='' hosts_copied='' nguon_mang='' fixture=''
ui() { "$scratch/bam-cua-so" "$app_pid" "$@"; }
capture() { ui capture "$proof/$1.png"; }
cleanup() {
  status=$?
  if [[ "$status" -ne 0 && -n "$app_pid" ]]; then
    ui dump 'lỗi' > "$proof/dieu-khien-khi-loi.txt" 2>/dev/null || true
    capture 'loi' || true
    worker_log="$HOME/Library/Logs/vn.msxgroup.phongdung/phan-dung.log"
    if [[ -f "$worker_log" ]]; then cp "$worker_log" "$proof/phan-dung.log"; fi
    find "$HOME/Library/Logs/DiagnosticReports" /Library/Logs/DiagnosticReports -maxdepth 1 -name '*WebKit*ips' -type f -mmin -10 -exec cp {} "$proof/" \; 2>/dev/null || true
    /usr/bin/log show --last 4m --style compact --predicate '(process CONTAINS "WebKit" OR process == "msx-phong-dung") AND (eventMessage CONTAINS[c] "crash" OR eventMessage CONTAINS[c] "terminate")' |
      tail -90 > "$proof/webkit.log" || true
  fi
  if [[ -n "$app_pid" ]]; then kill "$app_pid" 2>/dev/null || true; fi
  if [[ -n "$server_pid" ]]; then kill "$server_pid" 2>/dev/null || true; fi
  if [[ -n "$mounted" ]]; then hdiutil detach "$scratch/gan" >/dev/null || true; fi
  if [[ -n "$fixture" ]]; then rm -f "$fixture"; fi
  if [[ -n "$nguon_mang" ]]; then
    sudo networksetup -setsecurewebproxystate "$nguon_mang" off || true
  fi
  if [[ -n "$hosts_copied" ]]; then sudo cp "$scratch/hosts" /etc/hosts; fi
  exit "$status"
}
trap cleanup EXIT
[[ ! -e "$data" ]]
[[ "$(gh release view "$tag" -R "$GITHUB_REPOSITORY" --json isDraft --jq .isDraft)" == true ]]
gh release download "$tag" -R "$GITHUB_REPOSITORY" --dir "$qa" --pattern "$dmg"
printf '%s  %s\n' "$expected_dmg" "$qa/$dmg" | shasum -a 256 -c
hdiutil attach "$qa/$dmg" -mountpoint "$scratch/gan" -readonly -nobrowse -noautoopen
mounted=true
ditto "$scratch/gan/Vèo.app" "$installed"
hdiutil detach "$scratch/gan"
mounted=''
codesign --verify --deep --strict "$installed"
resources="$installed/Contents/Resources"
bin="$installed/Contents/MacOS/msx-phong-dung"
[[ "$(lipo -archs "$bin")" == "$arch" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$installed/Contents/Info.plist")" == 0.3.24 ]]
worker="$(shasum -a 256 "$resources/worker/dung-app.mjs" | awk '{print $1}')"
[[ "$worker" == '2743e3bf2fe283e1c165ffda4e4abc1f96c51c3efc90c28a508cb81378736085' ]]

jq -er '.items[] | [.tep,.sha256] | @tsv' "$resources/phan-chay.json" > "$scratch/goi.tsv"
while IFS=$'\t' read -r name digest; do
  [[ "$name" =~ ^[a-z0-9-]+\.tar\.gz$ ]]
  if [[ "$name" == ffmpeg-* ]]; then
    gh release download "$tag" -R "$GITHUB_REPOSITORY" --dir "$qa/goi" --pattern "$name"
  else
    curl -fLsS --retry 2 --max-time 90 "https://github.com/$GITHUB_REPOSITORY/releases/download/phan-chay/$name" -o "$qa/goi/$name"
  fi
  printf '%s  %s\n' "$digest" "$qa/goi/$name" | shasum -a 256 -c
done < "$scratch/goi.tsv"
[[ "$(wc -l < "$scratch/goi.tsv" | tr -d ' ')" == 7 ]]
python3 -m http.server 54325 --bind 127.0.0.1 --directory "$qa/goi" > "$scratch/server.log" 2>&1 &
server_pid=$!
for try in {1..25}; do
  if curl -fs 'http://127.0.0.1:54325/' > /dev/null; then break; fi
  kill -0 "$server_pid"
  sleep 0.2
done
curl -fsS 'http://127.0.0.1:54325/' > /dev/null

cp /etc/hosts "$scratch/hosts"
hosts_copied=true
printf '%s\n' '127.0.0.1 srrywxpcxqxuglvsjywg.supabase.co' '::1 srrywxpcxqxuglvsjywg.supabase.co' | sudo tee -a /etc/hosts >/dev/null
sudo dscacheutil -flushcache
sudo killall -HUP mDNSResponder
# WebKit có thể đọc proxy của máy. Giữ các lượt HTTPS trong máy thử khi dùng phiên tổng hợp.
iface="$(route -n get default | awk '/interface:/ {print $2}')"
service="$(networksetup -listnetworkserviceorder | awk -v iface="$iface" '/^\([0-9]+\)/ { service=$0; sub(/^\([0-9]+\) /,"",service) } index($0,"Device: " iface ")") { print service; exit }')"
[[ -n "$service" ]]
networksetup -getsecurewebproxy "$service" | grep -Fx 'Enabled: No'
nguon_mang="$service"
sudo networksetup -setsecurewebproxy "$nguon_mang" 127.0.0.1 54326
sudo networksetup -setsecurewebproxystate "$nguon_mang" on
scutil --proxy | grep -Eq 'HTTPSProxy +: 127\.0\.0\.1'
mkdir -p "$data"
printf '[]\n' > "$scratch/nhac/kho-nhac.json"
(umask 077; printf '%s\n' '{"refresh":"veo-qa-khong-phai-token","id":"00000000-0000-4000-8000-000000000026","email":"veo-qa@example.invalid","ten":"Kho thử Mac"}' > "$data/dang-nhap.json")
swiftc "$qa/bam-cua-so.swift" -o "$scratch/bam-cua-so"
start_app() {
  # Cảnh thử không có lời. Tách tải mô hình ra khỏi ca tái hiện cửa sổ trắng.
  VEO_PHAN_CHAY_GOC='http://127.0.0.1:54325' DUNG_KHO_NHAC="$scratch/nhac" DUNG_CHEP_LOI=may DUNG_WHISPER_MODEL="$scratch/khong-dung-chep-loi.bin" \
    HTTPS_PROXY='http://127.0.0.1:54326' NO_PROXY='127.0.0.1,localhost' PATH=/usr/bin:/bin:/usr/sbin:/sbin "$bin" > "$scratch/app-$1.log" 2>&1 &
  app_pid=$!
  sleep 2
  kill -0 "$app_pid"
}
click() { ui enter-app "$@"; sleep 0.25; }
await_stop() {
  for try in {1..40}; do
    if ! kill -0 "$app_pid" 2>/dev/null; then
      wait "$app_pid" || exit 1
      app_pid=''
      return
    fi
    sleep 0.25
  done
  return 1
}


start_app moi
for try in {1..60}; do
  if ui wait 'Dùng ngay' .4 2>/dev/null; then ui enter-app 'Dùng ngay' 2; fi
  if ui wait 'Tạo mới' 1 2>/dev/null; then break; fi
done
ui wait 'Tạo mới' 15
for try in {1..45}; do
  if jq -e --slurpfile source "$resources/phan-chay.json" '. == ($source[0].items | map({key:.ten,value:.sha256}) | from_entries)' "$runtime/.da-cai.json" >/dev/null 2>&1; then break; fi
  sleep 1
done
jq -e --slurpfile source "$resources/phan-chay.json" '. == ($source[0].items | map({key:.ten,value:.sha256}) | from_entries)' "$runtime/.da-cai.json" >/dev/null
mkdir -p "$HOME/Documents"
fixture="$HOME/Documents/Nguon Quay Drive.mp4"
sync="$HOME/Documents/Drive thử r27"
[[ ! -e "$fixture" && ! -e "$sync" ]]
mkdir "$sync"
"$runtime/ffmpeg" -v error -f lavfi -i 'color=c=0x203040:s=640x360:r=30:d=4,drawbox=x=0:y=0:w=105:h=360:color=red:t=fill,drawbox=x=535:y=0:w=105:h=360:color=blue:t=fill' \
  -f lavfi -i 'sine=f=431:r=48000:d=4' -c:v libx264 -threads 1 -c:a aac -t 4 "$fixture"
cp -p "$fixture" "$proof/nguon-ngang.mp4"

click 'Cài dựng clip mới'
click 'Cách dựng clip mới'
ui key-app 115
ui key-app 125
ui key-app 125
ui key-app 36
ui wait 'Vèo tìm điểm đổi cảnh tại máy. Có thể lấy lại mép đen đã rút trong Chỉnh nhanh → Cảnh.' 12
click 'Xong'
click 'Dọc 9:16'
ui key-app 34 cmd
ui click-text 'Documents'
ui click-file 'Nguon Quay Drive*'
ui click 'Open'
ui wait 'Xuất video' 150
capture '01-ban-dung-doc'
click 'Xuất video'
click '720p'
click 'Xuất 1 tệp'
ui wait 'Thành phẩm' 120
output="$(find "$data/du-an" -path '*/xuat/*.mp4' -type f -print)"
[[ -s "$output" ]]
cp -p "$output" "$proof/thanh-pham-doc.mp4"
"$runtime/ffprobe" -v error -show_entries stream=codec_name,width,height,avg_frame_rate,nb_frames -of json "$proof/thanh-pham-doc.mp4" > "$proof/video-doc.json"
jq -e '.streams | any(.codec_name=="h264" and .width==720 and .height==1280 and .nb_frames=="120")' "$proof/video-doc.json" >/dev/null

click 'Chỗ lưu'
click 'Chọn thư mục Drive…'
ui click-text 'Documents'
ui click-file 'Drive thử r27*'
ui click 'Open'
ui wait 'Thư mục đồng bộ · Drive thử r27' 20
click 'Video đưa lên Drive'
ui key-app 125
ui key-app 36
click 'Đưa bản dựng lên Drive'
ui wait 'Đã lưu vào thư mục Drive. Google Drive cho máy tính sẽ tải bản lên.' 90
capture '02-gui-ban-sao-drive'
index="$(find "$sync" -type f -name veo.json)"
[[ -s "$index" ]]
version="$(dirname "$index")"
original="$(jq -er '.plan.sources[0].original' "$index")"
normalized="$(jq -er '.plan.sources[0].path' "$index")"
[[ "$original" != "$normalized" && "$original" =~ ^tep/[0-9]+\.(mp4|mov)$ ]]
[[ -s "$version/$original" && -s "$version/$normalized" ]]
cmp "$fixture" "$version/$original"
source_hash="$(shasum -a 256 "$fixture" | cut -d ' ' -f1)"
jq -e --arg original "$original" --arg hash "$source_hash" '.plan.canvas == "doc" and (.files | any(.path == $original and .sha == $hash))' "$index" >/dev/null
cp -Rp "$sync" "$proof/drive"
jq -n --arg sha "$source_hash" --arg worker "$worker" --arg dmghash "$expected_dmg" --slurpfile index "$index" \
  '{chip:"arm64",boCai:$dmghash,workerSha256:$worker,tenDuAn:$index[0].name,sourceSha256:$sha,files:($index[0].files|length),guiBangCuaSo:true}' |
  tee "$proof/ket-qua.json"
ui key-app 53
ui key-app 12 cmd
await_stop
