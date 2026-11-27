from contextlib import closing
from pathlib import Path
import hashlib
import json
import os
import platform
from queue import Queue, Empty
import shutil
import sqlite3
import subprocess as sp
import sys
from threading import Thread
import time
from urllib.request import Request,urlopen
import wave

qa,runtime,worker,fonts=[Path(a).resolve() for a in sys.argv[1:]]
suffix='.exe' if os.name=='nt' else ''
node,ff,probe=[runtime/(p+suffix) for p in ('node','ffmpeg','ffprobe')]
assert all(p.is_file() for p in (node,ff,probe,worker)) and fonts.is_dir()
to_json=lambda x: json.dumps(x,ensure_ascii=False,separators=(',',':'))
def hash_file(path):
    with Path(path).open('rb') as file:
        return hashlib.file_digest(file,'sha256').hexdigest()
worker_hash=hash_file(worker)
assert worker_hash==os.environ['VEO_QA_WORKER_SHA']

qa.mkdir()
(qa/'nhac').mkdir()
(qa/'nhac/kho-nhac.json').write_text('[]'+chr(10))
(qa/'mau').mkdir()
sp.run([ff,'-loglevel','error','-f','lavfi','-i','testsrc2=size=320x568:r=30:d=2',
        '-f','lavfi','-i','sine=f=440:r=48000:d=2','-pix_fmt','yuv420p','-c:v','libx264','-c:a','aac',qa/'mau/s1.mp4'],check=True)
sp.run([ff,'-loglevel','error','-i',qa/'mau/s1.mp4','-frames:v','1',qa/'mau/bia.jpg'],check=True)
template={'version':2,'captions':{'breaks':{},'shifts':{},'texts':{}},
          'style':{'captionKind':'trang-vien-den','captionUpper':False,'captionLower':True,
                   'captionFontPx':53,'captionOutlinePx':4,'captionCenterY':.69,'maxWordsPerPage':9,
                   'keepGapSec':.4,'loudnessLufs':-14,'hook':{'on':False,'line1':None,'line2':None},
                   'tail':{'on':True},'music':{'clips':[],'adjusts':[]}}}

def make_fixture(case):
    data=qa/case
    src=data/'du-an/p1/lam-viec/nguon/s1.mp4'
    src.parent.mkdir(parents=True)
    shutil.copy2(qa/'mau/s1.mp4',src)
    cover=data/'bia-goc.jpg'
    shutil.copy2(qa/'mau/bia.jpg',cover)
    damaged=src.parents[2]/'tep'/(hash_file(cover)+'.jpg')
    damaged.parent.mkdir()
    content=bytearray(cover.read_bytes())
    content[-1]^=1
    damaged.write_bytes(content)
    assert hash_file(damaged)!=hash_file(cover)
    plan=json.loads(to_json(template))
    plan['sources']=[{'id':'s1','path':str(src),'original':str(src),'durationSec':2,'frames':60,'hasAudio':True}]
    plan['items']=[{'id':'i1','sourceId':'s1','startSec':0,'endSec':2,'keep':True}]
    plan['words']=[{'id':'w1','sourceId':'s1','heard':'mẫu','text':'mẫu','startSec':.2,'endSec':.7}]
    plan['style']['cover']={'on':False,'line1':'','line2':'','imagePath':str(cover)}
    plan['style']['voiceClean']='tat'
    before=[to_json(plan),to_json(plan|{'words':[plan['words'][0]|{'text':'giữ nội dung'}]})]
    file=data/'phong-dung.db'
    with closing(sqlite3.connect(file)) as db, db:
        db.executescript("""CREATE TABLE projects(
           id TEXT PRIMARY KEY, name TEXT NOT NULL, status TEXT NOT NULL, head INTEGER NOT NULL DEFAULT -1, clips_json TEXT NOT NULL,
           instructions TEXT NOT NULL DEFAULT '', created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, job_json TEXT, export_path TEXT, voice_gain_db REAL);
           CREATE TABLE versions(project_id TEXT NOT NULL, n INTEGER NOT NULL, plan_json TEXT NOT NULL, label TEXT NOT NULL,
             created_at INTEGER NOT NULL, PRIMARY KEY(project_id,n));
           PRAGMA user_version=0;""")
        db.execute("insert into projects(id,name,status,head,clips_json,created_at,updated_at) values('p1','Kho thử','san-sang',1,?,1,2)",(to_json([str(src)]),))
        db.executemany("insert into versions values('p1',?,?,?,1)",[(n,text,'Bản '+str(n+1)) for n,text in enumerate(before)])
    return data,file,src,cover,before

def state(file):
    with closing(sqlite3.connect(file.as_uri()+'?mode=ro',uri=True)) as db:
        assert db.execute('PRAGMA integrity_check').fetchone()==('ok',)
        return {
            'user_version':db.execute('PRAGMA user_version').fetchone()[0],
            'exports':bool(db.execute("select 1 from sqlite_master where name='export_requests'").fetchone()),
            'rows':[x[0] for x in db.execute('select plan_json from versions order by n')],
        }


data,file,src,cover,before=make_fixture('kho')
contents={p:hash_file(p) for p in (src,cover)}
env={k:v for k,v in os.environ.items() if not k.upper().startswith('DUNG_') and k.upper() not in ('NODE_OPTIONS','NODE_PATH')}
env.update(DUNG_DATA=str(data),DUNG_PORT='0',DUNG_FONTS=str(fonts),DUNG_FFMPEG=str(ff),
           DUNG_FFPROBE=str(probe),DUNG_KHO_NHAC=str(qa/'nhac'),DUNG_CLAUDE=str(qa/'khong-co-claude'))

def launch(stop):
    hook=Path(__file__).with_name('sau-khi-ghi.mjs').resolve()
    args=[node]+(['--import',hook.as_uri()] if stop else [])+[worker]
    with (qa/('chan.log' if stop else 'mo-lai.log')).open('w') as log:
        return sp.Popen(args,env=env,cwd=worker.parent,stdin=sp.PIPE,stdout=sp.PIPE,stderr=log)

def read_json(process):
    lines=Queue(maxsize=1)
    Thread(target=lambda:lines.put(process.stdout.readline()),daemon=True).start()
    try: raw=lines.get(timeout=45)
    except Empty: raise TimeoutError('Phần dựng chưa báo sẵn sàng')
    assert raw, 'Phần dựng đã dừng trước khi có kết quả'
    return json.loads(raw)

child=launch(True)
try:
    hook=read_json(child)
    assert hook=={'write':1,'transaction':True}, hook
finally:
    if child.poll() is None:
        child.kill()
        assert child.wait(timeout=15)!=0
crash=state(file)
assert all(hash_file(path)==h for path,h in contents.items())
assert crash=={'user_version':0,'exports':False,'rows':before}, crash

stage=src.parents[2]/'tep'
partial=stage/'.dang-chep-00000000-0000-4000-8000-000000000001'
note=stage/'.dang-chep-ghi-chu'
partial.write_bytes(bytes(4*1024*1024))
note.write_bytes(b'Ghi chu rieng')
stage_bytes=partial.stat().st_size
assert stage_bytes==4194304

proc=launch(False)
try:
    live=read_json(proc)
    def api(route,data=None):
        request=Request(f"http://127.0.0.1:{live['port']}/api/{route}",
                        None if data is None else json.dumps(data).encode(),
                        {'content-type':'application/json','x-dung-token':live['token']})
        with urlopen(request,timeout=15) as res: return json.load(res)
    project=api('projects/p1')
    assert len(project['history'])==2 and project['head']==1 and project['plan']['words'][0]['text']=='giữ nội dung'
    assert project['timeline']['frames']==60
    current=state(file)
    assert current['exports'] and current['user_version']==2
    assert not partial.exists() and note.read_bytes()==b'Ghi chu rieng'
    assert all(json.loads(raw)['sources'][0]['path']=='lam-viec/nguon/s1.mp4' for raw in current['rows'])
    copied=Path(project['plan']['style']['cover']['imagePath'])
    assert copied.is_relative_to(data/'du-an/p1/tep') and hash_file(copied)==contents[cover]
    assert all(hash_file(path)==h for path,h in contents.items())
    start=api('projects/p1/export',{'video':False,'audio':True,'audioFmt':'wav','check':True,'name':'Sau khi phuc hoi'})
    until=time.monotonic()+45
    while time.monotonic()<until:
        p=api('projects/p1')['project']
        if not p['busy']:
            assert p['job']['state']=='xong',p['job']
            wav,=[Path(f) for f in p['job']['files'] if f.endswith('.wav')]
            with wave.open(str(wav),'rb') as sound:
                assert (sound.getnframes(),sound.getframerate(),sound.getnchannels())==(96000,48000,2)
            break
        time.sleep(.15)
    else: raise TimeoutError('Xuất WAV sau khi phục hồi')
finally:
    proc.stdin.close()
    try: proc.wait(timeout=10)
    except sp.TimeoutExpired: proc.kill(); proc.wait()

proof={'platform':sys.platform,'arch':platform.machine(),'node':sp.check_output([node,'-v'],text=True).strip(),
       'workerSha256':worker_hash,'rollbackAfterKill':True,'userVersionAfterKill':0,'newTableAfterKill':False,
       'originalAssetsIntact':True,'legacyDamagedAssetRepaired':True,'recoveredVersions':2,
       'userVersionAfterRestart':2,'wavFrames':96000,
       'removedStaleBytes':stage_bytes,'similarNotePreserved':True}
(qa/'ket-qua.json').write_text(json.dumps(proof,ensure_ascii=False,indent=2)+chr(10),encoding='utf-8')
print(json.dumps(proof,ensure_ascii=False))
