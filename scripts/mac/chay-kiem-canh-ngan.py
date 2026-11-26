from pathlib import Path
import json
import os
import select
import shutil
import subprocess
import sys

resources, runtime, qa = map(Path, sys.argv[1:])
assert os.environ["GITHUB_ACTIONS"] == "true" and qa.is_relative_to(Path(os.environ["RUNNER_TEMP"]))
assert subprocess.check_output([runtime/"node","-p","process.arch"],text=True).strip()=="x64"
worker=resources/"worker"
for name in ("dung-app.mjs","veo-mcp.mjs","package.json"):
    shutil.copy2(worker/name,runtime/name)
music=qa/"nhac-trong"
music.mkdir()
env={k:v for k,v in os.environ.items() if not k.startswith("DUNG_") and k not in {"NODE_OPTIONS","NODE_PATH"}}
env.update(DUNG_DATA=str(qa/"Kho thử"),DUNG_KHO_NHAC=str(music),DUNG_PORT="0",
    DUNG_FFMPEG=str(runtime/"ffmpeg"),DUNG_FFPROBE=str(runtime/"ffprobe"),
    DUNG_FONTS=str(worker/"fonts"),DUNG_MAU_VIDEO_DIR=str(worker/"mau-video"),
    DUNG_WHISPER_MODEL=str(qa/"khong-chep-loi"))
proc=subprocess.Popen([runtime/"node",runtime/"dung-app.mjs"],cwd=runtime,env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE)
try:
    assert select.select([proc.stdout],[],[],45)[0]
    line=proc.stdout.readline()
    assert line, "Phần dựng kết thúc trước khi mở kết nối cục bộ."
    boot=json.loads(line)
    subprocess.run([sys.executable,qa/"kiem-canh-ngan.py",runtime/"ffmpeg",runtime/"ffprobe",qa/"minh-chung"],
        input=json.dumps(boot),text=True,check=True,timeout=180)
finally:
    proc.stdin.close()
    try: proc.wait(timeout=10)
    except subprocess.TimeoutExpired: proc.terminate(); proc.wait(timeout=5)
