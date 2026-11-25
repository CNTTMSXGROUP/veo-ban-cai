#!/usr/bin/env bash
set -euo pipefail

qa="${1:?đường dẫn thư mục kiểm thử}"
[[ "${GITHUB_ACTIONS:-}" == true && "$(dirname "$qa")" == "$RUNNER_TEMP" && "$(uname -m)" == x86_64 ]]
[[ "$(sysctl -in sysctl.proc_translated 2>/dev/null || true)" != 1 ]]
sysctl -n machdep.cpu.brand_string | grep -i Intel
sw_vers
sysctl -n hw.ncpu hw.memsize

name='Veo QA Intel 26'
data="$HOME/Library/Application Support/vn.msxgroup.phongdung.qa.intel20261126"
runtime="$data/phan-chay-x86_64"
installed="$qa/Ứng dụng thử/$name.app"
mount="$qa/gan"
mkdir -p "$mount" "$(dirname "$installed")" "$qa/nhac" "$qa/minh-chung"
[[ ! -e "$data" ]]
printf '[]\n' > "$qa/nhac/kho-nhac.json"
app_pid='' server_pid=''

stop_app() {
  if [[ -n "$app_pid" ]]; then
    kill "$app_pid" 2>/dev/null || true
    wait "$app_pid" 2>/dev/null || true
    app_pid=''
  fi
}
cleanup() {
  stop_app
  if [[ -n "$server_pid" ]]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  /usr/bin/hdiutil detach "$mount" >/dev/null 2>&1 || true
}
trap cleanup EXIT

/usr/bin/hdiutil attach "$qa/Veo-QA-Intel_0.3.24-r3.dmg" -readonly -nobrowse -noautoopen -mountpoint "$mount"
/usr/bin/ditto "$mount/$name.app" "$installed"
/usr/bin/hdiutil detach "$mount"
/usr/bin/codesign --verify --deep --strict "$installed"
bin="$installed/Contents/MacOS/veo-qa-intel-26"
resources="$installed/Contents/Resources"
[[ "$(/usr/bin/lipo -archs "$bin")" == x86_64 ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$installed/Contents/Info.plist")" == 0.3.24 ]]
chrome='/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'
/usr/bin/lipo "$chrome" -verify_arch x86_64
printf 'Đã sao chép từ DMG, kiểm chữ ký và tệp chạy .app x86_64.\n'

python3 "$qa/may-kiem-intel.py" "$qa" "$resources" > "$qa/may-chu.log" 2>&1 &
server_pid=$!
for i in {1..40}; do
  if /usr/bin/curl -fsS 'http://127.0.0.1:49325/qa/state' > /dev/null 2>&1; then break; fi
  kill -0 "$server_pid"
  sleep 0.25
done
/usr/bin/curl -fsS 'http://127.0.0.1:49325/qa/state' >/dev/null

start_app() {
  VEO_PHAN_CHAY_GOC='http://127.0.0.1:49325/runtime' \
  DUNG_KHO_NHAC="$qa/nhac" DUNG_HYPERFRAMES_BROWSER="$chrome" \
  PATH=/usr/bin:/bin:/usr/sbin:/sbin "$bin" > "$qa/app-$1.log" 2>&1 &
  app_pid=$!
}
wait_report() {
  for i in $(seq 1 "$2"); do
    if [[ -f "$qa/failure.json" ]]; then cat "$qa/failure.json"; return 1; fi
    if [[ -f "$qa/$1.json" ]]; then jq -e .ok "$qa/$1.json" > /dev/null; return; fi
    kill -0 "$app_pid"
    sleep 1
  done
  printf 'Quá giờ chờ báo cáo %s.\n' "$1" >&2
  return 1
}
start_app cold
wait_report cold 480

for tool in node ffmpeg ffprobe whisper-cli; do
  /usr/bin/lipo "$runtime/$tool" -verify_arch x86_64
  /usr/bin/codesign --verify "$runtime/$tool"
done
[[ "$("$runtime/node" -p 'process.arch')" == x64 ]]
python3 - "$runtime" "$resources" <<'PY'
import json
import sys
from pathlib import Path
runtime, resources = map(Path, sys.argv[1:])
parts = json.loads((resources / "phan-chay.json").read_text())["items"]
assert len(parts) == 7
assert json.loads((runtime / ".da-cai.json").read_text()) == {p["ten"]: p["sha256"] for p in parts}
assert all((runtime / e).exists() for p in parts for e in p["entries"])
print(f"Vèo đã tải bảy gói phần chạy, đủ {sum(p['size'] for p in parts)} byte và các dấu SHA-256.")
PY
video="$(jq -er .video "$qa/cold.json")"
preview="$(jq -er '.preview|select(test("^[0-9a-f]{40}$"))' "$qa/cold.json")"
[[ "$video" == "$data/"* && -f "$video" ]]
layer="$(find "$data/phong-cach" -path "*/$preview/lop.mov" -print -quit)"
view="$(dirname "$layer")/xem.mp4"
[[ -f "$layer" && -f "$view" ]]
probe() {
  "$runtime/ffprobe" -v error -of json -show_entries stream=codec_name,width,height,avg_frame_rate,nb_frames,pix_fmt "$1"
}
probe "$video" | jq -e '.streams | length == 2 and .[0].codec_name=="h264" and .[0].width==1280 and .[0].height==720 and .[0].avg_frame_rate=="30/1" and .[0].nb_frames=="120" and .[1].codec_name=="aac"'
probe "$view" | jq -e '.streams[0] | .codec_name=="h264" and .nb_frames=="60"'
probe "$layer" | jq -e '.streams[0] | .codec_name=="prores" and (.pix_fmt|startswith("yuva")) and .nb_frames=="60"'
"$runtime/ffmpeg" -v error -ss 1 -i "$layer" -vf alphaextract,format=gray -frames:v 1 -f rawvideo "$qa/lop-xam.bin"
python3 - "$qa/lop-xam.bin" <<'PY'
from pathlib import Path
import sys
pixels = Path(sys.argv[1]).read_bytes()
assert min(pixels) == 0 and max(pixels) > 220, "Lớp đồ họa không có cả phần trong suốt và chữ"
PY
"$runtime/ffmpeg" -v error -i "$video" -vf "select='eq(n,5)+eq(n,24)',format=gray" -fps_mode passthrough -frames:v 2 -f rawvideo "$qa/hai-khung-xam.bin"
python3 - "$qa/hai-khung-xam.bin" <<'PY'
from pathlib import Path
import sys
view = Path(sys.argv[1]).read_bytes()
size = 1280 * 720
assert len(view) == 2 * size
moved = sum(abs(a-b) > 20 for a, b in zip(view[:size], view[size:]))
assert moved > 1000, f"Cảnh đồ họa đầu chưa có chuyển động: {moved} điểm ảnh."
print(f"Cảnh đầu có {moved} điểm ảnh đổi rõ giữa hai khung chữ động.")
PY
cp "$video" "$qa/minh-chung/Goc-doc-sach-mac-intel.mp4"
"$runtime/ffmpeg" -v error -i "$video" -vf "select='eq(n,19)+eq(n,75)',scale=640:360,tile=2x1" -frames:v 1 "$qa/minh-chung/Hai-khung-kiem.png"
before="$(shasum -a 256 "$video" | awk '{print $1}')"

stop_app
touch "$qa/warm.flag"
start_app warm
wait_report warm 75
[[ ! -e "$qa/unexpected-download" ]]
[[ "$(shasum -a 256 "$video" | awk '{print $1}')" == "$before" ]]
grep -q 'HyperFrames .* sai một byte' "$qa/may-chu.log"
grep -q 'HyperFrames .* đúng nội dung' "$qa/may-chu.log"
jq -n --slurpfile c "$qa/cold.json" --slurpfile w "$qa/warm.json" \
  '{coldBootMs:$c[0].bootMs, graphicsInstallMs:$c[0].packMs, firstRenderMs:$c[0].renderMs, warmBootMs:$w[0].bootMs}'
printf 'Mở lại từ kho cũ, không tải lại gói và MP4 khớp SHA-256 %s.\n' "$before"
