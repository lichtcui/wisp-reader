#!/usr/bin/env python3
import json, sys
from pathlib import Path
sys.path.insert(0, "/Users/lichtcui/Documents/playground/tts/p3/harness")
from chunker import chunk_for_limit
from p3run import run_chunks, P3
from loopdetect import detect_file
PAGE=[c for c in json.load(open('/Users/lichtcui/Documents/playground/tts/p2/harness/cases.json'))['cases'] if c['id']=='page_long'][0]['text']
ch=chunk_for_limit(PAGE,510)
for k in range(5):
    tag=f"p4_rep20_t035_k{k}"
    prm={"repetition_penalty":2.0,"temperature":0.35,"top_k":4,"top_p":0.9}
    r=run_chunks(ch, P3/f"audio/{tag}.wav", report=P3/f"results/{tag}.json", no_seed=True, params=prm, tag=tag, log=P3/f"logs/{tag}.log")
    det,dur=detect_file(P3/f"audio/{tag}.wav")
    syn=json.loads((P3/f"results/{tag}.json").read_text())
    print(f"{tag}: dur={dur:.1f}s rtf={syn['rtf']} loops={det['n_events']} exact={det['exact_events']} longest={det['longest_sec']}", flush=True)
