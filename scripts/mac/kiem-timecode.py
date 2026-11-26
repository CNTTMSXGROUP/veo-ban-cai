from fractions import Fraction
from pathlib import Path
from urllib.parse import urlsplit
from urllib.request import Request, url2pathname, urlopen
import hashlib
import json
import platform
import shutil
import subprocess
import sys
import time
import xml.etree.ElementTree as ET

ffmpeg, ffprobe, evidence = map(Path, sys.argv[1:])
boot = json.load(sys.stdin)
work = evidence.parent / "moc-canh-chen"
work.mkdir()
evidence.mkdir(exist_ok=True)

def run(exe, *args):
    return subprocess.check_output([str(exe), *map(str, args)], timeout=60)

def ff(*args):
    return run(ffmpeg, "-hide_banner", "-v", "error", "-nostdin", *args)

def digest(file):
    return hashlib.sha256(file.read_bytes()).hexdigest()

def api(path, body=None):
    req = Request(f"http://127.0.0.1:{boot['port']}/api/{path}",
                  None if body is None else json.dumps(body).encode(),
                  {"content-type":"application/json", "x-dung-token":boot["token"]})
    with urlopen(req, timeout=35) as response:
        return json.load(response)

def wait_job(route, kind, request=None):
    deadline = time.monotonic() + 150
    while time.monotonic() < deadline:
        view = api(route)
        job = view["project"].get("job") or {}
        if job.get("kind") == kind and (request is None or job.get("xuatId") == request) and not view["project"]["busy"]:
            assert job["state"] == "xong", job
            return view
        time.sleep(0.2)
    raise TimeoutError(kind)

main = work / "Máy A.mp4"
insert = work / "Máy B.mov"
ff("-f","lavfi","-i","color=blue:s=320x180:r=30:d=6",
   "-an","-c:v","libx264","-threads","1",main)
ff("-f","lavfi","-i","color=red:s=320x180:r=25:d=3","-vf",
   "drawbox=color=lime:t=fill:enable='eq(n,20)',drawbox=color=yellow:t=fill:enable='gt(n,20)'",
   "-an","-c:v","libx264","-threads","1","-timecode","01:00:00:00",insert)
probe, = json.loads(run(ffprobe,"-v","error","-select_streams","v:0","-show_streams","-of","json",insert))["streams"]
assert (probe["r_frame_rate"],probe["nb_frames"],probe["tags"]["timecode"]) == ("25/1","75","01:00:00:00")

project = api("projects",{"name":"Mốc cảnh máy B","clips":[str(main)],"canvas":"ngang",
                         "dungTheo":"hinh","useAi":False,"autoExport":False})
route = "projects/"+project["id"]
assert wait_job(route,"dung")["timeline"]["frames"] == 180
asset, = api(route+"/tu-lieu",{"paths":[str(insert)]})["added"]
changed = api(route+"/act",{"name":"placeAsset","args":[asset["id"],"","",
    {"outAt":{"startFrame":60,"endFrame":90},"offsetSec":0.8}]})
assert changed["timeline"]["inserts"][0]["startFrame"] == 60
request = api(route+"/export",{"video":True,"res":720,"check":False,"fcpxml":True,"draft":True})["requestId"]
wait_job(route,"xuat",request)
record = next(x for x in api(route+"/exports")["runs"] if x["id"] == request)
files = {Path(x["path"]).suffix:Path(x["path"]) for x in record["result"]["files"]}
assert files.keys() == {".mp4",".fcpxml",".otio"}, files

xml = ET.parse(files[".fcpxml"])
connected, = xml.findall(".//asset-clip[@lane='1']")
media = xml.find(f".//asset[@id='{connected.attrib['ref']}']")
sec = lambda element,key: Fraction(element.attrib[key].removesuffix("s"))
assert sec(media,"start") == 3600 and sec(media,"duration") == 3
assert sec(connected,"start") - sec(media,"start") == Fraction(4,5)
assert sec(connected,"offset") == 2 and sec(connected,"duration") == 1
url = urlsplit(media.find("media-rep").attrib["src"])
assert url.scheme == "file" and not url.netloc and digest(Path(url2pathname(url.path))) == digest(insert)

otio = json.loads(files[".otio"].read_text(encoding="utf-8"))
gap, clip = otio["tracks"]["children"][1]["children"]
assert gap["OTIO_SCHEMA"] == "Gap.1" and gap["source_range"]["duration"]["value"] == 60
available = clip["media_references"]["DEFAULT_MEDIA"]["available_range"]
assert available["start_time"]["value"] == 108000 and available["duration"]["value"] == 90
assert clip["source_range"]["start_time"]["value"] == 108024 and clip["source_range"]["duration"]["value"] == 30
assert {v[key]["rate"] for v in (available,clip["source_range"]) for key in ("start_time","duration")} == {30}

frames = [(59,[0,0,255]),(60,[0,255,0]),(63,[255,255,0]),(90,[0,0,255])]
vf = "select='" + "+".join(f"eq(n,{frame})" for frame,_ in frames) + "',scale=2:2:flags=area,format=rgb24"
rgb = ff("-i",files[".mp4"],"-vf",vf,"-fps_mode","passthrough","-f","rawvideo","-")
assert len(rgb) == 12 * len(frames)
observed = [list(rgb[i:i+3]) for i in range(0,len(rgb),12)]
assert all(abs(x-y)<32 for actual,(_,expected) in zip(observed,frames) for x,y in zip(actual,expected)), observed
stream, = json.loads(run(ffprobe,"-v","error","-select_streams","v:0","-show_entries",
                         "stream=codec_name,width,height,nb_frames,avg_frame_rate","-of","json",files[".mp4"]))["streams"]
assert stream == {"codec_name":"h264","width":1280,"height":720,"nb_frames":"180","avg_frame_rate":"30/1"}, stream
for ext, path in files.items():
    shutil.copy2(path,evidence/("moc-canh-chen"+ext))
proof = {"system":platform.system(),"arch":platform.machine(),"sourceFps":25,"sourceTimecode":"01:00:00:00",
         "sourceFrame":20,"timelineFrames":[60,90],"fcpxmlStart":connected.attrib["start"],
         "otioMediaOffsetFrames":24,"video":stream,"pixels":dict(zip((f for f,_ in frames),observed)),
         "sha256":{ext:digest(path) for ext,path in files.items()}}
(evidence/"moc-canh-chen.json").write_text(json.dumps(proof,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
print(json.dumps(proof),flush=True)
