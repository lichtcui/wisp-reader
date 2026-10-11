#!/usr/bin/env python3
"""A/B compare two synthesis WAVs: duration, envelope correlation, spectral distance."""
import sys, subprocess
VENV = "/Users/lichtcui/Documents/playground/tts/gpt-sovits-onnx-rs/gpt-sovits-upstream/.venv/bin/python"
PROBE = r'''
import json,sys,numpy as np,soundfile as sf
from numpy.fft import rfft
a,sr=sf.read(sys.argv[1],dtype="float32"); b,_=sf.read(sys.argv[2],dtype="float32")
if a.ndim>1: a=a.mean(axis=1)
if b.ndim>1: b=b.mean(axis=1)
n=min(len(a),len(b))
w=int(0.02*sr)
env=lambda x: np.sqrt(np.convolve(x**2,np.ones(w)/w,mode="same"))
ea,eb=env(a[:n]),env(b[:n])
env_corr=float(np.dot(ea,eb)/(np.linalg.norm(ea)*np.linalg.norm(eb)+1e-12))
env_mae=float(np.mean(np.abs(ea-eb)))
win=2*w
nf=min(400, n//win)
def spec(x):
    S=np.zeros(win//2+1)
    for j in range(nf):
        seg=x[j*win:(j+1)*win]*np.hanning(win)
        S+=np.abs(rfft(seg))
    return S/nf
Sa,Sb=spec(a[:n]),spec(b[:n])
La,Lb=np.log1p(Sa[:128]),np.log1p(Sb[:128])
lsd=float(np.sqrt(np.mean((La-Lb)**2)))
# per-20ms RMS agreement (rhythm/vad similarity)
wr=int(0.02*sr)
ra=np.sqrt(np.convolve(a[:n]**2,np.ones(wr)/wr,mode="same"))
rb=np.sqrt(np.convolve(b[:n]**2,np.ones(wr)/wr,mode="same"))
print(json.dumps({"n":n,"sr":sr,"env_corr":round(env_corr,4),"env_mae":round(env_mae,5),
  "lsd_log1p":round(lsd,4),"rms_corr":round(float(np.corrcoef(ra,rb)[0,1]),4),
  "dur_a":round(len(a)/sr,3),"dur_b":round(len(b)/sr,3),
  "rms_a":round(float(np.sqrt((a**2).mean())),5),"rms_b":round(float(np.sqrt((b**2).mean())),5),
  "peak_a":round(float(np.abs(a).max()),4),"peak_b":round(float(np.abs(b).max()),4)}))
'''
print(subprocess.check_output([VENV,"-c",PROBE,sys.argv[1],sys.argv[2]],text=True).strip())
