import hashlib
import http.server
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import signal
import subprocess
import sys
import threading
import time
from urllib.error import HTTPError
from urllib.parse import urlsplit
from urllib.request import Request, urlopen

root = Path(sys.argv[1]).resolve()
arch = sys.argv[2]
assert arch in ("arm64", "x64")
platform = "arm64" if arch == "arm64" else "x86_64"
name = "Veo QA ARM64 26" if arch == "arm64" else "Veo QA Intel 26"
installed = root / "Ứng dụng thử" / f"{name}.app"
mount = root / "gan"
evidence = root / "minh-chung"
evidence.mkdir()
installed.parent.mkdir()
mount.mkdir()
def run(*args, **kwargs):
    return subprocess.run([str(x) for x in args], check=True, **kwargs)
def capture(*args):
    return run(*args, stdout=subprocess.PIPE).stdout
def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()

dmg = root / f"Veo-QA-mac-{arch}_0.3.24-r7.dmg"
run("/usr/bin/hdiutil","attach",dmg,"-mountpoint",mount,"-readonly","-nobrowse","-noautoopen")
try:
    run("/usr/bin/ditto",mount / installed.name,installed)
finally:
    run("/usr/bin/hdiutil","detach",mount)
plist = plistlib.loads((installed/"Contents/Info.plist").read_bytes())
assert plist["CFBundleShortVersionString"] == "0.3.24"
identifier = plist["CFBundleIdentifier"]
assert re.fullmatch(r"vn\.msxgroup\.phongdung\.qa\.(macarm|intel)20261126r5",identifier)
binary = installed / "Contents/MacOS" / plist["CFBundleExecutable"]
resources = installed / "Contents/Resources"
home = root / "home-qa" if arch == "arm64" else Path.home()
home.mkdir(exist_ok=True)
data = home / "Library/Application Support" / identifier
runtime = data / ("phan-chay-" + ("aarch64" if arch == "arm64" else "x86_64"))
assert not data.exists(), "Cần kho kiểm thử trống"
run("/usr/bin/codesign","--verify","--deep","--strict",installed)
run("/usr/bin/lipo",binary,"-verify_arch",platform)
assert list((resources / "licenses").glob("LIBVPX-PATENTS.txt"))
core = {p["tep"]:p for p in json.loads((resources/"phan-chay.json").read_text())["items"]}
renderer, = json.loads((resources/"phan-do-hoa.json").read_text())["items"]
assert len(core) == 7
worker_hash = digest(resources/"worker/dung-app.mjs")
chrome = Path("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
use_renderer = chrome.exists() and subprocess.run(
    ["/usr/bin/lipo",str(chrome),"-verify_arch",platform], stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL
).returncode == 0
public = "https://github.com/CNTTMSXGROUP/veo-ban-cai/releases/download/phan-chay/"
received = {}
requests = []
phase = "cold"
assets = root / "runtime"
for filename,spec in {**core,renderer["tep"]:renderer}.items():
    local = assets / filename
    if local.exists():
        assert local.is_file() and local.stat().st_size == spec["size"] and digest(local) == spec["sha256"], local

class Mirror(http.server.BaseHTTPRequestHandler):
    def log_message(self,*_):
        pass
    def respond(self, code, body=b"", kind="application/json"):
        self.send_response(code)
        self.send_header("Content-Length",str(len(body)))
        self.send_header("Content-Type",kind)
        self.send_header("Access-Control-Allow-Origin","*")
        self.end_headers()
        self.wfile.write(body)
    def do_GET(self):
        path = urlsplit(self.path).path
        if path == "/latest.json":
            return self.respond(204)
        if path == "/qa/tasks":
            return self.respond(200,json.dumps({"renderer":use_renderer and phase=="cold"}).encode())
        filename = path.removeprefix("/runtime/")
        if not path.startswith("/runtime/") or filename not in {*core,renderer["tep"]}:
            return self.respond(404)
        requests.append((phase,filename))
        print(f"{phase}: tải {filename}",flush=True)
        if phase == "warm":
            return self.respond(503)
        file = assets / filename
        if not file.exists():
            assert filename in core, filename
            self.send_response(307)
            self.send_header("Location",public+filename)
            self.end_headers()
            return
        asked = re.fullmatch(r"bytes=(\d+)-",self.headers.get("Range",""))
        start = int(asked[1]) if asked else 0
        size = file.stat().st_size
        if start >= size:
            return self.respond(416)
        self.send_response(206 if asked else 200)
        self.send_header("Content-Length",str(size-start))
        if asked:
            self.send_header("Content-Range",f"bytes {start}-{size-1}/{size}")
        self.end_headers()
        with file.open("rb") as stream:
            stream.seek(start)
            shutil.copyfileobj(stream,self.wfile)
    def do_POST(self):
        endpoint = self.path.removeprefix("/qa/")
        if endpoint not in ("starting","worker","boot","failure","renderer"):
            return self.respond(404)
        count = int(self.headers.get("Content-Length","0"))
        if count > 16_384:
            return self.respond(400)
        received[endpoint] = json.loads(self.rfile.read(count))
        print(f"{phase}: {endpoint}",flush=True)
        return self.respond(200,b"{}")

def start_app():
    env = {**os.environ,"HOME":str(home),"CFFIXED_USER_HOME":str(home),"PATH":"/usr/bin:/bin:/usr/sbin:/sbin",
           "VEO_PHAN_CHAY_GOC":"http://127.0.0.1:59343/runtime",
           "DUNG_KHO_NHAC":str(root/"nhac"),"DUNG_CHEP_LOI":"may"}
    for key in ("DUNG_FFMPEG","DUNG_FFPROBE","DUNG_GROQ_KEYS","DUNG_HYPERFRAMES_DIR","DUNG_DATA"):
        env.pop(key,None)
    if use_renderer:
        env["DUNG_HYPERFRAMES_BROWSER"] = str(chrome)
    (root/"nhac").mkdir(exist_ok=True)
    (root/"nhac/kho-nhac.json").write_text("[]\n")
    with (root/f"app-{phase}.log").open("w") as log:
        return subprocess.Popen([str(binary)],env=env,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)

def stop_app(proc):
    if proc.poll() is None:
        os.killpg(proc.pid,signal.SIGTERM)
        try: proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid,signal.SIGKILL)
            proc.wait(timeout=10)

def await_result(proc, item, seconds):
    end = time.monotonic()+seconds
    while time.monotonic()<end:
        if item in received:
            return received[item]
        if "failure" in received:
            raise RuntimeError(received["failure"])
        assert proc.poll() is None, f"App thoát khi chờ {item}"
        time.sleep(.12)
    raise TimeoutError(f"Chưa thấy {item} của app")

def make_api(boot):
    def api(path, body=None, timeout=75):
        headers = {"x-dung-token":boot["token"]}
        data = None
        if body is not None:
            headers["content-type"] = "application/json"
            data = json.dumps(body,ensure_ascii=False).encode()
        request = Request(f"http://127.0.0.1:{boot['port']}/api/"+path,data,headers)
        try:
            with urlopen(request,timeout=timeout) as result:
                return json.load(result)
        except HTTPError as error:
            raise RuntimeError(f"{path}: HTTP {error.code} {error.read(1200).decode(errors='replace')}") from None
    return api

def await_job(api, route, kind, expected="xong"):
    end = time.monotonic()+120
    while time.monotonic()<end:
        view = api(route)
        job = view["project"].get("job")
        if job and job["kind"] == kind and job["state"] != "dang-chay":
            assert job["state"] == expected, job
            assert view["project"]["busy"] is False, "Đã báo kết quả khi còn giữ lượt"
            return view
        time.sleep(.04)
    raise TimeoutError(f"{kind} {route}")

def media(path):
    return json.loads(capture(runtime/"ffprobe","-v","error","-show_entries",
                              "stream=codec_name,width,height,nb_frames,avg_frame_rate","-of","json",path))["streams"]

def inspect_exports(files):
    assert len(files)==4, files
    pictures=set()
    sound=set()
    for f in files:
        info=media(f)
        if f.endswith(".mp4"):
            v,a=info
            assert v["codec_name"]=="h264" and v["avg_frame_rate"]=="30/1" and int(v["nb_frames"])==60
            pictures.add((v["width"],v["height"]))
        else:
            assert f.endswith(".m4a")
            a,=info
        assert a["codec_name"]=="aac"
        sound.add(capture(runtime/"ffmpeg","-v","error","-i",f,"-map","0:a:0","-c","copy","-f","hash","-hash","sha256","-").strip().decode())
    assert pictures == {(1280,720),(720,1280),(720,720)}
    assert len(sound)==1
    return sorted(pictures),next(iter(sound))

def test_cold(boot):
    api=make_api(boot)
    assert len(api("pixel")["effects"])==244 and len(api("phong-cach/thu-vien")["items"]) >= 802
    clips = []
    for color,hz in (("red",440),("blue",660)):
        clip = root/f"Nguồn {color}.mp4"
        run(runtime/"ffmpeg","-v","error","-nostdin","-f","lavfi","-i",f"color={color}:s=640x360:r=30:d=2",
            "-f","lavfi","-i",f"sine=frequency={hz}:sample_rate=48000:duration=2","-c:v","libx264","-threads","1",
            "-c:a","aac","-y",clip)
        clips.append(clip)
    created = api("projects",{"name":"Đổi khung và xuất","clips":[str(clips[0])],"canvas":"ngang","dungTheo":"hinh","useAi":False})
    route = "projects/"+created["id"]
    await_job(api,route,"dung")
    original=clips[0]
    backup=root/"Nguồn còn nguyên.mp4"
    original.rename(backup)
    shutil.copy2(clips[1],original)
    api(route+"/canvas",{"canvas":"vuong"})
    failed=await_job(api,route,"dung","loi")
    assert "đã đổi nội dung" in failed["project"]["job"]["error"]["message"]
    backup.replace(original)
    api(route+"/canvas",{"canvas":"vuong"})
    assert await_job(api,route,"dung")["plan"]["canvas"]=="vuong"
    api(route+"/export",{"shape":"ngang","extraShapes":["doc","vuong"],"res":720,"audio":True,"audioFmt":"m4a","check":True})
    job=await_job(api,route,"xuat")["project"]["job"]
    sizes,aac=inspect_exports(job["files"])
    peaks=[i for i in job["checks"] if i["name"].endswith("Đỉnh tiếng")]
    assert len(peaks)==4 and all(p["ok"] for p in peaks)
    base = {"retry":True,"shapes":sizes,"audioHash":aac,"peakChecks":len(peaks)}
    (evidence/"kiem-co-ban.json").write_text(json.dumps(base,ensure_ascii=False,indent=2)+"\n")
    print("cold: đổi khung sau lỗi và ba tỷ lệ cùng AAC đã đạt",flush=True)
    scenes=[{"text":"Cảnh một","seconds":2},{"text":"Cảnh hai","seconds":2}]
    motion = False
    if use_renderer:
        status=api("do-hoa")
        assert status["engine"] and status["browser"] and status["three"] and status["gsap"], status
        spec={"version":1,"id":"chu-dong","title":"Góc đọc sách","subtitle":"","accent":"#ffc16e",
              "seconds":2,"speed":1,"chuDong":{"kieu":"nay","theo":"tu","treMs":50,"doNay":1.8}}
        begin=time.monotonic()
        print("cold: bắt đầu dựng bản xem chữ động",flush=True)
        preview=api("do-hoa/xem",{"canvas":"ngang","spec":spec},timeout=235)
        print(f"cold: dựng bản xem trong {time.monotonic()-begin:.2f}s",flush=True)
        assert preview["key"]
        scenes[0]={"text":"","seconds":2,"hinh":{"fit":"vua","startSec":0,"useAudio":False,
                    "asset":{"doHoaMoi":spec,"name":spec["title"]}}}
        motion=True
    story=api("tao-video",{"title":"Góc đọc sách","styleId":"pixel","canvas":"ngang","version":1,"scenes":scenes})
    story_route="projects/"+story["id"]
    await_job(api,story_route,"dung")
    api(story_route+"/export",{"res":720,"check":True})
    story_job=await_job(api,story_route,"xuat")["project"]["job"]
    video,=[f for f in story_job["files"] if f.endswith(".mp4")]
    picture,audio=media(video)
    assert picture["codec_name"]=="h264" and picture["nb_frames"]=="120" and audio["codec_name"]=="aac"
    shutil.copy2(video,evidence/"Goc-doc-sach.mp4")
    return {**base,"storyFrames":120,"motion":motion,
            "project":story["id"],"video":video,"videoHash":digest(Path(video))}

with http.server.ThreadingHTTPServer(("127.0.0.1",59343),Mirror) as server:
    thread=threading.Thread(target=server.serve_forever,daemon=True)
    thread.start()
    result={"architecture":arch,"sourceWorkerSha256":worker_hash,"dmgSha256":digest(dmg),"host":os.uname().machine}
    for phase in ("cold","warm"):
        received.clear()
        proc = start_app()
        try:
            boot = await_result(proc,"boot",180)
            status = boot["status"]
            size = sum(x["size"] for x in core.values()) if phase == "cold" else 0
            assert not status["dang"] and not status["loi"] and status["got"]==status["total"]==size, status
            result[phase]={"bootMs":boot["bootMs"],"bytes":size}
            if phase=="cold":
                for executable in ("node","ffmpeg","ffprobe","whisper-cli"):
                    run("/usr/bin/lipo",runtime/executable,"-verify_arch",platform)
                    run("/usr/bin/codesign","--verify",runtime/executable)
                assert capture(runtime/"node","-p","process.arch").strip().decode()==arch
                decoders = capture(runtime/"ffmpeg","-hide_banner","-decoders").decode()
                assert re.search(r"\blibvpx\s",decoders) and re.search(r"\blibvpx-vp9\s",decoders)
                assert json.loads((runtime/".da-cai.json").read_text()) == {p["ten"]:p["sha256"] for p in core.values()}
                if use_renderer:
                    result["rendererInstallMs"]=await_result(proc,"renderer",150)["ms"]
                result.update(test_cold(boot))
                print("cold: đã dựng và xuất cả hai ca",flush=True)
            else:
                p=make_api(boot)("projects/"+result["project"])["project"]
                assert p["exportPath"]==result["video"] and digest(Path(result["video"]))==result["videoHash"]
                assert not any(p=="warm" for p,_ in requests)
        finally:
            stop_app(proc)
    server.shutdown()
result.pop("video")
(evidence/"ket-qua.json").write_text(json.dumps(result,ensure_ascii=False,indent=2)+"\n")
print(json.dumps(result,ensure_ascii=False),flush=True)
