#!/usr/bin/env python3
"""P2 measurement harness: run gpt_sovits_demo, sample RSS, parse phase timings."""
import argparse, json, os, re, subprocess, sys, threading, time, wave
from pathlib import Path

REPO = Path("/Users/lichtcui/Documents/playground/tts/gpt-sovits-onnx-rs")
BIN = REPO / "target/release/examples/gpt_sovits_demo"

PHASE_RE = re.compile(r"DEBUG gpt_sovits_onnx_rs\] (.*?): ([\d.]+)(ms|s|µs)")
TOTAL_RE = re.compile(
    r"Synchronous Inference \((\d+) runs\):\s*\n\s*Average: ([\d.]+) ms"
    r"\s*\n\s*Median: ([\d.]+) ms\s*\n\s*Max: ([\d.]+) ms\s*\n\s*Min: ([\d.]+) ms")

def rss_bytes(pid):
    # macOS `ps -o rss=` is in KiB
    try:
        out = subprocess.check_output(["ps", "-o", "rss=", "-p", str(pid)],
                                      text=True, stderr=subprocess.DEVNULL).strip()
        return int(out) * 1024 if out else None
    except Exception:
        return None

def wav_info(path):
    with wave.open(str(path)) as f:
        return {"sr": f.getframerate(), "samples": f.getnframes(),
                "duration_sec": round(f.getnframes() / f.getframerate(), 3)}

def parse_log(text):
    phases = {}
    for m in PHASE_RE.finditer(text):
        name, val, unit = m.group(1).strip(), float(m.group(2)), m.group(3)
        phases.setdefault(name, []).append(val * {"ms": 1.0, "s": 1000.0, "µs": 0.001}[unit])
    return phases, TOTAL_RE.search(text), len(re.findall(r"Reallocating KV cache", text))

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bundle", required=True)
    ap.add_argument("--ref-text", required=True)
    ap.add_argument("--text", required=True)
    ap.add_argument("--runs", type=int, default=1)
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--out", required=True)
    ap.add_argument("--log", required=True)
    ap.add_argument("--result", required=True)
    ap.add_argument("--id", required=True)
    ap.add_argument("--interval", type=float, default=0.25)
    ap.add_argument("--timeout", type=float, default=7200)
    a = ap.parse_args()

    env = dict(os.environ, RUST_LOG="debug")
    cmd = [str(BIN), "--model-path", a.bundle, "--ref-text", a.ref_text,
           "--text", a.text, "--run-count", str(a.runs),
           "--seed", str(a.seed), "--output", a.out]
    t0 = time.time()
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            text=True, env=env, bufsize=1)
    buf, lock = [], threading.Lock()

    def reader():
        for line in proc.stdout:
            with lock:
                buf.append(line)
    th = threading.Thread(target=reader, daemon=True); th.start()

    samples, peak = [], 0
    while proc.poll() is None:
        r = rss_bytes(proc.pid)
        if r:
            peak = max(peak, r)
            samples.append([round(time.time() - t0, 2), r])
        if time.time() - t0 > a.timeout:
            proc.kill(); break
        time.sleep(a.interval)
    th.join(timeout=5)
    wall = time.time() - t0
    with lock:
        log_text = "".join(buf)
    Path(a.log).write_text(log_text)

    phases, totals, reallocs = parse_log(log_text)
    info = None
    if Path(a.out).exists():
        try:
            info = wav_info(a.out)
        except Exception:
            info = None
    phase_ms = {k: {"n": len(v), "sum_ms": round(sum(v), 1),
                    "mean_ms": round(sum(v) / len(v), 1),
                    "min_ms": round(min(v), 1), "max_ms": round(max(v), 1)}
                for k, v in phases.items()}
    res = {
        "id": a.id, "runs": a.runs, "seed": a.seed, "exit_code": proc.returncode,
        "wall_sec_incl_init": round(wall, 2),
        "demo_total_ms": ({"runs": int(totals.group(1)), "avg": float(totals.group(2)),
                           "median": float(totals.group(3)), "max": float(totals.group(4)),
                           "min": float(totals.group(5))} if totals else None),
        "phase_ms": phase_ms, "kv_cache_reallocs": reallocs, "audio": info,
        "peak_rss_bytes": peak, "peak_rss_gib": round(peak / 2**30, 3),
        "rss_samples": samples,
    }
    Path(a.result).write_text(json.dumps(res, ensure_ascii=False, indent=2))
    print(json.dumps({k: res[k] for k in ["id", "wall_sec_incl_init", "demo_total_ms",
                                          "kv_cache_reallocs", "audio", "peak_rss_gib",
                                          "exit_code"]}, ensure_ascii=False, indent=2))

if __name__ == "__main__":
    sys.exit(main())
