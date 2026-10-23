#!/usr/bin/env python3
"""书架「更新」（T-SHELF-7）主机侧仿真：不上设备就跑通 `model/ShelfUpdater.ets` 的编排。

为什么需要：这条路径的**真实依赖只有 3 个**（引擎 `bookEngine` / DB `upsertBook` / `isLocalBook`），
其余全是纯逻辑。因为网络请求的形态（`search` → `isSameBook` 取 `bookUrl` → `bookInfo`，
以及详情缺章名时的 `toc` 兜底）在
设备上要 20+ 秒一轮、还要真书，主机侧用**打桩引擎**能把并发上限 / 整体预算 / 单本超时 /
失败静默 / 基线前移 / 幂等这些分支一次跑完，秒级反馈。

做法（**不重写被测逻辑**）：从真源码机械切片 ——
  * `common/Format.ets` 的 `AUTHOR_LABELS`/`CHAPTER_LABELS`/`stripLabel`/`cleanAuthor`/`cleanChapter`
  * `model/ShelfUpdater.ets` 去掉 `import` 行的**全文**
前者保证 `chapterKey` 用的是真实现，后者保证被测的是真编排。再用 DevEco 自带的 `tsc`
编到 JS、`node` 跑断言。改动 `ShelfUpdater.ets` 后直接重跑本脚本即可。

用法：python3 scripts/shelf-updater-sim.py      （退出码 0 = 全部断言通过）
覆盖：本地 TXT 文件名拆书名/作者、计数（checked/failed/skipped/updated）、本地书排除、基线前移与「等价对齐」不误报、
      幂等（第二次点击 0 新章 + 0 写库）、并发上限 3、详情缺章名时目录末章兜底（URL 三级回退、
      卷标题跳过、目录失败隔离）、进度回调序列（含进行中失败数
      `failed` 累计值与 `shelfProgressText()` 三种文案形态）、预算耗尽、书源缺失、
      搜索 6s / 详情 15s 预算传入引擎（超时仍按单本失败隔离）。**未覆盖**：真机网络/真书/UI。
"""
import os, re, shutil, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORK = '/tmp/shelf-updater-sim'
TSC_CANDIDATES = [
    '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor-ohos-plugin/node_modules/typescript/bin/tsc',
    '/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript/bin/tsc',
]

STUBS = r"""// ── host stubs（只替换 3 个外部依赖：引擎 / DB / 本地书判定 + 2 个纯函数）──
interface BookSource { bookSourceUrl: string; bookSourceName: string; enabled?: boolean; }
interface Book { bookId: string; sourceUrl: string; name: string; author: string; lastChapterTitle: string; tocUrl: string; }
interface Chapter { title: string; isVolume?: boolean; }
interface BookSearchItem { name: string; author: string; bookUrl: string; lastChapter: string; }
interface SearchResult { items: BookSearchItem[]; }

interface Scenario {
  lastChapterTitle?: string;
  tocLastChapterTitle?: string;
  infoTocUrl?: string;
  failSearch?: boolean;
  failInfo?: boolean;
  failToc?: boolean;
  timeout?: boolean;
  delayMs?: number;
}
const ENGINE_INFO_TIMEOUT_MS: number = 15000;
const ENGINE_TOC_TIMEOUT_MS: number = 45000;
let scenario: Record<string, Scenario> = {};
let inFlight: number = 0;
let maxInFlight: number = 0;
let writes: string[] = [];
let progress: string[] = [];
let searchTimeouts: number[] = [];
let infoTimeouts: number[] = [];
let tocTimeouts: number[] = [];
let tocUrls: string[] = [];
const sleep = (ms: number): Promise<void> => new Promise<void>((r) => setTimeout(r, ms));

const bookEngine = {
  async search(_s: BookSource[], keyword: string, opts: { timeoutMs: number; concurrency: number }): Promise<SearchResult> {
    const sc = scenario[keyword];
    searchTimeouts.push(opts.timeoutMs);
    inFlight = inFlight + 1;
    if (inFlight > maxInFlight) { maxInFlight = inFlight; }
    await sleep(sc === undefined || sc.delayMs === undefined ? 0 : sc.delayMs);
    inFlight = inFlight - 1;
    if (sc !== undefined && sc.failSearch === true) { throw new Error('search failed'); }
    const hasTocFallback = sc !== undefined && sc.tocLastChapterTitle !== undefined;
    return { items: [{ name: keyword, author: '作者：烽火戏诸侯', bookUrl: 'u:' + keyword,
      lastChapter: hasTocFallback || sc === undefined || sc.lastChapterTitle === undefined ? '' : sc.lastChapterTitle }] };
  },
  async bookInfo(_s: BookSource, bookUrl: string, timeoutMs: number): Promise<Book> {
    const name = bookUrl.substring(2);
    const sc = scenario[name];
    infoTimeouts.push(timeoutMs);
    await sleep(sc === undefined || sc.delayMs === undefined ? 0 : sc.delayMs);
    if (sc !== undefined && sc.failInfo === true) { throw new Error('info failed'); }
    if (sc !== undefined && sc.timeout === true) { throw new Error('timeout'); }
    const hasTocFallback = sc !== undefined && sc.tocLastChapterTitle !== undefined;
    return { bookId: name, sourceUrl: 'http://s', name: name, author: '烽火戏诸侯',
      lastChapterTitle: hasTocFallback || sc === undefined || sc.lastChapterTitle === undefined ? '' : sc.lastChapterTitle,
      tocUrl: sc !== undefined && sc.infoTocUrl !== undefined ? sc.infoTocUrl : '' };
  },
  async toc(_s: BookSource, tocUrl: string, timeoutMs: number): Promise<Chapter[]> {
    const name = tocUrl.substring(2);
    const sc = scenario[name];
    tocUrls.push(tocUrl);
    tocTimeouts.push(timeoutMs);
    if (sc !== undefined && sc.failToc === true) { throw new Error('toc failed'); }
    return [{ title: '卷标题', isVolume: true }, { title: '第一段' }, { title: ' ' },
      { title: sc === undefined || sc.tocLastChapterTitle === undefined ? '' : sc.tocLastChapterTitle }];
  }
};
const upsertBook = async (book: Book): Promise<void> => { writes.push(book.name + '=' + book.lastChapterTitle); };
const isLocalBook = (book: Book): boolean => book.sourceUrl === 'local://';
function isSameBook(book: Book, item: BookSearchItem): boolean {
  if (book.name.trim() !== item.name.trim()) { return false; }
  const a = cleanAuthor(book.author);
  const b = cleanAuthor(item.author);
  if (a.length === 0 || b.length === 0) { return true; }
  return a === b;
}


"""

TEST = r"""// ── 场景：4 本网络书 + 1 本本地书（并发 3）──
function mk(id: string, name: string, last: string): Book {
  return { bookId: id, sourceUrl: 'http://s', name: name, author: '烽火戏诸侯', lastChapterTitle: last,
    tocUrl: 't:' + name };
}
let failures: number = 0;
function check(label: string, got: unknown, want: unknown): void {
  const ok = JSON.stringify(got) === JSON.stringify(want);
  if (!ok) { failures = failures + 1; }
  console.log((ok ? 'PASS ' : 'FAIL ') + label + ' -> ' + JSON.stringify(got) + (ok ? '' : ' (want ' + JSON.stringify(want) + ')'));
}

async function main(): Promise<void> {
  check('文件名作者全角冒号', splitTitleAuthor('大唐：李世民求我造反 作者：天下乐'),
    { title: '大唐：李世民求我造反', author: '天下乐' });
  check('文件名作者半角冒号', splitTitleAuthor('大唐：李世民求我造反 作者:天下乐'),
    { title: '大唐：李世民求我造反', author: '天下乐' });
  check('文件名作者括号', splitTitleAuthor('大唐：李世民求我造反（作者：天下乐）'),
    { title: '大唐：李世民求我造反', author: '天下乐' });
  check('文件名无作者', splitTitleAuthor('大唐：李世民求我造反'),
    { title: '大唐：李世民求我造反', author: '' });
  check('标题中间的作者字样不剥离', splitTitleAuthor('我在作者身边 作者：天下乐'),
    { title: '我在作者身边', author: '天下乐' });
  check('多个作者标签取最右一个', splitTitleAuthor('作者：我与作者 作者：天下乐'),
    { title: '作者：我与作者', author: '天下乐' });
  check('只有作者标签时不误拆', splitTitleAuthor('作者：天下乐'),
    { title: '作者：天下乐', author: '' });

  scenario = {
    '剑来': { lastChapterTitle: '第84章 明日无风', delayMs: 40 },     // 基线 第83章 → 有新章
    '雪中': { lastChapterTitle: '第83章 今日无事', delayMs: 40 },     // 基线带「最新：」标签 → 等价，不算新章
    '斗破': { failSearch: true, delayMs: 40 },                        // 搜索失败 → 静默
    '凡人': { lastChapterTitle: '第83章 今日无事', delayMs: 40 }      // 无基线 → 静默建基线
  };
  const books: Book[] = [
    mk('1', '剑来', '第83章 今日无事'),
    mk('2', '雪中', '最新：第83章 今日无事'),
    mk('3', '斗破', '第83章 今日无事'),
    mk('4', '凡人', '')
  ];
  const local: Book = { bookId: '5', sourceUrl: 'local://', name: '本地书', author: 'x', lastChapterTitle: '第一章',
    tocUrl: 'local://5' };
  books.push(local);

  const out = await checkShelfUpdates(books, [{ bookSourceUrl: 'http://s', bookSourceName: 's' }],
    (done: number, total: number, failed: number, local: number): void => {
      progress.push(done + '/' + total + ':' + failed + ':' + local);
    });
  check('total（本地书已排除）', out.total, 4);
  check('local（本地书单独计数）', out.local, 1);
  check('checked', out.checked, 3);
  check('failed（搜索失败静默）', out.failed, 1);
  check('skipped', out.skipped, 0);
  check('updated 书名', out.updated.map((b: Book): string => b.name), ['剑来']);
  // 雪中 那次是**设计行为**：原始串带「最新：」标签、归一化等价 ⇒ 静默对齐基线（不报新章）
  check('回写基线（新章 + 无基线 + 等价对齐）', writes.sort(), ['凡人=第83章 今日无事', '剑来=第84章 明日无风', '雪中=第83章 今日无事']);
  check('等价对齐不算新章', out.updated.map((b: Book): string => b.name).indexOf('雪中'), -1);
  check('进度首尾（done 从 0 走到 total）', [progress[0], progress[progress.length - 1].split(':')[0]],
    ['0/4:0:1', '4/4']);
  check('进度条数（1 次起始 + 每本 1 次）', progress.length, 5);
  check('并发上限 ≤ 3', maxInFlight <= 3, true);
  check('基线未被失败书改写（斗破）', books[2].lastChapterTitle, '第83章 今日无事');

  // 进行中进度文案（UI 直接渲染的字符串）：三种形态
  check('进度文案 无失败', shelfProgressText(1, 2, 0, 0), '检查中 1/2');
  check('进度文案 有失败', shelfProgressText(2, 3, 1, 0), '检查中 2/3 · 1 本未检查');
  check('进度文案 起始（0 本结束时不写 0 本未检查）', shelfProgressText(0, 2, 0, 0), '检查中 0/2');
  check('进度文案 无书', shelfProgressText(0, 0, 0, 0), '检查中…');
  check('进度文案 1 网络书 + 1 本地书', shelfProgressText(0, 1, 0, 1),
    '网络 0/1 · 本地 1');
  check('进度文案 网络书失败 + 本地书', shelfProgressText(1, 1, 1, 1),
    '网络 1/1 · 1 本未检查 · 本地 1');
  check('进度文案 仅本地书', shelfProgressText(0, 0, 0, 1), '本地 1');
  check('结束文案 全失败 + 本地书', shelfUpdateResultText({
    total: 1, local: 1, checked: 0, failed: 1, skipped: 0, updated: []
  }), '网络书检查失败，请检查网络或书源');
  check('结束文案 无新章 + 本地书', shelfUpdateResultText({
    total: 1, local: 1, checked: 1, failed: 0, skipped: 0, updated: []
  }), '没有发现新章节，1 本本地书跳过');
  check('结束文案 部分失败 + 本地书', shelfUpdateResultText({
    total: 2, local: 1, checked: 1, failed: 1, skipped: 0, updated: []
  }), '没有发现新章节，1 本未检查，另有 1 本本地书跳过');

  // qwyd 这类源没有 lastChapter 规则：详情与搜索都为空时必须回退目录末章，
  // 而不是把整本书误判成网络失败。
  writes = [];
  tocTimeouts = [];
  tocUrls = [];
  scenario = { '中国少了一味药': { tocLastChapterTitle: '第三十七章' } };
  const fallback = await checkShelfUpdates([mk('6', '中国少了一味药', '')],
    [{ bookSourceUrl: 'http://s', bookSourceName: 's' }], (): void => {});
  check('详情缺章名回退目录 checked', fallback.checked, 1);
  check('详情缺章名回退目录 failed', fallback.failed, 0);
  check('详情缺章名回退目录建基线', writes, ['中国少了一味药=第三十七章']);
  check('目录兜底跳过卷标题', lastContentChapterTitle([
    { title: '第一章' }, { title: '第二卷', isVolume: true }, { title: '' }
  ]), '第一章');
  check('目录兜底使用书架 tocUrl', tocUrls, ['t:中国少了一味药']);
  check('目录预算 45s', tocTimeouts, [45000]);

  // 详情页给出 tocUrl 时优先于书架旧值。
  tocUrls = [];
  scenario = { '详情目录': { tocLastChapterTitle: '第十章', infoTocUrl: 'i:详情目录' } };
  await checkShelfUpdates([mk('7', '详情目录', '')],
    [{ bookSourceUrl: 'http://s', bookSourceName: 's' }], (): void => {});
  check('目录兜底优先详情 tocUrl', tocUrls, ['i:详情目录']);

  // 详情与书架都没有 tocUrl 时，用搜索命中的 bookUrl。
  tocUrls = [];
  scenario = { '搜索地址': { tocLastChapterTitle: '第十一章' } };
  const searchUrlBook: Book = mk('8', '搜索地址', '');
  searchUrlBook.tocUrl = '';
  await checkShelfUpdates([searchUrlBook],
    [{ bookSourceUrl: 'http://s', bookSourceName: 's' }], (): void => {});
  check('目录兜底回退 bookUrl', tocUrls, ['u:搜索地址']);

  // 目录请求失败仍按单本失败隔离，不建基线。
  writes = [];
  scenario = { '目录失败': { failToc: true } };
  const tocFailed = await checkShelfUpdates([mk('9', '目录失败', '')],
    [{ bookSourceUrl: 'http://s', bookSourceName: 's' }], (): void => {});
  check('目录失败计 failed', tocFailed.failed, 1);
  check('目录失败不写库', writes.length, 0);

  scenario = {
    '剑来': { lastChapterTitle: '第84章 明日无风', delayMs: 40 },
    '雪中': { lastChapterTitle: '第83章 今日无事', delayMs: 40 },
    '斗破': { failSearch: true, delayMs: 40 },
    '凡人': { lastChapterTitle: '第83章 今日无事', delayMs: 40 }
  };

  // 幂等：把回写后的基线再查一次，必须 0 本有新章、0 次写库
  writes = [];
  const again = await checkShelfUpdates(books, [{ bookSourceUrl: 'http://s', bookSourceName: 's' }],
    (): void => {});
  check('第二次点击 updated', again.updated.length, 0);
  check('第二次点击写库次数', writes.length, 0);

  // 预算耗尽：deadline 已在过去 → 一条 lane 都不开始新书
  const skippedOut = await checkShelfUpdates(books, [{ bookSourceUrl: 'http://s', bookSourceName: 's' }],
    (): void => {}, -1);
  check('预算耗尽 skipped', skippedOut.skipped, 4);
  check('预算耗尽 checked', skippedOut.checked, 0);
  check('预算耗尽 updated', skippedOut.updated.length, 0);

  // 书源缺失/停用：记为失败，不发请求
  writes = [];
  const noSource = await checkShelfUpdates(books, [], (): void => {});
  check('无书源 failed', noSource.failed, 4);
  check('无书源 checked', noSource.checked, 0);
  check('无书源写库次数', writes.length, 0);

  // 本地书单：total=0，不报错
  const onlyLocal = await checkShelfUpdates([local], [], (): void => {});
  check('只有本地书 total', onlyLocal.total, 0);

  // 失败数必须**进行中**就能上报（不必等结束 toast）：2 本，一本搜索 0ms 即败、
  // 一本 150ms 才回 ⇒ 序列确定，且失败那本之后每一条都带着 failed=1。
  // （放在这里是因为它要重写 `scenario`，而随后的超时护栏块本就会自己重设。）
  scenario = {
    '剑来': { lastChapterTitle: '第84章 明日无风', delayMs: 150 },
    '斗破': { failSearch: true, delayMs: 0 }
  };
  const midProgress: string[] = [];
  await checkShelfUpdates([mk('1', '剑来', '第83章 今日无事'), mk('3', '斗破', '第83章 今日无事')],
    [{ bookSourceUrl: 'http://s', bookSourceName: 's' }],
    (done: number, total: number, failed: number, local: number): void => {
      midProgress.push(shelfProgressText(done, total, failed, local));
    });
  check('失败书之后每条进度都带未检查数', midProgress,
    ['检查中 0/2', '检查中 1/2 · 1 本未检查', '检查中 2/2 · 1 本未检查']);

  // 引擎超时预算：搜索/详情各自拿到产品默认值；详情失败只影响该本。
  searchTimeouts = [];
  infoTimeouts = [];
  scenario = {
    '剑来': { timeout: true, delayMs: 20 },
    '雪中': { lastChapterTitle: '第83章 今日无事', delayMs: 20 }
  };
  writes = [];
  const t0: number = Date.now();
  const slow = await checkShelfUpdates([mk('1', '剑来', '第83章 今日无事'), mk('2', '雪中', '第83章 今日无事')],
    [{ bookSourceUrl: 'http://s', bookSourceName: 's' }], (): void => {});
  const elapsed: number = Date.now() - t0;
  check('超时书 failed', slow.failed, 1);
  check('超时书不影响其余书', slow.checked, 1);
  check('超时书不报新章', slow.updated.length, 0);
  check('超时书不写库、原文相同的书也不写库', writes.length, 0);
  check('搜索预算 6s', searchTimeouts, [6000, 6000]);
  check('详情预算 15s', infoTimeouts, [15000, 15000]);
  check('失败隔离不等待整体预算', elapsed < 5000, true);
  console.log('   elapsed=' + elapsed + 'ms');

  console.log(failures === 0 ? 'ALL PASS' : 'FAILURES: ' + failures);
  process.exit(failures === 0 ? 0 : 1);
}
main();
"""


def read(rel):
    with open(os.path.join(ROOT, rel), encoding='utf-8') as f:
        return f.read()


def slice_between(text, a, b, label):
    if a not in text or b not in text:
        sys.exit('切片失败（%s）：%r / %r 找不到了，源码结构可能已改' % (label, a, b))
    return text[text.index(a):text.index(b)]


def main():
    fmt = slice_between(read('entry/src/main/ets/common/Format.ets'),
                        'export const AUTHOR_LABELS', 'export function formatBytes', 'Format.ets')
    updater = read('entry/src/main/ets/model/ShelfUpdater.ets')
    body = '\n'.join(l for l in updater.splitlines() if not l.startswith('import '))
    if 'JSON.parse(' in body:
        print('提示：ShelfUpdater.ets 现在含 JSON 往返，别忘了 entry/obfuscation-rules.txt')

    shutil.rmtree(WORK, ignore_errors=True)
    os.makedirs(WORK, exist_ok=True)
    src = os.path.join(WORK, 'shelf.ts')
    with open(src, 'w', encoding='utf-8') as f:
        f.write(fmt + '\n' + STUBS + '\n' + body + '\n'
                + 'declare const process: { exit(code?: number): void };\n' + TEST)

    tsc = next((p for p in TSC_CANDIDATES if os.path.exists(p)), None)
    if tsc is None:
        sys.exit('找不到 DevEco 的 tsc，改 TSC_CANDIDATES')
    out = os.path.join(WORK, 'out')
    r = subprocess.run([tsc, '--target', 'es2020', '--module', 'commonjs', '--lib', 'es2020,dom',
                        '--outDir', out, src], capture_output=True, text=True)
    if r.returncode != 0:
        print(r.stdout + r.stderr)
        sys.exit('tsc 失败')
    print('编译通过 → ' + out, flush=True)
    return subprocess.call(['node', os.path.join(out, 'shelf.js')])


if __name__ == '__main__':
    sys.exit(main())
