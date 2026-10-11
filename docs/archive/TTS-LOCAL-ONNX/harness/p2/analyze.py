#!/usr/bin/env python3
"""Audio analysis for P2 outputs: duration, speech-only duration, RMS/peak, RTF."""
import json, subprocess, sys
from pathlib import Path

VENV = "/Users/lichtcui/Documents/playground/tts/gpt-sovits-onnx-rs/gpt-sovits-upstream/.venv/bin/python"
P2 = Path("/Users/lichtcui/Documents/playground/tts/p2")

PROBE = r'''
import json,sys,numpy as np,soundfile as sf
p=sys.argv[1]
a,sr=sf.read(p,dtype="float32",always_2d=False)
if a.ndim>1: a=a.mean(axis=1)
n=len(a); dur=n/sr
# 50ms window energy, threshold 0.005, find first/last active window
w=int(0.05*sr)
if w<1: w=1
pad=(w-n%w)%w
win=np.concatenate([a,np.zeros(pad,dtype=a.dtype)]).reshape(-1,w)
rms=np.sqrt((win**2).mean(axis=1))
act=np.where(rms>0.005)[0]
lead = float(act[0]*w/sr) if len(act) else dur
tail = float((len(win)-1-act[-1])*w/sr) if len(act) else 0.0
speech = float((act[-1]-act[0]+1)*w/sr) if len(act) else 0.0
print(json.dumps({"sr":sr,"samples":n,"duration_sec":round(dur,3),
  "leading_silence_sec":round(lead,3),"trailing_silence_sec":round(tail,3),
  "speech_sec":round(speech,3),"rms":round(float(np.sqrt((a**2).mean())),5),
  "peak":round(float(np.abs(a).max()),5),"clipped":int(np.sum(np.abs(a)>=0.999))}))
'''

def probe(path):
    out = subprocess.check_output([VENV, "-c", PROBE, str(path)], text=True)
    return json.loads(out)

def main():
    for res_path in sorted((P2 / "results").glob("*.json")):
        r = json.loads(res_path.read_text())
        wav = P2 / f"audio/{r['id']}.wav"
        if not wav.exists():
            continue
        info = probe(wav)
        r["audio"] = info
        total = r.get("demo_total_ms")
        if total:
            r["rtf_total"] = round(total["avg"] / 1000.0 / info["duration_sec"], 4)
            if info["speech_sec"] > 0:
                r["rtf_speech"] = round(total["avg"] / 1000.0 / info["speech_sec"], 4)
        res_path.write_text(json.dumps(r, ensure_ascii=False, indent=2))
        print(f"{r['id']:32s} dur={info['duration_sec']:7.3f}s speech={info['speech_sec']:7.3f}s "
              f"rms={info['rms']:.4f} peak={info['peak']:.3f} rtf={r.get('rtf_total')}")

if __name__ == "__main__":
    main()
