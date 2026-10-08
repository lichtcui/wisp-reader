"""Remote TTS service: sherpa-onnx OfflineTts + ZipVoice (int8 distil) zero-shot clone.

Endpoints:
  GET  /health                   -> {"ok": true}
  POST /tts {text, voice, speed} -> audio/wav (24kHz S16LE mono, RIFF header)

Single user / single VPS worker. Reference audio is resampled to the model rate once
at load and kept resident; `tts.generate(...)` is serialized by a lock because
sherpa's OfflineTts.generate() is not thread-safe (`num_threads=4` per call, so two
concurrent calls would oversubscribe a 4-core box).

Post-processing (see `docs/research/TTS-ENGINE-COMPARISON.md` for the measurements):
ZipVoice at the only affordable step count (2-3 on a 4-core CPU) loses the 600-1500 Hz
presence band and piles ~48% of the energy into a single 200-300 Hz band, which is
audible as "boomy / muddy". `num_steps>=6` fixes it but pushes RTF above 1.5, so the
service instead applies a zero-phase FFT EQ (de-mud + presence), a per-voice loudness
normalization (the raw model differs by up to 5.5 dB between voices) and edge fades.
All of it costs ~0.2% CPU, i.e. it does not move the RTF.

Env knobs:
  NUM_STEPS           flow-matching steps (2-3 keeps RTF<1 on 4 cores; >=6 is cleaner but RTF>1)
  EQ_BANDS            "fc:gain_db:q,..." peaking filters; empty string disables EQ
  TARGET_RMS_DBFS     loudness target (default -16 dBFS RMS)
  PEAK_CEILING_DBFS   peak ceiling; normalization is reduced rather than clipping
  POST_ENABLE         "0" to bypass EQ/normalize/fades entirely (A/B + rollback)
  ZIPVOICE_DIR / VOCODER / REFS_DIR / X_API_KEY   as before

Auth: if `X_API_KEY` env is set, the `X-API-Key` request header must match.
"""

import io
import logging
import os
import threading
import time
import wave

import numpy as np
import sherpa_onnx as so
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import Response
from pydantic import BaseModel

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
log = logging.getLogger("remote-tts")

MODEL_DIR = os.environ.get(
    "ZIPVOICE_DIR",
    "/root/tts/zipvoice/sherpa-onnx-zipvoice-distill-int8-zh-en-emilia",
)
VOCODER = os.environ.get("VOCODER", "/root/tts/zipvoice/vocos_24khz.onnx")
REFS_DIR = os.environ.get("REFS_DIR", "/root/tts/refs")
API_KEY = os.environ.get("X_API_KEY", "").strip()

NUM_STEPS = int(os.environ.get("NUM_STEPS", "2"))  # 2 = RTF<1 前提；=3 偏慢但更干净，可 A/B
NUM_THREADS = 4
MODEL_PROVIDER = "cpu"

# --- post-processing -------------------------------------------------------------
POST_ENABLE = os.environ.get("POST_ENABLE", "1") != "0"
# Measured deviation of num_steps=3 output vs. the num_steps=6 output (and vs. the
# reference clips): too much 200-300 Hz, too little 600-1500 Hz. Values in dB.
EQ_BANDS_RAW = os.environ.get("EQ_BANDS", "280:-3.5:0.9,2800:+3.5:0.7")
TARGET_RMS_DBFS = float(os.environ.get("TARGET_RMS_DBFS", "-18"))
PEAK_CEILING_DBFS = float(os.environ.get("PEAK_CEILING_DBFS", "-1"))
FADE_IN_MS = 15
FADE_OUT_MS = 40

BAND_EDGES = [(0, 120), (120, 200), (200, 300), (300, 600), (600, 1500), (1500, 4000), (4000, 8000)]

# voice -> default reference audio (basename under REFS_DIR/<voice>/中文/emotions/)
VOICE_REFS = {
    "流萤": "【中立】…我应该会选择请求猎犬家系停止追捕。.wav",
    "花火": "【吃惊】…好吧，看你这个表情是不会相信我的…没事，我可以明天再来问你一遍！.wav",
    "卡芙卡": "【中立】黑塔用这么简单的小玩意藏她的宝贝？.wav",
}

_tts = None
_refs = {}  # voice -> (ref_samples float32 @ model rate, sr, ref_text)
_lock = threading.Lock()  # sherpa OfflineTts.generate() is not thread-safe; serialize


# --- audio helpers (numpy only: the VPS has no scipy/ffmpeg) ----------------------

def _resample_fft(x, sr_in, sr_out):
    """Band-limited (FFT) resampler. Runs 3x at startup; keeps the refs at the model
    rate so sherpa does not rebuild a 44.1k->24k resampler on every request."""
    if sr_in == sr_out:
        return x, sr_out
    n_out = int(round(len(x) * sr_out / sr_in))
    nfft = 1 << int(np.ceil(np.log2(max(len(x), 2))))
    X = np.fft.rfft(x, nfft)
    f = np.fft.rfftfreq(nfft, 1.0 / sr_in)
    taper = np.ones_like(f)
    hi = 0.45 * min(sr_in, sr_out)  # anti-alias corner
    lo = 0.9 * hi
    taper[f >= hi] = 0.0
    m = (f > lo) & (f < hi)
    taper[m] = 0.5 * (1.0 + np.cos(np.pi * (f[m] - lo) / (hi - lo)))
    n_out_fft = int(round(nfft * sr_out / sr_in))
    n_out_fft += n_out_fft % 2
    Y = np.zeros(n_out_fft // 2 + 1, dtype=np.complex128)
    k = min(len(X), len(Y))
    Y[:k] = X[:k] * taper[:k]
    y = np.fft.irfft(Y, n_out_fft) * (n_out_fft / nfft)
    return y[:n_out].astype(np.float32), sr_out


def _peaking_mag(f, sr, fc, gain_db, q):
    """|H(f)| of an RBJ peaking EQ, used as a zero-phase magnitude shaper."""
    a = 10.0 ** (gain_db / 40.0)
    w0 = 2.0 * np.pi * fc / sr
    z = 1j * (2.0 * np.pi * f / sr) / w0
    num = 1.0 + (a / q) * z + z * z
    den = 1.0 + z / (a * q) + z * z
    return np.abs(num) / np.maximum(np.abs(den), 1e-12)


def _parse_bands(raw):
    bands = []
    for item in raw.split(","):
        item = item.strip()
        if not item:
            continue
        parts = item.split(":")
        if len(parts) != 3:
            raise ValueError("bad EQ band %r (want fc:gain_db:q)" % item)
        bands.append((float(parts[0]), float(parts[1]), float(parts[2])))
    return bands


EQ_BANDS = _parse_bands(EQ_BANDS_RAW) if POST_ENABLE else []


def _eq(x, sr, bands):
    """Zero-phase FFT EQ. We already hold the whole paragraph, so an FFT pass (~20 ms
    for 30 s of audio) is cheaper and simpler than an IIR we cannot get from scipy."""
    if not bands or len(x) < 64:
        return x
    n = len(x)
    nfft = 1 << int(np.ceil(np.log2(n + sr // 5)))  # pad 200 ms so pre-ring is dropped
    spec = np.fft.rfft(x, nfft)
    f = np.fft.rfftfreq(nfft, 1.0 / sr)
    shape = np.ones_like(f)
    for fc, gain, q in bands:
        shape *= _peaking_mag(f, sr, fc, gain, q)
    return np.fft.irfft(spec * shape, nfft)[:n].astype(np.float32)


def _limit(x, sr, ceiling, block_ms=20):
    """Block-wise peak limiter: gain envelope from 20 ms block maxima, dilated over
    (not average-smoothed -- averaging dips the envelope wherever a quiet block
    neighbours a loud one, which let peaks back over the ceiling) and linearly
    interpolated back. Vectorized on purpose: a per-sample attack/release loop over
    30 s of audio would cost more than the synthesis itself."""
    b = max(1, int(sr * block_ms / 1000.0))
    n = max(len(x) // b, 1)
    seg = np.abs(x[: n * b]).reshape(n, b).max(axis=1)
    env = seg.copy()
    for k in (1, 2):  # dilate by +/-2 blocks (~40 ms) so the gain ramps instead of jumping
        if n > k:
            env[:-k] = np.maximum(env[:-k], seg[k:])
            env[k:] = np.maximum(env[k:], seg[:-k])
    g = np.minimum(1.0, ceiling / np.maximum(env, 1e-9))
    gi = np.interp(np.arange(len(x)), (np.arange(n) + 0.5) * b, g)
    y = (x * gi).astype(np.float32)
    # guarantee: the dilated envelope bounds the peak but not analytically, so bound it
    peak = float(np.abs(y).max())
    if peak > ceiling:
        y = (y * (ceiling / peak)).astype(np.float32)
    return y


def _normalize(x, sr, target_dbfs, ceiling_dbfs):
    """Gain to a target RMS (equalizes voices), then limit to the ceiling instead of
    just backing the gain off -- backing off made every voice peak-limited, which left
    a 3 dB loudness spread instead of closing it."""
    rms = float(np.sqrt(np.mean(np.square(x, dtype=np.float64))))
    if rms <= 1e-9:
        return x, 0.0, rms
    gain = (10.0 ** (target_dbfs / 20.0)) / rms
    y = (x * gain).astype(np.float32)
    ceiling = 10.0 ** (ceiling_dbfs / 20.0)
    if float(np.abs(y).max()) > ceiling:
        y = _limit(y, sr, ceiling)
    return y, 20.0 * np.log10(gain), float(np.sqrt(np.mean(np.square(y, dtype=np.float64))))


def _fades(x, sr, in_ms, out_ms):
    """The client concatenates paragraphs back-to-back with no crossfade, so a hard
    end at full amplitude is an audible click (and reads as low-frequency 'thump')."""
    y = x
    n_in, n_out = int(sr * in_ms / 1000), int(sr * out_ms / 1000)
    if 1 < n_in < len(y):
        y = y.copy()
        y[:n_in] *= np.linspace(0.0, 1.0, n_in, dtype=np.float32)
    if 1 < n_out < len(y):
        if y is x:
            y = y.copy()
        y[-n_out:] *= np.linspace(1.0, 0.0, n_out, dtype=np.float32)
    return y


def _profile(x, sr):
    """Energy share (%) per band + RMS + peak, for load/request telemetry.

    The FFT length is quantized to a power of two on purpose. numpy's pocketfft caches
    twiddle factors per transform length and never evicts; using len(x) here meant every
    new paragraph length added a permanent cache entry (~120 KB per 400k samples), which
    grew the server by ~1.5 MB per request. Zero-padding does not move the band
    percentages: Parseval scales every bin by the same nfft/n factor.
    """
    if len(x) < 256:
        return {}
    nfft = 1 << max(1, (len(x) - 1).bit_length())
    spec = np.abs(np.fft.rfft(x * np.hanning(len(x)), nfft)) ** 2
    f = np.fft.rfftfreq(nfft, 1.0 / sr)
    total = max(spec.sum(), 1e-12)
    out = {"rms": float(np.sqrt(np.mean(np.square(x, dtype=np.float64)))), "peak": float(np.abs(x).max())}
    for a, b in BAND_EDGES:
        out["%d-%d" % (a, b)] = float(spec[(f >= a) & (f < b)].sum() / total * 100.0)
    return out


def _fmt_profile(p):
    if not p:
        return "(too short)"
    bands = " ".join(
        "%d-%d=%.1f" % (a, b, p["%d-%d" % (a, b)]) for a, b in BAND_EDGES
    )
    return "rms=%.4f peak=%.3f | %s" % (p["rms"], p["peak"], bands)


def _load_wav(path):
    with wave.open(path, "rb") as w:
        sr, n, ch, sw = w.getframerate(), w.getnframes(), w.getnchannels(), w.getsampwidth()
        raw = w.readframes(n)
    if sw == 2:
        x = np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768.0
    elif sw == 4:
        x = np.frombuffer(raw, dtype=np.int32).astype(np.float32) / 2147483648.0
    else:
        raise ValueError("unsupported sampwidth %d" % sw)
    if ch > 1:
        x = x.reshape(-1, ch).mean(axis=1)
    return x, sr


def _ref_text_from(path):
    stem = os.path.splitext(os.path.basename(path))[0]
    return stem.split("】", 1)[1].strip() if "】" in stem else stem.strip()


def _build():
    global _tts
    t0 = time.time()
    zip_cfg = so.OfflineTtsZipvoiceModelConfig(
        tokens=os.path.join(MODEL_DIR, "tokens.txt"),
        encoder=os.path.join(MODEL_DIR, "encoder.int8.onnx"),
        decoder=os.path.join(MODEL_DIR, "decoder.int8.onnx"),
        vocoder=VOCODER,
        data_dir=os.path.join(MODEL_DIR, "espeak-ng-data"),
        lexicon=os.path.join(MODEL_DIR, "lexicon.txt"),
    )
    model_cfg = so.OfflineTtsModelConfig(zipvoice=zip_cfg, num_threads=NUM_THREADS, provider=MODEL_PROVIDER)
    _tts = so.OfflineTts(so.OfflineTtsConfig(model=model_cfg, max_num_sentences=1))
    for voice, name in VOICE_REFS.items():
        path = os.path.join(REFS_DIR, voice, "中文", "emotions", name)
        samples, sr = _load_wav(path)
        rms_in = float(np.sqrt(np.mean(np.square(samples, dtype=np.float64))))
        samples, sr = _resample_fft(samples, sr, 24000)
        rms_out = float(np.sqrt(np.mean(np.square(samples, dtype=np.float64))))
        _refs[voice] = (samples, sr, _ref_text_from(path))
        log.info(
            "ref loaded voice=%s file=%s sr=%d dur=%.2fs rms %.4f->%.4f",
            voice, name, sr, len(samples) / sr, rms_in, rms_out,
        )
    # warmup: pay the first-inference / resampler creation cost now, not on first request
    _s, _sr, _t = _refs[list(VOICE_REFS)[0]]
    warm = _tts.generate("你好", prompt_text=_t, prompt_samples=_s, sample_rate=_sr, num_steps=NUM_STEPS)
    log.info(
        "post-processing: enabled=%s eq=%s target=%.1fdBFS ceiling=%.1fdBFS",
        POST_ENABLE, EQ_BANDS_RAW if POST_ENABLE else "(off)", TARGET_RMS_DBFS, PEAK_CEILING_DBFS,
    )
    log.info("tts ready (warmed) in %.2fs; warmup %s", time.time() - t0,
             _fmt_profile(_profile(np.asarray(warm.samples, dtype=np.float32), warm.sample_rate)))


_build()

app = FastAPI(title="remote-tts", version="1.1.0")


class TtsRequest(BaseModel):
    text: str
    voice: str = "流萤"
    speed: float = 1.0


@app.get("/health")
def health():
    return {"ok": True, "steps": NUM_STEPS, "post": POST_ENABLE, "eq": EQ_BANDS_RAW if POST_ENABLE else ""}


@app.post("/tts")
def synthesize(req: TtsRequest, request: Request):
    if API_KEY:
        got = request.headers.get("X-API-Key", "")
        if got != API_KEY:
            raise HTTPException(status_code=401, detail="unauthorized")
    if req.voice not in VOICE_REFS:
        raise HTTPException(status_code=400, detail="unknown voice")
    text = req.text.strip()
    if not text:
        raise HTTPException(status_code=400, detail="empty text")
    # `speed` is accepted for API compatibility but ZipVoice has no rate control;
    # playback speed is handled client-side (system TTS only) in v1.

    ref_samples, ref_sr, ref_text = _refs[req.voice]
    t0 = time.time()
    with _lock:
        audio = _tts.generate(
            text,
            prompt_text=ref_text,
            prompt_samples=ref_samples,
            sample_rate=ref_sr,
            num_steps=NUM_STEPS,
        )
        t_synth = time.time()
        samples = np.asarray(audio.samples, dtype=np.float32)
        out_sr = audio.sample_rate
        raw_prof = _profile(samples - samples.mean(), out_sr)
        out_rms = float(raw_prof.get("rms", 0.0))
        if POST_ENABLE:
            samples = samples - samples.mean()
            samples = _eq(samples, out_sr, EQ_BANDS)
            samples, gain_db, out_rms = _normalize(samples, out_sr, TARGET_RMS_DBFS, PEAK_CEILING_DBFS)
            samples = _fades(samples, out_sr, FADE_IN_MS, FADE_OUT_MS)
        else:
            gain_db = 0.0
        wall = time.time() - t0
        # only the last-resort safety net: normalization already keeps us under the ceiling
        s16 = np.clip(samples * 32767.0, -32768.0, 32767.0).astype("<i2")
        dur = len(samples) / out_sr

        buf = io.BytesIO()
        with wave.open(buf, "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(out_sr)
            w.writeframes(s16.tobytes())
    log.info(
        "synth voice=%s chars=%d dur=%.2fs wall=%.2fs rtf=%.3f synth=%.2fs sr=%d gain=%+.2fdB "
        "rms %.4f->%.4f",
        req.voice, len(text), dur, wall, wall / dur if dur else 0.0, t_synth - t0, out_sr, gain_db,
        raw_prof.get("rms", 0.0), out_rms,
    )
    log.info("  before: %s", _fmt_profile(raw_prof))
    log.info("  after : %s", _fmt_profile(_profile(samples - samples.mean(), out_sr)))
    return Response(content=buf.getvalue(), media_type="audio/wav")
