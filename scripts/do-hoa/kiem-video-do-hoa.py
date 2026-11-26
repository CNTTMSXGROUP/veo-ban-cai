import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path

data, tool_dir, manifest, proof, server_log = map(Path, sys.argv[1:])
part, = json.loads(manifest.read_text(encoding="utf-8-sig"))["items"]
pack = data / "goi-do-hoa" / part["sha256"] / "render-hyperframes"
assert (pack / "render.mjs").is_file()
assert (pack / "node_modules/gsap/dist/gsap.min.js").is_file()
traffic = re.findall(
    rf'"GET /{re.escape(part["tep"])} HTTP/[^"]+" (\d{{3}})',
    server_log.read_text(encoding="utf-8", errors="replace"),
)
assert traffic == ["404", "200"], traffic

preview, = data.glob("phong-cach/do-hoa-v*/*/xem.mp4")
layer = preview.with_name("lop.mov")
video = proof / "Chuyen-dong-chu.mp4"

def run(tool, *args):
    name = tool + (".exe" if sys.platform == "win32" else "")
    return subprocess.check_output([str(tool_dir / name), "-v", "error", *args])

def streams(path):
    return json.loads(run(
        "ffprobe", "-of", "json", "-show_entries",
        "stream=codec_name,width,height,avg_frame_rate,nb_frames,pix_fmt", str(path),
    ))["streams"]

frames = streams(video)
assert len(frames) == 2 and frames[1]["codec_name"] == "aac", frames
assert (frames[0]["width"], frames[0]["height"], frames[0]["codec_name"],
        frames[0]["avg_frame_rate"], frames[0]["nb_frames"]) == (1280, 720, "h264", "30/1", "120"), frames
render = streams(layer)[0]
assert render["codec_name"] == "prores" and render["pix_fmt"].startswith("yuva"), render
view = streams(preview)[0]
assert view["codec_name"] == "h264" and view["nb_frames"] == "120", view

alpha = run("ffmpeg", "-ss", "1", "-i", str(layer), "-vf", "alphaextract,format=gray",
            "-frames:v", "1", "-f", "rawvideo", "-")
assert min(alpha) == 0 and max(alpha) > 220
diff = run("ffmpeg", "-i", str(video), "-vf", "select='eq(n,2)+eq(n,35)',format=gray",
           "-fps_mode", "passthrough", "-frames:v", "2", "-f", "rawvideo", "-")
area = 1280 * 720
assert len(diff) == area * 2
changed = sum(abs(a - b) > 20 for a, b in zip(diff[:area], diff[area:]))
assert changed > 1000, changed
print(json.dumps({
    "platform": sys.platform, "packageSha256": part["sha256"], "packageBytes": part["size"],
    "downloadStatuses": traffic, "downloadOnReopen": 0,
    "videoSha256": hashlib.sha256(video.read_bytes()).hexdigest(),
    "streams": frames, "layer": render, "preview": view, "movingPixels": changed,
    "openedAndPlayedAfterRestart": True,
}, ensure_ascii=False, indent=2))
