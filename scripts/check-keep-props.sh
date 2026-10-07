#!/usr/bin/env bash
# 核对「会经 JSON 往返的 interface 字段名」是否都进了混淆 keep 列表。
#
# 为什么需要：`entry/obfuscation-rules.txt` 开了 `-enable-property-obfuscation`，release 构建会把
# 属性名改成短名。debug 里一切正常，release 里却读到 undefined / 备份文件键名变样——
# 这类 bug 只在 release 现形，靠人眼核对 159 行 keep 列表必然漏。
#
# 判定范围（机械、无需人判）：
#   1) entry/src/main/ets/engine/types.ets（跨 NAPI 的类型，全部字段）
#   2) 任何含 `JSON.parse(` / `JSON.stringify(` 的 .ets 文件里声明的 interface 字段
#      （目前是备份文件 BackupPayload、章节/目录缓存 CachedXxx、本地书 LocalToc 等）
#
# 用法：scripts/check-keep-props.sh   （= make check 的一步）
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

python3 - <<'PY'
import glob, re, sys

KEEP_FILE = 'entry/obfuscation-rules.txt'
keep = {
    line.strip()
    for line in open(KEEP_FILE, encoding='utf-8')
    if line.strip() and not line.lstrip().startswith('#')
}

ets = sorted(glob.glob('entry/src/main/ets/**/*.ets', recursive=True))
targets = ['entry/src/main/ets/engine/types.ets']
for f in ets:
    src = open(f, encoding='utf-8').read()
    if 'JSON.parse(' in src or 'JSON.stringify(' in src:
        targets.append(f)
targets = sorted(set(targets))

missing = {}
for f in targets:
    cur = None
    for line in open(f, encoding='utf-8'):
        m = re.match(r'\s*(?:export )?interface (\w+)', line)
        if m:
            cur = m.group(1)
            continue
        if re.match(r'\s*\}', line):
            cur = None
            continue
        m2 = re.match(r'\s{2,}(\w+)\??\s*:', line)
        if m2 and cur and m2.group(1) not in keep:
            missing.setdefault(m2.group(1), set()).add(f'{cur}@{f}')

print(f'核对 {len(targets)} 个 .ets 文件（含 JSON 往返 + 跨 NAPI）↔ {KEEP_FILE}')
if not missing:
    print(f'✓ {len(keep)} 个 keep 名字覆盖全部 JSON 字段（无遗漏）')
    sys.exit(0)

print(f'✗ 有 {len(missing)} 个字段名没进 keep 列表（release 构建后会被改名，JSON 往返会读到 undefined）：')
for name in sorted(missing):
    print(f'    {name:<16} ← ' + '、'.join(sorted(missing[name])))
print(f'\n修法：把上面每个名字加一行到 {KEEP_FILE}（照现有格式，一个名字一行）。')
sys.exit(1)
PY
