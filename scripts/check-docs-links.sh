#!/usr/bin/env bash
# 校验仓库内 .md 的相对链接（含锚点前的路径部分）是否指向存在的文件/目录。
#
# 为什么需要：文档一直在搬（docs/archive/ 归档、拆分大文件），链接断掉不会有人发现，
# 但会让下一个人（或 AI）白翻一次。
#
# 用法：scripts/check-docs-links.sh   （= make check 的一步）
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

python3 - <<'PY'
import os, re, sys

files = ['AGENTS.md', 'README.md']
for base, dirs, names in os.walk('docs'):
    dirs[:] = [d for d in dirs if not d.startswith('.')]
    files += [os.path.join(base, n) for n in sorted(names) if n.endswith('.md')]
files = [f for f in sorted(set(files)) if os.path.exists(f)]

LINK = re.compile(r'\[[^\]]*\]\(([^)\s]+)\)')
missing, checked = [], 0
for f in files:
    text = open(f, encoding='utf-8').read()
    for line_no, line in enumerate(text.splitlines(), 1):
        for target in LINK.findall(line):
            if target.startswith(('http://', 'https://', 'mailto:', '#', 'file:')):
                continue
            path = target.split('#')[0]
            if not path:
                continue
            # 绝对路径不在仓库内（常见于 /tmp 临时证据），本脚本只校验仓库相对链接。
            if path.startswith('/'):
                continue
            checked += 1
            resolved = os.path.normpath(os.path.join(os.path.dirname(f), path))
            if not os.path.exists(resolved):
                missing.append((f, line_no, target))

print(f'检查 {len(files)} 个 .md 的 {checked} 条相对链接')
if not missing:
    print('✓ 无失效链接')
    sys.exit(0)
print(f'✗ {len(missing)} 条失效：')
for f, line_no, target in missing:
    print(f'    {f}:{line_no} → {target}')
sys.exit(1)
PY
