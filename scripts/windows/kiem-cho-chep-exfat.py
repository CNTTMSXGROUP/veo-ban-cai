import hashlib
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import time
from urllib.request import Request, urlopen
import wave
import unicodedata

d=Path(__file__).resolve().parent
root=d/('kiem-app-'+sys.argv[2])
root.mkdir()
data=root/'kho'
out=Path(sys.argv[3])/('Bộ thử phục hồi '+sys.argv[2])
out.mkdir()
assert root.stat().st_dev != out.stat().st_dev
runtime=Path(sys.argv[4])
worker=Path(sys.argv[1]).resolve()
ext='.exe' if sys.platform=='win32' else ''
node=runtime/('node'+ext)
ffmpeg=runtime/('ffmpeg'+ext)
ffprobe=runtime/('ffprobe'+ext)
cover=out/'Bộ bàn giao thử.jpg'
audio=out/'Bộ bàn giao thử.wav'
subprocess.run([ffmpeg,'-v','error','-f','lavfi','-i','color=blue:s=32x32:d=1','-frames:v','1',root/'cover.jpg'],check=True)
length=256*1024*1024
with (root/'source.wav').open('wb') as file:
    file.write(struct.pack('<4sI4s4sIHHIIHH4sI',b'RIFF',36+length,b'WAVE',b'fmt ',16,1,2,48000,192000,4,16,b'data',length))
    file.write(b'VEO\0')
    file.seek(44+length-4)
    file.write(b'CHEP')
total=44+length
def digest(path):
    with path.open('rb') as f: return hashlib.file_digest(f,'sha256').hexdigest()
expected=digest(root/'source.wav')
stage=subprocess.Popen([node,d/'giu-lan-xuat.mjs',root,data,out],cwd=worker.parent)
try:
    until=time.monotonic()+15
    while time.monotonic()<until and stage.poll() is None:
        try: partial=audio.stat().st_size
        except FileNotFoundError: partial=-1
        if 1 < partial < total:
            stage.kill()
            break
        time.sleep(.0005)
    assert stage.wait(timeout=10)!=0 and 1 < partial < total
finally:
    if stage.poll() is None: stage.kill(); stage.wait()
prefix=audio.stat()
assert prefix.st_ino and 0 < prefix.st_size < total
cover_stamp=cover.stat().st_mtime_ns
cover_hash=digest(cover)
job=json.loads((root/'yeu-cau.json').read_text())
assert Path(job['stage']).is_dir()
env={**os.environ,'DUNG_DATA':str(data),'DUNG_FFMPEG':str(ffmpeg),'DUNG_FFPROBE':str(ffprobe),
     'DUNG_FONTS':str(worker.parent/'fonts'),'DUNG_CHEP_LOI':'may','DUNG_PORT':'0'}
for key in ('DUNG_TU_CHAY_LAI','DUNG_TOKEN','DUNG_GIU','DUNG_LOG','DUNG_GROQ_KEYS'): env.pop(key,None)
app=subprocess.Popen([node,worker],env=env,cwd=worker.parent,stdout=subprocess.PIPE,stdin=subprocess.PIPE)
try:
    boot=json.loads(app.stdout.readline())
    def api(path,post=False):
        request=Request(f"http://127.0.0.1:{boot['port']}/api/{path}",b'{}' if post else None,
                        {'x-dung-token':boot['token'],'content-type':'application/json'})
        with urlopen(request,timeout=12) as r: return json.load(r)
    route='projects/'+job['projectId']
    export=route+'/exports/'+job['requestId']
    read=lambda: next(r for r in api(route+'/exports')['runs'] if r['id']==job['requestId'])
    assert read()['state']=='bi-ngat'
    assert api(export+'/retry',True).get('ok')
    until=time.monotonic()+60
    while time.monotonic()<until:
        result=read()
        if result['state']!='dang-chay':
            assert result['state']=='xong',(result,api(route)['project']['job'].get('error'))
            break
        time.sleep(.06)
    else: raise TimeoutError('Chưa thử lại xong')
    assert [Path(f['path']).name for f in result['result']['files']]==[cover.name,audio.name],result
    assert digest(audio)==expected and digest(cover)==cover_hash and cover.stat().st_mtime_ns==cover_stamp
    assert audio.stat().st_ino==prefix.st_ino and audio.stat().st_size==total
    names=[]
    for file in out.iterdir():
        if file.name.startswith("._"):
            with file.open("rb") as metadata: assert metadata.read(4)==bytes.fromhex("00051607")
        else: names.append(unicodedata.normalize("NFC",file.name))
    assert sorted(names)==sorted([cover.name,audio.name]), names
    assert not Path(job['stage']).exists()
    with wave.open(str(audio),'rb') as f: assert f.getframerate()==48000 and f.getnframes()*4==length
    proof={'filesystem':'ExFAT','fileBytes':total,'resumedBytes':prefix.st_size,'sameInode':True,
           'coverPreserved':True,'stageRemoved':True,'wavSha256':expected,'duplicateFiles':0}
    (root/'ket-qua.json').write_text(json.dumps(proof)+'\n')
    print(json.dumps(proof),flush=True)
finally:
    if app.stdin: app.stdin.close()
    try: app.wait(timeout=10)
    except subprocess.TimeoutExpired: app.kill(); app.wait()
