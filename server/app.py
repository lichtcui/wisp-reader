"""Remote TTS service for the HarmonyOS reader.

Two engines, selected by `ENGINE`:

  vits      (default) sherpa-onnx OfflineTts + multi-speaker VITS.
            Model: vits-hf-zh-jp-zomehwh.onnx (804 speakers, native 22050 Hz).
            Chinese pronunciation comes from a *Chinese-only* lexicon -- see below.
  zipvoice  sherpa-onnx OfflineTtsZipvoiceModelConfig zero-shot cloning (kept for
            rollback; RTF>=0.83 on a 4-core box and its few-step flow-matching output
            is audibly muddy at any affordable step count).

Endpoints:
  GET  /health                   -> {"ok", "engine", "voices", "speed_scale", ...}
  POST /tts {text, voice, speed} -> audio/wav (24 kHz S16LE mono, RIFF header)

Why the lexicon matters (this was the "some characters sound like a Japanese person"
bug): the checkpoint's own lexicon ships as two concatenated, codepoint-sorted
passes -- pass 1 is a Chinese *single-character* table, pass 2 is a Japanese word
list, and the two only overlap for 1,376 words. sherpa's InitLexicon keeps the first
occurrence, so Chinese wins for those, but every multi-character Chinese word that
exists only in the Japanese pass is read in Japanese:

    追求 -> ʦ ɯ ↑ i k y ɯ ɯ (tsuikyuu)   instead of   zhuīqiú
    分裂 -> b ɯ ↑ N r e ʦ ɯ  (bunretsu)  instead of   fēnliè

`lexicon_final.txt` is built by `mklex2.py`: the complete pure-Chinese lexicon
(66,395 entries, 0 duplicates when loaded) plus 395 rare single chars from the
checkpoint's Chinese pass; the Japanese pass is dropped outright.

Text normalization: the model's symbol table has no digits, so without `rule_fsts`
every number is silently dropped ("第2024章" -> "第章"). `date.fst`, `number.fst`
and `phone.fst` expand digits to Chinese before synthesis.

Pauses: punctuation is not in the lexicon (it is dropped as OOV) but sherpa still
splits on it, and it produces only ~80 ms of silence. Measured: the same paragraph
with punctuation removed has *zero* internal pauses. `SENTENCE_PAUSE_MS` therefore
splits the text at sentence enders server-side and inserts real silence, while commas
keep the model's own short pauses.

Post-processing (numpy only -- the VPS has no scipy/ffmpeg/sox). For ZipVoice the
few-step flow-matching output piles ~48% of its energy into 200-300 Hz and loses the
600-1500 Hz presence band, hence the optional zero-phase EQ; VITS does not need it,
so EQ defaults to off there. Loudness normalization (voices differ by up to 5.5 dB)
plus a block-wise peak limiter and edge fades always run. All of it costs ~0.2% CPU.

Env knobs:
  ENGINE              vits | zipvoice
  VITS_DIR            model dir (default /root/tts/genshin-vits)
  VITS_DICT_DIR       jieba dict dir for word segmentation
  RULE_FST_DIR        dir holding date.fst / number.fst / phone.fst
  SPEED_SCALE         server-side multiplier on the client's speed (default 0.85)
  SENTENCE_PAUSE_MS   silence inserted between sentences (default 320; 0 = off)
  EQ_BANDS            "fc:gain_db:q,..."; empty disables EQ
  TARGET_RMS_DBFS     loudness target (default -18 dBFS RMS)
  PEAK_CEILING_DBFS   peak ceiling; the limiter engages instead of clipping
  POST_ENABLE         "0" to bypass EQ/normalize/limit/fades (A/B + rollback)
  X_API_KEY           if set, requests need a matching `X-API-Key` header
  NUM_STEPS / ZIPVOICE_DIR / VOCODER / REFS_DIR   ZipVoice engine only
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

ENGINE = os.environ.get("ENGINE", "vits").strip().lower()
API_KEY = os.environ.get("X_API_KEY", "").strip()
NUM_THREADS = 4
MODEL_PROVIDER = "cpu"
OUT_SR = 24000  # the client's contract (SAMPLE_RATE_REMOTE)

# --- VITS engine -----------------------------------------------------------------
VITS_DIR = os.environ.get("VITS_DIR", "/root/tts/genshin-vits")
VITS_MODEL = os.path.join(VITS_DIR, "vits-hf-zh-jp-zomehwh.onnx")
VITS_TOKENS = os.path.join(VITS_DIR, "zome_tokens.txt")
VITS_LEXICON = os.path.join(VITS_DIR, "lexicon_final.txt")
VITS_DICT_DIR = os.environ.get("VITS_DICT_DIR", "/root/tts/vits-zh-ll/sherpa-onnx-vits-zh-ll/dict")
RULE_FST_DIR = os.environ.get("RULE_FST_DIR", "/root/tts/vits-zh-ll/sherpa-onnx-vits-zh-ll")
RULE_FSTS = [x.strip() for x in os.environ.get("RULE_FSTS", "date.fst,number.fst,phone.fst").split(",") if x.strip()]

# sid verified by measuring F0 per speaker: male voices must land at 90-140 Hz.
VITS_VOICES = {
    "胡桃": 119,      # 312 Hz
    "甘雨": 111,      # 273 Hz
    "刻晴": 115,      # 255 Hz
    "雷电将军": 125,  # 208 Hz
    "钟离": 104,      # 122 Hz
}
# The app still ships TTS_REMOTE_VOICE_OPTIONS=[流萤, 花火, 卡芙卡]; accepting them here
# keeps the client working until that list is updated.
VITS_VOICE_ALIASES = {"流萤": "甘雨", "花火": "胡桃", "卡芙卡": "雷电将军"}

SPEED_SCALE = float(os.environ.get("SPEED_SCALE", "0.85"))
SENTENCE_PAUSE_MS = float(os.environ.get("SENTENCE_PAUSE_MS", "320"))

# --- ZipVoice engine (rollback path) ---------------------------------------------
MODEL_DIR = os.environ.get("ZIPVOICE_DIR",
                           "/root/tts/zipvoice/sherpa-onnx-zipvoice-distill-int8-zh-en-emilia")
VOCODER = os.environ.get("VOCODER", "/root/tts/zipvoice/vocos_24khz.onnx")
REFS_DIR = os.environ.get("REFS_DIR", "/root/tts/refs")
NUM_STEPS = int(os.environ.get("NUM_STEPS", "3"))  # 2 = RTF<1 前提；>=6 更干净但 RTF>1.5

VOICE_REFS = {
    "流萤": "【中立】…我应该会选择请求猎犬家系停止追捕。.wav",
    "花火": "【吃惊】…好吧，看你这个表情是不会相信我的…没事，我可以明天再来问你一遍！.wav",
    "卡芙卡": "【中立】黑塔用这么简单的小玩意藏她的宝贝？.wav",
}

# --- post-processing -------------------------------------------------------------
POST_ENABLE = os.environ.get("POST_ENABLE", "1") != "0"
# Only meaningful for ZipVoice; VITS output needs no spectral correction.
EQ_BANDS_RAW = os.environ.get("EQ_BANDS", "" if ENGINE == "vits" else "280:-3.5:0.9,2800:+3.5:0.7")
TARGET_RMS_DBFS = float(os.environ.get("TARGET_RMS_DBFS", "-18"))
PEAK_CEILING_DBFS = float(os.environ.get("PEAK_CEILING_DBFS", "-1"))
FADE_IN_MS = 15
FADE_OUT_MS = 40

BAND_EDGES = [(0, 120), (120, 200), (200, 300), (300, 600), (600, 1500), (1500, 4000), (4000, 8000)]

_tts = None
_refs = {}  # ZipVoice only: voice -> (samples float32 @ model rate, sr, ref_text)
_lock = threading.Lock()  # OfflineTts.generate() is not thread-safe; serialize


# --- audio helpers (numpy only: the VPS has no scipy/ffmpeg) ----------------------

def _resample_fft(x, sr_in, sr_out):
    """Band-limited (FFT) resampler. Verified tone-transparent: 1000 Hz in -> 1000 Hz
    out. Done once per response (22050 -> 24000), never per reference clip."""
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
    bands = " ".join("%d-%d=%.1f" % (a, b, p["%d-%d" % (a, b)]) for a, b in BAND_EDGES)
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


def _split_sentences(text):
    """Break on sentence enders so we can insert our own silence between them.

    sherpa already splits on punctuation, but it only produces ~80 ms of silence
    (measured), which reads as "no room to breathe" over a whole chapter. Commas stay
    inside a segment on purpose: the model's own short pause there is about right.
    """
    out = []
    buf = []
    for ch in text:
        if ch in "\n\r":
            if buf:
                out.append("".join(buf))
                buf = []
            continue
        if ch in "。！？!?…":
            buf.append(ch)
            out.append("".join(buf))
            buf = []
        else:
            buf.append(ch)
    if buf:
        out.append("".join(buf))
    return [s.strip() for s in out if s.strip()]


def _build_vits():
    global _tts
    _tts = so.OfflineTts(so.OfflineTtsConfig(
        model=so.OfflineTtsModelConfig(
            vits=so.OfflineTtsVitsModelConfig(
                model=VITS_MODEL,
                tokens=VITS_TOKENS,
                lexicon=VITS_LEXICON,
                dict_dir=VITS_DICT_DIR,
            ),
            num_threads=NUM_THREADS,
            provider=MODEL_PROVIDER,
        ),
        max_num_sentences=1,
        rule_fsts=",".join(os.path.join(RULE_FST_DIR, x) for x in RULE_FSTS),
    ))
    first_sid = VITS_VOICES["钟离"]
    t0 = time.time()
    _tts.generate("你好", sid=first_sid, speed=1.0)  # pay jieba/FST/ORT-arena cost now
    log.info("vits ready (warmed) in %.2fs sr=%d speakers=%d model=%s lexicon=%s rule_fsts=%s",
             time.time() - t0, _tts.sample_rate, _tts.num_speakers,
             os.path.basename(VITS_MODEL), os.path.basename(VITS_LEXICON), ",".join(RULE_FSTS))
    log.info("voices=%s aliases=%s speed_scale=%.2f sentence_pause=%.0fms",
             sorted(VITS_VOICES), VITS_VOICE_ALIASES, SPEED_SCALE, SENTENCE_PAUSE_MS)


def _build_zipvoice():
    global _tts
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
        samples, sr = _resample_fft(samples, sr, OUT_SR)
        rms_out = float(np.sqrt(np.mean(np.square(samples, dtype=np.float64))))
        _refs[voice] = (samples, sr, _ref_text_from(path))
        log.info("ref loaded voice=%s file=%s sr=%d dur=%.2fs rms %.4f->%.4f",
                 voice, name, sr, len(samples) / sr, rms_in, rms_out)
    _s, _sr, _t = _refs[list(VOICE_REFS)[0]]
    warm = _tts.generate("你好", prompt_text=_t, prompt_samples=_s, sample_rate=_sr, num_steps=NUM_STEPS)
    log.info("zipvoice ready (warmed); warmup %s",
             _fmt_profile(_profile(np.asarray(warm.samples, dtype=np.float32), warm.sample_rate)))


def _build():
    t0 = time.time()
    if ENGINE == "vits":
        _build_vits()
    elif ENGINE == "zipvoice":
        _build_zipvoice()
    else:
        raise SystemExit("unknown ENGINE %r (want vits|zipvoice)" % ENGINE)
    log.info("engine=%s post: enabled=%s eq=%s target=%.1fdBFS ceiling=%.1fdBFS",
             ENGINE, POST_ENABLE, EQ_BANDS_RAW if POST_ENABLE else "(off)",
             TARGET_RMS_DBFS, PEAK_CEILING_DBFS)
    log.info("startup total %.2fs", time.time() - t0)


_build()

app = FastAPI(title="remote-tts", version="2.0.0")


class TtsRequest(BaseModel):
    text: str
    voice: str = "钟离"
    speed: float = 1.0


@app.get("/health")
def health():
    return {
        "ok": True,
        "engine": ENGINE,
        "version": "2.0.0",
        "sample_rate": OUT_SR,
        "voices": sorted(VITS_VOICES) if ENGINE == "vits" else sorted(VOICE_REFS),
        "speed_scale": SPEED_SCALE,
        "post": POST_ENABLE,
        "eq": EQ_BANDS_RAW if POST_ENABLE else "",
    }


def _synth_vits(text, voice, speed):
    sid = VITS_VOICES[voice]
    parts = _split_sentences(text)
    pause = np.zeros(max(0, int(OUT_SR * SENTENCE_PAUSE_MS / 1000.0)), dtype=np.float32)
    chunks = []
    for i, seg in enumerate(parts):
        audio = _tts.generate(seg, sid=sid, speed=speed)
        seg_x = np.asarray(audio.samples, dtype=np.float32)
        src_sr = audio.sample_rate
        seg_x = seg_x - seg_x.mean()
        seg_x, src_sr = _resample_fft(seg_x, src_sr, OUT_SR)
        if i:
            chunks.append(pause)
        chunks.append(seg_x)
    return np.concatenate(chunks) if chunks else np.zeros(0, dtype=np.float32), OUT_SR, len(parts)


def _synth_zipvoice(text, voice, speed):
    ref_samples, ref_sr, ref_text = _refs[voice]
    audio = _tts.generate(text, prompt_text=ref_text, prompt_samples=ref_samples,
                          sample_rate=ref_sr, num_steps=NUM_STEPS)
    return np.asarray(audio.samples, dtype=np.float32), audio.sample_rate, 1


@app.post("/tts")
def synthesize(req: TtsRequest, request: Request):
    if API_KEY and request.headers.get("X-API-Key", "") != API_KEY:
        raise HTTPException(status_code=401, detail="unauthorized")

    voice = req.voice
    if ENGINE == "vits":
        voice = VITS_VOICE_ALIASES.get(voice, voice)
        if voice not in VITS_VOICES:
            raise HTTPException(status_code=400, detail="unknown voice")
    elif voice not in VOICE_REFS:
        raise HTTPException(status_code=400, detail="unknown voice")

    text = req.text.strip()
    if not text:
        raise HTTPException(status_code=400, detail="empty text")

    # The client hardcodes speed=1.0 for the remote engine; SPEED_SCALE is the server-side
    # default rate, and a future client-side speed setting multiplies on top of it.
    speed = min(2.0, max(0.5, req.speed)) * SPEED_SCALE

    t0 = time.time()
    with _lock:
        if ENGINE == "vits":
            samples, out_sr, n_seg = _synth_vits(text, voice, speed)
        else:
            samples, out_sr, n_seg = _synth_zipvoice(text, voice, speed)
        t_synth = time.time()
        raw_prof = _profile(samples, out_sr)
        if POST_ENABLE:
            samples = _eq(samples, out_sr, EQ_BANDS)
            samples, gain_db, out_rms = _normalize(samples, out_sr, TARGET_RMS_DBFS, PEAK_CEILING_DBFS)
            samples = _fades(samples, out_sr, FADE_IN_MS, FADE_OUT_MS)
        else:
            gain_db, out_rms = 0.0, float(raw_prof.get("rms", 0.0))
        wall = time.time() - t0
        s16 = np.clip(samples * 32767.0, -32768.0, 32767.0).astype("<i2")
        dur = len(samples) / out_sr

        buf = io.BytesIO()
        with wave.open(buf, "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(out_sr)
            w.writeframes(s16.tobytes())

    log.info("synth engine=%s voice=%s chars=%d segs=%d speed=%.3f dur=%.2fs wall=%.2fs rtf=%.3f "
             "synth=%.2fs sr=%d gain=%+.2fdB rms %.4f->%.4f",
             ENGINE, voice, len(text), n_seg, speed, dur, wall, wall / dur if dur else 0.0,
             t_synth - t0, out_sr, gain_db, raw_prof.get("rms", 0.0), out_rms)
    log.info("  before: %s", _fmt_profile(raw_prof))
    log.info("  after : %s", _fmt_profile(_profile(samples, out_sr)))
    return Response(content=buf.getvalue(), media_type="audio/wav")
