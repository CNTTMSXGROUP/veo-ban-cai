#!/usr/bin/python3
from pathlib import Path
from os import execv
import sys

ffmpeg=Path(__file__).resolve().with_name('ffmpeg')
args=sys.argv[1:]
if args and Path(args[-1]).name.endswith('-so-cung-luong.mp4.dang-xuat.mp4'):
    uncontrolled=iter(args)
    args=[]
    for arg in uncontrolled:
        if arg in ('-threads','-threads:v','-filter_complex_threads'):
            next(uncontrolled)
        else:
            args.append(arg)
execv(ffmpeg,[str(ffmpeg),*args])
