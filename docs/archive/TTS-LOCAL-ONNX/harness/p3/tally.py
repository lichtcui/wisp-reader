#!/usr/bin/env python3
"""Join sweep.jsonl with per-run report JSONs and aggregate by stage/limit/params."""
import json, sys, collections
from pathlib import Path
P3 = Path("/Users/lichtcui/Documents/playground/tts/p3")

import re, subprocess
PY310 = "/Users/lichtcui/Documents/playground/tts/gpt-sovits-onnx-rs/gpt-sovits-upstream/.venv/bin/python"

def wav_dur(p):
    try:
        return float(subprocess.check_output([PY310, "-c",
            "import soundfile as sf,sys;print(sf.info(sys.argv[1]).duration)", str(p)],
            text=True).strip())
    except Exception:
        return None

def load():
    rows = [json.loads(l) for l in (P3/"results/sweep.jsonl").read_text().splitlines() if l.strip()]
    for r in rows:
        rep = P3 / "results" / f"{r['tag']}.json"
        if rep.exists():
            d = json.loads(rep.read_text())
            r["rtf_synth"] = d.get("rtf"); r["total_ms"] = d.get("total_ms")
            r["audio_sec"] = r.get("audio_sec") or d.get("audio_sec")
            r["per_chunk_ms"] = [c["ms"] for c in d.get("chunks", [])]
        if not r.get("total_ms"):
            log = P3 / "logs" / f"{r['tag']}.log"
            if log.exists():
                m = re.search(r'"total_ms":\s*([0-9.]+)', log.read_text())
                if m: r["total_ms"] = float(m.group(1))
        if not r.get("audio_sec"):
            w = P3 / "audio" / f"{r['tag']}.wav"
            r["audio_sec"] = wav_dur(w) if w.exists() else None
        if r.get("total_ms") and r.get("audio_sec"):
            r["rtf_synth"] = round(r["total_ms"]/1000.0/r["audio_sec"], 4)
    return rows

def med(v):
    v = sorted(v); return v[len(v)//2] if v else None

if __name__ == "__main__":
    rows = load()
    key = sys.argv[1] if len(sys.argv) > 1 else "limit"
    groups = collections.defaultdict(list)
    for r in rows:
        if key == "limit":
            g = r["limit"]
        elif key == "params":
            g = json.dumps(r["params"], sort_keys=True)
        else:
            g = r["stage"]
        groups[g].append(r)
    for g in sorted(groups, key=str):
        v = groups[g]
        n = len(v)
        loop = sum(1 for r in v if r["detect"]["n_events"] > 0)
        ex = sum(1 for r in v if r["detect"]["exact_events"] > 0)
        longest = max((r["detect"]["longest_sec"] for r in v), default=0)
        rtf = med([r["rtf_synth"] for r in v if r.get("rtf_synth")])
        dur = med([r["audio_sec"] for r in v if r.get("audio_sec")])
        print(f"{str(g):46s} n={n:2d} loop={loop}/{n} exact={ex} max={longest:4.1f}s "
              f"med_rtf={rtf if rtf is None else round(rtf,3)} med_dur={dur if dur is None else round(dur,1)} "
              f"chunks={v[0]['n_chunks']}")
