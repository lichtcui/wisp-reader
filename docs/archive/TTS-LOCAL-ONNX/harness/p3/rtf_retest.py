#!/usr/bin/env python3
"""P3 final RTF re-test (short / long / mixed) at the final config (int8, chunk<=45)."""
import json, sys, os
from pathlib import Path
sys.path.insert(0, "/Users/lichtcui/Documents/playground/tts/p3/harness")
from chunker import chunk_for_limit
from p3run import run_chunks, P3
from loopdetect import detect_file
from proc_sampler import loadavg
CASES = json.load(open("/Users/lichtcui/Documents/playground/tts/p2/harness/cases.json"))["cases"]
SHORT = [c for c in CASES if c["id"] == "short_zh"][0]["text"]
BASE = [c for c in CASES if c["id"] == "baseline_doc"][0]["text"]
PAGE = [c for c in CASES if c["id"] == "page_long"][0]["text"]
MIXED = [c for c in CASES if c["id"] == "mixed_zh_en"][0]["text"]
LIMIT = 45
K = int(os.environ.get("K", "3"))
OUT = P3 / "results" / "rtf_final.jsonl"

for name, txt in [("short30", SHORT), ("baseline77", BASE), ("page444", PAGE), ("mixed251", MIXED)]:
    for k in range(K):
        tag = f"rtf_{name}_k{k}"
        ch = chunk_for_limit(txt, LIMIT)
        r = run_chunks(ch, P3/f"audio/{tag}.wav", report=P3/f"results/{tag}.json",
                       no_seed=True, tag=tag, log=P3/f"logs/{tag}.log", rust_log="debug")
        det, dur = detect_file(P3/f"audio/{tag}.wav")
        syn = json.loads((P3/f"results/{tag}.json").read_text())
        row = {"case": name, "k": k, "chars": len(txt), "n_chunks": len(ch),
               "total_ms": syn["total_ms"], "audio_sec": syn["audio_sec"], "rtf": syn["rtf"],
               "loops": det["n_events"], "longest": det["longest_sec"],
               "peak_rss_gib": r["peak_rss_gib"], "load1": r["load1"]}
        with open(OUT, "a") as f:
            f.write(json.dumps(row, ensure_ascii=False) + "\n")
        print(f"{tag}: chunks={len(ch)} dur={syn['audio_sec']}s rtf={syn['rtf']} "
              f"loops={det['n_events']} peak={r['peak_rss_gib']}GiB load1={r['load1']}", flush=True)
