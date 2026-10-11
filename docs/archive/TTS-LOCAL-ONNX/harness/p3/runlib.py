#!/usr/bin/env python3
"""P3 run helpers: drive gpt_sovits_demo, libproc RSS sampling, log parsing."""
import json, os, re, subprocess, threading, time, wave
from pathlib import Path

P3 = Path("/Users/lichtcui/Documents/playground/tts/p3")
REPO = Path("/Users/lichtcui/Documents/playground/tts/gpt-sovits-onnx-rs")
BIN = REPO / "target/release/examples/gpt_sovits_demo"
PY310 = REPO / "gpt-sovits-upstream/.venv/bin/python"
BUNDLE_INT8 = str(P3.parent / "p2/bundles/liuying-int8")
BUNDLE_FP32 = str(P3.parent / "p2/bundles/liuying-nanguo")
REF_TEXT = "抱歉，我不得不这么做……"

import sys
sys.path.insert(0, str(P3 / "harness"))
from proc_sampler import rusage

PHASE_RE = re.compile(r"DEBUG gpt_sovits_onnx_rs\] (.*?): ([\d.]+)(ms|s|µs)")
TOTAL_RE = re.compile(
    r"Synchronous Inference \((\d+) runs\):\s*\n\s*Average: ([\d.]+) ms"
    r"\s*\n\s*Median: ([\d.]+) ms\s*\n\s*Max: ([\d.]+) ms\s*\n\s*Min: ([\d.]+) ms")
CHUNK_RE = re.compile(r"Processing chunk: (.*)$", re.M)
FINAL_RE = re.compile(r"t2s final len: (\d+), prefix_len: (\d+), stop_idx: (\d+)")
SEM_RE = re.compile(r"pred_semantic len=(\d+), head=\[([0-9, ]*)\]")
PROC_RE = re.compile(r"process: \"(.*)\"")


def wav_info(path):
    with wave.open(str(path)) as f:
        return {"sr": f.getframerate(), "samples": f.getnframes(),
                "duration_sec": round(f.getnframes() / f.getframerate(), 3)}


def parse_log(text):
    phases = {}
    for m in PHASE_RE.finditer(text):
        name, val, unit = m.group(1).strip(), float(m.group(2)), m.group(3)
        phases.setdefault(name, []).append(val * {"ms": 1.0, "s": 1000.0, "µs": 0.001}[unit])
    stop_idx = [int(m.group(3)) for m in FINAL_RE.finditer(text)]
    hit1500 = sum(1 for v in stop_idx if v >= 1500)
    return {
        "phases": {k: {"n": len(v), "sum_ms": round(sum(v), 1),
                       "mean_ms": round(sum(v) / len(v), 1),
                       "min_ms": round(min(v), 1), "max_ms": round(max(v), 1)}
                   for k, v in phases.items()},
        "demo_total_ms": ({**_totals(TOTAL_RE.search(text))} if TOTAL_RE.search(text) else None),
        "kv_cache_reallocs": len(re.findall(r"Reallocating KV cache", text)),
        "chunks": [c.strip() for c in CHUNK_RE.findall(text)],
        "stop_idx": stop_idx,
        "hit1500": hit1500,
        "sem_lens": [int(m.group(1)) for m in SEM_RE.finditer(text)],
        "proc_texts": PROC_RE.findall(text),
        "truncated_tokens": len(re.findall(r"SoVITS output cropped", text)),
    }


def _totals(m):
    if not m:
        return None
    return {"runs": int(m.group(1)), "avg": float(m.group(2)), "median": float(m.group(3)),
            "max": float(m.group(4)), "min": float(m.group(5))}


def run(text, out_wav, log_path, seed=42, runs=1, bundle=None, ref_text=REF_TEXT,
        params=None, params_file=None, timeout=7200, sample=True, interval=0.2,
        sample_rusage=False, extra=(), rusage_interval=2.0):
    bundle = bundle or BUNDLE_INT8
    cmd = [str(BIN), "--model-path", bundle, "--ref-text", ref_text, "--text", text,
           "--run-count", str(runs), "--output", str(out_wav)]
    if seed is not None:
        cmd += ["--seed", str(seed)]
    if params:
        for k, v in params.items():
            cmd += [f"--{k.replace('_','-')}", str(v)]
    if params_file:
        cmd += ["--params", str(params_file)]
    cmd += list(extra)
    env = dict(os.environ, RUST_LOG="debug")
    t0 = time.time()
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            text=True, env=env, bufsize=1)
    buf, lock = [], threading.Lock()

    def reader():
        for line in proc.stdout:
            with lock:
                buf.append(line)
    threading.Thread(target=reader, daemon=True).start()

    samples, peak_res, peak_foot = [], 0, 0
    last_ru = 0.0
    while proc.poll() is None:
        res, foot = rusage(proc.pid)
        if res:
            peak_res = max(peak_res, res)
            peak_foot = max(peak_foot, foot)
            if sample and time.time() - t0 - last_ru >= (interval if not sample_rusage else rusage_interval):
                last_ru = time.time() - t0
                samples.append([round(time.time() - t0, 2), res, foot])
        if time.time() - t0 > timeout:
            proc.kill()
            break
        time.sleep(interval)
    wall = time.time() - t0
    with lock:
        log_text = "".join(buf)
    Path(log_path).write_text(log_text)
    info = parse_log(log_text)
    info.update({
        "text": text, "seed": seed, "runs": runs, "bundle": Path(bundle).name,
        "exit_code": proc.returncode, "wall_sec_incl_init": round(wall, 3),
        "out_wav": str(out_wav), "audio": (wav_info(out_wav) if Path(out_wav).exists() else None),
        "peak_rss_bytes": peak_res, "peak_rss_gib": round(peak_res / 2**30, 3),
        "peak_foot_bytes": peak_foot, "peak_foot_gib": round(peak_foot / 2**30, 3),
        "rss_samples": samples,
    })
    return info


def load_audio(path):
    """Return (float32 mono array, sr) via the venv python (numpy/soundfile)."""
    code = ("import sys,numpy as np,soundfile as sf;"
            "a,sr=sf.read(sys.argv[1],dtype='float32');"
            "a=a.mean(axis=1) if a.ndim>1 else a;"
            "np.save(sys.argv[2],a);print(sr)")
    tmp = P3 / "asm/_audio_tmp.npy"
    out = subprocess.check_output([str(PY310), "-c", code, str(path), str(tmp)], text=True)
    import numpy as np
    return np.load(tmp), int(out.strip())
