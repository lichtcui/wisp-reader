#!/usr/bin/env python3
"""T0.2 并发 / 超时实测台（主机侧，不上设备）。

用途：给 `detect-engine` 定「并发上限」与「L1 超时」提供实测依据，产出
`docs/specs/SPEC-DETECT-ENGINE.md` §3.3 / §3.5 的表格。

用法（等价于 `make probe`，只是把多轮重复 + 统计做掉）：

    python3 scripts/detect-bench.py --input <大源集合.json> \
        --sample 240 --rounds 3 --concurrency 8,16,32 --keyword 重生

    # L1（单次搜索 = search_one）的时延分布，用来定 L1 超时
    python3 scripts/detect-bench.py --input <大源集合.json> --cmd search \
        --sample 240 --rounds 2 --concurrency 8 --timeout 20000

**前置条件（重要）**：`runtime.rs` 的 `detect` 把并发 `clamp(1, 8)`，`--concurrency 16/32`
会被静默夹回 8。测 8 以上的档位前，先临时把上限放宽（测完回退，见 SPEC-DETECT-ENGINE §3.5）。
脚本会把「请求的并发」和「实际使用的并发」都打出来，方便发现夹回。

输出：每档每轮一行明细 + 一张汇总 markdown 表；原始 JSON 落在 `--outdir`（默认 /tmp/detect-bench）。
"""

from __future__ import annotations

import argparse
import json
import os
import random
import statistics
import subprocess
import sys
import time
from collections import Counter
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
BIN = REPO / "rust" / "legado-engine" / "target" / "release" / "examples" / "probe"


def load_pool(path: str) -> list[dict]:
    data = json.loads(Path(path).read_text(encoding="utf-8"))
    if isinstance(data, dict):
        data = [data]
    # 只留「导入后引擎真的会去测」的源：启用 + 有搜索书目规则 + 有 base url。
    pool = [
        s
        for s in data
        if s.get("enabled", True)
        and (s.get("ruleSearch") or {}).get("bookList")
        and s.get("bookSourceUrl")
    ]
    return pool


def sample(pool: list[dict], n: int, seed: int) -> list[dict]:
    if n >= len(pool):
        return pool
    return random.Random(seed).sample(pool, n)


def pct(values: list[float], p: float) -> float:
    if not values:
        return 0.0
    values = sorted(values)
    idx = min(len(values) - 1, int(round(p / 100.0 * (len(values) - 1))))
    return values[idx]


def parse_probe_json(text: str):
    """probe 会先打一行「探针：N 个书源 ← path」，再 dump JSON。

    detect 的结果是数组，search 的是 `{sources, items}` 对象 → 两种都接。
    """
    starts = [i for i in (text.find("\n["), text.find("\n{")) if i >= 0]
    if not starts:
        raise ValueError("probe 输出里没有 JSON：\n" + text[:2000])
    return json.loads(text[min(starts) + 1 :])


def run_probe(sample_path: Path, cmd: str, args: list[str]) -> tuple[list[dict], float]:
    argv = [str(BIN), str(sample_path), cmd, *args, "--json"]
    t0 = time.monotonic()
    proc = subprocess.run(
        argv, cwd=REPO / "rust" / "legado-engine", capture_output=True, text=True
    )
    wall = time.monotonic() - t0
    if proc.returncode != 0:
        sys.exit(f"probe 失败（{proc.returncode}）：\n{proc.stdout}\n{proc.stderr}")
    return parse_probe_json(proc.stdout), wall


def summarize(rows: list[dict], wall: float, cmd: str) -> dict:
    n = len(rows)
    if cmd == "detect":
        ok = sum(1 for r in rows if r["ok"])
        stages = Counter(r["stage"] if not r["ok"] else "ok" for r in rows)
    else:
        ok = sum(1 for r in rows if r["ok"])
        stages = Counter(r["error"] if not r["ok"] else "ok" for r in rows)
    elapsed = [float(r["elapsedMs"]) for r in rows]
    return {
        "n": n,
        "wall_s": round(wall, 1),
        "per_min": round(n / wall * 60, 1) if wall else 0.0,
        "ok": ok,
        "ok_rate": round(ok / n, 3) if n else 0.0,
        "timeout": stages.get("timeout", 0),
        "timeout_rate": round(stages.get("timeout", 0) / n, 3) if n else 0.0,
        "stages": dict(stages.most_common()),
        "elapsed_ms": {
            "p50": round(pct(elapsed, 50)),
            "p90": round(pct(elapsed, 90)),
            "p95": round(pct(elapsed, 95)),
            "p99": round(pct(elapsed, 99)),
            "max": round(max(elapsed)) if elapsed else 0,
        },
    }


def rows_of(payload, cmd: str) -> list[dict]:
    return payload if cmd == "detect" else payload["sources"]


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--input", required=True, help="大源集合 JSON（Legado 导出格式）")
    ap.add_argument("--sample", type=int, default=240, help="抽样条数（默认 240）")
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--rounds", type=int, default=3)
    ap.add_argument("--concurrency", default="8,16,32")
    ap.add_argument("--keyword", default="重生")
    ap.add_argument("--timeout", type=int, default=0, help="单源超时 ms（0=引擎默认 45000）")
    ap.add_argument("--cmd", choices=["detect", "search"], default="detect")
    ap.add_argument("--outdir", default="/tmp/detect-bench")
    args = ap.parse_args()

    if not BIN.exists():
        sys.exit(f"找不到 {BIN}；先 `cd rust/legado-engine && cargo build --release --example probe`")

    outdir = Path(args.outdir)
    outdir.mkdir(parents=True, exist_ok=True)
    pool = load_pool(args.input)
    picked = sample(pool, args.sample, args.seed)
    sample_path = outdir / f"sample-{args.sample}-seed{args.seed}.json"
    sample_path.write_text(json.dumps(picked, ensure_ascii=False), encoding="utf-8")
    print(f"源池 {len(pool)} 条 → 抽样 {len(picked)} 条（seed={args.seed}）→ {sample_path}")

    levels = [int(c) for c in args.concurrency.split(",")]
    summary: list[dict] = []
    for conc in levels:
        rounds: list[dict] = []
        for r in range(1, args.rounds + 1):
            extra = [args.keyword, "--concurrency", str(conc)]
            if args.timeout:
                extra += ["--timeout", str(args.timeout)]
            rows, wall = run_probe(sample_path, args.cmd, extra)
            rows = rows_of(rows, args.cmd)
            got = len(rows)
            stats = summarize(rows, wall, args.cmd)
            stats["round"] = r
            stats["concurrency"] = conc
            rounds.append(stats)
            raw = outdir / f"{args.cmd}-c{conc}-r{r}.json"
            raw.write_text(json.dumps(rows, ensure_ascii=False), encoding="utf-8")
            stages = " ".join(f"{k}={v}" for k, v in stats["stages"].items())
            print(
                f"  [{args.cmd} c={conc} r{r}] {got} 源 {stats['wall_s']}s "
                f"{stats['per_min']}/min ok={stats['ok_rate']:.0%} "
                f"timeout={stats['timeout_rate']:.0%} | {stages}"
            )
        summary.append(
            {
                "concurrency": conc,
                "wall_s_median": round(statistics.median(r["wall_s"] for r in rounds), 1),
                "per_min_median": round(statistics.median(r["per_min"] for r in rounds), 1),
                "ok_rate_mean": round(statistics.mean(r["ok_rate"] for r in rounds), 3),
                "timeout_rate_mean": round(statistics.mean(r["timeout_rate"] for r in rounds), 3),
                "p50_ms": rounds[0]["elapsed_ms"]["p50"],
                "p95_ms": rounds[0]["elapsed_ms"]["p95"],
                "stages": dict(
                    Counter(
                        k for r in rounds for k, v in r["stages"].items() for _ in range(v)
                    ).most_common()
                ),
                "rounds": rounds,
            }
        )

    (outdir / f"summary-{args.cmd}.json").write_text(
        json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    print(f"\n{'并发':>4} | {'时长中位':>8} | {'源/分钟':>9} | {'成功率':>7} | {'超时率':>7} | 失败类型")
    print("----:|--------:|---------:|-------:|-------:|:--------")
    for s in summary:
        others = " ".join(
            f"{k}={v}" for k, v in s["stages"].items() if k not in ("ok", "timeout")
        )
        print(
            f"{s['concurrency']:>4} | {s['wall_s_median']:>7}s | {s['per_min_median']:>9} | "
            f"{s['ok_rate_mean']:>6.1%} | {s['timeout_rate_mean']:>6.1%} | timeout={s['stages'].get('timeout', 0)} {others}"
        )
    print(f"\n明细 JSON：{outdir}/summary-{args.cmd}.json")


if __name__ == "__main__":
    main()
