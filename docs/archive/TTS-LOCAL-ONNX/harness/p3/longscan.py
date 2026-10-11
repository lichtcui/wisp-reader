#!/usr/bin/env python3
"""O(n) repeat scan for very long outputs (1 h): 0.3 s blocks + 0.05 s hop hashing."""
import sys, json
import numpy as np
sys.path.insert(0, "/Users/lichtcui/Documents/playground/tts/p3/harness")
from runlib import load_audio

MIN_SEP = 1.0
def scan(path):
    x, sr = load_audio(path); x = np.asarray(x, float)
    blk, hop = int(0.3*sr), int(0.05*sr)
    m = (len(x)-blk)//hop + 1
    lvl = np.median(np.sqrt((x[:len(x)//sr*sr].reshape(-1, sr)**2).mean(axis=1))) if len(x)>sr else 1e-3
    gate = 0.15*lvl
    H = {}
    rms = np.empty(m)
    for k in range(m):
        i = k*hop; seg = x[i:i+blk]
        r = np.sqrt((seg**2).mean()); rms[k] = r
        if r < gate: continue
        H.setdefault(seg.astype(np.float32).tobytes(), []).append(k)
    covered = np.zeros(m, bool)
    n_pairs = 0
    for ks in H.values():
        if len(ks) < 2: continue
        for a in range(len(ks)):
            for b in range(a+1, len(ks)):
                if (ks[b]-ks[a])*hop < MIN_SEP*sr: continue
                covered[ks[a]] = True; covered[ks[b]] = True; n_pairs += 1
    # merge covered into events
    events = []
    k = 0
    while k < m:
        if covered[k]:
            j = k
            while j+1 < m and covered[j+1]: j += 1
            events.append((k*hop/sr, (j*hop+blk)/sr))
            k = j+1
        else: k += 1
    return {"dur_sec": round(len(x)/sr,1), "n_blocks": m, "n_pairs": n_pairs,
            "repeated_sec": round(sum(e-s for s,e in events),1), "events": len(events),
            "event_list": [(round(a,1), round(b,1)) for a,b in events]}

if __name__ == "__main__":
    for p in sys.argv[1:]:
        print(p, json.dumps(scan(p), ensure_ascii=False)[:2000])
