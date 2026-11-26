import hashlib
import http.server
import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import subprocess
import sys
import threading
import time
from urllib.parse import urlsplit
from urllib.request import Request, urlopen

root = Path(sys.argv[1]).resolve()
assert os.uname().machine == "x86_64"
home = root/"home-qa"
home.mkdir()
app = root/"install/Veo QA Intel 26.app"
plist_path = app/"Contents/Info.plist"
old_app = plistlib.loads(plist_path.read_bytes())
assert old_app["CFBundleShortVersionString"] == "0.3.23"
assert old_app["CFBundleIdentifier"] == "vn.msxgroup.phongdung.qa.intel20261126r5"
binary = app/"Contents/MacOS"/old_app["CFBundleExecutable"]
data = home/"Library/Application Support"/old_app["CFBundleIdentifier"]
runtime = data/"phan-chay-x86_64"
archive = root/"Veo-QA-Intel-cap-nhat_0.3.24-r10.app.tar.gz"
sig = archive.with_name(archive.name+".sig").read_text().strip()
feed = {"version":"0.3.24","notes":"Kiểm thử tự cập nhật","platforms":
        {"darwin-x86_64":{"signature":sig,"url":"http://127.0.0.1:59343/ban-moi.tar.gz"}}}

def manifest(file):
    items = json.loads(file.read_text())["items"]
    assert len(items)==7 and {p["ten"] for p in items}=={"node","ffmpeg","whisper","loc-on","ve-chu","chan-dung","tieng-dong"}
    return {p["ten"]:p for p in items}

def sha(file):
    with Path(file).open("rb") as f:
        return hashlib.file_digest(f,"sha256").hexdigest()

old = manifest(app/"Contents/Resources/phan-chay.json")
new = manifest(root/"phan-chay-moi.json")
assert {name for name in old if old[name]["sha256"]!=new[name]["sha256"]} == {"ffmpeg"}
paths = {p["tep"]:(root/"runtime"/p["tep"]) for p in [*old.values(),*new.values()]}
for p in [*old.values(),*new.values()]:
    file = paths[p["tep"]]
    assert file.stat().st_size==p["size"] and sha(file)==p["sha256"]

reports, requests = {}, []
allow = False
class Server(http.server.BaseHTTPRequestHandler):
    def log_message(self,*_): pass

    def response(self, status, data=b""):
        self.send_response(status)
        self.send_header("Content-Length",str(len(data)))
        self.send_header("Content-Type","application/json")
        self.send_header("Access-Control-Allow-Origin","*")
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        uri=urlsplit(self.path).path
        if uri == "/qa/tasks":
            return self.response(200,json.dumps({"apply":allow,"renderer":False}).encode())
        if uri == "/latest.json":
            return self.response(200,json.dumps(feed).encode())
        if uri == "/ban-moi.tar.gz":
            file=archive
        elif uri.startswith("/runtime/") and uri[9:] in paths:
            file=paths[uri[9:]]
        else:
            return self.response(404)
        requests.append(uri)
        self.send_response(200)
        self.send_header("Content-Length",str(file.stat().st_size))
        self.end_headers()
        with file.open("rb") as f:
            shutil.copyfileobj(f,self.wfile)

    def do_POST(self):
        name=self.path.removeprefix("/qa/")
        if name not in ("old","applying","starting","worker","boot","failure"):
            return self.response(404)
        reports[name]=json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        print(name,flush=True)
        return self.response(200,b"{}")

def ready(name, timeout=180):
    end=time.monotonic()+timeout
    while time.monotonic()<end:
        if "failure" in reports:
            raise RuntimeError(reports["failure"])
        if name in reports:
            return reports[name]
        time.sleep(.12)
    raise TimeoutError(f"Chưa nhận bước {name}")

def client(auth, route, payload=None):
    headers={"x-dung-token":auth["token"]}
    if payload is not None:
        headers["content-type"]="application/json"
    req=Request(f"http://127.0.0.1:{auth['port']}/api/"+route,
                None if payload is None else json.dumps(payload,ensure_ascii=False).encode(),headers)
    with urlopen(req,timeout=60) as reply:
        return json.load(reply)

def wait_job(auth, route, kind):
    end=time.monotonic()+160
    while time.monotonic()<end:
        v=client(auth,route)
        job=v["project"].get("job") or {}
        if job.get("kind")==kind and not v["project"]["busy"]:
            assert job["state"]=="xong",job
            return v
        time.sleep(.3)
    raise TimeoutError(kind)

def render(auth, route, name):
    client(auth,route+"/export",{"video":True,"captions":True,"check":False,"res":720,"name":name})
    view=wait_job(auth,route,"xuat")
    file,=[Path(f) for f in view["project"]["job"]["files"] if f.endswith(".mp4")]
    assert file.is_file() and file.is_relative_to(data) and file.stem==name
    streams=json.loads(subprocess.check_output([runtime/"ffprobe","-v","error","-show_entries",
        "stream=codec_name,width,height,avg_frame_rate,nb_frames","-of","json",file]))["streams"]
    assert [x["codec_name"] for x in streams]==["h264","aac"]
    decoded=subprocess.check_output([runtime/"ffmpeg","-v","error","-i",file,"-map","0:v","-f","hash","-hash","sha256","-"]).strip().decode()
    return file, streams, decoded

def capture(v):
    plan=v["plan"]
    return {"head":v["head"],"stamp":v["stamp"],"history":[(r["n"],r["label"]) for r in v["history"]],
            "frames":v["timeline"]["frames"],"captions":[page["text"] for page in v["timeline"]["pages"]],
            "sources":plan["sources"],"inserts":plan["style"]["inserts"],"cover":plan["style"]["cover"]}

def stamps(items):
    assert json.loads((runtime/".da-cai.json").read_text())=={name:p["sha256"] for name,p in items.items()}

env={key:value for key,value in os.environ.items() if not key.startswith("DUNG_") and key!="NODE_OPTIONS"}
env.update(HOME=str(home), CFFIXED_USER_HOME=str(home), PATH="/usr/bin:/bin:/usr/sbin:/sbin",
           VEO_PHAN_CHAY_GOC="http://127.0.0.1:59343/runtime", DUNG_CHEP_LOI="may",
           DUNG_WHISPER_MODEL=str(root/"ggml-base.en-q5_1.bin"), DUNG_KHO_NHAC=str(root/"nhac"))
(root/"nhac").mkdir()
(root/"nhac/kho-nhac.json").write_text("[]\n")
with http.server.ThreadingHTTPServer(("127.0.0.1",59343),Server) as server, (root/"app.log").open("w") as log:
    threading.Thread(target=server.serve_forever,daemon=True).start()
    proc=subprocess.Popen([binary],env=env,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
    try:
        auth=ready("old")
        stamps(old)
        subprocess.run(["lipo",runtime/"node","-verify_arch","x86_64"],check=True)
        clip=root/"qa-upgrade-voice.mp4"
        cover=root/"Bìa thử.jpg"
        subprocess.run([runtime/"ffmpeg","-v","error","-i",clip,"-frames:v","1","-y",cover],check=True)
        row=client(auth,"projects",{"name":"Kho cũ · Ba thẻ màu","clips":[str(clip)],"ngonNgu":"en","useAi":False,"autoExport":False})
        route="projects/"+row["id"]
        view=wait_job(auth,route,"dung")
        source=view["plan"]["sources"][0]["id"]
        caption="Ba THẺ Màu · giữ kho cũ"
        sticker=client(auth,route+"/nhan-dan",{"id":"mui-ten"})["id"]
        mask={"mode":"solid","shape":"rect","strength":100,"color":"#172937"}
        actions=[
            ("editPageText",[view["timeline"]["pages"][0]["firstWordId"],caption]),
            ("placeMask",[mask,{"sourceId":source,"startSec":1,"endSec":3},{"box":{"x":325,"y":695,"w":432,"h":418}}]),
            ("placeAsset",[sticker,"","",{"at":{"sourceId":source,"startSec":3.1,"endSec":5},"box":{"x":90,"y":980,"w":360,"h":260}}]),
            ("setCoverImage",[str(cover)]),
            ("editCoverImage",[{"zoom":130,"x":21,"preset":"dien-anh"}]),
        ]
        for name,args in actions:
            view=client(auth,route+"/act",{"name":name,"args":args,"stamp":view["stamp"]})
        before=capture(view)
        assert len(before["history"])==6 and caption in before["captions"]
        assert any(i.get("asset")==sticker for i in before["inserts"]) and before["cover"]["imageEdit"]["zoom"]==130
        old_file,streams,before_picture=render(auth,route,"Veo-tu-0323")
        files={clip,old_file,Path(before["cover"]["imagePath"]),*[Path(s["path"]) for s in before["sources"]],
               *[Path(i["path"]) for i in before["inserts"] if i.get("path")]}
        hashes={f:sha(f) for f in files}
        print("đã xuất từ 0.3.23",flush=True)
        cut=len(requests)
        allow=True
        assert ready("applying")["version"]=="0.3.24"
        live=ready("boot")
        assert plistlib.loads(plist_path.read_bytes())["CFBundleShortVersionString"]=="0.3.24"
        subprocess.run(["codesign","--verify","--deep","--strict",app],check=True)
        resources=app/"Contents/Resources"
        worker_hash=sha(resources/"worker/dung-app.mjs")
        assert worker_hash=="cf6d5faf0ab00e1ef3d07f351756d2859f1f697a804979495b6ae40dcfb98477"
        assert manifest(resources/"phan-chay.json")==new
        notices={"LICENSE":"8267348d5af1262c11d1a08de2f5afc77457755f1ac658627dd9acf71011d615",
                 "PATENTS":"cc3273e0694ea5896145e0677699b53471b03ea43021ddc50e7923fbb9f5023c"}
        for name,hash_value in notices.items():
            assert sha(resources/"licenses"/f"LIBVPX-{name}.txt")==hash_value
        assert [p for p in requests[cut:] if p.startswith("/runtime/")]==["/runtime/"+new["ffmpeg"]["tep"]]
        assert live["status"]["got"]==live["status"]["total"]==new["ffmpeg"]["size"]
        stamps(new)
        assert capture(client(live,route))==before
        assert all(sha(f)==hash_value for f,hash_value in hashes.items())
        assert client(live,route+"/undo",{})["head"]!=before["head"]
        assert capture(client(live,route+"/redo",{}))==before
        new_file,actual,after_picture=render(live,route,"Veo-sau-0324")
        assert actual==streams and sha(old_file)==hashes[old_file]
        print(f"hình trước {before_picture} · sau {after_picture}",flush=True)
        assert after_picture==before_picture,"Tệp xuất lại khác hình giải mã."
        client(live,route+"/export",{"video":False,"draft":True,"name":"Veo-nhap-sau-0324"})
        draft,=[Path(f) for f in wait_job(live,route,"xuat")["project"]["job"]["files"] if f.endswith(".otio")]
        otio_start=json.loads(draft.read_text())["global_start_time"]
        assert otio_start=={"OTIO_SCHEMA":"RationalTime.1","value":0,"rate":30}
        proof={"host":os.uname().machine,"from":"0.3.23","to":"0.3.24","history":len(before["history"]),
               "preservedFiles":len(hashes),"frames":int(actual[0]["nb_frames"]),"sameDecodedPicture":True,
               "runtimeBytes":new["ffmpeg"]["size"],"workerSha256":worker_hash,"otioFps":otio_start["rate"]}
        evidence=root/"minh-chung"
        evidence.mkdir()
        shutil.copy2(new_file,evidence/"Veo-sau-0324.mp4")
        shutil.copy2(draft,evidence/"Veo-nhap-sau-0324.otio")
        (evidence/"ket-qua.json").write_text(json.dumps(proof,ensure_ascii=False,indent=2)+"\n")
        print(json.dumps(proof,ensure_ascii=False),flush=True)
    finally:
        for line in subprocess.check_output(["/bin/ps","-axo","pid=,args="],text=True).splitlines():
            pid,_,command=line.strip().partition(" ")
            if command.lstrip()==str(binary):
                try: os.kill(int(pid),signal.SIGTERM)
                except ProcessLookupError: pass
        proc.wait(timeout=10)
        server.shutdown()
