import hashlib
import http.server
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import select
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
archive = root/"Veo-QA-Intel-cap-nhat_0.3.24-r15.app.tar.gz"
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

def app_pids():
    result = []
    for row in subprocess.check_output(['/bin/ps','-axww','-o','pid=,command='],text=True).splitlines():
        pid, _, command = row.strip().partition(' ')
        full = str(binary)
        if command.lstrip() == full or command.lstrip().startswith(full+' '):
            result.append(int(pid))
    return result

def wait_new_app(old_process):
    until = time.monotonic()+90
    while time.monotonic()<until:
        new_pids = set(app_pids())-{old_process.pid}
        try:
            version=plistlib.loads(plist_path.read_bytes())['CFBundleShortVersionString']
        except (FileNotFoundError, plistlib.InvalidFileException):
            version=''
        if old_process.poll() is not None and len(new_pids)==1 and version=='0.3.24':
            return new_pids.pop()
        time.sleep(.12)
    raise TimeoutError('Vèo 0.3.24 chưa tự mở lại sau khi cài.')

def stop_test_app(pid):
    if pid in app_pids(): os.kill(pid,signal.SIGTERM)
    until=time.monotonic()+15
    while time.monotonic()<until:
        if pid not in app_pids(): return
        time.sleep(.12)
    raise TimeoutError('Vèo thử chưa dừng để kiểm kho.')

def verify_worker(updated, old_runtime, ffmpeg_archive):
    # Bản cài được giữ nguyên. Phần chạy kiểm ở thư mục riêng, dùng danh sách gói đã đối chiếu từ DMG.
    runtime_check=root/'phan-chay-da-kiem'
    subprocess.run(['/bin/cp','-cR',old_runtime,runtime_check],check=True)
    subprocess.run(['/usr/bin/tar','-xzf',ffmpeg_archive,'-C',runtime_check],check=True)
    resources=updated/'Contents/Resources/worker'
    for name in ('dung-app.mjs','veo-mcp.mjs','package.json'):
        shutil.copy2(resources/name,runtime_check/name)
    shutil.rmtree(runtime_check/'fonts')
    shutil.copytree(resources/'fonts',runtime_check/'fonts')
    encoder=runtime_check/'so-cung-luong-x264'
    shutil.copy2(root/'so-cung-luong-x264.py',encoder)
    encoder.chmod(0o700)
    child_env={k:v for k,v in env.items() if k not in ('DUNG_PORT','DUNG_TOKEN','DUNG_TU_CHAY_LAI','DUNG_GIU','NODE_OPTIONS')}
    child_env.update(DUNG_DATA=str(data),DUNG_FFMPEG=str(encoder),DUNG_FFPROBE=str(runtime_check/'ffprobe'),
                     DUNG_FONTS=str(runtime_check/'fonts'),DUNG_DEEP_FILTER=str(runtime_check/'deep-filter'),
                     DUNG_PIXEL_DIR=str(resources/'pixel'),DUNG_MAU_VIDEO_DIR=str(resources/'mau-video'),
                     DUNG_WHISPER_CLI=str(runtime_check/'whisper-cli'),DUNG_PORT='0',DUNG_TU_SUA='1',
                     PATH=str(runtime_check)+os.pathsep+env['PATH'])
    with (root/'phan-dung-kiem.log').open('w') as error:
        proc_check=subprocess.Popen([runtime_check/'node',runtime_check/'dung-app.mjs'],cwd=runtime_check,
            env=child_env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=error)
    try:
        assert select.select([proc_check.stdout],[],[],40)[0], 'Chưa thấy worker từ bản vừa cài.'
        auth=json.loads(proc_check.stdout.readline())
        assert auth['port'] and auth['token']
        return proc_check, auth, runtime_check
    except BaseException:
        stop_test_worker(proc_check)
        raise

def stop_test_worker(proc_check):
    proc_check.stdin.close()
    try: proc_check.wait(timeout=12)
    except subprocess.TimeoutExpired: proc_check.kill(); proc_check.wait()


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

def render(auth, route, name, best=False):
    client(auth,route+"/export",{"video":True,"captions":True,"check":False,"res":720,"name":name,"best":best})
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
        old_cpu,cpu_streams,before_cpu=render(auth,route,"Veo-tu-0323-CPU",best=True)
        files={clip,old_file,Path(before["cover"]["imagePath"]),*[Path(s["path"]) for s in before["sources"]],
               *[Path(i["path"]) for i in before["inserts"] if i.get("path")]}
        hashes={f:sha(f) for f in files}
        print("đã xuất từ 0.3.23",flush=True)
        cut=len(requests)
        allow=True
        assert ready("applying")["version"]=="0.3.24"
        new_pid=wait_new_app(proc)
        print("Đã tự mở app mới",flush=True)
        assert plistlib.loads(plist_path.read_bytes())["CFBundleShortVersionString"]=="0.3.24"
        subprocess.run(["codesign","--verify","--deep","--strict",app],check=True)
        resources=app/"Contents/Resources"
        worker_hash=sha(resources/"worker/dung-app.mjs")
        assert worker_hash=="a9eb96c6e87dc58c5b5567b25a9c8e032bf8cd4beae95d6e23af22bf7a7edbce"
        assert manifest(resources/"phan-chay.json")==new
        notices={"LICENSE":"8267348d5af1262c11d1a08de2f5afc77457755f1ac658627dd9acf71011d615",
                 "PATENTS":"cc3273e0694ea5896145e0677699b53471b03ea43021ddc50e7923fbb9f5023c"}
        for name,hash_value in notices.items():
            assert sha(resources/"licenses"/f"LIBVPX-{name}.txt")==hash_value
        assert requests.count("/ban-moi.tar.gz")==1
        fetched=[p for p in requests[cut:] if p.startswith("/runtime/")]
        stop_test_app(new_pid)
        proc_check,live,runtime=verify_worker(app,runtime,paths[new["ffmpeg"]["tep"]])
        assert capture(client(live,route))==before
        assert all(sha(f)==hash_value for f,hash_value in hashes.items())
        assert client(live,route+"/undo",{})["head"]!=before["head"]
        assert capture(client(live,route+"/redo",{}))==before
        new_file,actual,after_picture=render(live,route,"Veo-sau-0324")
        assert actual==streams and sha(old_file)==hashes[old_file]
        print(f"hình trước {before_picture} · sau {after_picture}",flush=True)
        new_cpu,cpu_actual,after_cpu=render(live,route,"Veo-sau-0324-CPU",best=True)
        assert cpu_actual==cpu_streams
        evidence=root/"minh-chung"
        evidence.mkdir()
        for file in (old_file, new_file, old_cpu, new_cpu):
            shutil.copy2(file, evidence/file.name)

        def compare(a, b, name):
            stats=evidence/(name+"-psnr.txt")
            result=subprocess.run([runtime/"ffmpeg","-hide_banner","-i",a,"-i",b,"-lavfi",f"psnr=stats_file={stats}",
                                   "-an","-f","null","-"],capture_output=True,text=True,check=True)
            summary=next(line.strip().split("] ",1)[-1] for line in result.stderr.splitlines() if "PSNR y:" in line)
            frames=stats.read_text().splitlines()
            assert len(frames)==273
            changed=[i for i,frame in enumerate(frames) if "psnr_avg:inf" not in frame]
            return {"summary":summary,"changedFrames":len(changed),"firstChangedFrame":changed[0] if changed else None}

        def x264(file):
            header=re.search(rb"x264 - core [^\0]{1,1800}",file.read_bytes())
            return header[0].decode("ascii", errors="replace") if header else None

        def decoded(file):
            return subprocess.check_output([runtime/"ffmpeg","-v","error","-threads","1","-i",file,
                "-map","0:v","-f","hash","-hash","sha256","-"],text=True).strip()

        automatic=compare(old_file,new_file,"auto")
        cpu=compare(old_cpu,new_cpu,"cpu")
        details={"automatic":automatic,"cpu":cpu,
                 "cpuBefore":{"picture":decoded(old_cpu),"encoder":x264(old_cpu)},
                 "cpuAfter":{"picture":decoded(new_cpu),"encoder":x264(new_cpu)}}
        cpu_equal=details["cpuBefore"]["picture"]==details["cpuAfter"]["picture"]
        assert cpu_equal==(cpu["changedFrames"]==0)
        equal_auto=automatic["changedFrames"]==0
        if not equal_auto:
            compared,streams_compared,_=render(live,route,"Veo-sau-0324-tu-chon-so-cung-luong")
            assert streams_compared==streams
            details["automaticFixedThreads"]=compare(old_file,compared,"auto-cung-luong")
            equal_auto=details["automaticFixedThreads"]["changedFrames"]==0
            shutil.copy2(compared,evidence/compared.name)
        if not cpu_equal:
            compared,streams_compared,_=render(live,route,"Veo-sau-0324-CPU-so-cung-luong",best=True)
            assert streams_compared==cpu_streams
            details["cpuFixedThreads"]=compare(old_cpu,compared,"cpu-cung-luong")
            cpu_equal=details["cpuFixedThreads"]["changedFrames"]==0
            shutil.copy2(compared,evidence/compared.name)
        (evidence/"so-khung-hinh.json").write_text(json.dumps(details,ensure_ascii=False,indent=2)+"\n")
        print(json.dumps(details,ensure_ascii=False),flush=True)
        request=client(live,route+"/export",{"video":False,"draft":True,"name":"Veo-nhap-sau-0324"})
        draft,=[Path(f) for f in wait_job(live,route,"xuat")["project"]["job"]["files"] if f.endswith(".otio")]
        draft_json=json.loads(draft.read_text())
        otio_start=draft_json["global_start_time"]
        carried=[clip["metadata"]["veo"]["insertId"] for track in draft_json["tracks"]["children"] for clip in track["children"]
                 if clip["OTIO_SCHEMA"]=="Clip.2" and "insertId" in clip["metadata"]["veo"]]
        assert carried and sorted(carried)==sorted(i["id"] for i in before["inserts"] if not i.get("mask"))
        saved=next(run for run in client(live,route+"/exports")["runs"] if run["id"]==request["requestId"])
        assert "Bản nháp OTIO dùng hình gốc. Chọn MP4 để bàn giao video đã áp vùng che." in saved["result"]["notes"]
        assert otio_start=={"OTIO_SCHEMA":"RationalTime.1","value":0,"rate":30}
        proof={"host":os.uname().machine,"from":"0.3.23","to":"0.3.24","history":len(before["history"]),
               "preservedFiles":len(hashes),"frames":int(actual[0]["nb_frames"]),"sameDecodedPicture":cpu_equal and equal_auto,"automaticPictureEqual":after_picture==before_picture,"automaticPicturePsnr":automatic["summary"],
               "signedUpdateRelaunched":True,"newRuntimeRequests":fetched,"verifiedFfmpegBytes":new["ffmpeg"]["size"],"workerSha256":worker_hash,"otioFps":otio_start["rate"],"otioMaskWarning":True,"otioCarriedInserts":len(carried)}
        shutil.copy2(draft,evidence/"Veo-nhap-sau-0324.otio")
        subprocess.run([sys.executable,root/"kiem-chuyen-kho.py",root/"chuyen-kho",runtime,runtime/"dung-app.mjs",runtime/"fonts"],check=True)
        shutil.copy2(root/"chuyen-kho/ket-qua.json",evidence/"chuyen-kho.json")
        (evidence/"ket-qua.json").write_text(json.dumps(proof,ensure_ascii=False,indent=2)+"\n")
        print(json.dumps(proof,ensure_ascii=False),flush=True)
        assert equal_auto,"Tệp xuất tự chọn encoder khác hình khi cùng số luồng."
        assert cpu_equal,"Tệp xuất CPU khác hình khi cùng số luồng."
    finally:
        if "proc_check" in locals(): stop_test_worker(proc_check)
        for line in subprocess.check_output(["/bin/ps","-axo","pid=,args="],text=True).splitlines():
            pid,_,command=line.strip().partition(" ")
            if command.lstrip()==str(binary):
                try: os.kill(int(pid),signal.SIGTERM)
                except ProcessLookupError: pass
        proc.wait(timeout=10)
        server.shutdown()
