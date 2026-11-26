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
dmg="Veo-QA-mac-${tag_arch}_0.3.24-r25.dmg"
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
[[ "$worker" == '646effff3e93df723fc6baf0d68c56fa6fa79168f56f331dff18999ef2779511' ]]

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
click() { ui click "$@"; sleep 0.25; }
await_stop() {
  for try in {1..40}; do
    if ! kill -0 "$app_pid" 2>/dev/null; then wait "$app_pid"; app_pid=''; return; fi
    sleep 0.25
  done
  echo 'Vèo chưa thoát sau Command-Q.' >&2
  return 1
}

start_app moi
if ! ui click 'Dùng ngay' 4 2>/dev/null; then ui wait 'Tạo mới' 90; fi
for try in {1..45}; do
  if jq -e --slurpfile source "$resources/phan-chay.json" '. == ($source[0].items | map({key:.ten,value:.sha256}) | from_entries)' "$runtime/.da-cai.json" > /dev/null 2>&1; then break; fi
  sleep 1
done
jq -e --slurpfile source "$resources/phan-chay.json" '. == ($source[0].items | map({key:.ten,value:.sha256}) | from_entries)' "$runtime/.da-cai.json" > /dev/null
"$runtime/ffmpeg" -v error -f lavfi -i 'testsrc2=s=256x256:r=30:d=4' -an -c:v libx264 -threads 1 "$proof/Canh A.mp4"
mkdir -p "$HOME/Documents"
[[ ! -e "$HOME/Documents/Canh A.mp4" ]]
cp "$proof/Canh A.mp4" "$HOME/Documents/Canh A.mp4"
fixture="$HOME/Documents/Canh A.mp4"
capture '01-danh-sach-lam-viec'
click 'Tạo mới'
click 'Từ ý tưởng / Storyboard'
click 'Dùng kịch bản mẫu'
if ! ui wait 'Đưa việc vào lịch' 3 2>/dev/null; then
  ui space 'Dùng kịch bản mẫu'
  ui wait 'Đưa việc vào lịch' 10
fi
click 'Chọn tệp cho Ảnh hoặc clip cảnh 1'
ui click-text 'Documents'
ui click-file 'Canh A*'
click 'Open'
ui wait 'Canh A.mp4' 20
capture '02-storyboard'
click 'Dựng video'
if ! ui wait 'Xuất video' 55; then
  capture '03-khi-dung'
  ui wait 'Xuất video' 70
fi
if [[ "$arch" == x86_64 ]]; then
  click 'Sửa tay'
  click 'Hiệu ứng hình'
  click 'Cả video'
  click 'Phim cũ'
  note='Khung xem dùng màu cơ bản vì WebGL chưa sẵn sàng. Kiểm màu nâng cao trong bản xuất.'
  ui wait "$note" 12
  capture '03-mau-khi-xem'
  click 'Hoàn tác*'
  if ui wait "$note" 3 2>/dev/null; then echo 'Cảnh báo màu còn hiện sau hoàn tác.' >&2; exit 1; fi
  capture '03-hoan-tac-mau'
  click 'Làm lại*'
  ui wait "$note" 12
  click 'Tự động'
fi
click 'Xuất video'
click '720p'
click 'Xuất 1 tệp'
ui wait 'Thành phẩm' 180
capture '03-thanh-pham'
output="$(find "$data/du-an" -path '*/xuat/*.mp4' -type f -print)"
[[ -f "$output" && -s "$output" ]]
mp4="$proof/Thanh-pham.mp4"
cp "$output" "$mp4"
hash="$(shasum -a 256 "$output" | awk '{print $1}')"
"$runtime/ffprobe" -v error -select_streams v:0 -show_entries stream=codec_name,width,height,avg_frame_rate,nb_frames -of json "$mp4" > "$proof/mp4.json"
jq -e '.streams[0] | .codec_name=="h264" and .nb_frames=="600" and .avg_frame_rate=="30/1" and (.height==720 or .width==720)' "$proof/mp4.json" > /dev/null
before="$(grep -c 'GET /.*tar.gz' "$scratch/server.log")"
ui key 12 cmd
await_stop
start_app mo-lai
ui wait 'Thành phẩm' 90
click 'Phát'
ui wait 'Dừng' 8
capture '04-phat-sau-khi-mo-lai'
click 'Dừng'
click 'Sửa tay'
click 'Lịch sử xuất'
ui wait "$(basename "$output")" 15
capture '05-lich-su'
[[ "$(shasum -a 256 "$output" | awk '{print $1}')" == "$hash" ]]
after="$(grep -c 'GET /.*tar.gz' "$scratch/server.log")"
[[ "$before" == 7 && "$after" == "$before" ]]
jq -n --arg os "$(sw_vers -productVersion)" --arg arch "$arch" --arg sha "$hash" --arg worker "$worker" \
  --arg dmg "$expected_dmg" --slurpfile video "$proof/mp4.json" \
  '{macOS:$os,chip:$arch,source:"6e8f8b027cef3cf312dea471b88131595d0c2326",workerSha256:$worker,dmgSha256:$dmg,video:$video[0].streams[0],sha256:$sha,goiLanDau:7,goiMoLai:0,moLai:true}' |
  tee "$proof/ket-qua.json"
