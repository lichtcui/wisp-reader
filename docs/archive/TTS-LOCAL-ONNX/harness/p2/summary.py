#!/usr/bin/env python3
"""Summarize P2 results into a markdown-ish table + outlier stats."""
import json, glob
from pathlib import Path
P2 = Path("/Users/lichtcui/Documents/playground/tts/p2")

def rows():
    out=[]
    for f in sorted(glob.glob(str(P2/"results/*.json"))):
        d=json.load(open(f))
        t=d.get("demo_total_ms") or {}
        ph=d.get("phase_ms",{})
        a=d.get("audio") or {}
        t2s=ph.get("T2S S Decoder all time",{})
        vits=ph.get("SoVITS all time",{})
        pre=ph.get("g2pw and preprocess time",{})
        out.append({
          "id":d["id"],"runs":d["runs"],
          "avg_ms":round(t.get("avg",0),1) if t else None,
          "med_ms":round(t.get("median",0),1) if t else None,
          "min_ms":round(t.get("min",0),1) if t else None,
          "max_ms":round(t.get("max",0),1) if t else None,
          "spread":round((t.get("max",0)/t.get("min",1)),2) if t else None,
          "dur":a.get("duration_sec"),"speech":a.get("speech_sec"),
          "rtf":d.get("rtf_total"),
          "t2s_mean_ms":t2s.get("mean_ms"),"t2s_max_ms":t2s.get("max_ms"),
          "vits_mean_ms":vits.get("mean_ms"),
          "pre_mean_ms":pre.get("mean_ms"),
          "peak_gib":d.get("peak_rss_gib"),
          "reallocs":d.get("kv_cache_reallocs"),
        })
    return out

if __name__=="__main__":
    for r in rows():
        print(f"{r['id']:30s} runs={r['runs']:3d} dur={str(r['dur']):>8s} rtf={str(r['rtf']):>7s} "
              f"avg={str(r['avg_ms']):>9s} min={str(r['min_ms']):>8s} max={str(r['max_ms']):>9s} "
              f"spread={str(r['spread']):>6s} peak={r['peak_gib']}GiB realloc={r['reallocs']}")
