#!/usr/bin/env python3
"""P3 batch experiments (resumable). Stages: repro | limit | params | final."""
import json, sys, time
from pathlib import Path
sys.path.insert(0, "/Users/lichtcui/Documents/playground/tts/p3/harness")
from chunker import chunk_for_limit
from p3run import run_chunks, P3
from loopdetect import detect_file
from proc_sampler import loadavg

CASES = json.load(open("/Users/lichtcui/Documents/playground/tts/p2/harness/cases.json"))["cases"]
PAGE = [c for c in CASES if c["id"] == "page_long"][0]["text"]
SHORT = [c for c in CASES if c["id"] == "short_zh"][0]["text"]
MIXED = [c for c in CASES if c["id"] == "mixed_zh_en"][0]["text"]
OUT = P3 / "results" / "sweep.jsonl"


def done_tags():
    if not OUT.exists():
        return set()
    return {json.loads(l)["tag"] for l in OUT.read_text().splitlines() if l.strip()}


def one(stage, tag, text, limit, seed, no_seed, params):
    chunks = chunk_for_limit(text, limit)
    wav = P3 / "audio" / f"{tag}.wav"
    rep = P3 / "results" / f"{tag}.json"
    log = P3 / "logs" / f"{tag}.log"
    r = run_chunks(chunks, wav, report=rep, seed=seed, no_seed=no_seed,
                   params=params, tag=tag, log=log)
    det, dur = detect_file(wav)
    syn = json.loads(rep.read_text()) if rep.exists() else {}
    r.update({"stage": stage, "limit": limit, "detect": det,
              "rtf_synth": syn.get("rtf"), "total_ms": syn.get("total_ms"),
              "load1_end": round(loadavg()[0], 2)})
    r.pop("log_tail", None)
    with open(OUT, "a") as f:
        f.write(json.dumps(r, ensure_ascii=False) + "\n")
    print(f"[{stage}] {tag}: n={len(chunks)} dur={dur:.1f}s rtf_synth={r['rtf_synth']} "
          f"rtf_wall={r['wall_sec']/dur:.2f} loops={det['n_events']} exact={det['exact_events']} "
          f"longest={det['longest_sec']}s load1={r['load1']}->{r['load1_end']} "
          f"peak={r['peak_rss_gib']}GiB", flush=True)
    return r


def stage_repro():
    for k in range(3):
        if f"repro_s42_{k}" not in done_tags():
            one("repro", f"repro_s42_{k}", PAGE, 510, 42, False, None)


def stage_nosd(limit=510, k_n=5, prefix="nosd"):
    for k in range(k_n):
        tag = f"{prefix}{limit}_k{k}"
        if tag not in done_tags():
            one("nosd", tag, PAGE, limit, None, True, None)


def stage_limit():
    for limit in (510, 90, 60, 45):
        for k in range(5):
            tag = f"lim{limit}_k{k}"
            if tag not in done_tags():
                one("limit", tag, PAGE, limit, None, True, None)


PARAMS = {
    "p0_default":   {"repetition_penalty": 1.35, "temperature": 1.0,  "top_k": 4, "top_p": 0.9},
    "p1_rep16":     {"repetition_penalty": 1.60, "temperature": 1.0,  "top_k": 4, "top_p": 0.9},
    "p2_rep20_t07": {"repetition_penalty": 2.00, "temperature": 0.7,  "top_k": 4, "top_p": 0.9},
    "p3_rep135_t06":{"repetition_penalty": 1.35, "temperature": 0.6,  "top_k": 4, "top_p": 0.9},
}


def stage_params(limit=510, k_n=5):
    for name, prm in PARAMS.items():
        for k in range(k_n):
            tag = f"{name}_k{k}"
            if tag not in done_tags():
                one("params", tag, PAGE, limit, None, True, prm)


def stage_final():
    for limit, kn in ((45, 8), (30, 5)):
        for k in range(kn):
            tag = f"fin{limit}_k{k}"
            if tag not in done_tags():
                one("final", tag, PAGE, limit, None, True, None)


STAGES = {"repro": stage_repro, "limit": stage_limit, "params": stage_params,
          "final": stage_final}
if __name__ == "__main__":
    for s in sys.argv[1:] or ["limit"]:
        try:
            STAGES[s]()
        except Exception as e:
            print(f"stage {s} FAILED: {e}", flush=True)
