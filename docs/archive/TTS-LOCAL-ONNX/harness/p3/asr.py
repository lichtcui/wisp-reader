#!/usr/bin/env python3
"""ASR transcription with faster-whisper (small, int8, cpu) for P3 repeat checking."""
import os, sys, time
os.environ.setdefault("HF_ENDPOINT", "https://hf-mirror.com")
import numpy as np, soundfile as sf
from faster_whisper import WhisperModel

M = None
def model():
    global M
    if M is None:
        M = WhisperModel("small", device="cpu", compute_type="int8", cpu_threads=4,
                         download_root="/Users/lichtcui/Documents/playground/tts/p3/whisper-models")
    return M

def transcribe(path, language="zh"):
    a, sr = sf.read(path, dtype="float32")
    if a.ndim > 1: a = a.mean(axis=1)
    t0 = time.time()
    segs, info = model().transcribe(a, language=language, beam_size=5,
                                    vad_filter=False, condition_on_previous_text=False)
    out = [{"start": round(s.start,2), "end": round(s.end,2), "text": s.text.strip()} for s in segs]
    return {"dur": round(len(a)/sr,2), "asr_sec": round(time.time()-t0,2),
            "text": "".join(s["text"] for s in out), "segments": out}

if __name__ == "__main__":
    import json
    for p in sys.argv[1:]:
        r = transcribe(p)
        print(f"=== {p}  dur={r['dur']}s asr={r['asr_sec']}s")
        print(r["text"])
