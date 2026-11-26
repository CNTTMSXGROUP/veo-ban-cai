from base64 import b64decode
from pathlib import Path
from time import monotonic, sleep
from urllib.request import Request, urlopen
import hashlib
import json
import os
import re
import shutil
import subprocess as sp
import sys

ffmpeg,ffprobe,evidence=map(Path,sys.argv[1:])
boot=json.load(sys.stdin)
root=evidence.parent
evidence.mkdir()
mau=[
    ("huong-dan","sang","ngang",20), ("tro-chuyen","am","doc",18), ("san-pham","dien-anh","doc",16),
    ("ban-tin","lanh","ngang",18), ("chuyen-dong","ruc-ro","vuong",16), ("pixel","phim-cu","vuong",16),
]
res={"ngang":(1280,720),"doc":(720,1280),"vuong":(720,720)}
sha=lambda b: hashlib.sha256(b).hexdigest()

def request(path,body=None,headers=None):
    args={"content-type":"application/json","x-dung-token":boot["token"],**(headers or {})}
    return urlopen(Request(f"http://127.0.0.1:{boot['port']}/api/{path}",
        None if body is None else json.dumps(body,ensure_ascii=False).encode(),args),timeout=45)

def api(path,body=None):
    with request(path,body) as response: return json.load(response)

def wait(id,kind,key=None):
    until=monotonic()+90
    while monotonic()<until:
        view=api("projects/"+id)
        job=view["project"].get("job") or {}
        if job.get("kind")==kind and (key is None or job.get("xuatId")==key) and not view["project"]["busy"]:
            assert job["state"]=="xong",(id,job)
            return view
        sleep(.18)
    raise TimeoutError((id,kind))

def run(exe,*args):
    return sp.check_output([str(exe),*map(str,args)],timeout=80)

def ff(*args):
    return run(ffmpeg,"-hide_banner","-v","error","-nostdin",*args)

def streams(file):
    rows=json.loads(run(ffprobe,"-v","error","-show_entries",
        "stream=codec_type,codec_name,width,height,nb_frames,avg_frame_rate:format=duration","-of","json",file))
    v,=[r for r in rows["streams"] if r["codec_type"]=="video"]
    a=[r["codec_name"] for r in rows["streams"] if r["codec_type"]=="audio"]
    return v,a,float(rows["format"]["duration"])

def psnr(a,b):
    check=sp.run([str(ffmpeg),"-hide_banner","-nostdin","-filter_complex_threads","1",
        "-i",str(evidence/(a+".mp4")),"-i",str(evidence/(b+".mp4")),
        "-lavfi","psnr","-an","-f","null","-"],capture_output=True,text=True,check=True,timeout=75)
    result=re.search(r"average:([\d.]+|inf) min:([\d.]+|inf)",check.stderr)
    assert result,(a,b,check.stderr[-400:])
    return result.groups()

def export(id,name,w,h):
    at=monotonic()
    base="projects/"+id
    key=api(base+"/export",{"video":True,"res":720,"best":True,"check":True,"name":name})["requestId"]
    wait(id,"xuat",key)
    row=next(r for r in api(base+"/exports")["runs"] if r["id"]==key)
    video,=[f for f in row["result"]["files"] if f["kind"]=="video"]
    file=Path(video["path"])
    v,a,d=streams(file)
    assert (v["width"],v["height"],v["codec_name"],v["avg_frame_rate"],int(v["nb_frames"]),a)==(w,h,"h264","30/1",120,["aac"]),(name,v,a,d)
    assert abs(d-4)<0.07,(name,d)
    pic=ff("-ss","0.9","-i",file,"-frames:v","1","-vf","scale=32:18,format=rgb24","-f","rawvideo","-")
    audio=ff("-i",file,"-vn","-ac","1","-ar","48000","-f","s16le","-")
    assert len(pic)==32*18*3 and len(audio)>=4*48000*2,(name,len(pic),len(audio))
    checks=video.get("checks") or row["result"].get("checks") or []
    assert checks,(name,row["result"])
    dest=evidence/(name+".mp4")
    shutil.copy2(file,dest)
    return {"picture":sha(pic),"audio":sha(audio),"sha256":sha(dest.read_bytes()),"frames":120,
        "size":[w,h],"ms":round((monotonic()-at)*1000),
        "qc":len(checks),"warnings":[str(c["name"]) for c in checks if not c["ok"]]}

path=root/"Clip chung.mp4"
ff("-f","lavfi","-i","testsrc2=s=320x180:r=30:d=4","-f","lavfi","-i","sine=f=480:r=48000:d=4",
   "-c:v","libx264","-c:a","aac","-threads","1",path)
source_sha=sha(path.read_bytes())
id=api("projects",{"name":"Clip gốc cho sáu phong cách","clips":[str(path)],"canvas":"ngang",
                   "dungTheo":"hinh","useAi":False,"autoExport":False})["id"]
original=wait(id,"dung")
assert original["timeline"]["frames"]==120
if original["plan"]["style"]["tail"]["on"]:
    original=api(f"projects/{id}/act",{"name":"setStyle","args":[{"tail":{"on":False}}],"stamp":original["stamp"]})
assert not original["plan"]["style"]["tail"]["on"] and original["timeline"]["tailFadeSec"]==0
base=export(id,"clip-goc",*res["ngang"])
brief=[{"text":"Sắp xếp một góc đọc sách","seconds":2},{"text":"Sáng vừa đủ, dễ tập trung","seconds":2}]
rows=[]
for style,look,shape,duration in mau:
    route="phong-cach/mau-veo/"+style
    with request(route) as response: demo=response.read()
    with request(route,headers={"Range":"bytes=100-227"}) as response:
        assert response.status==206 and response.read()==demo[100:228]
    with request(route+"/anh.jpg") as response: assert response.read(3)==bytes((255,216,255))
    sample=root/(style+"-mau.mp4")
    sample.write_bytes(demo)
    v,a,d=streams(sample)
    assert v["codec_name"]=="h264" and abs(d-duration)<0.12,(style,d,v)
    assert v["width"]*res[shape][1]==v["height"]*res[shape][0],(style,v)
    kieu=api(route,{})
    assert kieu["id"]=="veo-"+style+"-v1" and kieu["style"]["mauHinh"]["preset"]==look
    again=api("projects/"+id)
    assert again["head"]==original["head"]
    at=monotonic()
    preview=api(f"projects/{id}/so-bo-kieu",{"at":0.9,"stamp":again["stamp"],"style":kieu["style"],"rutNghi":False})
    preview_ms=round((monotonic()-at)*1000)
    left,right=[b64decode(preview[key]["anh"],validate=True) for key in ("truoc","sau")]
    assert left.startswith(b"\xff\xd8\xff") and right.startswith(b"\xff\xd8\xff") and left!=right,style
    assert preview["truoc"]["at"]==preview["sau"]["at"] and "Màu hình toàn video" in preview["doi"]
    assert api("projects/"+id)["stamp"]==again["stamp"],style
    at=monotonic()
    changed=api(f"projects/{id}/act",{"name":"applyKieu","args":[kieu["style"],kieu["name"]],"stamp":preview["stamp"]})
    apply_ms=round((monotonic()-at)*1000)
    assert changed["plan"]["style"]["looks"][0]["preset"]==look
    for name in ("sources","items","words"):
        assert changed["plan"][name]==original["plan"][name],(style,name)
    edited=export(id,"sua-"+style,*res["ngang"])
    assert edited["picture"]!=base["picture"] and edited["audio"]==base["audio"],(style,edited,base)
    undone=api(f"projects/{id}/undo",{})
    assert undone["head"]==original["head"] and undone["plan"]==original["plan"],style
    assert undone["timeline"]==original["timeline"],style

    made=api("tao-video",{"version":1,"title":"Góc đọc sách","styleId":style,"canvas":shape,"scenes":brief})["id"]
    story=wait(made,"dung")
    sb=story["plan"]["storyboard"]
    assert sb["styleId"]==style and sb["canvas"]==shape and story["timeline"]["frames"]==120
    assert [{k:c[k] for k in ("text","seconds")} for c in sb["scenes"]]==brief,style
    created=export(made,"tao-"+style,*res[shape])
    # shortcut: ngưỡng cho clip tổng hợp này, hiệu chuẩn lại nếu đổi tư liệu hoặc cấu hình xuất.
    db,_=psnr("clip-goc","sua-"+style)
    assert float(db)<48.5,(style,db)
    edited["psnrAgainstOriginalDb"]=db
    rows.append({"style":style,"preset":look,"canvas":shape,"sampleSeconds":d,"sampleBytes":len(demo),
                 "previewMs":preview_ms,"previewChanged":True,"applyMs":apply_ms,"undo":True,"edit":edited,"create":created})
    print(style,edited["ms"],created["ms"],edited["warnings"],created["warnings"],flush=True)
assert sha(path.read_bytes())==source_sha and len(rows)==6
for purpose in ("edit","create"):
    assert len({r[purpose]["picture"] for r in rows})==6
restored=export(id,"clip-sau-hoan-tac",*res["ngang"])
assert restored["audio"]==base["audio"]
db,minimum=psnr("clip-goc","clip-sau-hoan-tac")
assert float(minimum)>=49.5,(db,minimum)
proof={"source":os.environ["VEO_QA_SOURCE"],"workerSha256":os.environ["VEO_QA_WORKER_SHA"],"system":os.environ["VEO_QA_OS"],
       "inputSha256":source_sha,"restored":True,"baselineTail":False,"rows":rows,"useAi":False,
       "restoredAveragePsnrDb":db,"restoredMinPsnrDb":minimum,"restoredAudioExact":True}
(evidence/"ket-qua-kho.json").write_text(json.dumps(proof,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
print(evidence/"ket-qua-kho.json",flush=True)
