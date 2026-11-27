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
tag=veo-qa-0324-ban-chinh-2
dmg_arch="$tag_arch"; if [[ "$tag_arch" == arm64 ]]; then dmg_arch=aarch64; fi
dmg="Veo_0.3.24_${dmg_arch}.dmg"
data="$HOME/Library/Application Support/vn.msxgroup.phongdung"
runtime="$data/phan-chay-$runtime_arch"
installed="$scratch/Vèo.app"
app_pid='' server_pid='' mounted='' hosts_copied='' nguon_mang='' sample_pid=''
ui() { "$scratch/bam-cua-so" "$app_pid" "$@"; }
capture() { ui capture "$proof/$1.png"; }
cleanup() {
  status=$?
  if [[ -n "$sample_pid" ]]; then kill "$sample_pid" 2>/dev/null || true; fi
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
[[ "$worker" == "${VEO_QA_WORKER_SHA:?}" ]]

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

curl -fLsS --max-time 140 --retry 2 'https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-base.en-q5_1.bin?download=true' -o "$scratch/ggml-base.en-q5_1.bin"
printf '%s  %s\n' '4baf70dd0d7c4247ba2b81fafd9c01005ac77c2f9ef064e00dcf195d0e2fdd2f' "$scratch/ggml-base.en-q5_1.bin" | shasum -a 256 -c
gh release download veo-qa-windows-20261126-7bc6cdf -R "$GITHUB_REPOSITORY" --dir "$scratch" --pattern qa-upgrade-voice.mp4
printf '%s  %s\n' '4c99742130fb5cecd2f8f5ad7c8c3f718b11ea668b4e93ff9b2ac971606cff71' "$scratch/qa-upgrade-voice.mp4" | shasum -a 256 -c
swiftc "$qa/lai-app-mac.swift" -o "$scratch/lai"
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


ready() {
  for try in {1..60}; do
    ui click 'Dùng ngay' 1 2>/dev/null || true
    if ui wait "$1" 1 2>/dev/null; then break; fi
  done
  sleep 2
  ui click 'Dùng ngay' 1 2>/dev/null || true
  ui wait "$1" 10
}
quit_app() {
  ui key-app 12 cmd
  if ! await_stop; then ui key-app 13 cmd; await_stop; fi
}

# Lần mở đầu để app tự tải phần chạy.
start_app moi
ready 'Tạo mới'
quit_app
VEO_QA_DATA="$data" VEO_QA_CLIP="$scratch/qa-upgrade-voice.mp4" VEO_QA_MODEL="$scratch/ggml-base.en-q5_1.bin" \
  "$runtime/node" "$qa/tao-sua-tay.mjs" "$runtime" "$runtime" "$qa"
id="$(cat "$qa/id-du-an.txt")"
db="$data/phong-dung.db"

start_app sua
ready '[TEST] Sửa tay*'
ui fit 'cửa sổ thường'
capture '10-mo-lai'
ui dump 'mở lại' > "$proof/10-mo-lai.txt"
if ! ui wait 'Sửa tay' 5 2>/dev/null; then ui click '[TEST] Sửa tay*' 8 || ui click-text '[TEST] Sửa tay' 8; fi
click 'Sửa tay'
sleep 4
ui click 'Dùng ngay' 1 2>/dev/null || true
capture '11-man-sua-tay'
ui dump 'sửa tay' > "$proof/11-man-sua-tay.txt"

lai() { "$scratch/lai" "$1" "$app_pid" "${@:2}"; }
fail=0
ket() {
  printf '%s | %s\n' "$1" "$2" | tee -a "$proof/ket-qua-sua-tay.txt"
  capture "$3" || true
  if [[ "$1" == HONG ]]; then fail=1; ui dump x > "$proof/$3.txt" || true; fi
}
dem() { sqlite3 -readonly "$db" "SELECT count(*) FROM versions WHERE project_id='$id'"; }
dau() { sqlite3 -readonly "$db" "SELECT head FROM projects WHERE id='$id'"; }
cho_dem() { for i in {1..40}; do if (( $(dem) > $1 )); then sleep 1; return 0; fi; sleep .25; done; return 1; }
co_menu() { sleep .8; [[ -n "$(lai find 'Trình đơn thành phần')" ]]; }
khung() {
  local line
  line="$(lai find 'Kéo khung để dời' | head -1)"
  [[ -n "$line" ]] || return 1
  read -r _ cx cy w h _ <<<"$line"
  echo "khung $cx $cy $w $h" >> "$proof/toa-do.txt"
}
khoi() { lai find 'Mũi tên vàng' | sort -k3,3n | tail -1; }

line="$(khoi)"
[[ -n "$line" ]] || { echo 'Không thấy khối cảnh chèn trên dải thời gian' >&2; exit 1; }
read -r _ bx by _ <<<"$line"
lai click "$bx" "$by"
sleep 1.2
if khung; then ket DAT 'Chọn khối cảnh chèn thì khung hiện trên khung xem' '12-chon-canh'; else ket HONG 'Chọn khối cảnh chèn thì khung hiện trên khung xem' '12-chon-canh'; exit 1; fi

n="$(dem)"
lai right "$cx" "$cy"
if co_menu; then ket DAT 'Chuột phải vào khung cảnh chèn mở trình đơn' '13-chuot-phai'; else ket HONG 'Chuột phải vào khung cảnh chèn mở trình đơn' '13-chuot-phai'; fi
ui key-app 53; sleep .6
lai ctrl "$cx" "$cy"
if co_menu; then ket DAT 'Ctrl + bấm vào khung cảnh chèn mở trình đơn' '14-ctrl-bam'; else ket HONG 'Ctrl + bấm vào khung cảnh chèn mở trình đơn' '14-ctrl-bam'; fi
ui key-app 53; sleep .6
old="$cx $cy $w $h"
if khung && [[ "$(dem)" == "$n" && "$cx $cy $w $h" == "$old" ]]; then ket DAT 'Mở trình đơn không làm đổi khung' '15-sau-trinh-don'; else ket HONG "Mở trình đơn không làm đổi khung ($old thành $cx $cy $w $h, bản sửa $n thành $(dem))" '15-sau-trinh-don'; fi
ui key-app 53; sleep .8
lai right "$cx" "$cy"
if co_menu; then ket DAT 'Chuột phải khi chưa chọn gì vẫn chọn cảnh và mở trình đơn' '16-chuot-phai-chua-chon'; else ket HONG 'Chuột phải khi chưa chọn gì vẫn chọn cảnh và mở trình đơn' '16-chuot-phai-chua-chon'; fi
ui key-app 53; sleep .8

keo() { # tên, ảnh, x1 y1 x2 y2, điều kiện trên khung mới
  local n0 w0=$w h0=$h x0=$cx y0=$cy
  n0="$(dem)"
  lai drag "$3" "$4" "$app_pid" "$5" "$6"
  if cho_dem "$n0" && khung && eval "$7"; then ket DAT "$1: $x0 $y0 $w0 $h0 thành $cx $cy $w $h" "$2"; else ket HONG "$1: trước $x0 $y0 $w0 $h0, sau $cx $cy $w $h, bản sửa $n0 thành $(dem)" "$2"; fi
}
khung
sx=$((cx + w / 2 - 1)); sy=$((cy + h / 2 - 1))
keo 'Kéo góc khung ra' '17-keo-goc-ra' "$sx" "$sy" $((sx + 40)) $((sy + 30)) '(( w > w0 ))'
sx=$((cx + w / 2 - 1)); sy=$((cy + h / 2 - 1))
keo 'Kéo góc khung vào' '18-keo-goc-vao' "$sx" "$sy" $((sx - 50)) $((sy - 36)) '(( w < w0 ))'
keo 'Kéo dời khung' '19-doi-khung' "$cx" "$cy" $((cx - 30)) $((cy - 40)) '(( cx < x0 && cy < y0 ))'
h1="$(dau)"; x1=$cx
ui key-app 6 cmd; sleep 2
if [[ "$(dau)" != "$h1" ]] && khung && (( cx != x1 )); then ket DAT 'Hoàn tác trả khung về chỗ cũ' '20-hoan-tac'; else ket HONG 'Hoàn tác trả khung về chỗ cũ' '20-hoan-tac'; fi

line="$(khoi)"; read -r _ bx by bw _ <<<"$line"
n0="$(dem)"
lai drag "$bx" "$by" "$app_pid" $((bx + 45)) "$by"
if cho_dem "$n0"; then
  line="$(khoi)"; read -r _ bx2 _ <<<"$line"
  if (( bx2 > bx )); then ket DAT "Kéo khối cảnh chèn trên dải thời gian: $bx thành $bx2" '21-keo-khoi'; else ket HONG "Kéo khối cảnh chèn trên dải thời gian: $bx thành $bx2" '21-keo-khoi'; fi
else ket HONG 'Kéo khối cảnh chèn trên dải thời gian không lưu' '21-keo-khoi'; fi

quit_app
start_app mo-lai-lan-2
ready '[TEST] Sửa tay*'
capture '22-mo-lai-sau-sua'
sqlite3 -readonly "$db" "SELECT n,label FROM versions WHERE project_id='$id' ORDER BY n" | tee "$proof/lich-su-sua.txt"
cat "$proof/ket-qua-sua-tay.txt"
exit "$fail"
