#!/usr/bin/env python3
"""Host contract checks for the pure TOC-quality analyzer used by the source-switch drawer.

Like `detect-job-sim.py` this imports the real `model/TocQuality.ets` source instead of a
copy: ArkTS-only import lines are stripped, and the `Chapter` interface is sliced from
`engine/types.ets` so the fixture shape cannot drift from the engine contract.

The fixtures reproduce the two shapes measured on the device for 《剑来》
(`docs/bugfix/TASKS.md` T-SWITCH-2): yetianlian/`小说` returns the detail page's
"最新章节列表" preview block on top of the real TOC (1321 rows / 12 duplicate URLs),
`bbiquge8` returns the same book without that block (1309 rows / 0 duplicate URLs).
"""

import os
import re
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORK = '/tmp/toc-quality-sim'
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

function row(index: number, title: string, url: string, isVolume?: boolean): Chapter {
  return { bookId: 'b', index: index, title: title, url: url, isVip: false, isVolume: isVolume };
}

const CN = ['零', '一', '二', '三', '四', '五', '六', '七', '八', '九'];
function hundreds(n: number): string {
  let out = '';
  const thousands = Math.floor(n / 1000);
  const rest = n % 1000;
  if (thousands > 0) { out += CN[thousands] + '千'; }
  const h = Math.floor(rest / 100);
  if (h > 0) { out += CN[h] + '百'; }
  const t = Math.floor((rest % 100) / 10);
  const o = rest % 10;
  if (t > 1) { out += CN[t] + '十'; } else if (t === 1) { out += '十'; }
  if (o > 0) { out += CN[o]; }
  return out.length > 0 ? out : '零';
}

// ── 数字解析：目录里真实出现的两种写法 ──────────────────────────────
eq(cnNumber('十'), 10, 'cn ten');
eq(cnNumber('十二'), 12, 'cn twelve');
eq(cnNumber('八十四'), 84, 'cn eighty-four');
eq(cnNumber('两百零四'), 204, 'cn two hundred four with 两');
eq(cnNumber('一千零六十四'), 1064, 'cn one thousand sixty-four');
eq(cnNumber('一千二百一十八'), 1218, 'cn the real last chapter');
eq(chapterNumberOf('第84章 上升地'), 84, 'arabic chapter number');
eq(chapterNumberOf('第一千二百一十八章 看书人'), 1218, 'chinese chapter number');
eq(chapterNumberOf('第1162章（1） 第四把飞剑'), 1162, 'suffixed chapter number keeps the number');
eq(chapterNumberOf('紧急通知'), 0, 'notice has no chapter number');
eq(chapterNumberOf('第一卷 笼中雀 第一章 惊蛰'), 1, 'volume-prefixed chapter number');
ok(isChapterLike('第3章 放霁'), 'normal chapter is chapter-like');
ok(!isChapterLike('紧急通知'), 'notice is not chapter-like');
ok(!isChapterLike('请假一天，顺便小聊几句。'), 'leave note is not chapter-like');
ok(!isChapterLike('楔子'), 'foreword is not chapter-like');
// 站点错别字（张/章，真机实测）仍算「带章号」，不能计成公告
ok(hasChapterNumber('第四百二十张 山水依旧'), 'typo chapter still carries a chapter number');
ok(!isChapterLike('第四百二十张 山水依旧'), 'but it is not a strict chapter heading');
ok(!hasChapterNumber('紧急通知'), 'notice carries no chapter number');

// ── 目录形状：与真机实测的两种形状同构 ─────────────────────────────
// main：1218 章（前 84 章带「第一卷」标记 → 不参与章号回退判定）+ 2 条公告 + 2 行重号标题
function mainBody(): Chapter[] {
  const out: Chapter[] = [];
  let i = 0;
  for (let n = 1; n <= 1218; n++) {
    const title = n <= 84 ? '第一卷 笼中雀 ' + '第' + hundreds(n) + '章 甲' + n : '第' + hundreds(n) + '章 甲' + n;
    out.push(row(i++, title, '/c/' + n + '.html'));
  }
  out.push(row(i++, '紧急通知', '/c/notice1.html'));
  out.push(row(i++, '请假一天，顺便小聊几句。', '/c/notice2.html'));
  out.push(row(i++, '第349章 埋河封正', '/c/349a.html'));
  out.push(row(i++, '第349章 埋河封正', '/c/349b.html'));
  return out;
}

// tail：站点把第二次上传接在正文卷后面，重新从「第1章」编号（含一行重复标题）
function tailBlock(): Chapter[] {
  const out: Chapter[] = [];
  let i = 0;
  for (let n = 1; n <= 84; n++) {
    out.push(row(i++, '第' + n + '章 尾' + n, '/t/' + n + '.html'));
  }
  out.push(row(i++, '第33章 尾33', '/t/33b.html'));
  return out;
}

// preview：详情页顶部的「最新章节列表」预览块（最新在前，URL 与 tail 尾部完全相同）
function previewBlock(): Chapter[] {
  const out: Chapter[] = [];
  for (let n = 84; n >= 73; n--) {
    out.push(row(0, '第' + n + '章 尾' + n, '/t/' + n + '.html'));
  }
  return out;
}

const yetianlian = previewBlock().concat(mainBody()).concat(tailBlock());
const bbiquge8 = mainBody().concat(tailBlock());

const qa = analyzeToc(yetianlian);
eq(qa.rows, yetianlian.length, 'rows equals the row count');
eq(qa.volumes, 0, 'no volume rows in this shape');
eq(qa.dupUrls, 12, 'preview block duplicates 12 chapter URLs');
eq(qa.tailRestart, true, 'tail renumbers from chapter 1 after 1218');
eq(qa.level, TOC_QUALITY_SUSPECT, 'duplicate URLs make the candidate suspect');
eq(tocQualityLabel(qa), '⚠ 目录 12 行重复', 'suspect label leads with the duplicate count');
ok(tocQualityWarning(qa).indexOf('12') >= 0, 'switch confirmation carries the duplicate count');

const qb = analyzeToc(bbiquge8);
eq(qb.rows, bbiquge8.length, 'second shape row count');
eq(qb.dupUrls, 0, 'same book without the preview block has no duplicate URL');
eq(qb.tailRestart, true, 'shared upstream tail renumbering is still reported');
eq(qb.level, TOC_QUALITY_NOTICE, 'tail renumbering is only a notice, never suspect');
eq(tocQualityLabel(qb), '目录末段重新编号', 'notice label names the tail renumbering');
eq(tocQualityWarning(qb), '', 'notice level adds no switch warning');

// 两个候选的对比就是这次体检的意义：同一个「123 行重复」只属于其中一个源
ok(qa.level > qb.level, 'the two candidates are ranked apart by the TOC check');

// ── 干净目录：不显示任何徽标 ──────────────────────────────────────
const clean: Chapter[] = [];
for (let n = 1; n <= 300; n++) { clean.push(row(n, '第' + n + '章 正文', '/k/' + n + '.html')); }
const qc = analyzeToc(clean);
eq(qc.level, TOC_QUALITY_CLEAN, 'monotone clean TOC stays clean');
eq(tocQualityLabel(qc), '', 'clean TOC renders no badge');
eq(tocQualityWarning(qc), '', 'clean TOC adds no warning');

// ── 卷行：`isVolume` / 空 URL 不得被当成重复 ──────────────────────
const withVolumes: Chapter[] = [
  row(0, '第一卷 笼中雀', '', true),
  row(1, '第1章 惊蛰', '/v/1.html'),
  row(2, '第2章 开门', '/v/2.html'),
  row(3, '第二卷 山水郎', '', true),
  row(4, '第3章 日出', '/v/3.html')
];
const qv = analyzeToc(withVolumes);
eq(qv.volumes, 2, 'volume rows are counted separately');
eq(qv.dupUrls, 0, 'empty volume URLs are not duplicate chapters');
eq(qv.level, TOC_QUALITY_CLEAN, 'volumes alone do not dirty a TOC');

// ── 逐卷重新编号（标题自带卷标记）不算「末段回退」 ────────────────
const perVolume: Chapter[] = [];
for (let n = 1; n <= 84; n++) { perVolume.push(row(n, '第一卷 第' + n + '章 甲', '/p1/' + n + '.html')); }
for (let n = 1; n <= 84; n++) { perVolume.push(row(n, '第二卷 第' + n + '章 乙', '/p2/' + n + '.html')); }
const qp = analyzeToc(perVolume);
eq(qp.tailRestart, false, 'per-volume numbering is not mistaken for a tail restart');
eq(qp.level, TOC_QUALITY_CLEAN, 'per-volume numbering stays clean');

// ── 尾部太短 / 书太小：不做「末段回退」判定 ───────────────────────
const shortTail: Chapter[] = [];
for (let n = 1; n <= 200; n++) { shortTail.push(row(n, '第' + n + '章 甲', '/s/' + n + '.html')); }
shortTail.push(row(200, '第2章 尾', '/s/tail.html'));
eq(analyzeToc(shortTail).tailRestart, false, 'a tail shorter than 5 rows is not a restart');

const tiny: Chapter[] = [];
for (let n = 1; n <= 12; n++) { tiny.push(row(n, '第' + n + '章 甲', '/x/' + n + '.html')); }
tiny.push(row(12, '第1章 尾', '/x/tail.html'));
eq(analyzeToc(tiny).tailRestart, false, 'a small book is not flagged for renumbering');

// ── 只有重号标题（>= 3）时才给提示级徽标 ─────────────────────────
const dupOnly: Chapter[] = [];
for (let n = 1; n <= 50; n++) { dupOnly.push(row(n, '第' + n + '章 甲', '/d/' + n + '.html')); }
dupOnly.push(row(50, '第7章 甲', '/d/7b.html'));
dupOnly.push(row(51, '第8章 甲', '/d/8b.html'));
dupOnly.push(row(52, '第9章 甲', '/d/9b.html'));
const qd = analyzeToc(dupOnly);
eq(qd.dupUrls, 0, 'different URLs are not duplicate rows');
eq(qd.dupTitles, 3, 'duplicate titles are counted');
eq(qd.level, TOC_QUALITY_NOTICE, 'three duplicate titles raise a notice');
eq(tocQualityLabel(qd), '目录 3 个重复标题', 'duplicate-title label');

// ── 空目录 / 只有卷行的目录：不崩、不误报 ─────────────────────────
eq(analyzeToc([]).level, TOC_QUALITY_CLEAN, 'empty TOC is clean and safe');
eq(tocQualityLabel(undefined), '', 'absent quality renders no badge');
eq(tocQualityWarning(undefined), '', 'absent quality adds no warning');

// ── 整份目录没有标题（真机实测某候选 1331 行全空）⇒ 可疑级 ────────
const titleless: Chapter[] = [];
for (let n = 1; n <= 1331; n++) { titleless.push(row(n, '', '/n/' + n + '.html')); }
const qt = analyzeToc(titleless);
eq(qt.untitled, 1331, 'titleless rows are counted separately');
eq(qt.notices, 0, 'a titleless row is not an announcement');
eq(qt.dupUrls, 0, 'titleless rows are still distinct URLs');
eq(qt.level, TOC_QUALITY_SUSPECT, 'a titleless TOC is suspect');
eq(tocQualityLabel(qt), '⚠ 目录 1331 行没有标题', 'titleless label states the observable fact');
ok(tocQualityWarning(qt).indexOf('1331') >= 0, 'titleless switch warning carries the count');
ok(tocQualityWarning(qt).indexOf('章名') >= 0, 'titleless warning says the reader will show no names');

// 零星空行（站点偶发）不触发可疑级
const fewTitleless: Chapter[] = [];
for (let n = 1; n <= 80; n++) { fewTitleless.push(row(n, '第' + n + '章 甲', '/f/' + n + '.html')); }
fewTitleless.push(row(80, '', '/f/empty1.html'));
fewTitleless.push(row(81, '', '/f/empty2.html'));
const qf = analyzeToc(fewTitleless);
eq(qf.untitled, 2, 'stray empty titles are counted');
eq(qf.level, TOC_QUALITY_CLEAN, 'two stray empty titles do not dirty a TOC');

// ── 站点不按「第 N 章」编号：不把整份目录读成「公告」────────────────
const unnumbered: Chapter[] = [];
for (let n = 1; n <= 40; n++) { unnumbered.push(row(n, '第' + n + '章 甲', '/u/' + n + '.html')); }
for (let n = 1; n <= 60; n++) { unnumbered.push(row(n, '番外·甲' + n, '/u/x' + n + '.html')); }
const qu = analyzeToc(unnumbered);
eq(qu.numbered, 40, 'numbered rows are counted');
eq(qu.numberingOff, true, 'a minority of numbered rows means the source numbers differently');
eq(qu.notices, 0, 'unnumbered titles are not announcements when the source does not number chapters');
eq(qu.level, TOC_QUALITY_CLEAN, 'a differently-numbered TOC is not flagged');

// 少数公告（3 条）仍然照常提示
const noted: Chapter[] = [];
for (let n = 1; n <= 60; n++) { noted.push(row(n, '第' + n + '章 甲', '/g/' + n + '.html')); }
noted.push(row(60, '紧急通知', '/g/n1.html'));
noted.push(row(61, '请假一天，顺便小聊几句。', '/g/n2.html'));
noted.push(row(62, '上架感言', '/g/n3.html'));
const qn = analyzeToc(noted);
eq(qn.numbered, 60, 'numbered rows counted before notices');
eq(qn.numberingOff, false, 'a majority of numbered rows keeps numbering on');
eq(qn.notices, 3, 'three notices are counted');
eq(qn.level, TOC_QUALITY_NOTICE, 'three notices raise a notice');
eq(tocQualityLabel(qn), '目录含 3 条公告', 'notice label names the announcements');

if (failures.length > 0) {
  console.log('FAILED ' + failures.length + ' / ' + (passed + failures.length));
  for (const item of failures) { console.log('  ' + item); }
  process.exitCode = 1;
} else {
  console.log('PASS ' + passed + ' toc-quality contract assertions');
}
"""


def read(rel):
    with open(os.path.join(ROOT, rel), encoding='utf-8') as f:
        return f.read()


def strip_imports(text):
    return '\n'.join(line for line in text.splitlines() if not line.startswith('import '))


def slice_interface(text, name):
    start = text.find('export interface %s {' % name)
    if start < 0:
        return None
    end = text.find('\n}', start)
    if end < 0:
        return None
    return text[start:end + 2].replace('export interface ', 'interface ', 1)


def main():
    types = read('entry/src/main/ets/engine/types.ets')
    chapter_interface = slice_interface(types, 'Chapter')
    if chapter_interface is None:
        sys.exit('slice failed: Chapter interface not found in engine/types.ets')

    raw_quality = read('entry/src/main/ets/model/TocQuality.ets')
    quality = strip_imports(raw_quality)
    for needle in ('export function analyzeToc', 'export function chapterNumberOf',
                   'export function cnNumber', 'export function tocQualityLabel',
                   'export function tocQualityWarning', 'export const TOC_QUALITY_SUSPECT'):
        if needle not in quality:
            sys.exit('slice failed: %r missing from model/TocQuality.ets' % needle)
    # 纯度：整个模型只允许依赖 engine 的 `Chapter` 类型（无 kit 模块、无 IO、无引擎调用）。
    imports = [line for line in raw_quality.splitlines() if line.startswith('import ')]
    if imports != ["import { Chapter } from '../engine/types';"]:
        sys.exit('purity failed: TocQuality.ets imports %r' % imports)
    if '@kit.' in quality or '@ohos.' in quality:
        sys.exit('purity failed: TocQuality.ets imports a HarmonyOS kit module')

    shutil.rmtree(WORK, ignore_errors=True)
    os.makedirs(WORK, exist_ok=True)
    src = os.path.join(WORK, 'toc-quality.ts')
    with open(src, 'w', encoding='utf-8') as f:
        f.write(chapter_interface + '\n')
        f.write(quality + '\n' + TEST + '\n')

    tsc = next((path for path in TSC_CANDIDATES if os.path.exists(path)), None)
    if tsc is None:
        sys.exit('DevEco tsc not found; update TSC_CANDIDATES')
    out = os.path.join(WORK, 'out')
    proc = subprocess.run([tsc, '--target', 'es2020', '--module', 'commonjs', '--lib', 'es2020',
                           '--strict', '--outDir', out, src], capture_output=True, text=True)
    if proc.returncode != 0:
        print(proc.stdout + proc.stderr)
        sys.exit('tsc failed')
    return subprocess.call(['node', os.path.join(out, 'toc-quality.js')])


if __name__ == '__main__':
    sys.exit(main())