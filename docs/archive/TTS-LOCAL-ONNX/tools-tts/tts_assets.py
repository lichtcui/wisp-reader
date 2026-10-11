#!/usr/bin/env python3
"""TTS 音色素材工具：解压/校验角色包，以及参考音频的静音分析与裁剪。

背景（见 docs/tts-p0-report.md）：
  1. 角色包 zip 里的条目名是 GBK 字节流被当作 cp437，直接 unzip 会得到乱码路径；
  2. 重下得到的 `.pth` 内层有 2 字节幻数被改写（`30 36` 应为 `PK`），不修则 torch.load 失败；
  3. 部分参考音频带长前导静音（如流萤【难过】1.75s），而运行时不做静音裁剪，会污染 SSL 特征。

用法：
  ./tts_assets.py extract --zip ~/Downloads/流萤.zip --out /tmp/probe
  ./tts_assets.py analyze --dir ~/Documents/playground/tts/models/v2ProPlus/流萤
  ./tts_assets.py trim --src <原wav> --out <ref.wav> [--stage <bundle_dir>]
"""

from __future__ import annotations

import argparse
import array
import math
import os
import shutil
import sys
import wave
import zipfile
from pathlib import Path

PK_MAGIC = b"PK"


def _gbk_name(info: zipfile.ZipInfo) -> str:
    return info.orig_filename.encode("cp437", errors="replace").decode("gbk", "replace")


def _read_wav(path: Path) -> tuple[array.array, int, int]:
    with wave.open(str(path)) as f:
        channels, width, rate, frames = f.getnchannels(), f.getsampwidth(), f.getframerate(), f.getnframes()
        if width != 2:
            raise SystemExit(f"{path}: 仅支持 16-bit PCM（当前 {width * 8}-bit）")
        raw = f.readframes(frames)
    samples = array.array("h")
    samples.frombytes(raw)
    if sys.byteorder == "big":
        samples.byteswap()
    if channels > 1:
        mono = array.array("h", [0]) * (len(samples) // channels)
        for i in range(len(mono)):
            mono[i] = int(sum(samples[i * channels : (i + 1) * channels]) / channels)
        samples = mono
    return samples, rate, channels


def _write_wav(path: Path, samples: array.array, rate: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(path), "wb") as f:
        f.setnchannels(1)
        f.setsampwidth(2)
        f.setframerate(rate)
        if sys.byteorder == "big":
            samples.byteswap()
        f.writeframes(samples.tobytes())


def _envelope(samples: array.array, rate: int, window_sec: float) -> list[float]:
    win = max(1, int(window_sec * rate))
    out = []
    for start in range(0, len(samples) - win + 1, win):
        chunk = samples[start : start + win]
        acc = 0.0
        for s in chunk:
            acc += float(s) * float(s)
        out.append(math.sqrt(acc / len(chunk)) / 32768.0)
    return out


def _speech_span(samples: array.array, rate: int, threshold: float, window_sec: float) -> tuple[float, float]:
    env = _envelope(samples, rate, window_sec)
    idx = [i for i, v in enumerate(env) if v > threshold]
    if not idx:
        return 0.0, len(samples) / rate
    return idx[0] * window_sec, (idx[-1] + 1) * window_sec


def cmd_extract(args: argparse.Namespace) -> int:
    src, out = Path(args.zip).expanduser(), Path(args.out).expanduser()
    if not src.is_file():
        raise SystemExit(f"找不到 zip：{src}")
    repaired: list[str] = []
    total = 0
    with zipfile.ZipFile(src) as z:
        for info in z.infolist():
            name = _gbk_name(info)
            target = out / name
            if name.endswith("/"):
                target.mkdir(parents=True, exist_ok=True)
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            data = z.read(info)
            if len(data) != info.file_size:
                raise SystemExit(f"{name}: 大小不符（{len(data)} != {info.file_size}），zip 可能损坏")
            if name.endswith(".pth") and data[:2] != PK_MAGIC:
                data = PK_MAGIC + data[2:]
                repaired.append(name)
            target.write_bytes(data)
            total += len(data)
    print(f"解压完成 → {out}（{total:,} B）")
    for name in repaired:
        print(f"  已修幻数：{name}")
    if args.verify:
        for path in sorted(out.rglob("*")):
            if path.suffix not in (".pth", ".ckpt"):
                continue
            try:
                with zipfile.ZipFile(path) as z:
                    print(f"  校验 {path.name}: entries={len(z.infolist())} testzip={z.testzip()}")
            except Exception as exc:
                print(f"  校验 {path.name}: 失败 {exc}")
                return 1
    return 0


def cmd_analyze(args: argparse.Namespace) -> int:
    root = Path(args.dir).expanduser()
    files = sorted(root.rglob("*.wav"))
    if not files:
        raise SystemExit(f"{root} 下没有 wav")
    print(f"{'参考音频':38s} {'总长':>7s} {'前导':>7s} {'尾部':>7s} {'实际语音':>9s}")
    for path in files:
        samples, rate, _ = _read_wav(path)
        total = len(samples) / rate
        lead, end = _speech_span(samples, rate, args.threshold, args.window)
        trail = max(0.0, total - end)
        flag = "  <== 前导静音偏长" if lead > args.warn_lead else ""
        print(f"{path.name[:36]:38s} {total:6.2f}s {lead:6.2f}s {trail:6.2f}s {total - lead - trail:8.2f}s{flag}")
    return 0


def cmd_trim(args: argparse.Namespace) -> int:
    src = Path(args.src).expanduser()
    samples, rate, channels = _read_wav(src)
    lead, end = _speech_span(samples, rate, args.threshold, args.window)
    start = max(0, int((lead - args.pre) * rate))
    stop = min(len(samples), int((end + args.post) * rate))
    trimmed = samples[start:stop]
    if args.min_sec and len(trimmed) / rate < args.min_sec:
        print(f"警告：裁剪后仅 {len(trimmed) / rate:.2f}s，低于建议下限 {args.min_sec}s")
    print(
        f"{src.name}: {len(samples) / rate:.2f}s → {len(trimmed) / rate:.2f}s "
        f"（去前导 {start / rate:.2f}s、尾部 {max(0.0, (len(samples) - stop) / rate):.2f}s，{channels}ch→mono）"
    )
    out = Path(args.out).expanduser()
    _write_wav(out, trimmed, rate)
    print(f"  写入 {out}")
    if args.stage:
        stage_dir = Path(args.stage).expanduser()
        stage_dir.mkdir(parents=True, exist_ok=True)
        staged = stage_dir / "ref.wav"
        shutil.copyfile(out, staged)
        print(f"  已 staging → {staged}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_ext = sub.add_parser("extract", help="按 GBK 解码解压角色包，并修复 .pth 幻数")
    p_ext.add_argument("--zip", required=True)
    p_ext.add_argument("--out", required=True)
    p_ext.add_argument("--verify", action="store_true", help="解压后逐个校验 .pth/.ckpt")
    p_ext.set_defaults(func=cmd_extract)

    p_ana = sub.add_parser("analyze", help="分析参考音频的静音分布")
    p_ana.add_argument("--dir", required=True)
    p_ana.add_argument("--threshold", type=float, default=0.02)
    p_ana.add_argument("--window", type=float, default=0.02)
    p_ana.add_argument("--warn-lead", type=float, default=0.3)
    p_ana.set_defaults(func=cmd_analyze)

    p_trim = sub.add_parser("trim", help="裁掉参考音频的首尾静音并 staging 为 ref.wav")
    p_trim.add_argument("--src", required=True)
    p_trim.add_argument("--out", required=True)
    p_trim.add_argument("--stage", help="额外复制为 <dir>/ref.wav")
    p_trim.add_argument("--threshold", type=float, default=0.02)
    p_trim.add_argument("--window", type=float, default=0.02)
    p_trim.add_argument("--pre", type=float, default=0.03, help="保留的前导余量（秒）")
    p_trim.add_argument("--post", type=float, default=0.10, help="保留的尾部余量（秒）")
    p_trim.add_argument("--min-sec", type=float, default=3.0, help="低于此长度时告警（0 关闭）")
    p_trim.set_defaults(func=cmd_trim)

    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
