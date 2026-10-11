#!/usr/bin/env python3
"""T2S semantic-token dump via parse of engine logs + audio-based loop detection.

For each chunk the engine logs `pred_semantic len=<n>, head=[...]`. We extract
the per-chunk semantic length, and (optionally) compare per-chunk token streams
for cross-chunk repetition of the same token span.
"""
import json, random, sys
import numpy as np
from pathlib import Path
sys.path.insert(0, "/Users/lichtcui/Documents/playground/tts/p3/harness")
from runlib import BIN, BUNDLE_INT8, REF_TEXT
import subprocess, os

def import_semantic(chunks, seed=None, no_seed=True, params=None, tag="sem"):
    """Run with DEBUG logging to capture pred_semantic heads and lengths."""
    cmd = [str(BIN), "--model-path", BUNDLE_INT8, "--lang", "zh", "--ref-text", REF_TEXT,
           "--output", f"/tmp/{tag}.wav"]
    for c in chunks:
        cmd += ["--chunk", c]
    cmd += (["--no-seed"] if no_seed else ["--seed", str(seed)])
    if params:
        for k, v in params.items():
            cmd += [f"--{k.replace('_','-')}", str(v)]
    env = dict(os.environ, RUST_LOG="debug")
    out = subprocess.run(cmd, capture_output=True, text=True, env=env).stdout
    import re
    lens = [int(m) for m in re.findall(r"pred_semantic len=(\d+)", out)]
    return lens
