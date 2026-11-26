from fractions import Fraction
from pathlib import Path
from urllib.request import Request, urlopen
import hashlib
import json
import os
import shutil
import subprocess as sp
import sys
import time
import xml.etree.ElementTree as ET

ffmpeg,ffprobe,evidence=map(Path,sys.argv[1:])
boot=json.load(sys.stdin)
trial=evidence.parent/'canh-ngan'
trial.mkdir()
evidence.mkdir()

main, insert = trial/"May-A.mp4", trial/"May-B.mov"
colors = [(255,0,0),(0,255,255),(0,255,0),(255,0,255),(255,255,0),(255,110,0)]

def run(*args, **opt): return sp.run([str(x) for x in args],check=True,**opt)
def digest(path): return hashlib.sha256(path.read_bytes()).hexdigest()
def ff(*args,**opt): return run(ffmpeg,"-hide_banner","-v","error","-nostdin",*args,**opt)

ff("-f","lavfi","-i","color=blue:s=320x180:r=30:d=6","-an","-c:v","libx264","-threads","1",main)
boxes=",".join(f"drawbox=c=0x{r:02x}{g:02x}{b:02x}:t=fill:enable='between(n,{3*i},{3*i+2})'" for i,(r,g,b) in enumerate(colors))
ff("-f","lavfi","-i","color=red:s=320x180:r=30:d=0.6","-vf",boxes,"-an","-c:v","libx264","-threads","1",
   "-timecode","01:00:00:00",insert)
media = json.loads(run(ffprobe,"-v","error","-select_streams","v:0","-show_streams","-of","json",insert,capture_output=True).stdout)["streams"][0]
assert (media["nb_frames"],media["avg_frame_rate"],media["tags"]["timecode"]) == ("18","30/1","01:00:00:00")


def api(path,body=None):
    req=Request(f"http://127.0.0.1:{boot['port']}/api/{path}",None if body is None else json.dumps(body).encode(),
        {"content-type":"application/json","x-dung-token":boot["token"]})
    with urlopen(req,timeout=30) as resp: return json.load(resp)
def wait(route,kind,key=None):
    until=time.monotonic()+60
    while time.monotonic()<until:
        view=api(route)
        job=view["project"].get("job") or {}
        if job.get("kind")==kind and (key is None or job.get("xuatId")==key) and not view["project"]["busy"]:
            assert job["state"]=="xong",job
            return view
        time.sleep(.15)
    raise TimeoutError(kind)
project=api("projects",{"name":"Ba cach xu ly canh ngan","clips":[str(main)],"canvas":"ngang","dungTheo":"hinh",
                        "useAi":False,"autoExport":False})
route="projects/"+project["id"]
assert wait(route,"dung")["timeline"]["frames"]==180
asset,=api(route+"/tu-lieu",{"paths":[str(insert)]})["added"]
for begin,end,mode in [(30,54,"cham"),(60,84,"giu-cuoi"),(90,126,"lap")]:
    api(route+"/act",{"name":"placeAsset","args":[asset["id"],"","",
        {"outAt":{"startFrame":begin,"endFrame":end},"offsetSec":.2,"short":mode}]})
key=api(route+"/export",{"video":True,"best":True,"res":720,"check":False,"fcpxml":True,"draft":True})["requestId"]
wait(route,"xuat",key)
record=next(x for x in api(route+"/exports")["runs"] if x["id"]==key)
assert "Ứng dụng nhập OTIO tự chọn khung khi phát cảnh kéo chậm. Dùng MP4 để đối chiếu từng khung." in record["result"]["notes"]
files={Path(f["path"]).suffix:Path(f["path"]) for f in record["result"]["files"]}
assert files.keys()=={".mp4",".fcpxml",".otio"}

sources={}
for frame in range(30,54): sources[frame]=6+(frame-30)//2
for frame in range(60,84): sources[frame]=6+min(frame-60,11)
for frame in range(90,126): sources[frame]=(frame-90+6)%18
expected={i: colors[sources[i]//3] if i in sources else (0,0,255) for i in range(180)}
rgba=ff("-i",files[".mp4"],"-vf","scale=2:2:flags=area,format=rgb24","-f","rawvideo","-",capture_output=True).stdout
assert len(rgba)==180*12
wrong=[(i, tuple(rgba[12*i:12*i+3]), color) for i,color in expected.items()
       if any(abs(x-y)>30 for x,y in zip(rgba[12*i:12*i+3],color))]
assert not wrong,wrong


xml=ET.parse(files[".fcpxml"])
def stamp(element,key): return Fraction(element.attrib[key].removesuffix("s"))
project_map={}
for clip in xml.findall(".//asset-clip[@lane='1']"):
    local=stamp(clip,"start")
    at,n=(int(stamp(clip,key)*30) for key in ("offset","duration"))
    points=clip.findall("timeMap/timept")
    assert len(points) in (0,2)
    if points:
        t0,t1=(stamp(p,"time") for p in points)
        a,b=(stamp(p,"value") for p in points)
        assert t0==local and (t1-t0)*30==n and 3600<=a<=b<=Fraction(18003,5)
    for k in range(n):
        s=local+Fraction(k,30) if not points else a+(b-a)*k/n
        assert at+k not in project_map
        project_map[at+k]=int((s-3600)*30)
assert len(xml.findall(".//asset-clip[@lane='1']"))==6 and project_map==sources


assert os.environ['VEO_QA_SOURCE']=='a8ce2349f19b342fec6f018325bec950b5353f48'
proof={'source':os.environ['VEO_QA_SOURCE'],'workerSha256':os.environ['VEO_QA_WORKER_SHA'],
       'system':os.environ['VEO_QA_OS'],'mp4Frames':180,'originalFrames':18,'mappedFrames':len(project_map),
       'exportNotice':True,'outputsSha256':{ext:digest(path) for ext,path in files.items()}}
for ext,path in files.items(): shutil.copy2(path,evidence/('canh-ngan'+ext))
(evidence/'ket-qua.json').write_text(json.dumps(proof,indent=2)+'\n')
print(json.dumps(proof),flush=True)
