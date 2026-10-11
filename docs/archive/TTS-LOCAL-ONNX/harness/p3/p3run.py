#!/usr/bin/env python3
"""P3 single-run driver using the gpt_sovits_p3 example (load once, chunked synth)."""
import json, os, sys, subprocess, threading, time
from pathlib import Path
sys.path.insert(0, "/Users/lichtcui/Documents/playground/tts/p3/harness")
from proc_sampler import rusage, loadavg

P3 = Path("/Users/lichtcui/Documents/playground/tts/p3")
BIN = Path("/Users/lichtcui/Documents/playground/tts/gpt-sovits-onnx-rs/target/release/examples/gpt_sovits_p3")
BUNDLE = "/Users/lichtcui/Documents/playground/tts/p2/bundles/liuying-int8"
REF = "抱歉，我不得不这么做……"


def run_chunks(chunks, out_wav, report=None, seed=42, no_seed=False, params=None,
               bundle=BUNDLE, timeout=7200, tag="run", log=None, rust_log="info"):
    cmd = [str(BIN), "--model-path", bundle, "--ref-text", REF, "--lang", "zh",
           "--output", str(out_wav)]
    if report:
        cmd += ["--report", str(report)]
    for c in chunks:
        cmd += ["--chunk", c]
    if no_seed:
        cmd += ["--no-seed"]
    else:
        cmd += ["--seed", str(seed)]
    if params:
        for k, v in params.items():
            cmd += [f"--{k.replace('_','-')}", str(v)]
    env = dict(os.environ, RUST_LOG=rust_log)
    t0 = time.time()
    load1 = loadavg()[0]
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            text=True, env=env, bufsize=1)
    buf, lock = [], threading.Lock()

    def rd():
        for line in proc.stdout:
            with lock:
                buf.append(line)
    threading.Thread(target=rd, daemon=True).start()

    samples, peak_res, peak_foot = [], 0, 0
    while proc.poll() is None:
        res, foot = rusage(proc.pid)
        if res:
            peak_res = max(peak_res, res); peak_foot = max(peak_foot, foot)
            samples.append([round(time.time() - t0, 2), res, foot])
        if time.time() - t0 > timeout:
            proc.kill(); break
        time.sleep(0.5)
    with lock:
        log_text = "".join(buf)
    if log:
        Path(log).write_text(log_text)
    wall = time.time() - t0
    info = type("I", (), {})()
    dur = None
    try:
        import subprocess as _sp
        dur = float(_sp.check_output(["/Users/lichtcui/Documents/playground/tts/gpt-sovits-onnx-rs/gpt-sovits-upstream/.venv/bin/python",
            "-c", "import soundfile as sf,sys;print(sf.info(sys.argv[1]).duration)", str(out_wav)], text=True).strip())
    except Exception:
        pass
    return {"tag": tag, "seed": (None if no_seed else seed), "no_seed": no_seed,
            "params": params or {}, "n_chunks": len(chunks),
            "chunk_lens": [len(c) for c in chunks],
            "exit_code": proc.returncode, "wall_sec": round(wall, 3),
            "load1": round(load1, 2), "audio_sec": round(dur, 3) if dur else None,
            "peak_rss_gib": round(peak_res / 2**30, 3),
            "peak_foot_gib": round(peak_foot / 2**30, 3),
            "rss_samples": samples, "log_tail": log_text[-2000:]}
