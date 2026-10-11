#!/usr/bin/env python3
"""Drive the P2 case matrix from cases.json + reference variants."""
import json, subprocess, sys
from pathlib import Path

P2 = Path("/Users/lichtcui/Documents/playground/tts/p2")
cases = json.loads((P2 / "harness/cases.json").read_text())["cases"]
REFS = {
    "nanguo": {"bundle": P2 / "bundles/liuying-nanguo",
               "ref_text": "抱歉，我不得不这么做……"},
    "zhongli": {"bundle": P2 / "bundles/liuying-zhongli",
                "ref_text": "我应该会选择请求猎犬家系停止追捕。"},
}
want_cases = sys.argv[1].split(",") if len(sys.argv) > 1 else None
want_refs = sys.argv[2].split(",") if len(sys.argv) > 2 else ["nanguo"]

for c in cases:
    if want_cases and c["id"] not in want_cases:
        continue
    for rname in want_refs:
        r = REFS[rname]
        rid = f'{c["id"]}__{rname}'
        print(f"=== {rid} ===", flush=True)
        subprocess.run([sys.executable, str(P2 / "harness/measure.py"),
                        "--id", rid, "--bundle", str(r["bundle"]),
                        "--ref-text", r["ref_text"], "--text", c["text"],
                        "--runs", str(c["run_count"]), "--seed", str(c["seed"]),
                        "--out", str(P2 / f"audio/{rid}.wav"),
                        "--log", str(P2 / f"logs/{rid}.log"),
                        "--result", str(P2 / f"results/{rid}.json")], check=False)
