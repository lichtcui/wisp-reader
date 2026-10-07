"""Remote TTS service: sherpa-onnx OfflineTts + ZipVoice (int8 distil) zero-shot clone.

Endpoints:
  GET  /health                   -> {"ok": true}
  POST /tts {text, voice, speed} -> audio/wav (24kHz S16LE mono, RIFF header)

Single user / single VPS worker. Reference audio is loaded once per voice and kept
resident; `tts.generate(...)` is called per sentence with `num_steps=2` hardcoded
(RTF stays < 1 at 2 steps on a 4-core CPU; 3+ steps drop below real time).

Auth: if `X_API_KEY` env is set, the `X-API-Key` request header must match. With
tailscale as the first line of defence this is optional, but deploy.sh sets it.
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

# voice -> default reference audio (basename under REFS_DIR/<voice>/中文/emotions/)
VOICE_REFS = {
    "流萤": "【中立】…我应该会选择请求猎犬家系停止追捕。.wav",
    "花火": "【吃惊】…好吧，看你这个表情是不会相信我的…没事，我可以明天再来问你一遍！.wav",
    "卡芙卡": "【中立】黑塔用这么简单的小玩意藏她的宝贝？.wav",
}

_tts = None
_refs = {}  # voice -> (ref_samples float32, ref_sr, ref_text)
_lock = threading.Lock()  # sherpa OfflineTts.generate() is not thread-safe; serialize


def _fade_in(samples, sr, ms=12):
    """Short linear fade-in to mask any onset transient (ZipVoice int8 artifacts)."""
    n = int(sr * ms / 1000)
    if n > 1 and len(samples) > n:
        out = samples.copy()
        out[:n] *= np.linspace(0.0, 1.0, n)
        return out
    return samples


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
        _refs[voice] = (samples, sr, _ref_text_from(path))
        log.info("ref loaded voice=%s file=%s sr=%d dur=%.2fs", voice, name, sr, len(samples) / sr)
    # warmup: pay the first-inference / resampler creation cost now, not on first request
    _s, _sr, _t = _refs[list(VOICE_REFS)[0]]
    _tts.generate("你好", prompt_text=_t, prompt_samples=_s, sample_rate=_sr, num_steps=NUM_STEPS)
    log.info("tts ready (warmed) in %.2fs", time.time() - t0)


_build()

app = FastAPI(title="remote-tts", version="1.0.0")


class TtsRequest(BaseModel):
    text: str
    voice: str = "流萤"
    speed: float = 1.0


@app.get("/health")
def health():
    return {"ok": True}


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
    samples = np.asarray(audio.samples, dtype=np.float32)
    out_sr = audio.sample_rate
    samples = _fade_in(samples, out_sr)
    s16 = np.clip(samples * 32767.0, -32768.0, 32767.0).astype("<i2")
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(out_sr)
        w.writeframes(s16.tobytes())
    log.info(
        "synth voice=%s chars=%d dur=%.2fs wall=%.2fs rtf=%.3f sr=%d",
        req.voice, len(text), len(samples) / out_sr, time.time() - t0,
        (time.time() - t0) / (len(samples) / out_sr), out_sr,
    )
    return Response(content=buf.getvalue(), media_type="audio/wav")