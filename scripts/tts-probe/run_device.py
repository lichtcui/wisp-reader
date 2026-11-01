#!/usr/bin/env python3
"""Run the sherpa-onnx TTS latency probe on one connected HarmonyOS device."""

from __future__ import annotations

import argparse
import json
import math
import os
import shlex
import shutil
import statistics
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable


REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_DEVECO = Path("/Applications/DevEco-Studio.app")
DEFAULT_HDC = DEFAULT_DEVECO / "Contents/sdk/default/openharmony/toolchains/hdc"
DEFAULT_CACHE = Path.home() / ".cache/source-reader/tts-probe"
DEFAULT_BUNDLE = "com.lichtcui.sourcereader"
DEFAULT_ABILITY = "EntryAbility"
DEFAULT_REMOTE_ROOT = "data/storage/el2/base/haps/entry/files/tts-probe"


@dataclass(frozen=True)
class TextCase:
    text_id: str
    text: str


@dataclass(frozen=True)
class ModelSpec:
    name: str
    family: str
    model: str
    tokens: str
    lexicon: tuple[str, ...] = ()
    vocoder: str | None = None
    voices: str | None = None
    data_dir: str | None = None
    lang: str | None = None
    rule_fsts: tuple[str, ...] = ()

    def required_files(self, models_dir: Path) -> list[Path]:
        names = [
            self.model,
            self.tokens,
            *self.lexicon,
            self.vocoder,
            self.voices,
            self.data_dir,
            *self.rule_fsts,
        ]
        return [models_dir / self.name / name for name in names if name]


MODEL_SPECS: dict[str, ModelSpec] = {
    "melo": ModelSpec(
        name="melo",
        family="vits",
        model="model.int8.onnx",
        tokens="tokens.txt",
        lexicon=("lexicon.txt",),
        rule_fsts=("date.fst", "number.fst", "phone.fst"),
    ),
    "fanchen": ModelSpec(
        name="fanchen",
        family="vits",
        model="vits-zh-hf-fanchen-C.onnx",
        tokens="tokens.txt",
        lexicon=("lexicon.txt",),
        rule_fsts=("date.fst", "number.fst", "phone.fst"),
    ),
    "matcha": ModelSpec(
        name="matcha",
        family="matcha",
        model="model-steps-3.onnx",
        tokens="tokens.txt",
        lexicon=("lexicon.txt",),
        vocoder="vocos-22khz-univ.onnx",
        rule_fsts=("date.fst", "number.fst", "phone.fst"),
    ),
    "piper-xiao-ya": ModelSpec(
        name="piper-xiao-ya",
        family="vits",
        model="zh_CN-xiao_ya-medium.onnx",
        tokens="tokens.txt",
        lexicon=("lexicon.txt",),
        rule_fsts=("date.fst", "number.fst", "phone.fst"),
    ),
    "piper-chaowen": ModelSpec(
        name="piper-chaowen",
        family="vits",
        model="zh_CN-chaowen-medium.onnx",
        tokens="tokens.txt",
        lexicon=("lexicon.txt",),
        rule_fsts=("date.fst", "number.fst", "phone.fst"),
    ),
    "matcha-zh-en": ModelSpec(
        name="matcha-zh-en",
        family="matcha",
        model="model-steps-3.onnx",
        tokens="tokens.txt",
        lexicon=("lexicon.txt", "lexicon-en-us.txt"),
        vocoder="vocos-16khz-univ.onnx",
        data_dir="espeak-ng-data",
        rule_fsts=("phone-zh.fst", "date-zh.fst", "number-zh.fst"),
    ),
    "kokoro": ModelSpec(
        name="kokoro",
        family="kokoro",
        model="model.int8.onnx",
        tokens="tokens.txt",
        lexicon=("lexicon-us-en.txt", "lexicon-zh.txt"),
        voices="voices.bin",
        data_dir="espeak-ng-data",
        lang="zh",
        rule_fsts=("phone-zh.fst", "date-zh.fst", "number-zh.fst"),
    ),
}


DEFAULT_TEXTS = [
    TextCase("short", "春江潮水连海平，海上明月共潮生。"),
    TextCase(
        "mixed",
        "他翻开第三十二章，发现日期停在2026年10月24日，窗外忽然下起了小雨。",
    ),
    TextCase(
        "long",
        "夜色像一条慢慢展开的长卷，远处的钟声穿过薄雾，落在安静的街道上。"
        "林舟合上手里的书，听见门外有人轻声叫他的名字。他走出去，看见路灯下"
        "停着一辆旧自行车，车筐里放着一封没有署名的信。信的第一页只写了一句话："
        "明天下午三点，去河边的旧书店，那里有人等你。林舟把信折好，回到桌前，"
        "打开了 Chapter 7。",
    ),
]


class ProbeError(RuntimeError):
    pass


class Hdc:
    def __init__(self, executable: Path, target: str):
        self.executable = executable
        self.target = target

    def command(self, args: Iterable[str]) -> list[str]:
        return [str(self.executable), "-t", self.target, *map(str, args)]

    def run(self, args: Iterable[str], *, quiet: bool = False) -> subprocess.CompletedProcess[str]:
        command = self.command(args)
        result = subprocess.run(command, text=True, capture_output=True, check=False)
        combined = result.stdout + result.stderr
        if result.returncode != 0 or "need connect-key" in combined:
            rendered = " ".join(shlex.quote(part) for part in command)
            raise ProbeError(
                f"command failed ({result.returncode}): {rendered}\n"
                f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}"
            )
        if not quiet and result.stdout.strip():
            print(result.stdout.rstrip())
        return result

    def shell(self, command: str, *, quiet: bool = False) -> subprocess.CompletedProcess[str]:
        return self.run(["shell", command], quiet=quiet)


    def send_file(self, local: Path, remote: str, bundle: str) -> None:
        command = self.command(["file", "send", "-b", bundle, str(local), remote])
        result = subprocess.run(command, text=True, capture_output=True, check=False)
        combined = result.stdout + result.stderr
        if result.returncode != 0 or "[Fail]" in combined:
            rendered = " ".join(shlex.quote(part) for part in command)
            raise ProbeError(
                f"command failed ({result.returncode}): {rendered}\n"
                f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}"
            )

    def recv_file(
        self, remote: str, local: Path, bundle: str, *, optional: bool = False
    ) -> bool:
        if local.exists():
            local.unlink()
        command = self.command(["file", "recv", "-b", bundle, remote, str(local)])
        result = subprocess.run(command, text=True, capture_output=True, check=False)
        if result.returncode == 0 and local.is_file():
            return True
        if optional:
            return False
        rendered = " ".join(shlex.quote(part) for part in command)
        raise ProbeError(
            f"command failed ({result.returncode}): {rendered}\n"
            f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}"
        )


def parse_csv(value: str) -> list[str]:
    return [part.strip() for part in value.split(",") if part.strip()]


def parse_threads(value: str) -> list[int]:
    try:
        threads = sorted(set(int(part) for part in parse_csv(value)))
    except ValueError as exc:
        raise argparse.ArgumentTypeError("threads must be comma-separated integers") from exc
    if not threads or any(item < 1 for item in threads):
        raise argparse.ArgumentTypeError("threads must all be >= 1")
    return threads


def parse_sids(value: str) -> list[int]:
    try:
        sids = sorted(set(int(part) for part in parse_csv(value)))
    except ValueError as exc:
        raise argparse.ArgumentTypeError("sids must be comma-separated integers") from exc
    if not sids or any(item < 0 for item in sids):
        raise argparse.ArgumentTypeError("sids must all be >= 0")
    return sids


def find_hdc(requested: str | None) -> Path:
    candidates = [
        Path(requested) if requested else None,
        Path(os.environ["HDC"]) if os.environ.get("HDC") else None,
        DEFAULT_HDC,
        Path(found) if (found := shutil.which("hdc")) else None,
    ]
    for candidate in candidates:
        if candidate and candidate.is_file():
            return candidate
    raise ProbeError(
        "hdc not found. Pass --hdc, set HDC, or install DevEco Studio at "
        f"{DEFAULT_DEVECO}."
    )


def connected_targets(hdc_path: Path) -> list[str]:
    result = subprocess.run(
        [str(hdc_path), "list", "targets", "-v"],
        text=True,
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        raise ProbeError(f"hdc list targets -v failed: {result.stderr.strip()}")

    targets: list[str] = []
    for raw_line in result.stdout.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("[Empty]"):
            continue
        fields = line.split()
        if not fields:
            continue
        if any(field.lower() == "offline" for field in fields):
            continue
        if any(field.lower() == "connected" for field in fields):
            targets.append(fields[0])
    return targets


def select_target(hdc_path: Path, requested: str | None) -> str:
    targets = connected_targets(hdc_path)
    if not targets:
        raise ProbeError(
            "No connected HarmonyOS device (hdc list targets -v is [Empty]). "
            "Connect and unlock the phone, authorize this computer, then rerun "
            "`make tts-probe-run`."
        )
    if requested:
        if requested not in targets:
            raise ProbeError(
                f"Requested target {requested!r} is not connected; connected targets: {targets}"
            )
        return requested
    if len(targets) > 1:
        raise ProbeError(
            f"Multiple connected targets: {targets}. Choose one with --target."
        )
    return targets[0]


def validate_local_inputs(probe_dir: Path, models_dir: Path, models: list[str]) -> list[Path]:
    required = [
        probe_dir / "app/entry/build/default/outputs/default/entry-default-signed.hap",
        probe_dir / "lib/libttsprobe.so",
        probe_dir / "lib/libsherpa-onnx-c-api.so",
        probe_dir / "lib/libonnxruntime.so",
        probe_dir / "lib/libc++_shared.so",
    ]
    for model_name in models:
        required.extend(MODEL_SPECS[model_name].required_files(models_dir))

    missing = [path for path in required if not path.exists()]
    if missing:
        rendered = "\n".join(f"  {path}" for path in missing)
        raise ProbeError(
            "Missing probe/model files:\n"
            f"{rendered}\n"
            "Run `make tts-probe-build` and `make tts-probe-models` first."
        )
    return required


def manifest_rows(
    args: argparse.Namespace, selected_models: list[str]
) -> tuple[str, list[dict[str, Any]]]:
    rows: list[str] = []
    groups: list[dict[str, Any]] = []
    for model in selected_models:
        spec = MODEL_SPECS[model]
        model_dir = Path("models") / model
        for text_case in args.text_cases:
            for sid in args.sids:
                for threads in args.threads:
                    identifier = group_id(model, text_case.text_id, sid, threads)
                    output = f"wav/{slug(identifier)}.wav"
                    fields = [
                        spec.family,
                        spec.name,
                        text_case.text_id,
                        str(model_dir / spec.model),
                        str(model_dir / spec.vocoder) if spec.vocoder else "",
                        ",".join(str(model_dir / name) for name in spec.lexicon),
                        str(model_dir / spec.tokens),
                        str(model_dir / spec.data_dir) if spec.data_dir else "",
                        "",
                        ",".join(str(model_dir / name) for name in spec.rule_fsts),
                        str(model_dir / spec.voices) if spec.voices else "",
                        spec.lang or "",
                        text_case.text,
                        output,
                        str(threads),
                        str(sid),
                        str(args.warmup),
                        str(args.runs),
                    ]
                    if any("\t" in field or "\n" in field or "\r" in field for field in fields):
                        raise ProbeError(
                            f"manifest field contains a newline/tab: {identifier}"
                        )
                    rows.append("\t".join(fields))
                    groups.append(
                        {
                            "id": identifier,
                            "model": model,
                            "text_id": text_case.text_id,
                            "threads": threads,
                            "sid": sid,
                            "text_chars": len(text_case.text),
                            "remote_wav": output,
                        }
                    )
    return "\n".join(rows) + "\n", groups


def push_relative_tree(
    hdc: Hdc, bundle: str, local_root: Path, remote_root: str
) -> None:
    files = sorted(path for path in local_root.rglob("*") if path.is_file())
    print(f"push {len(files)} files from {local_root.name}", flush=True)
    # `hdc file send -b` creates the destination tree recursively. A directory
    # created through `hdc shell -b` lands outside the mapped app filesDir.
    hdc.send_file(local_root, remote_root, bundle)


def push_file(
    hdc: Hdc,
    bundle: str,
    local: Path,
    remote_root: str,
    relative: str,
    index: int,
    total: int,
) -> None:
    remote = f"{remote_root.rstrip('/')}/{relative}"
    print(f"push [{index}/{total}] {relative}", flush=True)
    hdc.send_file(local, remote, bundle)


def percentile(values: list[float], fraction: float) -> float:
    ordered = sorted(values)
    if not ordered:
        return math.nan
    position = (len(ordered) - 1) * fraction
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return ordered[lower]
    weight = position - lower
    return ordered[lower] * (1.0 - weight) + ordered[upper] * weight


def group_id(model: str, text_id: str, sid: int, threads: int) -> str:
    return f"{model}|{text_id}|sid={sid}|threads={threads}"


def slug(value: str) -> str:
    return "".join(char if char.isalnum() or char in "-_." else "_" for char in value)


def evaluate_group(records: list[dict[str, Any]], args: argparse.Namespace) -> dict[str, Any]:
    rtf_values = [float(record["rtf"]) for record in records]
    rms_values = [float(record["rms"]) for record in records]
    silence_values = [float(record["silence_ratio"]) for record in records]
    clipping_values = [float(record["clipping_ratio"]) for record in records]
    finite = all(bool(record.get("finite")) for record in records)
    timing_pass = (
        len(records) == args.runs
        and finite
        and percentile(rtf_values, 0.50) <= args.max_p50_rtf
        and percentile(rtf_values, 0.95) <= args.max_p95_rtf
    )
    signal_pass = (
        bool(records)
        and min(rms_values) >= args.min_rms
        and max(silence_values) <= args.max_silence_ratio
        and max(clipping_values) <= args.max_clipping_ratio
    )
    return {
        "runs": len(records),
        "rtf_p50": percentile(rtf_values, 0.50),
        "rtf_p95": percentile(rtf_values, 0.95),
        "rtf_max": max(rtf_values) if rtf_values else math.nan,
        "audio_sec_median": statistics.median(
            float(record["audio_sec"]) for record in records
        )
        if records
        else math.nan,
        "sample_rate": records[-1].get("sample_rate") if records else None,
        "rms_min": min(rms_values) if rms_values else math.nan,
        "silence_ratio_max": max(silence_values) if silence_values else math.nan,
        "clipping_ratio_max": max(clipping_values) if clipping_values else math.nan,
        "finite": finite,
        "timing_pass": timing_pass,
        "signal_pass": signal_pass,
        "candidate_pass": timing_pass and signal_pass,
        "cer": "not_measured",
        "human_listening": "not_reviewed",
    }


def write_summary(
    artifact_dir: Path,
    args: argparse.Namespace,
    target: str,
    selected_models: list[str],
    groups: list[dict[str, Any]],
    failures: list[dict[str, Any]],
) -> None:
    model_summary: dict[str, Any] = {}
    for model in selected_models:
        model_groups = [group for group in groups if group["model"] == model]
        model_summary[model] = {
            "groups": len(model_groups),
            "all_groups_timing_pass": bool(model_groups)
            and all(group["metrics"]["timing_pass"] for group in model_groups),
            "all_groups_candidate_pass": bool(model_groups)
            and all(group["metrics"]["candidate_pass"] for group in model_groups),
            "worst_p95_rtf": max(
                (group["metrics"]["rtf_p95"] for group in model_groups), default=math.nan
            ),
        }

    payload = {
        "schema": 1,
        "measured_at_utc": datetime.now(timezone.utc).isoformat(),
        "device_target": target,
        "scope": "ONNX Runtime CPU on the connected HarmonyOS device",
        "not_measured": ["ASR CER", "human listening", "100-run thermal stability"],
        "config": {
            "models": selected_models,
            "text_ids": [case.text_id for case in args.text_cases],
            "threads": args.threads,
            "sids": args.sids,
            "warmup": args.warmup,
            "runs": args.runs,
            "speed": args.speed,
            "max_num_sentences": args.max_num_sentences,
        },
        "gate": {
            "p50_rtf_max": args.max_p50_rtf,
            "p95_rtf_max": args.max_p95_rtf,
            "rms_min": args.min_rms,
            "silence_ratio_max": args.max_silence_ratio,
            "clipping_ratio_max": args.max_clipping_ratio,
        },
        "models": model_summary,
        "groups": groups,
        "failures": failures,
    }
    (artifact_dir / "summary.json").write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )

    lines = [
        "# HarmonyOS on-device TTS RTF sweep",
        "",
        f"- Device: `{target}`",
        f"- Scope: ONNX Runtime CPU; gate p50 <= {args.max_p50_rtf:.2f}, "
        f"p95 <= {args.max_p95_rtf:.2f}",
        "- Not measured yet: ASR CER, human listening, 100-run thermal stability",
        "",
        "| Model | Text | Threads | Runs | p50 RTF | p95 RTF | Max RTF | RMS min | Silence max | Clip max | Gate |",
        "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|:---:|",
    ]
    for group in groups:
        metrics = group["metrics"]
        status = "PASS" if metrics["candidate_pass"] else "FAIL"
        lines.append(
            f"| {group['model']} | {group['text_id']} | {group['threads']} | "
            f"{metrics['runs']} | {metrics['rtf_p50']:.4f} | "
            f"{metrics['rtf_p95']:.4f} | {metrics['rtf_max']:.4f} | "
            f"{metrics['rms_min']:.4f} | {metrics['silence_ratio_max']:.3f} | "
            f"{metrics['clipping_ratio_max']:.5f} | {status} |"
        )
    if failures:
        lines.extend(["", "## Failures", ""])
        for failure in failures:
            lines.append(
                f"- `{failure['group']}`: {failure['error'].splitlines()[0]}"
            )
    lines.extend(
        [
            "",
            "`PASS` only means the timing and signal sanity gates passed. It is not a "
            "pronunciation or listening-quality verdict.",
            "",
        ]
    )
    (artifact_dir / "summary.md").write_text("\n".join(lines), encoding="utf-8")


def probe_hap(probe_dir: Path, override: Path | None) -> Path:
    if override:
        path = override
    else:
        path = (
            probe_dir
            / "app/entry/build/default/outputs/default/entry-default-signed.hap"
        )
    if not path.is_file():
        raise ProbeError(f"probe HAP not found: {path}; run `make tts-probe-build`")
    return path


def capture_device_logs(
    hdc: Hdc, bundle: str, artifact_dir: Path
) -> None:
    commands = {
        "probe.log": (
            f"hilog -x | grep -E 'TtsProbe|EntryAbilitySmoke|{bundle}' "
            "| tail -n 300 || true"
        ),
        "process.log": f"ps -ef | grep {shlex.quote(bundle)} | grep -v grep || true",
    }
    for name, command in commands.items():
        result = subprocess.run(
            hdc.command(["shell", command]),
            text=True,
            capture_output=True,
            check=False,
        )
        (artifact_dir / name).write_text(
            result.stdout + result.stderr, encoding="utf-8"
        )


def wait_for_completion(
    hdc: Hdc,
    bundle: str,
    remote_root: str,
    artifact_dir: Path,
    timeout_seconds: int,
) -> bool:
    remote_done = f"{remote_root}/results.jsonl.done"
    local_done = artifact_dir / "results.jsonl.done"
    deadline = time.monotonic() + timeout_seconds
    last_report = time.monotonic()
    last_error_check = time.monotonic()
    while time.monotonic() < deadline:
        if hdc.recv_file(remote_done, local_done, bundle, optional=True):
            text = local_done.read_text(encoding="utf-8", errors="replace").strip()
            if text.startswith("{") and "manifest_complete" not in text:
                try:
                    payload = json.loads(text)
                except json.JSONDecodeError:
                    payload = None
                if isinstance(payload, dict) and "groups" in payload:
                    return True
        if time.monotonic() - last_error_check >= 5:
            result = subprocess.run(
                hdc.command(
                    [
                        "shell",
                        "hilog -x | grep 'TtsProbe: Probe failed' | tail -n 1",
                    ]
                ),
                text=True,
                capture_output=True,
                check=False,
            )
            if "TtsProbe: Probe failed" in result.stdout:
                (artifact_dir / "probe-error.log").write_text(
                    result.stdout, encoding="utf-8"
                )
                return False
            last_error_check = time.monotonic()
        if time.monotonic() - last_report >= 20:
            print("waiting for on-device NAPI manifest...", flush=True)
            last_report = time.monotonic()
        time.sleep(2)
    return False


def result_records(text: str) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    for line in text.splitlines():
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(event, dict):
            records.append(event)
    return records


def group_result(
    hdc: Hdc,
    bundle: str,
    remote_root: str,
    artifact_dir: Path,
    args: argparse.Namespace,
    expected: dict[str, Any],
    records: list[dict[str, Any]],
) -> tuple[dict[str, Any] | None, list[dict[str, Any]]]:
    measured = [
        record
        for record in records
        if record.get("event") == "run"
        and not record.get("warmup")
        and record.get("label") == expected["model"]
        and record.get("text_id") == expected["text_id"]
        and record.get("threads") == expected["threads"]
        and record.get("sid") == expected["sid"]
    ]
    direct_errors = [
        record.get("error", "on-device failure")
        for record in records
        if record.get("event") == "failure"
        and record.get("label") == expected["model"]
        and record.get("text_id") == expected["text_id"]
        and record.get("threads") == expected["threads"]
        and record.get("sid") == expected["sid"]
    ]
    if direct_errors or len(measured) != args.runs:
        error = direct_errors[0] if direct_errors else (
            f"expected {args.runs} measured runs, got {len(measured)}"
        )
        return None, [{"group": expected["id"], "error": error}]

    metrics = evaluate_group(measured, args)
    local_wav = artifact_dir / "wav" / f"{slug(expected['id'])}.wav"
    if not hdc.recv_file(
        f"{remote_root}/{expected['remote_wav']}", local_wav, bundle, optional=True
    ):
        return None, [
            {
                "group": expected["id"],
                "error": f"missing audio output {expected['remote_wav']}",
            }
        ]
    return (
        {
            "model": expected["model"],
            "text_id": expected["text_id"],
            "threads": expected["threads"],
            "sid": expected["sid"],
            "text_chars": expected["text_chars"],
            "wav": str(local_wav.relative_to(artifact_dir)),
            "metrics": metrics,
        },
        [],
    )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--hdc", help="Path to hdc")
    parser.add_argument("--target", help="Connected hdc target; required if multiple")
    parser.add_argument("--bundle", default=DEFAULT_BUNDLE)
    parser.add_argument("--ability", default=DEFAULT_ABILITY)
    parser.add_argument("--hap", type=Path, help="Override the probe HAP path")
    parser.add_argument(
        "--probe-dir", type=Path, default=REPO_ROOT / "build/tts-probe"
    )
    parser.add_argument(
        "--models-dir",
        type=Path,
        default=Path(os.environ.get("TTS_PROBE_MODELS", DEFAULT_CACHE / "models")),
    )
    parser.add_argument(
        "--models", default="melo,fanchen,matcha", help="Comma-separated model names"
    )
    parser.add_argument("--threads", type=parse_threads, default=[1, 2, 4])
    parser.add_argument(
        "--sid",
        "--sids",
        dest="sids",
        type=parse_sids,
        default=[0],
        help="Comma-separated speaker IDs",
    )
    parser.add_argument(
        "--texts",
        default=",".join(case.text_id for case in DEFAULT_TEXTS),
        help="Comma-separated text case IDs",
    )
    parser.add_argument("--warmup", type=int, default=2)
    parser.add_argument("--runs", type=int, default=10)
    parser.add_argument("--speed", type=float, default=1.0)
    parser.add_argument("--max-num-sentences", type=int, default=1)
    parser.add_argument("--max-p50-rtf", type=float, default=0.60)
    parser.add_argument("--max-p95-rtf", type=float, default=0.70)
    parser.add_argument("--min-rms", type=float, default=0.008)
    parser.add_argument("--max-silence-ratio", type=float, default=0.90)
    parser.add_argument("--max-clipping-ratio", type=float, default=0.01)
    parser.add_argument(
        "--remote-root",
        help="Reuse an explicit device-visible path below the app's EL2 base",
    )
    parser.add_argument("--timeout", type=int, default=1800)
    parser.add_argument(
        "--artifact-dir",
        type=Path,
        default=REPO_ROOT
        / "build/tts-probe/results"
        / datetime.now().strftime("%Y%m%d-%H%M%S"),
    )
    parser.add_argument("--skip-push", action="store_true", help="Reuse pushed models")
    parser.add_argument("--skip-install", action="store_true")
    parser.add_argument(
        "--dry-run", action="store_true", help="Validate inputs and print the matrix"
    )
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    if args.warmup < 0 or args.runs < 1:
        parser.error("--warmup must be >= 0 and --runs must be >= 1")
    if args.timeout < 1:
        parser.error("--timeout must be >= 1")
    if args.remote_root is not None and (
        args.remote_root.startswith("/")
        or not args.remote_root.startswith("data/storage/el2/base/")
    ):
        parser.error(
            "--remote-root must use the device-visible data/storage/el2/base/ prefix"
        )

    selected_models = parse_csv(args.models)
    unknown = [name for name in selected_models if name not in MODEL_SPECS]
    if unknown or not selected_models:
        parser.error(f"unknown/empty --models value; choose from {sorted(MODEL_SPECS)}")
    text_ids = parse_csv(args.texts)
    text_by_id = {case.text_id: case for case in DEFAULT_TEXTS}
    unknown_texts = [text_id for text_id in text_ids if text_id not in text_by_id]
    if unknown_texts or not text_ids:
        parser.error(
            f"unknown/empty --texts value; choose from {sorted(text_by_id)}"
        )
    args.text_cases = [text_by_id[text_id] for text_id in text_ids]
    args.models_list = selected_models

    validate_local_inputs(args.probe_dir, args.models_dir, selected_models)
    hap = probe_hap(args.probe_dir, args.hap)
    matrix_size = (
        len(selected_models) * len(args.text_cases) * len(args.sids) * len(args.threads)
    )
    if args.dry_run:
        print(
            f"Probe inputs valid: {matrix_size} groups x {args.warmup + args.runs} "
            "generations each"
        )
        for model in selected_models:
            for text_case in args.text_cases:
                for sid in args.sids:
                    for threads in args.threads:
                        print(
                            f"  {model:15s} text={text_case.text_id:5s} sid={sid} "
                            f"threads={threads} runs={args.runs}"
                        )
        return 0

    hdc_path = find_hdc(args.hdc)
    target = select_target(hdc_path, args.target)
    hdc = Hdc(hdc_path, target)
    print(f"device: {target}", flush=True)

    args.artifact_dir.mkdir(parents=True, exist_ok=True)
    wav_dir = args.artifact_dir / "wav"
    wav_dir.mkdir(exist_ok=True)
    groups: list[dict[str, Any]] = []
    failures: list[dict[str, Any]] = []
    manifest, expected_groups = manifest_rows(args, selected_models)
    (args.artifact_dir / "manifest.tsv").write_text(manifest, encoding="utf-8")
    shutil.copy2(hap, args.artifact_dir / hap.name)
    if args.remote_root is None:
        args.remote_root = (
            f"{DEFAULT_REMOTE_ROOT}/runs/{args.artifact_dir.name}-{os.getpid()}"
        )
    if not args.skip_install:
        print(f"installing probe HAP: {hap.name}", flush=True)
        hdc.run(["install", "-r", str(hap)], quiet=True)

    remote_root = args.remote_root.rstrip("/")
    remote_manifest = f"{remote_root}/manifest.tsv"
    remote_results = f"{remote_root}/results.jsonl"
    remote_done = f"{remote_root}/results.jsonl.done"
    print(f"remote root: {remote_root}", flush=True)
    with tempfile.TemporaryDirectory(prefix="tts-probe-bootstrap-") as temp:
        bootstrap = Path(temp) / "bootstrap"
        wav = bootstrap / "wav"
        wav.mkdir(parents=True)
        (bootstrap / ".bootstrap").write_text("ok\n", encoding="utf-8")
        (wav / ".keep").write_text("", encoding="utf-8")
        hdc.send_file(bootstrap, remote_root, args.bundle)

    if not args.skip_push:
        for model in selected_models:
            print(f"pushing model: {model}", flush=True)
            push_relative_tree(
                hdc,
                args.bundle,
                args.models_dir / model,
                f"{remote_root}/models/{model}",
            )
    else:
        print("reusing previously pushed models", flush=True)

    push_file(
        hdc,
        args.bundle,
        args.artifact_dir / "manifest.tsv",
        remote_root,
        "manifest.tsv",
        1,
        1,
    )
    with tempfile.TemporaryDirectory(prefix="tts-probe-sentinel-") as temp:
        temp_dir = Path(temp)
        pending = temp_dir / "pending"
        pending.write_text('{"pending":true}\n', encoding="utf-8")
        hdc.send_file(pending, remote_results, args.bundle)
        hdc.send_file(pending, remote_done, args.bundle)

        default_root = DEFAULT_REMOTE_ROOT.rstrip("/")
        if not remote_root.startswith(default_root + "/"):
            raise ProbeError(
                f"remote root must be below {default_root}: {remote_root}"
            )
        pointer = temp_dir / "current-run.txt"
        pointer.write_text(
            remote_root[len(default_root) + 1 :] + "\n", encoding="utf-8"
        )
        hdc.send_file(pointer, f"{default_root}/current-run.txt", args.bundle)

    subprocess.run(hdc.command(["shell", "hilog", "-r"]), capture_output=True, check=False)
    hdc.shell(f"aa force-stop {shlex.quote(args.bundle)}", quiet=True)
    started = hdc.shell(
        f"aa start -a {shlex.quote(args.ability)} -b {shlex.quote(args.bundle)}",
        quiet=True,
    )
    started_text = (started.stdout + started.stderr).strip()
    print(started_text or "probe app started", flush=True)
    if "Error Code:" in started_text or "failed to start" in started_text:
        capture_device_logs(hdc, args.bundle, args.artifact_dir)
        raise ProbeError(f"failed to launch probe app: {started_text}")

    completed = wait_for_completion(
        hdc,
        args.bundle,
        remote_root,
        args.artifact_dir,
        args.timeout,
    )
    capture_device_logs(hdc, args.bundle, args.artifact_dir)
    if not completed:
        probe_error = args.artifact_dir / "probe-error.log"
        detail = (
            probe_error.read_text(encoding="utf-8", errors="replace").strip()
            if probe_error.is_file()
            else f"timed out after {args.timeout}s waiting for results.jsonl.done"
        )
        failures.append(
            {
                "group": "probe",
                "error": detail,
            }
        )

    local_results = args.artifact_dir / "results.jsonl"
    hdc.recv_file(remote_results, local_results, args.bundle, optional=True)
    text = (
        local_results.read_text(encoding="utf-8", errors="replace")
        if local_results.is_file()
        else ""
    )
    (args.artifact_dir / "runs.jsonl").write_text(text, encoding="utf-8")
    records = result_records(text)

    for expected in expected_groups:
        group, group_failures = group_result(
            hdc,
            args.bundle,
            remote_root,
            args.artifact_dir,
            args,
            expected,
            records,
        )
        if group:
            groups.append(group)
        failures.extend(group_failures)

    known_groups = {failure["group"] for failure in failures}
    known_groups.update(group["model"] + "|" + group["text_id"] for group in groups)
    for record in records:
        if record.get("event") != "failure":
            continue
        label = str(record.get("label", "manifest"))
        text_id = str(record.get("text_id", "?"))
        identifier = group_id(
            label,
            text_id,
            int(record.get("sid", 0)),
            int(record.get("threads", 0)),
        )
        if identifier in known_groups or identifier in {
            failure["group"] for failure in failures
        }:
            continue
        failures.append(
            {
                "group": identifier,
                "error": str(record.get("error", "on-device failure")),
            }
        )

    write_summary(
        args.artifact_dir,
        args,
        target,
        selected_models,
        groups,
        failures,
    )
    print(f"summary: {args.artifact_dir / 'summary.md'}")
    if failures:
        print(f"completed with {len(failures)} failed groups", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ProbeError as exc:
        print(f"tts-probe: {exc}", file=sys.stderr)
        raise SystemExit(1)
