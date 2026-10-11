#!/usr/bin/env python3
"""P3 repeat ("复读") detector v4 — FFT normalized autocorrelation + blockwise verify.

Event = a pair of non-overlapping speech spans (>= MIN_BLOCK) that are
  exact : max|a-b| <= 1e-4
  near  : sample-level cosine >= 0.90
separated by >= MIN_SEP, both above an energy gate. The 0.30 s
fragment_interval zero padding is excluded by the energy gate.
loop_rate = runs with >=1 event / runs.
"""
import sys
sys.path.insert(0, "/Users/lichtcui/Documents/playground/tts/p3/harness")
import json
import numpy as np
from runlib import load_audio

EXACT_TOL = 1e-4
NEAR_COS = 0.90
MIN_BLOCK = 0.30
MIN_SEP = 0.50
ENERGY_FRAC = 0.15


def _speech_level(x, sr):
    w = max(1, int(0.02 * sr))
    n = (len(x) // w) * w
    if n == 0:
        return 0.0
    r = np.sqrt((x[:n].reshape(-1, w) ** 2).mean(axis=1))
    return float(np.median(r[r > 1e-3])) if np.any(r > 1e-3) else 0.0


def _lag_correlation(x):
    n = len(x)
    f = np.fft.rfft(x, 2 * n)
    num = np.fft.irfft(f * np.conj(f))[:n]
    cs = np.concatenate([[0.0], np.cumsum(x * x)])
    tot = cs[-1]
    lags = np.arange(n)
    e1 = cs[n - lags]
    e2 = tot - cs[lags]
    den = np.sqrt(np.maximum(e1 * e2, 0.0)) + 1e-12
    return num / den


def _verify(x, sr, lag, gate):
    """Blockwise verify at a candidate lag; return best event or None."""
    n = len(x)
    m_len = n - lag
    if m_len <= 0:
        return None
    a = x[:m_len]
    b = x[lag:]
    w = int(MIN_BLOCK * sr)
    mb = m_len // w
    if mb < 1:
        return None
    A = a[:mb * w].reshape(mb, w)
    B = b[:mb * w].reshape(mb, w)
    md = np.abs(A - B).mean(axis=1)
    den = np.linalg.norm(A, axis=1) * np.linalg.norm(B, axis=1) + 1e-12
    cos = (A * B).sum(axis=1) / den
    rmsA = np.sqrt((A ** 2).mean(axis=1))
    rmsB = np.sqrt((B ** 2).mean(axis=1))
    ok = ((md <= EXACT_TOL) | (cos >= NEAR_COS)) & (rmsA > gate) & (rmsB > gate)
    best = (0, 0)
    s = None
    for k in range(mb + 1):
        if k < mb and ok[k]:
            if s is None:
                s = k
        else:
            if s is not None:
                if k - s > best[1]:
                    best = (s, k - s)
                s = None
    if best[1] < 1:
        return None
    s, ln = best
    # sample-level refinement: longest exact run around the found span
    i0, j0 = s * w, s * w + lag
    seg_len = ln * w
    md_seg = float(md[s:s + ln].mean())
    cos_seg = float(cos[s:s + ln].mean())
    kind = "exact" if md_seg <= EXACT_TOL else "near"
    return {"t_a": round(i0 / sr, 3), "t_b": round(j0 / sr, 3),
            "sep_sec": round(lag / sr, 3), "len_sec": round(seg_len / sr, 3),
            "block_mean_abs_diff": round(md_seg, 8),
            "max_abs_diff": round(float(np.abs(A[s:s + ln] - B[s:s + ln]).max()), 6),
            "cos": round(cos_seg, 5), "kind": kind}


def detect(x, sr, max_events=8):
    x = np.asarray(x, dtype=np.float64)
    x = x - x.mean()
    n = len(x)
    lvl = _speech_level(x, sr)
    gate = max(1e-6, ENERGY_FRAC * lvl)
    if n < int(1.0 * sr) or lvl == 0.0:
        return {"n_events": 0, "events": [], "exact_events": 0, "near_events": 0,
                "longest_sec": 0.0, "tot_repeat_sec": 0.0, "speech_level": round(lvl, 5)}

    r = _lag_correlation(x)
    lo = int(MIN_SEP * sr)
    r[:lo] = 0.0
    # local maxima with prominence
    idx = np.arange(len(r))
    peaks = []
    step = max(1, int(0.02 * sr))
    for i in range(lo, len(r) - 1, step):
        j = min(len(r), i + step)
        k = i + int(np.argmax(r[i:j]))
        if k > 0 and k < len(r) - 1 and r[k] >= r[k - 1] and r[k] >= r[k + 1]:
            peaks.append((k, float(r[k])))
    peaks.sort(key=lambda t: -t[1])
    # dedupe candidates by lag proximity
    cands, seen = [], []
    for k, v in peaks:
        if v <= 0:
            continue
        if any(abs(k - s) < int(0.05 * sr) for s in seen):
            continue
        seen.append(k)
        cands.append((k, v))
        if len(cands) >= 60:
            break

    events = []
    for lag, v in cands:
        ev = _verify(x, sr, lag, gate)
        if ev is None:
            continue
        dup = None
        for e in events:
            if (abs(e["t_a"] - ev["t_a"]) < 0.4 and abs(e["t_b"] - ev["t_b"]) < 0.4) or \
               (abs(e["t_a"] - ev["t_b"]) < 0.4 and abs(e["t_b"] - ev["t_a"]) < 0.4):
                dup = e
                break
        if dup is None:
            events.append(ev)
        elif ev["len_sec"] > dup["len_sec"]:
            dup.update(ev)
        if len(events) >= max_events:
            break
    events.sort(key=lambda e: (-e["len_sec"]))
    events = events[:max_events]
    events.sort(key=lambda e: e["t_a"])
    return {"n_events": len(events), "events": events,
            "exact_events": sum(1 for e in events if e["kind"] == "exact"),
            "near_events": sum(1 for e in events if e["kind"] == "near"),
            "longest_sec": round(max((e["len_sec"] for e in events), default=0.0), 3),
            "tot_repeat_sec": round(sum(e["len_sec"] for e in events), 3),
            "speech_level": round(lvl, 5)}


def detect_file(p):
    x, sr = load_audio(p)
    return detect(x, sr), len(x) / sr


if __name__ == "__main__":
    for p in sys.argv[1:]:
        r, dur = detect_file(p)
        print(f"{p}\n  dur={dur:.2f}s -> {json.dumps(r, ensure_ascii=False)}")
