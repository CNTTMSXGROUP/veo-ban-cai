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
dmg="Veo-QA-mac-${tag_arch}_0.3.24-${VEO_QA_REVISION:?phiên bản thử}.dmg"
data="$HOME/Library/Application Support/vn.msxgroup.phongdung"
runtime="$data/phan-chay-$runtime_arch"
installed="$scratch/Vèo.app"
app_pid='' server_pid='' mounted='' hosts_copied='' nguon_mang=''
ui() { "$scratch/bam-cua-so" "$app_pid" "$@"; }
capture() { ui capture "$proof/$1.png"; }
cleanup() {
  status=$?
  if [[ "$status" -ne 0 && -f "$scratch/server.log" ]]; then
    cp "$scratch/server.log" "$proof/may-chu-tai.log"
  fi
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
[[ "$worker" == "${VEO_QA_WORKER_SHA:-be1338d83671e8897aa8cbd874af41d4ec3aea0439bd8b6dbd810211caf50bd7}" ]]

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
manifest="$resources/phan-do-hoa.json"
IFS=$'	' read -r renderer_file renderer_sha renderer_size < <(jq -er '.items[0] | [.tep,.sha256,.size] | @tsv' "$manifest")
[[ "$renderer_file" =~ ^render-hyperframes-darwin-[a-z0-9-]+\.tar\.gz$ ]]
gh release download "$tag" -R "$GITHUB_REPOSITORY" --dir "$qa" --pattern "$renderer_file"
printf '%s  %s\n' "$renderer_sha" "$qa/$renderer_file" | shasum -a 256 -c
[[ "$(stat -f %z "$qa/$renderer_file")" == "$renderer_size" ]]
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
  VEO_PHAN_CHAY_GOC='http://127.0.0.1:54325' DUNG_KHO_NHAC="$scratch/nhac" DUNG_HYPERFRAMES_BROWSER="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" DUNG_CHEP_LOI=may DUNG_WHISPER_MODEL="$scratch/khong-dung-chep-loi.bin" \
    HTTPS_PROXY='http://127.0.0.1:54326' NO_PROXY='127.0.0.1,localhost' PATH=/usr/bin:/bin:/usr/sbin:/sbin "$bin" > "$scratch/app-$1.log" 2>&1 &
  app_pid=$!
  sleep 2
  kill -0 "$app_pid"
}
click() { ui click "$@"; sleep 0.25; }
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
if ! ui click 'Dùng ngay' 4 2>/dev/null; then ui wait 'Tạo mới' 90; fi
ui fit 'cửa sổ thường'
[[ ! -e "$data/goi-do-hoa/$renderer_sha/render-hyperframes" ]]
click 'Tạo mới'
click 'Từ ý tưởng / Storyboard'
printf '%s' 'Cảnh thử đồ họa' | /usr/bin/pbcopy
ui replace-app 'Tên video'
printf 4 | /usr/bin/pbcopy
ui replace-app 'Số giây cảnh 1'
click 'Ngang 16:9'
click 'Tạo đồ họa'
ui wait 'Tải bộ dựng*' 25
capture '01-tai-bo-dung'
now_ms() { python3 -c 'import time; print(time.monotonic_ns() // 10**6)'; }
download_started="$(now_ms)"
click 'Tải bộ dựng*'
ui wait 'Máy chủ chưa cung cấp được gói tải này. Hãy thử lại sau.' 10
ui wait 'Thử tải lại*' 40
printf '%s\n' "$(( $(now_ms) - download_started ))" > "$proof/thoi-gian-bao-loi-ms.txt"
[[ ! -e "$data/goi-do-hoa/$renderer_sha/render-hyperframes" ]]
capture '02-thu-tai-lai'
cp "$qa/$renderer_file" "$qa/goi/$renderer_file"
click 'Thử tải lại*'
for try in {1..45}; do
  if [[ -f "$data/goi-do-hoa/$renderer_sha/render-hyperframes/render.mjs" ]]; then break; fi
  sleep 1
done
[[ -f "$data/goi-do-hoa/$renderer_sha/render-hyperframes/render.mjs" ]]
click 'Chữ động'
printf '%s' 'Góc đọc sách' | /usr/bin/pbcopy
ui replace-app 'Dòng chữ'
click 'Dựng bản xem'
ui wait 'Video xem thử đồ họa' 140
sleep 0.9
capture '03-xem-chu-dong'
click 'Dùng đồ họa cho cảnh 1'
ui wait 'Sửa đồ họa' 15
capture '04-do-hoa-da-vao-canh'
click 'Dựng video'
ui wait 'Xuất video' 140
click 'Xuất video'
click '720p'
click 'Xuất 1 tệp'
ui wait 'Thành phẩm' 140
output="$(find "$data/du-an" -path '*/xuat/*.mp4' -type f -print)"
[[ -f "$output" && -s "$output" ]]
cp "$output" "$proof/Chuyen-dong-chu.mp4"
hash="$(shasum -a 256 "$output" | awk '{print $1}')"
ui key-app 12 cmd
if ! await_stop; then
  ui key-app 13 cmd
  await_stop
fi
start_app mo-lai
ui wait 'Thành phẩm' 90
click 'Phát'
ui wait 'Dừng' 8
capture '05-phat-sau-khi-mo-lai'
[[ "$(shasum -a 256 "$output" | awk '{print $1}')" == "$hash" ]]
cp "$scratch/server.log" "$proof/may-chu-tai.log"
python3 "$qa/kiem-video-do-hoa.py" "$data" "$runtime" "$manifest" "$proof" "$proof/may-chu-tai.log" | tee "$proof/ket-qua.json"
