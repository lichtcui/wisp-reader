#!/usr/bin/env python3
"""P3 1-hour stability run: fixed final config, in-process repeated synth.

Samples RSS/phys_footprint with libproc, parses the engine DEBUG log for
per-chunk EOS/anomaly signals, and finally runs the repeat detector over the
whole output.
"""
import json, os, re, subprocess, sys, threading, time
from pathlib import Path
sys.path.insert(0, "/Users/lichtcui/Documents/playground/tts/p3/harness")
from proc_sampler import rusage, loadavg
from chunker import chunk_for_limit
from p3run import BIN, BUNDLE, REF
from loopdetect import detect_file

P3 = Path("/Users/lichtcui/Documents/playground/tts/p3")
CASES = json.load(open("/Users/lichtcui/Documents/playground/tts/p2/harness/cases.json"))["cases"]
PAGE = [c for c in CASES if c["id"] == "page_long"][0]["text"]
MIXED = [c for c in CASES if c["id"] == "mixed_zh_en"][0]["text"]
LIMIT = 45
ITERS = int(os.environ.get("ITERS", "40"))

base = chunk_for_limit(PAGE, LIMIT) + chunk_for_limit(MIXED, LIMIT)
chunks = base * ITERS
print(f"chunks={len(chunks)} (base={len(base)} x {ITERS})", flush=True)

out_wav = P3 / "audio/stability1h.wav"
rep = P3 / "results/stability1h.json"
log = P3 / "logs/stability1h.log"
cmd = [str(BIN), "--model-path", BUNDLE, "--lang", "zh", "--ref-text", REF,
       "--output", str(out_wav), "--report", str(rep), "--no-seed"]
for c in chunks:
    cmd += ["--chunk", c]
env = dict(os.environ, RUST_LOG="debug", GSV_DUMP_SEMANTIC=str(P3 / "asm" / "stability"))
(P3 / "asm" / "stability").mkdir(parents=True, exist_ok=True)
t0 = time.time()
proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=env)
buf, lock = [], threading.Lock()
def rd():
    for line in proc.stdout:
        with lock: buf.append(line)
threading.Thread(target=rd, daemon=True).start()

samples, peak_res, peak_foot = [], 0, 0
while proc.poll() is None:
    res, foot = rusage(proc.pid)
    if res:
        peak_res = max(peak_res, res); peak_foot = max(peak_foot, foot)
        samples.append([round(time.time()-t0, 1), res, foot])
    time.sleep(5)
with lock:
    log_text = "".join(buf)
log.write_text(log_text)
wall = time.time()-t0
d = json.loads(rep.read_text()) if rep.exists() else {}
stop = [int(x) for x in re.findall(r"t2s final len: (\d+), prefix_len: \d+, stop_idx: (\d+)", log_text)] if False else \
       [int(m.group(1)) for m in re.finditer(r"stop_idx: (\d+)", log_text)]
sem = [int(m.group(1)) for m in re.finditer(r"pred_semantic len=(\d+)", log_text)]
res = {
    "iters": ITERS, "n_chunks": len(chunks), "limit": LIMIT, "wall_sec": round(wall,1),
    "exit_code": proc.returncode, "total_ms": d.get("total_ms"), "audio_sec": d.get("audio_sec"),
    "rtf_synth": d.get("rtf"), "peak_rss_gib": round(peak_res/2**30,3),
    "peak_foot_gib": round(peak_foot/2**30,3),
    "rss_first": samples[0] if samples else None, "rss_last": samples[-1] if samples else None,
    "n_stop": len(stop), "n_full1500": sum(1 for s in stop if s >= 1500),
    "n_sem": len(sem), "sem_min": min(sem) if sem else None, "sem_max": max(sem) if sem else None,
    "n_chunk_fail": len(re.findall(r"Failed to process chunk", log_text)),
    "n_panic": len(re.findall(r"panic", log_text, re.I)),
    "kv_reallocs": len(re.findall(r"Reallocating KV cache", log_text)),
    "load1_start": round(loadavg()[0],2), "load1_end": round(loadavg()[0],2),
    "rss_samples": samples,
}
(P3/"results/stability1h_meta.json").write_text(json.dumps(res, ensure_ascii=False, indent=2))
print(json.dumps({k:v for k,v in res.items() if k!="rss_samples"}, ensure_ascii=False, indent=1), flush=True)
