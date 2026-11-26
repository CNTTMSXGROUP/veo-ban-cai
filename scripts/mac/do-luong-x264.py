#!/usr/bin/python3
from pathlib import Path
import json
import os
import subprocess as sp
import sys

executable=Path(__file__).resolve().with_name('ffmpeg')
flags=sys.argv[1:]
preset=flags.index('-preset') if '-preset' in flags else -1
target='.Veo-sau-0324-CPU.mp4.dang-xuat.mp4'
if preset<0 or flags[preset+1]!='slow' or Path(flags[-1]).name!=target:
    os.execv(executable,[str(executable),*flags])

result=sp.run([executable,*flags])
if result.returncode:
    sys.exit(result.returncode)
notes=Path(os.environ['VEO_QA_DO_LUONG_X264'])
options=('threads','threads:v','filter_complex_threads')
base=[]
source_options={}
i=0
while i<len(flags)-1:
    option=flags[i].lstrip('-')
    if option in options:
        source_options[option]=flags[i+1]
        i+=2
    else:
        base.append(flags[i])
        i+=1

def decoded(output):
    return sp.check_output([executable,'-v','error','-threads','1','-i',output,
                            '-map','0:v','-f','hash','-hash','sha256','-'],text=True).strip()

runs={}
for count in (1,2,3):
    choice=list(base)
    first=choice.index('-i')
    choice[first:first]=['-threads',str(min(2,count))]
    output=notes.parent/f'cpu-{count}-luong.mp4'
    sp.run([executable,'-filter_complex_threads',str(count),*choice,'-threads:v',str(count),output],
           stdout=sp.DEVNULL,check=True)
    runs[count]=decoded(output)
    output.unlink()
notes.write_text(json.dumps({'productionThreads':source_options,'productionDecoded':decoded(flags[-1]),'forcedThreadsDecoded':runs},
                            indent=2)+chr(10))
