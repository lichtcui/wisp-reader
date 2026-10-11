#!/usr/bin/env python3
"""Extra P3 runs: (a) g2pw preprocessing vs chunk limit, (b) fixed-seed reproducibility."""
import json, sys
from pathlib import Path
sys.path.insert(0, "/Users/lichtcui/Documents/playground/tts/p3/harness")
from chunker import chunk_for_limit
from p3run import run_chunks, P3
from loopdetect import detect_file
CASES = json.load(open("/Users/lichtcui/Documents/playground/tts/p2/harness/cases.json"))["cases"]
PAGE = [c for c in CASES if c["id"] == "page_long"][0]["text"]

def g2pw(limit):
    ch = chunk_for_limit(PAGE, limit)
    tag = f"g2pw{limit}"
    r = run_chunks(ch, P3/f"audio/{tag}.wav", report=P3/f"results/{tag}.json",
                   no_seed=True, tag=tag, log=P3/f"logs/{tag}.log", rust_log="debug")
    print(f"g2pw limit={limit}: n_chunks={len(ch)} log={P3}/logs/{tag}.log", flush=True)

def seedcheck(seed, k):
    ch = chunk_for_limit(PAGE, 510)
    tag = f"seed{seed}_{k}"
    r = run_chunks(ch, P3/f"audio/{tag}.wav", report=P3/f"results/{tag}.json",
                   seed=seed, no_seed=False, tag=tag, log=P3/f"logs/{tag}.log")
    det, dur = detect_file(P3/f"audio/{tag}.wav")
    print(f"seed{seed}_{k}: dur={dur:.1f}s loops={det['n_events']} longest={det['longest_sec']}", flush=True)

if __name__ == "__main__":
    what = sys.argv[1]
    if what == "g2pw":
        for lim in (510, 60):
            g2pw(lim)
    elif what == "seed":
        seedcheck(42, 0); seedcheck(42, 1)
    elif what == "seed7":
        seedcheck(7, 0); seedcheck(7, 1)
