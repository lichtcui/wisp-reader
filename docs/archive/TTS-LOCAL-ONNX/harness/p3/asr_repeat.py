#!/usr/bin/env python3
"""ASR-based repeat check: transcribe, then look for a repeated sentence/n-gram.

faster-whisper timestamps are unreliable on clips with many long pauses, so this
is used as a *qualitative* cross-check only (see P3 report §口径).
"""
import os, sys, re
os.environ.setdefault("HF_ENDPOINT", "https://hf-mirror.com")
sys.path.insert(0, "/Users/lichtcui/Documents/playground/tts/p3/harness")
from asr import transcribe

def norm(t):
    return re.sub(r"[^\u4e00-\u9fffA-Za-z0-9]", "", t)

def main(p):
    r = transcribe(p)
    t = norm(r["text"])
    print(f"=== {p} dur={r['dur']}s asr={r['asr_sec']}s")
    print("  text:", t)
    # count repeated 6-grams of characters
    n = 6
    grams = [t[i:i+n] for i in range(len(t)-n+1)]
    from collections import Counter
    c = Counter(grams)
    rep = [(g, k) for g, k in c.most_common(8) if k > 1]
    print("  repeated char 6-grams:", rep[:5])
    for g, k in rep[:3]:
        pos = [m.start() for m in re.finditer(re.escape(g), t)]
        print(f"    gram {g!r} x{k} at {pos}")

if __name__ == "__main__":
    for p in sys.argv[1:]:
        main(p)
