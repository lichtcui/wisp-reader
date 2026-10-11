#!/usr/bin/env python3
"""Objective timbre-clone score: cosine(reference SV embedding, clip SV embedding).

Same path as P2 §③: Kaldi fbank (80 mel, 16 kHz, dither=0) -> sv.onnx (eres2net).
Run with the upstream venv python (needs torch/torchaudio/kaldi/onnxruntime).
"""
import argparse, json, os, sys
from pathlib import Path

UPSTREAM = Path("/Users/lichtcui/Documents/playground/tts/gpt-sovits-onnx-rs/gpt-sovits-upstream")
SV = Path("/Users/lichtcui/Documents/playground/tts/p2/bundles/liuying-int8/sv.onnx")

def emb(path, sess, np, torch, torchaudio):
    wav, sr = torchaudio.load(str(path))
    if wav.shape[0] > 1:
        wav = wav.mean(0, keepdim=True)
    if sr != 16000:
        wav = torchaudio.functional.resample(wav, sr, 16000)
    a = wav.squeeze(0).numpy().astype(np.float32)
    fb = torchaudio.compliance.kaldi.fbank(torch.from_numpy(a).unsqueeze(0),
                                           num_mel_bins=80, sample_frequency=16000, dither=0.0).numpy()
    return sess.run(None, {"audio_feature": fb})[0].reshape(-1)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("clips", nargs="+")
    ap.add_argument("--ref", default="/Users/lichtcui/Documents/playground/tts/p2/bundles/liuying-int8/ref.wav")
    a = ap.parse_args()
    os.chdir(UPSTREAM); sys.path.insert(0, str(UPSTREAM)); sys.path.insert(0, str(UPSTREAM/"GPT_SoVITS"))
    import numpy as np, onnxruntime as ort, torch, torchaudio
    sess = ort.InferenceSession(str(SV), providers=["CPUExecutionProvider"])
    r = emb(a.ref, sess, np, torch, torchaudio)
    print(f"ref {a.ref}")
    for c in a.clips:
        e = emb(c, sess, np, torch, torchaudio)
        cos = float(np.dot(r, e) / (np.linalg.norm(r) * np.linalg.norm(e)))
        print(f"  {Path(c).name:34s} cos={cos:.4f}")

if __name__ == "__main__":
    main()
