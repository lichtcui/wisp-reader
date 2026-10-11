#!/usr/bin/env python3
"""ASR a full clip and print timed segments, to compare a repeated region a vs b."""
import sys, os
os.environ.setdefault("HF_ENDPOINT", "https://hf-mirror.com")
import soundfile as sf
sys.path.insert(0, "/Users/lichtcui/Documents/playground/tts/p3/harness")
from asr import model

def main(p, a, b):
    x, sr = sf.read(p, dtype="float32")
    if x.ndim > 1: x = x.mean(axis=1)
    segs, info = model().transcribe(x, language="zh", beam_size=5, vad_filter=False,
                                    condition_on_previous_text=False)
    print(f"### {p}  dur={len(x)/sr:.1f}s")
    for s in segs:
        mark = ""
        if a - 0.5 <= s.start <= a + 6: mark = "  <== REGION-A"
        if b - 0.5 <= s.start <= b + 6: mark = "  <== REGION-B"
        print(f"  [{s.start:7.2f} -> {s.end:7.2f}] {s.text.strip()}{mark}")

if __name__ == "__main__":
    main(sys.argv[1], float(sys.argv[2]), float(sys.argv[3]))
