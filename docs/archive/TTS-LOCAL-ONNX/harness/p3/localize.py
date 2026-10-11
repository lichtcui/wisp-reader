#!/usr/bin/env python3
"""Localize repeat events onto engine chunks (silence-gap boundaries)."""
import sys, json
import numpy as np
sys.path.insert(0, "/Users/lichtcui/Documents/playground/tts/p3/harness")
from runlib import load_audio
from loopdetect import detect


def chunk_bounds(x, sr):
    w = int(0.01 * sr)
    n = (len(x)//w)*w
    e = np.sqrt((x[:n].reshape(-1, w)**2).mean(axis=1))
    z = e < 1e-6
    d = np.diff(np.concatenate([[0], z.view(np.int8), [0]]))
    st = np.where(d == 1)[0]; en = np.where(d == -1)[0]
    starts = [s*w/sr for s, e2 in zip(st, en) if (e2-s)*w/sr >= 0.25]
    return starts


def main(p):
    x, sr = load_audio(p)
    x = np.asarray(x, float)
    b = chunk_bounds(x, sr)
    r = detect(x, sr)
    def cid(t):
        return sum(1 for s in b if t >= s)
    print(f"{p}  dur={len(x)/sr:.1f}s chunks={len(b)+1} boundaries={[round(s,2) for s in b]}")
    for e in r["events"]:
        ca = cid(e["t_a"]); cb = cid(e["t_b"])
        print(f"  {e['kind']:5s} {e['len_sec']:5.2f}s  t_a={e['t_a']:7.2f}(chunk{ca}) "
              f"t_b={e['t_b']:7.2f}(chunk{cb})  cross_chunk={ca!=cb}")
    return r

if __name__ == "__main__":
    for p in sys.argv[1:]:
        main(p)
