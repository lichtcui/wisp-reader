#!/usr/bin/env python3
"""Pre-generation worker: turns queued chapters into cached 24 kHz WAVs.

Separate process from `app.py` on purpose (IMPL §2.1): it holds ~3.3 GB of torch +
GPT-SoVITS weights, so it must never be able to take the live VITS service down with it
(the box is 3.9 GB RAM). It talks to the online service over HTTP only, for the yield
gate in /health.

    systemctl start tts-job     # disabled by default; nothing runs unattended
    journalctl -u tts-job -f

Queue = the filesystem, `queue/new -> queue/run` by atomic rename (one worker, serial):
a crash is recovered by the stale reaper, and two instances cannot claim the same item.

The synthesis口径 is *not* reimplemented here: `synth_native()` in `/root/tts/gsv/gsv_batch.py`
is imported as the single source of truth (cut5 + fragment_interval=0.3 + the same
post-processing as app.py). One deviation was necessary: that file called `main()` at
import time, so its last line is now guarded by `if __name__ == "__main__":` -- running
it as a script behaves exactly as before.

See docs/research/TTS-PREGEN-IMPL.md §2.2-§2.4, §2.6, §2.7.
"""

import argparse
import ctypes
import gc
import json
import logging
import os
import random
import re
import signal
import sys
import time
import urllib.request
import wave

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
GSV_ROOT = os.environ.get("GSV_ROOT", "/root/tts/gsv")
# Import order matters: tts_cache computes its paths at import time, and gsv_batch does
# `os.chdir(REPO)` at import time (its build() uses repo-relative asset paths).
sys.path.insert(0, HERE)
import tts_cache as cache  # noqa: E402

log = logging.getLogger("tts-job")
STOP = False

SAMPLE_RATE = 24000        # client contract (Const.SAMPLE_RATE_REMOTE)
SAMPLE_STEPS = 32          # ignored by v2ProPlus (noise scheduler is v3/v4 only)
MAX_ATTEMPTS = 3
WORKER_ID = "job_worker/1"


# --- small helpers ---------------------------------------------------------------
def _trim():
    """glibc only returns freed pages to the OS on malloc_trim; without it the RSS
    ratchets up ~100 MB per block (measured) instead of falling back (IMPL §2.2)."""
    gc.collect()
    try:
        ctypes.CDLL("libc.so.6").malloc_trim(0)
    except Exception:  # non-glibc; the numbers still stay inside the HWM budget
        pass


def _sleep(seconds):
    """Interruptible sleep so SIGTERM does not wait out a 15 s poll."""
    end = time.time() + seconds
    while not STOP and time.time() < end:
        time.sleep(min(1.0, max(0.05, end - time.time())))


def _swap_total_mb():
    with open("/proc/meminfo") as f:
        for line in f:
            if line.startswith("SwapTotal:"):
                return int(line.split()[1]) // 1024
    return 0


def _rss_mb():
    d = {}
    with open("/proc/self/status") as f:
        for line in f:
            if line.startswith(("VmRSS:", "VmHWM:")):
                d[line.split(":")[0]] = int(line.split()[1]) // 1024
    return d


def _on_term(signum, _frame):
    global STOP
    log.warning("signal %d: finishing the current block, then releasing the item", signum)
    STOP = True


# --- engine backends -------------------------------------------------------------
class GsvBackend:
    """GPT-SoVITS v2ProPlus. All three exported engines share one synth interface."""

    name = "gsv_v2proplus"

    def __init__(self, voice):
        import gsv_batch as gb  # noqa: E402  (slow: pulls in torch)

        self.gb = gb
        self.cfg = dict(gb.MODELS[voice])
        self.cfg["role"] = voice
        os.makedirs(cache.WORK_DIR, exist_ok=True)
        # synth_native() writes one WAV per block to its module-level OUT_DIR; point that
        # at our scratch dir (deleted after each block) instead of /root/tts/gsv/out.
        gb.OUT_DIR = cache.WORK_DIR
        t0 = time.time()
        self.tts, _ = gb.build(voice, self.cfg)
        log.info("engine ready engine=%s voice=%s load=%.1fs mem=%s",
                 self.name, voice, time.time() - t0, _rss_mb())

    def synth(self, text, tag, seed_value):
        """One block, one run(). `seed_value` seeds the global RNG that GPT-SoVITS uses
        to derive its own seed when `seed=-1` (see `_predict_seed`), which is how the
        same chapter/block reproduces the same audio without copying the call args."""
        random.seed(seed_value)
        return self.gb.synth_native(self.tts, self.cfg, text, 1.0, SAMPLE_STEPS, True, tag=tag)


def _predict_seed(seed_value):
    """GPT-SoVITS: `seed = random.randint(0, 2**32-1)` when seed == -1 (TTS.py). With the
    global RNG seeded to `seed_value` first, that call returns exactly this value -- so we
    can record the effective seed in meta without parsing the library's stdout."""
    return random.Random(seed_value).randint(0, 2 ** 32 - 1)


def make_backend(engine, voice):
    if engine == "gsv_v2proplus":
        return GsvBackend(voice)
    raise SystemExit("engine %r is not implemented by this worker (IMPL §2.3 lists "
                     "zipvoice_s12 as a documented fallback: same skeleton, swap synth())" % engine)


# --- yield gate ------------------------------------------------------------------
class Gate:
    """Watches /health.lastTtsAgeMs: while someone is listening in real time, the batch
    job waits. This is the only place where the worker can hurt the live service, so it
    is checked before *every* block, not just per chapter (IMPL §2.4)."""

    def __init__(self, api_base, fresh_ms):
        self.url = api_base.rstrip("/") + "/health"
        self.fresh_ms = fresh_ms
        self.warned = False

    def age_ms(self):
        try:
            with urllib.request.urlopen(self.url, timeout=5) as r:
                return json.loads(r.read().decode("utf-8")).get("lastTtsAgeMs")
        except Exception as exc:
            if not self.warned:
                log.warning("health probe failed (%s); not gating on it", exc)
                self.warned = True
            return None

    def wait(self):
        while not STOP:
            age = self.age_ms()
            if age is None or age >= self.fresh_ms:
                return True
            log.info("yield: lastTtsAgeMs=%dms < %dms -- live /tts in flight, sleeping 15s",
                     age, self.fresh_ms)
            _sleep(15)
        return False


# --- chunking --------------------------------------------------------------------
_SENT_RE = re.compile(r"[^。！？!?;；…]*[。！？!?;；…]+|[^。！？!?;；…]+")


def _units(paragraphs, limit, oversized):
    """Paragraphs -> fill units, splitting *only* paragraphs longer than `limit` (and then
    only at sentence enders). Real chapters arrive as 50-300 char paragraphs, so the split
    branch is a safety valve: sending a whole chapter as one line must not become a single
    huge `run()` call -- that is the case that blew up memory on the engine side."""
    out = []
    for i, p in enumerate(paragraphs):
        if len(p) <= limit:
            out.append((i, p, False))
            continue
        oversized.append(i)
        buf = ""
        for s in _SENT_RE.findall(p):
            if buf and len(buf) + len(s) > limit:
                out.append((i, buf, True))
                buf = ""
            buf += s
            while len(buf) > limit:  # no punctuation at all: last resort, hard cut
                out.append((i, buf[:limit], True))
                buf = buf[limit:]
        if buf:
            out.append((i, buf, True))
    return out


def chunk_paragraphs(paragraphs, limit):
    """Greedy fill to <= `limit` chars, **never cutting a paragraph** unless the paragraph
    is itself longer than `limit` (IMPL §2.2: a block boundary is where the 320 ms seam
    goes, and the paragraph is the client's progress unit). Returns [(p0, p1, text, split)]
    with p1 exclusive; `split` marks a block that had to cut inside a paragraph."""
    oversized = []
    units = _units(paragraphs, limit, oversized)
    if oversized:
        log.warning("paragraph(s) %s exceed %d chars: cut at sentence enders, so the "
                    "paragraph->time mapping is only approximate there", oversized, limit)
    out, cur, p0, p1, split = [], [], None, 0, False
    for i, text, sp in units:
        if cur and len("\n".join(cur)) + 1 + len(text) > limit:
            out.append((p0, p1, "\n".join(cur), split))
            cur, split = [], False
        if not cur:
            p0 = i
        cur.append(text)
        p1 = i + 1
        split = split or sp
    if cur:
        out.append((p0, p1, "\n".join(cur), split))
    return out


def qc_block(rec, chars):
    """Per-block sanity gate (IMPL §2.7). Cheap: the numbers already come from the
    engine call. A silent/empty/short block is the failure mode that would otherwise be
    stitched into a 30 min file nobody listens to until it is too late."""
    if not rec:
        return "no audio returned"
    after = rec.get("after") or {}
    sec = float(after.get("sec") or 0.0)
    if sec <= 0:
        return "empty audio"
    cps = chars / sec
    if not 3.5 <= cps <= 6.5:
        return "chars/sec %.2f outside [3.5,6.5]" % cps
    peak_db = float(after.get("peak_dbfs", -99))
    if not -25.0 <= peak_db <= -1.0:
        return "peak %.1f dBFS outside [-25,-1]" % peak_db
    if float(after.get("rms_dbfs", -99)) < -45.0:
        return "silent block (rms %.1f dBFS)" % after["rms_dbfs"]
    return None


# --- one item --------------------------------------------------------------------
def fail_item(key, err, item=None):
    log.error("FAIL key=%s err=%s", key, err)
    extra = dict(item or {})
    extra.update({"err": err, "failedAt": cache.now_ms()})
    cache.finish(key, "fail", extra)
    for path in (cache.audio_path(key) + ".part",):
        try:
            os.unlink(path)
        except OSError:
            pass


def run_item(key, item, backend, gate, args):
    paras = [p.strip() for p in item.get("paragraphs", []) if p and p.strip()]
    if not paras:
        return fail_item(key, "no paragraphs", item)
    blocks = chunk_paragraphs(paras, args.chunk_chars)
    chars = len(cache.canonical_text(paras))
    base_seed = int(key[:8], 16)
    log.info("start key=%s chars=%d paras=%d blocks=%d voice=%s engine=%s attempts=%s",
             key, chars, len(paras), len(blocks), item.get("voice"), item.get("engine"),
             item.get("attempts", 0))

    frames, chunks, seeds = [], [], []
    synth_ms = 0.0
    for i, (p0, p1, text, split) in enumerate(blocks):
        if STOP:
            break
        if not gate.wait():  # SIGTERM while yielding
            break
        seed_value = base_seed + i
        predicted = _predict_seed(seed_value)
        rec, qc_err = None, None
        for attempt in (1, 2):  # one retry, same seed (IMPL §2.7)
            log.info("block %d/%d attempt=%d chars=%d seed=%d p0=%d p1=%d",
                     i + 1, len(blocks), attempt, len(text), predicted, p0, p1)
            try:
                rec = backend.synth(text, tag="%s_%02d" % (key, i + 1), seed_value=seed_value)
                qc_err = qc_block(rec, len(text))
            except Exception as exc:  # noqa: BLE001 -- one bad block must not kill the worker
                rec, qc_err = None, "exception: %r" % exc
                log.exception("block %d raised", i + 1)
            if not qc_err:
                break
            log.warning("block %d/%d attempt %d rejected: %s", i + 1, len(blocks), attempt, qc_err)
        if qc_err:
            _trim()
            return fail_item(key, "block %d/%d: %s" % (i + 1, len(blocks), qc_err), item)

        synth_ms += float(rec.get("wall_s") or 0.0) * 1000.0
        path = os.path.join(cache.WORK_DIR, rec["file"])
        with wave.open(path, "rb") as w:
            if w.getframerate() != SAMPLE_RATE or w.getnchannels() != 1 or w.getsampwidth() != 2:
                os.unlink(path)
                _trim()
                return fail_item(key, "block %d/%d: unexpected WAV format %dHz ch=%d sw=%d" % (
                    i + 1, len(blocks), w.getframerate(), w.getnchannels(), w.getsampwidth()), item)
            frames.append(np.frombuffer(w.readframes(w.getnframes()), dtype="<i2"))
        try:
            os.unlink(path)  # scratch: the final file is the only cache artifact we keep
        except OSError:
            pass
        chunks.append({"i": i, "t0Ms": 0, "t1Ms": 0, "chars": len(text),
                       "p0": p0, "p1": p1, "audioMs": 0, "synthMs": int(rec["wall_s"] * 1000),
                       "split": split})
        seeds.append(predicted)
        _trim()
        # Heartbeat: the stale reaper measures "no progress in --stale-min", not "in run/
        # for --stale-min" -- a single 1500-char block legitimately runs for ~30 min.
        try:
            os.utime(cache.queue_path(key, "run"), None)
        except OSError:
            pass
        log.info("block %d/%d done audio=%.1fs synth=%.1fs rtf=%.2f cps=%.2f mem=%s",
                 i + 1, len(blocks), rec["after"]["sec"], rec["wall_s"],
                 rec["wall_s"] / max(rec["after"]["sec"], 1e-6), len(text) / max(rec["after"]["sec"], 1e-6),
                 _rss_mb())

    if STOP or len(frames) != len(blocks):
        for f in frames:
            del f
        _trim()
        log.warning("key=%s interrupted after %d/%d blocks; releasing to new/",
                    key, len(frames), len(blocks))
        return cache.release(key)

    # stitch with the same 320 ms seam app.py uses between sentences
    pause = np.zeros(int(SAMPLE_RATE * cache.SEAM_MS / 1000.0), dtype="<i2")
    parts, t = [], 0
    for i, f in enumerate(frames):
        parts.append(f)
        chunks[i]["t0Ms"] = int(round(t / SAMPLE_RATE * 1000.0))
        t += len(f)
        chunks[i]["t1Ms"] = int(round(t / SAMPLE_RATE * 1000.0))
        chunks[i]["audioMs"] = chunks[i]["t1Ms"] - chunks[i]["t0Ms"]
        t += len(pause)
    for i in range(len(frames) - 1):
        parts.insert(2 * i + 1, pause)
    audio = np.concatenate(parts)
    total_ms = int(round(len(audio) / SAMPLE_RATE * 1000.0))

    need = int(audio.nbytes) + 44
    ev = cache.evict(need)
    if not ev["satisfied"]:
        del audio, parts, frames
        _trim()
        return fail_item(key, "cache_full_wait_playback (need %dMB, protected %d)"
                         % (need // 1048576, ev["protected"]), item)
    if ev["deleted"]:
        log.info("evicted %d played item(s) freeing %.1fMB: %s",
                 len(ev["deleted"]), ev["freed"] / 1048576.0, ev["deleted"])

    tmp = cache.audio_path(key) + ".part"
    with wave.open(tmp, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SAMPLE_RATE)
        w.writeframes(audio.tobytes())
    os.replace(tmp, cache.audio_path(key))  # atomic: a reader never sees a half file
    del audio, parts, frames
    _trim()

    old = cache.read_json(cache.meta_path(key)) or {}
    meta = {
        "key": key, "engine": item.get("engine", "gsv_v2proplus"), "voice": item.get("voice", ""),
        "speed": cache.SPEED, "ver": cache.PREGEN_VER,
        "bookId": item.get("bookId", ""), "chapterIndex": item.get("chapterIndex", 0),
        "title": item.get("title", ""),
        "chars": chars, "audioMs": total_ms, "synthMs": int(synth_ms),
        "createdAt": cache.now_ms(), "lastPlayedAt": int(old.get("lastPlayedAt") or 0),
        "chunks": chunks,
        # ops/reconciliation extras (not part of the client contract)
        "seeds": seeds, "blocks": len(blocks), "bytes": need,
        "splitBlocks": sum(1 for c in chunks if c["split"]),
        "rtf": round(synth_ms / 1000.0 / max(total_ms / 1000.0, 1e-6), 3),
        "charsPerSecAudio": round(chars / max(total_ms / 1000.0, 1e-6), 2),
        "synthMsPerChar": round(synth_ms / max(chars, 1), 1),
        "worker": WORKER_ID, "attempts": int(item.get("attempts") or 0),
    }
    cache.write_json(cache.meta_path(key), meta)
    cache.finish(key, "done", {"key": key})
    log.info("done key=%s chars=%d audio=%.1fs(%.1fmin) synth=%.1fs(%.2fh) rtf=%.2f "
             "bytes=%.1fMB blocks=%d mem=%s",
             key, chars, total_ms / 1000.0, total_ms / 60000.0, synth_ms / 1000.0,
             synth_ms / 3600000.0, meta["rtf"], need / 1048576.0, len(blocks), _rss_mb())
    return {"key": key, "audioMs": total_ms, "synthMs": int(synth_ms), "bytes": need}


# --- stale reaper ----------------------------------------------------------------
def reap_stale(stale_sec):
    """A killed worker leaves items in run/. After `stale_sec` they go back to new/ with
    attempts+1; attempts >= MAX_ATTEMPTS means the block reliably kills the box, so the
    item is failed instead of looping (IMPL §2.2 step 1)."""
    for key, path, mtime in cache.list_queue("run"):
        age = time.time() - mtime
        if age < stale_sec:
            continue
        item = cache.read_json(path) or {}
        attempts = int(item.get("attempts") or 0) + 1
        item["attempts"] = attempts
        item["staleAt"] = cache.now_ms()
        if attempts >= MAX_ATTEMPTS:
            fail_item(key, "stale x%d (>%.0fs in run/, worker killed?)" % (attempts, stale_sec), item)
        else:
            cache.write_json(path, item)
            cache.release(key)
            log.warning("reaped stale key=%s age=%.0fs attempts=%d -> new/", key, age, attempts)


# --- main ------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--engine", default="gsv_v2proplus", choices=["gsv_v2proplus"])
    ap.add_argument("--voice", default="流萤")
    ap.add_argument("--api-base", default="http://127.0.0.1:9880")
    ap.add_argument("--chunk-chars", type=int, default=1500)
    ap.add_argument("--yield-ms", type=int, default=60000, help="yield while /tts is newer than this")
    ap.add_argument("--stale-min", type=float, default=45.0)
    ap.add_argument("--poll", type=float, default=10.0)
    ap.add_argument("--once", action="store_true", help="process at most one item, then exit")
    ap.add_argument("--min-swap-mb", type=int, default=4096)
    args = ap.parse_args()

    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
    signal.signal(signal.SIGTERM, _on_term)
    signal.signal(signal.SIGINT, _on_term)

    swap = _swap_total_mb()
    if swap < args.min_swap_mb:
        # 3.3 GB resident on a 3.9 GB box: without the big swapfile the kernel picks a
        # victim and it may well be the live VITS service (IMPL §2.3).
        log.error("refusing to start: SwapTotal=%dMB < %dMB (see IMPL §2.3)", swap, args.min_swap_mb)
        return 3
    cache.ensure_dirs()
    log.info("worker start engine=%s voice=%s cache=%s maxBytes=%.1fGB reserveFree=%.1fGB "
             "chunkChars=%d swap=%dMB",
             args.engine, args.voice, cache.CACHE_DIR, cache.CACHE_MAX_BYTES / 1024 ** 3,
             cache.RESERVE_FREE / 1024 ** 3, args.chunk_chars, swap)

    backend, gate, done = None, Gate(args.api_base, args.yield_ms), 0
    while not STOP:
        reap_stale(args.stale_min * 60.0)
        entries = cache.list_queue("new")
        if not entries:
            if args.once:
                break
            _sleep(args.poll)
            continue
        key = entries[0][0]  # oldest first
        if not cache.claim(key):
            continue
        item = cache.read_json(cache.queue_path(key, "run")) or {}
        eng, voi = item.get("engine") or args.engine, item.get("voice") or args.voice
        if eng != args.engine or voi != args.voice:
            # Never synthesize one voice under another voice's key: the key would be
            # silently wrong for the client (IMPL §2.3 -- one worker, one voice pair).
            fail_item(key, "worker serves only engine=%s voice=%s, item asked %s/%s"
                      % (args.engine, args.voice, eng, voi), item)
            if args.once:
                break
            continue
        if backend is None:
            backend = make_backend(args.engine, args.voice)
        try:
            run_item(key, item, backend, gate, args)
        except Exception as exc:  # noqa: BLE001 -- the queue must survive anything
            log.exception("item %s crashed", key)
            fail_item(key, "worker crash: %r" % exc, item)
        done += 1
        if args.once:
            break

    log.info("worker exit items=%d stop=%s", done, STOP)
    return 0


if __name__ == "__main__":
    sys.exit(main())
