#!/usr/bin/env python3
"""Host contract checks for `BookContent.sanitizeText` (the single text-cleaning implementation).

Like `toc-quality-sim.py` this runs the **real source**, not a copy: the pure region
(`PAGE_MARK_RE` + `sanitizeText`) is sliced out of `model/BookContent.ets` and compiled with the
DevEco TypeScript compiler, so the reader / TTS / TXT-export paths cannot drift apart from the
checked contract.

The main fixture reproduces the shape measured through `make probe` for
《我都成超人了，灵气才复苏？》@ bbiquge8 (`/book/176923/tc_5.html`): `nextContentUrl` stitches the
chapter from three sub-pages, and every sub-page prints the chapter name again with only a page
number appended (`第五章 寻找 (第1/3页)`), which used to leak a duplicate title line into the reader
(see `docs/bugfix/TASKS.md` T-READ-9).
"""

import os
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORK = '/tmp/book-content-sim'
TSC_CANDIDATES = [
    '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor-ohos-plugin/node_modules/typescript/bin/tsc',
    '/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript/bin/tsc',
]

TEST = r"""
declare const console: { log(message: string): void };
declare const process: { exitCode?: number };

let passed: number = 0;
const failures: string[] = [];
function ok(cond: boolean, label: string): void {
  if (cond) { passed++; return; }
  failures.push(label);
}
function eq(actual: unknown, expect: unknown, label: string): void {
  ok(actual === expect, label + ' (expected ' + JSON.stringify(expect) + ', got ' + JSON.stringify(actual) + ')');
}
function body(raw: string, title: string): string {
  const out: string[] = sanitizeText(raw, title);
  return out.join('|');
}
function markLines(raw: string, title: string): string[] {
  return sanitizeText(raw, title).filter((line: string) => /\/\s*\d+\s*页?|第\s*\d+\s*\/\s*\d+/.test(line));
}

// ── 探针实测形状：bbiquge8 第五章 由 3 个分页子页拼成，每个子页再印一次章名 + 页码 ──
const bb: string = [
  '第五章 寻找 (第1/3页)',
  '教学楼，四楼。',
  '“呼——”',
  '第五章 寻找 (第2/3页)',
  '陈洛扶着墙面，走出楼梯间。',
  '第五章 寻找 (第3/3页)',
  '他离开宿舍的时间，是7:56.'
].join('\n');
const pb: string[] = sanitizeText(bb, '第五章 寻找');
eq(pb.length, 5, 'three paginated title lines are dropped (1 title + 4 body lines)');
eq(pb[0], '第五章 寻找', 'the title heading is still added once, first');
eq(markLines(bb, '第五章 寻找').length, 0, 'no page-marked line survives anywhere in the chapter');
ok(pb.indexOf('教学楼，四楼。') > 0, 'body before the second sub-page survives');
ok(pb.indexOf('他离开宿舍的时间，是7:56.') > 0, 'body after the third sub-page survives');

// ── 写法变体：全角括号 / 半角括号 / 空格塞满 / 只有章节名带括号 ──────────────
eq(body('第五章 寻找（第1/3页）\n正文。', '第五章 寻找'), '第五章 寻找|正文。', 'fullwidth parens');
eq(body('第五章 寻找 （ 第 1 / 3 页 ）\n正文。', '第五章 寻找'), '第五章 寻找|正文。', 'spaces inside the mark');
eq(body('第五章 寻找 第2/3页\n正文。', '第五章 寻找'), '第五章 寻找|正文。', 'bare 第N/M页 suffix');
eq(body('第五章 寻找 (2/3)\n正文。', '第五章 寻找'), '第五章 寻找|正文。', 'parens without 第/页');
eq(body('第五章 寻找 (第1/3页)\n正文。', '第五章 寻找（上）'), '第五章 寻找（上）|第五章 寻找 (第1/3页)|正文。', 'a bracketed title does not swallow a different chapter name');

// ── 孤立页码行（站点把标记单独成行）────────────────────────────────────
eq(body('(第1/3页)\n正文。', '第五章 寻找'), '第五章 寻找|正文。', 'standalone mark line is dropped');
eq(body('第2/3页\n正文。', ''), '正文。', 'no title: standalone mark dropped, empty title adds no heading');

// ── 刻意保守：裸 `N/M` 与「章名后面还有字」都保留 ───────────────────────
eq(body('第五章 寻找 1/3\n正文。', '第五章 寻找'), '第五章 寻找|第五章 寻找 1/3|正文。',
  'a bare fraction after the title is not a page mark');
eq(body('第五章 寻找 (第1/3页) 之后\n正文。', '第五章 寻找'), '第五章 寻找|第五章 寻找 (第1/3页) 之后|正文。',
  'trailing text after the mark means it is not a paginated heading');
eq(body('第五章 寻找线索的人\n正文。', '第五章 寻找'), '第五章 寻找|第五章 寻找线索的人|正文。',
  'title as a prefix of a longer word is body text');

// ── 既有规则不回归：当前位置面包屑 / 整行等于章名 / 本地 TXT 的标题行 ────
eq(body('当前位置：/作者/书名/第五章\n正文。', '第五章 寻找'), '第五章 寻找|正文。', 'breadcrumb still dropped');
eq(body('第五章 寻找\n教学楼，四楼。\n第五章 寻找\n', '第五章 寻找'), '第五章 寻找|教学楼，四楼。',
  'exact title lines are dropped, heading added once');
eq(body('第五章 寻找\n正文。', ''), '第五章 寻找|正文。', 'empty title keeps every line and adds no heading');
eq(body('第五章 寻找\n\n正文。\n', '第五章 寻找'), '第五章 寻找|正文。', 'blank lines are skipped');

if (failures.length > 0) {
  console.log('FAILED ' + failures.length + ' / ' + (passed + failures.length));
  for (const item of failures) { console.log('  ' + item); }
  process.exitCode = 1;
} else {
  console.log('PASS ' + passed + ' book-content contract assertions');
}
"""


def read(rel):
    with open(os.path.join(ROOT, rel), encoding='utf-8') as f:
        return f.read()


def slice_region(text, start_marker):
    start = text.find(start_marker)
    if start < 0:
        return None
    end = text.find('\n}\n', start)
    if end < 0:
        return None
    return text[start:end + 2]


def main():
    raw_content = read('entry/src/main/ets/model/BookContent.ets')
    region = slice_region(raw_content, 'const PAGE_MARK_RE')
    if region is None:
        sys.exit('slice failed: PAGE_MARK_RE .. sanitizeText region not found in model/BookContent.ets')
    if 'export function sanitizeText(' not in region or 'PAGE_MARK_RE.test' not in region:
        sys.exit('slice failed: model/BookContent.ets changed shape; update the slice markers')
    # 纯度：这段必须是可单测的纯文本逻辑（无 kit 模块、无引擎调用、无 IO）。
    for banned in ('import ', '@kit.', '@ohos.', 'bookEngine', 'common.'):
        if banned in region:
            sys.exit('purity failed: sanitizeText region depends on %r' % banned)
    if raw_content.count('export function sanitizeText(') != 1:
        sys.exit('purity failed: there must be exactly one sanitizeText implementation')
    region = region.replace('export function sanitizeText(', 'function sanitizeText(')

    shutil.rmtree(WORK, ignore_errors=True)
    os.makedirs(WORK, exist_ok=True)
    src = os.path.join(WORK, 'book-content.ts')
    with open(src, 'w', encoding='utf-8') as f:
        f.write(region + '\n' + TEST + '\n')

    tsc = next((path for path in TSC_CANDIDATES if os.path.exists(path)), None)
    if tsc is None:
        sys.exit('DevEco tsc not found; update TSC_CANDIDATES')
    out = os.path.join(WORK, 'out')
    proc = subprocess.run([tsc, '--target', 'es2020', '--module', 'commonjs', '--lib', 'es2020',
                           '--strict', '--outDir', out, src], capture_output=True, text=True)
    if proc.returncode != 0:
        print(proc.stdout + proc.stderr)
        sys.exit('tsc failed')
    return subprocess.call(['node', os.path.join(out, 'book-content.js')])


if __name__ == '__main__':
    sys.exit(main())