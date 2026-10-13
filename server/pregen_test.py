#!/usr/bin/env python3
"""Acceptance harness for the TTS pre-generation API (docs/research/TTS-PREGEN-IMPL.md §1.4).

Talks to the server over HTTP exactly like the app will (phase 2), and inspects the
artifacts with the stdlib only -- so it runs on the VPS with /usr/bin/python3, no venv.
`meta/*.json` is read from disk because `GET /meta/<key>` is deliberately not part of the
phase-1 API surface.

    python3 pregen_test.py gen /tmp/ab_text.txt --wait      # submit + poll + verify
    python3 pregen_test.py again /tmp/ab_text.txt           # idempotency (same key, no requeue)
    python3 pregen_test.py verify <key>                     # 24k mono s16, duration/peak/clip
    python3 pregen_test.py range <key> --range 0-63         # Range support (player seeking)
    python3 pregen_test.py probe /tmp/chapter.txt           # POST /cache/probe -> same key
    python3 pregen_test.py item <key> | stats | delete <key> | wait <jobId>
"""

import argparse
import array
import io
import json
import math
import os
import sys
import time
import urllib.error
import urllib.request
import wave

BASE = os.environ.get("TTS_API", "http://127.0.0.1:9880")
META_DIR = os.environ.get("TTS_CACHE", "/root/tts/cache") + "/meta"
TERMINAL = ("ready", "failed")


def api(path, data=None, headers=None, method=None, raw=False):
    body = json.dumps(data).encode("utf-8") if data is not None else None
    hdrs = dict(headers or {})
    if body:
        hdrs["Content-Type"] = "application/json"
    req = urllib.request.Request(BASE + path, data=body, headers=hdrs, method=method)
    try:
        with urllib.request.urlopen(req, timeout=600) as r:
            blob = r.read()
            return r.status, r.headers, (blob if raw else json.loads(blob.decode("utf-8")))
    except urllib.error.HTTPError as e:
        blob = e.read()
        try:
            return e.code, e.headers, json.loads(blob.decode("utf-8"))
        except Exception:
            return e.code, e.headers, blob


def paragraphs(path):
    with open(path, encoding="utf-8") as f:
        return [p.strip() for p in f.read().splitlines() if p.strip()]


def item_of(path, a, voice=None, engine=None):
    paras = paragraphs(path)
    return {"bookId": a.book, "chapterIndex": a.index, "title": a.title,
            "paragraphs": paras, "voice": voice or a.voice, "engine": engine or a.engine}


def submit(it):
    st, _, r = api("/job", {"items": [it]})
    if st != 200:
        print("POST /job -> %s %s" % (st, json.dumps(r, ensure_ascii=False)[:400]))
        return None, None
    return r["jobId"], r["items"][0]


def poll(job_id, key, interval, timeout=43200):
    t0 = time.time()
    while True:
        st, _, s = api("/job/status?jobId=%s" % job_id)
        entry = next((e for e in s.get("items", []) if e["key"] == key), {})
        print("[%6.0fs] state=%-8s counts=%s audioMs=%s %s" % (
            time.time() - t0, entry.get("state"), {k: v for k, v in s.items()
                                                   if k in ("queued", "running", "done", "failed", "expired") and v},
            entry.get("audioMs", ""), entry.get("err", "")))
        if entry.get("state") in TERMINAL or time.time() - t0 > timeout:
            return entry, time.time() - t0
        time.sleep(interval)


def analyse(blob, want_rate=24000):
    with wave.open(io.BytesIO(blob)) as w:
        rate, ch, sw, n = w.getframerate(), w.getnchannels(), w.getsampwidth(), w.getnframes()
        pcm = w.readframes(n)
    a = array.array("h")
    a.frombytes(pcm)
    peak = max((abs(v) for v in a), default=0) / 32768.0
    rms = math.sqrt(sum(float(v) * v for v in a) / len(a)) / 32768.0 if a else 0.0
    clip = 100.0 * sum(1 for v in a if abs(v) >= 32767) / len(a) if a else 0.0
    return {"cast": (rate, ch, sw), "ok": (rate, ch, sw) == (want_rate, 1, 2),
            "sec": len(a) / rate, "peak_dbfs": round(20 * math.log10(max(peak, 1e-9)), 2),
            "rms_dbfs": round(20 * math.log10(max(rms, 1e-9)), 1), "clip_pct": round(clip, 4),
            "bytes": len(blob)}


def disk_meta(key):
    path = os.path.join(META_DIR, key + ".json")
    if not os.path.exists(path):
        return None
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def verify(key):
    st, _, blob = api("/audio/%s" % key, raw=True)
    if st != 200:
        print("GET /audio/%s -> %s %s" % (key, st, str(blob)[:200]))
        return 1
    info = analyse(blob)
    print("audio %s %s" % (key, json.dumps(info)))
    bad = not info["ok"] or info["peak_dbfs"] > -1.0 or info["clip_pct"] > 0.01
    meta = disk_meta(key)
    if meta:
        dur = info["sec"] * 1000.0
        print("meta  %s audioMs=%s synthMs=%s rtf=%s chars=%s blocks=%s seeds=%s" % (
            key, meta.get("audioMs"), meta.get("synthMs"), meta.get("rtf"), meta.get("chars"),
            len(meta.get("chunks") or []), len(meta.get("seeds") or [])))
        if meta.get("audioMs"):
            d = 100.0 * (meta["audioMs"] - dur) / dur
            print("stamp audioMs=%d vs measured=%.0f (%.2f%%)" % (meta["audioMs"], dur, d))
            if abs(d) > 2.0:
                print("FAIL stamped duration differs from the file by >2%")
                bad = True
        ch = meta.get("chunks") or []
        if ch and ch[-1]["t1Ms"] > meta.get("audioMs", 0) + 1:
            print("FAIL last chunk ends after audioMs")
            bad = True
        if meta.get("chars") and dur:
            cps = meta["chars"] / info["sec"]
            print("chars/sec of audio = %.2f (block QC expects 3.5-6.5)" % cps)
    print("VERDICT %s" % ("FAIL" if bad else "OK"))
    return 1 if bad else 0


def main():
    global BASE, META_DIR
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--base", default=BASE)
    ap.add_argument("--meta-dir", default=META_DIR)
    sub = ap.add_subparsers(dest="cmd", required=True)

    for name, fn, needs_file in (("gen", None, True), ("again", None, True)):
        p = sub.add_parser(name)
        p.add_argument("file")
        p.add_argument("--voice", default="流萤")
        p.add_argument("--engine", default="gsv_v2proplus")
        p.add_argument("--book", default="acceptance")
        p.add_argument("--index", type=int, default=1)
        p.add_argument("--title", default="验收样本")
        p.add_argument("--wait", action="store_true")
        p.add_argument("--poll", type=float, default=20.0)
        p.add_argument("--timeout", type=float, default=43200.0)

    p = sub.add_parser("verify")
    p.add_argument("key")
    p = sub.add_parser("range")
    p.add_argument("key")
    p.add_argument("--range", default="0-63")
    p = sub.add_parser("probe")
    p.add_argument("file")
    p.add_argument("--voice", default="流萤")
    p.add_argument("--engine", default="gsv_v2proplus")
    p.add_argument("--book", default="acceptance")
    p.add_argument("--index", type=int, default=1)
    p.add_argument("--title", default="验收样本")
    p = sub.add_parser("item")
    p.add_argument("key")
    p = sub.add_parser("wait")
    p.add_argument("jobId")
    p.add_argument("--poll", type=float, default=30.0)
    p = sub.add_parser("stats")
    p = sub.add_parser("delete")
    p.add_argument("key")

    a = ap.parse_args()
    BASE, META_DIR = a.base, a.meta_dir
    cmd = a.cmd

    if cmd in ("gen", "again"):
        it = item_of(a.file, a)
        chars = sum(len(p) for p in it["paragraphs"]) + len(it["paragraphs"]) - 1
        before = None
        if cmd == "again":
            st, _, r0 = api("/job", {"items": [it]})
            key0 = r0["items"][0]["key"] if st == 200 else None
            before = disk_meta(key0) if key0 else None
            st, _, s0 = api("/cache/stats")
            print("warm: key=%s state=%s createdAt=%s queue=%s" % (
                key0, r0["items"][0]["state"] if st == 200 else "?", (before or {}).get("createdAt"),
                s0.get("queue") if st == 200 else "?"))
        print("submit file=%s paras=%d chars=%d voice=%s engine=%s" % (
            a.file, len(it["paragraphs"]), chars, it["voice"], it["engine"]))
        job, entry = submit(it)
        if not job:
            return 1
        print("POST /job -> jobId=%s key=%s state=%s" % (job, entry["key"], entry["state"]))
        key = entry["key"]
        if cmd == "again":
            if entry["state"] != "ready":
                print("FAIL re-POST did not report ready (got %s)" % entry["state"])
                return 1
            after = disk_meta(key)
            st, _, s = api("/cache/stats")
            q = s.get("queue", {})
            ok = (before or {}).get("createdAt") == (after or {}).get("createdAt") \
                and q.get("new", 1) == 0 and q.get("run", 1) == 0
            print("after: createdAt=%s queue=%s" % ((after or {}).get("createdAt"), q))
            print("VERDICT %s (no requeue, artifacts untouched)" % ("OK" if ok else "FAIL"))
            return 0 if ok else 1
        if not a.wait:
            return 0
        entry, dt = poll(job, key, a.poll, a.timeout)
        print("total %.1fs -> %s" % (dt, entry.get("state")))
        return verify(key) if entry.get("state") == "ready" else 1

    if cmd == "verify":
        return verify(a.key)
    if cmd == "range":
        st, hdrs, blob = api("/audio/%s" % a.key, headers={"Range": "bytes=%s" % a.range}, raw=True)
        print("Range %s -> %s len=%s content-range=%s accept-ranges=%s" % (
            a.range, st, len(blob), hdrs.get("Content-Range"), hdrs.get("Accept-Ranges")))
        return 0 if st == 206 and len(blob) == int(a.range.split("-")[1]) + 1 else 1
    if cmd == "probe":
        it = item_of(a.file, a)
        st, _, r = api("/cache/probe", {k: it[k] for k in ("paragraphs", "voice", "engine")})
        print("POST /cache/probe -> %s %s" % (st, json.dumps(r, ensure_ascii=False)))
        return 0 if st == 200 else 1
    if cmd == "item":
        st, _, r = api("/job/status?key=%s" % a.key)
        print(json.dumps(r, ensure_ascii=False))
        return 0
    if cmd == "wait":
        t0 = time.time()
        while True:
            st, _, s = api("/job/status?jobId=%s" % a.jobId)
            print("[%6.0fs] %s" % (time.time() - t0, {k: v for k, v in s.items()
                                                      if k not in ("items",)}), flush=True)
            if s.get("queued", 0) == 0 and s.get("running", 0) == 0:
                return 0 if s.get("failed", 0) == 0 else 1
            time.sleep(a.poll)
    if cmd == "stats":
        st, _, r = api("/cache/stats")
        print(json.dumps(r, ensure_ascii=False, indent=1) if st == 200 else "%s %s" % (st, r))
        return 0 if st == 200 else 1
    if cmd == "delete":
        st, _, r = api("/cache/%s" % a.key, method="DELETE")
        print("DELETE /cache/%s -> %s %s" % (a.key, st, r))
        return 0 if st in (200, 204) else 1
    return 1


if __name__ == "__main__":
    sys.exit(main())
