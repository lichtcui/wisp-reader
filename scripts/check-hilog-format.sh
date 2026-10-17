#!/usr/bin/env bash
# 核对 hilog 格式串里没有它不支持的占位符。
#
# 为什么需要：`hilog` 只认 `%{public}d` / `%{public}s` 这几种占位符，写 `%{public}f`
# **不报错**，直接把值按字面打成 `}f`（真机日志里出现过 `preg play para=0 base=0 rate=}f`，
# 看起来像「倍速算崩了」，实际只是格式串问题）。浮点自己格式化成字符串再走 `%{public}s`。
#
# 用法：scripts/check-hilog-format.sh   （= make check 的一步）
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

python3 - <<'PY'
import glob, re, sys

BAD = re.compile(r'%\{public\}f|%\{private\}f|(?<![\w%])%f\b')

files = sorted(glob.glob('entry/src/main/ets/**/*.ets', recursive=True))
hits = []
for f in files:
    for i, line in enumerate(open(f, encoding='utf-8'), 1):
        stripped = line.strip()
        if stripped.startswith('//') or stripped.startswith('*') or stripped.startswith('/*'):
            continue  # 注释里提 `%f` 是说明，不是格式串
        if BAD.search(line):
            hits.append((f, i, stripped))

print(f'核对 {len(files)} 个 .ets 的 hilog 格式串（不支持的占位符）')
if not hits:
    print('✓ 没有 hilog 不支持的占位符（%f 之类）')
    sys.exit(0)

print(f'✗ {len(hits)} 处用了 hilog 不支持的占位符（真机上会打成 `}}f` 之类的乱码）：')
for f, i, line in hits:
    print(f'    {f}:{i}  {line[:110]}')
print('\n修法：浮点用 `x.toFixed(2)` 格成字符串，格式串改 `%{public}s`。')
sys.exit(1)
PY
