#!/usr/bin/env bash
set -euo pipefail
qa="${1:?thư mục thử}"
[[ "${GITHUB_ACTIONS:-}" == true && "$qa" == "$RUNNER_TEMP/veo-r27-blender" ]]
cd "$qa"
proof="$qa/proof"
blender="$qa/blender-5.3.0-linux-x64/blender"
cp nguon/ban-giao.otio "$qa/ban-giao.otio"
# Gắn hai tư liệu tổng hợp vào đường dẫn mà Blender đọc từ các URI ổ Windows.
python3 - <<'PY'
import json
import shutil
from pathlib import Path
from urllib.parse import unquote, urlsplit

timeline = json.loads(Path("ban-giao.otio").read_text())
fixtures = {"May A.mp4": "May A.mp4", "5ddd6103ebbb6eb0ec5d.mov": "May B.mov"}
seen = set()
for track in timeline["tracks"]["children"]:
    for strip in track["children"]:
        if strip["OTIO_SCHEMA"] != "Clip.2":
            continue
        reference = strip["media_references"]["DEFAULT_MEDIA"]
        url = urlsplit(reference["target_url"])
        target = Path(unquote(url.path).removeprefix("/"))
        assert url.scheme == "file" and url.netloc == "" and not target.is_absolute()
        assert target.parts[0] in ("C:", "D:") and ".." not in target.parts
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(Path("nguon/tu-lieu") / fixtures[target.name], target)
        seen.add(target.name)
assert seen == set(fixtures)
PY

export DISPLAY=:97 LIBGL_ALWAYS_SOFTWARE=1 BLENDER_USER_CONFIG="$qa/blender-config"
Xvfb "$DISPLAY" -screen 0 1366x900x24 -nolisten tcp > "$proof/xvfb.log" 2>&1 &
x_pid=$!
app_pid=""
wm_pid=""
cleanup() {
  if [[ -n "$app_pid" ]]; then kill "$app_pid" 2>/dev/null || true; fi
  if [[ -n "$wm_pid" ]]; then kill "$wm_pid" 2>/dev/null || true; fi
  kill "$x_pid" 2>/dev/null || true
}
trap cleanup EXIT
for i in {1..40}; do
  if xdpyinfo > /dev/null 2>&1; then break; fi
  sleep .25
done
xdpyinfo > /dev/null
openbox > "$proof/openbox.log" 2>&1 &
wm_pid=$!

capture() { import -window root "$proof/$1.png"; }
key() { xdotool key --clearmodifiers "$@"; }
type_text() { xdotool type --clearmodifiers -- "$1"; }
start_app() {
  "$blender" --window-maximized "$@" >> "$proof/blender.log" 2>&1 &
  app_pid=$!
  win="$(timeout 45 xdotool search --sync --onlyvisible --class blender | head -1)"
  xdotool windowactivate --sync "$win"
  sleep 2
}
pick_file() {
  browser="$(timeout 20 xdotool search --sync --onlyvisible --name 'Blender File View' | head -1)"
  xdotool windowactivate --sync "$browser"
  key ctrl+l ctrl+a
  type_text "$1/"
  key Return
  sleep .5
  geometry="$(xdotool getwindowgeometry --shell "$browser")"
  w="$(awk -F= '$1=="WIDTH" {print $2}' <<< "$geometry")"
  h="$(awk -F= '$1=="HEIGHT" {print $2}' <<< "$geometry")"
  xdotool mousemove --window "$browser" "$((w/2))" "$((h-17))" click 1
  key ctrl+a
  type_text "$2"
  capture "$3"
  xdotool mousemove --window "$browser" "$((w-65))" "$((h-17))" click 1
  sleep 1.5
}

start_app --factory-startup --app-template Video_Editing
sleep 2
capture 00-khoi-tao
xdotool mousemove 680 666 click 1
sleep 2
xdotool mousemove 996 630 click 1
key Escape
capture 01-khong-gian-dung
xdotool mousemove 480 670
key F3
type_text 'Import OTIO'
capture 02-tim-nhap-otio
key Return
pick_file "$qa" ban-giao.otio 03-chon-otio
capture 04-da-nhap
xdotool mousemove 480 670
key Home shift+Left ctrl+s
pick_file "$proof" r27-otio.blend 05-luu-ban-blender
[[ -s "$proof/r27-otio.blend" ]]
key ctrl+q
timeout 18 tail --pid="$app_pid" -f /dev/null
wait "$app_pid"
app_pid=""
start_app "$proof/r27-otio.blend"
xdotool mousemove 480 670
key shift+Left
sleep .8
capture 06-canh-chen-sau-khi-mo-lai
xdotool key --clearmodifiers --repeat 105 --delay 18 Right
sleep .8
capture 07-clip-chinh-sau-khi-mo-lai
python3 - "$proof" <<'PY'
import json
import sys
from pathlib import Path
from PIL import Image

root = Path(sys.argv[1])
counts = {}
for name in ("06-canh-chen-sau-khi-mo-lai", "07-clip-chinh-sau-khi-mo-lai"):
    image = Image.open(root / f"{name}.png").convert("RGB").crop((350, 115, 1010, 475))
    pixels = list(image.getdata())
    counts[name] = {
        "cam": sum(r > 110 and r - b > 65 and g - b > 35 for r, g, b in pixels),
        "lam": sum(b > 110 and b - r > 60 and b - g > 60 for r, g, b in pixels),
    }
assert counts["06-canh-chen-sau-khi-mo-lai"]["cam"] > 3500, counts
assert counts["07-clip-chinh-sau-khi-mo-lai"]["lam"] > 3500, counts
(root / "ket-qua.json").write_text(json.dumps({"blender": "5.3.0", "moLai": True, "mauKhung": counts}, ensure_ascii=False) + "\n")
PY
sha256sum ban-giao.otio | tee "$proof/otio-sha256.txt"
key ctrl+q
timeout 18 tail --pid="$app_pid" -f /dev/null
wait "$app_pid"
app_pid=""
