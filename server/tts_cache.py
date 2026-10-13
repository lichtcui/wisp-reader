"""Pre-gen cache helpers shared by `app.py` (HTTP) and `job_worker.py` (synthesis).

Deliberately numpy/torch-free and import-safe so app.py can keep its "never import
torch" property. This module is the **single source of truth** for four things the two
processes must never disagree about:

  * the on-disk layout (`audio/ meta/ queue/{new,run,done,fail} jobs/`),
  * the cache key (`sha256(canonical | voice | 1.0 | engine | v1)[:16]`),
  * what "ready"/"queued"/... means,
  * the eviction policy (played first, unplayed protected, two ceilings).

See `docs/research/TTS-PREGEN-IMPL.md` §1/§2.5/§2.6. Deployed twice -- `/root/tts/server/`
for the API and `/root/tts/gsv/` for the worker (which runs with `WorkingDirectory=/root/tts/gsv`).
"""

import hashlib
import json
import os
import re
import shutil
import time

# --- contract constants ----------------------------------------------------------
PREGEN_VER = 1        # post-processing contract (24k / -18 dBFS / -1 dBFS / 15+40 ms / 320 ms). Bump = old cache dies.
SPEED = 1.0           # cached audio is always speed 1.0; rate changes happen client-side
SEAM_MS = 320.0       # == app.py SENTENCE_PAUSE_MS; the silence the worker splices between blocks
BYTES_PER_CHAR = 9900  # measured: 48 KB/s / 4.85 chars-per-second at speed 1.0 (IMPL §0)
KEY_RE = re.compile(r"^[0-9a-f]{16}$")
QUEUE_STATES = ("new", "run", "done", "fail")
# Engines a job may name. `zipvoice_s12` is a documented fallback (IMPL §2.3) that the
# worker does not implement yet -- the API accepts it so the key/engine field stays
# stable, and the worker rejects it loudly instead of silently synthesizing a mismatch.
PREGEN_ENGINES = ("gsv_v2proplus", "zipvoice_s12")

CACHE_DIR = os.path.abspath(os.environ.get("CACHE_DIR", "/root/tts/cache"))
AUDIO_DIR = os.path.join(CACHE_DIR, "audio")
META_DIR = os.path.join(CACHE_DIR, "meta")
JOBS_DIR = os.path.join(CACHE_DIR, "jobs")
QUEUE_DIR = os.path.join(CACHE_DIR, "queue")
WORK_DIR = os.path.join(CACHE_DIR, "work")


def parse_size(raw, default):
    """'2G' / '1.5G' / '1536M' / '999' -> bytes. Kept dumb on purpose: only K/M/G."""
    if raw is None or raw == "":
        return default
    s = str(raw).strip().upper()
    mult = 1
    if s.endswith("K"):
        mult, s = 1024, s[:-1]
    elif s.endswith("M"):
        mult, s = 1024 ** 2, s[:-1]
    elif s.endswith("G"):
        mult, s = 1024 ** 3, s[:-1]
    try:
        return int(float(s) * mult)
    except ValueError:
        return default


CACHE_MAX_BYTES = parse_size(os.environ.get("CACHE_MAX_BYTES"), 2 * 1024 ** 3)
RESERVE_FREE = parse_size(os.environ.get("RESERVE_FREE"), int(1.5 * 1024 ** 3))


# --- paths ----------------------------------------------------------------------
def ensure_dirs():
    for d in (AUDIO_DIR, META_DIR, JOBS_DIR, WORK_DIR) + tuple(state_dir(s) for s in QUEUE_STATES):
        os.makedirs(d, exist_ok=True)


def state_dir(state):
    return os.path.join(QUEUE_DIR, state)


def audio_path(key):
    return os.path.join(AUDIO_DIR, key + ".wav")


def meta_path(key):
    return os.path.join(META_DIR, key + ".json")


def queue_path(key, state):
    return os.path.join(state_dir(state), key + ".json")


def job_path(job_id):
    return os.path.join(JOBS_DIR, job_id + ".json")


def valid_key(key):
    """Guards every path that is built from a client-supplied key (path traversal)."""
    return bool(key) and bool(KEY_RE.match(key))


# --- json / fs helpers ----------------------------------------------------------
def read_json(path, default=None):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def write_json(path, obj):
    """Atomic: a reader either sees the old file or the new one, never a partial one."""
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)


def now_ms():
    return int(time.time() * 1000)


# --- cache key -----------------------------------------------------------------
def canonical_text(paragraphs):
    """Trim each paragraph, drop the empty ones, join with '\\n'.

    The trim/drop rules live here so the API (`/job`, `/cache/probe`) and the worker
    always hash the same text; a client that sends padding must not get a second key.
    """
    return "\n".join(p.strip() for p in (paragraphs or []) if p and p.strip())


def cache_key(paragraphs, voice, engine, ver=PREGEN_VER):
    raw = "%s|%s|%.1f|%s|v%d" % (canonical_text(paragraphs), voice, SPEED, engine, ver)
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()[:16]


def est_bytes(chars):
    """Pre-flight footprint estimate so /job can refuse before anything is generated."""
    return max(0, int(chars)) * BYTES_PER_CHAR


# --- state ----------------------------------------------------------------------
def queue_state(key):
    """Which queue dir holds this key (None if never enqueued / already reaped)."""
    for state in QUEUE_STATES:
        if os.path.exists(queue_path(key, state)):
            return state
    return None


def is_ready(key):
    """Audio is written with os.replace *before* meta, so require both."""
    return os.path.exists(audio_path(key)) and os.path.exists(meta_path(key))


def item_state(key):
    """ready | queued | running | failed | expired | unknown.

    `expired` is the tombstone case (done/ item whose audio an eviction deleted); the
    client treats anything that is not `ready` as a cache miss.
    """
    if is_ready(key):
        return "ready"
    state = queue_state(key)
    if state == "new":
        return "queued"
    if state == "run":
        return "running"
    if state == "fail":
        return "failed"
    if state == "done":
        return "expired"
    return "unknown"


def list_queue(state, limit=None):
    """Oldest-first (mtime) entries of a queue dir: [(key, path, mtime), ...]."""
    d = state_dir(state)
    out = []
    try:
        names = os.listdir(d)
    except OSError:
        return out
    for name in names:
        if not name.endswith(".json"):
            continue
        path = os.path.join(d, name)
        try:
            out.append((name[:-5], path, os.path.getmtime(path)))
        except OSError:
            continue
    out.sort(key=lambda t: t[2])
    return out[:limit] if limit else out


def queue_counts():
    return {state: len(list_queue(state)) for state in QUEUE_STATES}


def claim(key):
    """new -> run, atomically (os.rename on one filesystem). False = lost the race."""
    try:
        os.rename(queue_path(key, "new"), queue_path(key, "run"))
        return True
    except OSError:
        return False


def release(key):
    """run -> new (SIGTERM / stale reaper); attempts are the caller's business."""
    try:
        os.rename(queue_path(key, "run"), queue_path(key, "new"))
        return True
    except OSError:
        return False


def finish(key, state, extra=None):
    """run -> done|fail, optionally merging `extra` into the item JSON."""
    src, dst = queue_path(key, "run"), queue_path(key, state)
    if extra:
        item = read_json(src, {}) or {}
        item.update(extra)
        write_json(src, item)
    try:
        os.replace(src, dst)
        return True
    except OSError:
        return False


def delete_item(key, state):
    try:
        os.unlink(queue_path(key, state))
    except OSError:
        pass


# --- playback marking + stats ---------------------------------------------------
def touch_played(key, ts_ms=None):
    """GET /audio/<key> marks the item played -- this is what makes it evictable."""
    ts = ts_ms or now_ms()
    meta = read_json(meta_path(key))
    if meta is None:
        return
    meta["lastPlayedAt"] = ts
    write_json(meta_path(key), meta)
    try:
        os.utime(audio_path(key), None)
    except OSError:
        pass


def _audio_entries():
    """[(key, path, size, lastPlayedAt)] for every playable file that has meta."""
    out = []
    try:
        names = os.listdir(AUDIO_DIR)
    except OSError:
        return out
    for name in names:
        if not name.endswith(".wav"):
            continue
        key = name[:-4]
        path = os.path.join(AUDIO_DIR, name)
        try:
            size = os.path.getsize(path)
        except OSError:
            continue
        meta = read_json(meta_path(key)) or {}
        out.append((key, path, size, int(meta.get("lastPlayedAt") or 0)))
    return out


def stats():
    ensure_dirs()  # the API must answer before the first job ever creates the tree
    entries = _audio_entries()
    protected = sum(1 for e in entries if e[3] <= 0)
    du = shutil.disk_usage(CACHE_DIR)
    return {
        "files": len(entries),
        "bytes": sum(e[2] for e in entries),
        "maxBytes": CACHE_MAX_BYTES,
        "freeBytes": du.free,
        "reserveFreeBytes": RESERVE_FREE,
        "protected": protected,
        "played": len(entries) - protected,
        "queue": queue_counts(),
    }


def delete_cache(key, drop_tombstone=True):
    """Drop one cached chapter (client calls DELETE /cache/<key> after listening)."""
    removed = []
    for path in (audio_path(key), meta_path(key)):
        try:
            os.unlink(path)
            removed.append(os.path.basename(path))
        except OSError:
            pass
    if drop_tombstone:
        delete_item(key, "done")
    return removed


def evict(need_bytes=0):
    """Make room for `need_bytes` more of cache; delete played items, oldest first.

    Two ceilings (IMPL §2.6): `bytes + need <= CACHE_MAX_BYTES` and the disk must keep
    `RESERVE_FREE` free after the write. Unplayed items are **protected** -- the whole
    point is to never evict the chapter the user is about to listen to; when only
    protected items are left and it still does not fit, the caller answers
    `409 cache_full_wait_playback` instead of deleting them.
    """
    ensure_dirs()
    entries = _audio_entries()
    total = sum(e[2] for e in entries)
    protected = sum(1 for e in entries if e[3] <= 0)

    def fits(extra, free):
        return total + extra <= CACHE_MAX_BYTES and free - extra >= RESERVE_FREE

    free = shutil.disk_usage(CACHE_DIR).free
    freed = 0
    if fits(need_bytes, free):
        return {"freed": 0, "satisfied": True, "protected": protected, "deleted": []}

    deleted = []
    for key, path, size, played_at in sorted(entries, key=lambda e: (e[3] <= 0, e[3])):
        if played_at <= 0:
            break  # entries are sorted played-first; the rest is protected
        if fits(need_bytes, free):
            break
        delete_cache(key, drop_tombstone=False)
        deleted.append(key)
        total -= size
        free += size
        freed += size
    return {"freed": freed, "satisfied": fits(need_bytes, free), "protected": protected, "deleted": deleted}


# --- jobs (a /job POST is a group of keys; kept in a file, not in memory) --------
def write_job(job_id, keys, items):
    write_json(job_path(job_id), {"jobId": job_id, "keys": keys, "items": items, "createdAt": now_ms()})


def read_job(job_id):
    return read_json(job_path(job_id))


def new_job_id():
    return "%08x%s" % (int(time.time()), os.urandom(3).hex())


def prune_jobs(keep=500):
    """Job records are tiny, but the box is small; keep the newest `keep` of them."""
    entries = []
    try:
        for name in os.listdir(JOBS_DIR):
            if name.endswith(".json"):
                path = os.path.join(JOBS_DIR, name)
                try:
                    entries.append((os.path.getmtime(path), path))
                except OSError:
                    pass
    except OSError:
        return 0
    entries.sort(reverse=True)
    for _, path in entries[keep:]:
        try:
            os.unlink(path)
        except OSError:
            pass
    return max(0, len(entries) - keep)
