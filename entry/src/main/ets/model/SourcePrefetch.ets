import { bookEngine } from '../engine/BookEngineNapi';
import { Book, BookSearchItem, BookSource, Chapter } from '../engine/types';
import { ENGINE_INFO_TIMEOUT_MS, ENGINE_TOC_TIMEOUT_MS } from '../common/Const';
import { analyzeToc, TocQuality } from './TocQuality';

/**
 * 换源预热缓存（v1.1 提速；实测数字与验收见 `docs/bugfix/TASKS.md` T-SWITCH-1）。
 *
 * 换源的等待几乎全在**点「切换」之后**：`bookInfo` 1.1s + 全量目录爬取 5.9s
 * （bbiquge8《剑来》1308 行 / 13 页，主机侧 release 实测）。而抽屉从打开到用户点下去
 * 通常有好几秒（检索 13 源 3.3s）—— 把这段时间用来**预热最可能被选中的候选**，
 * 点下去就直接命中（实测 7s → ~0.2s）。
 *
 * 两条自我约束：
 * - **只放内存**，不写 `TocCache`：候选没被选中时不留任何垃圾文件（`switchSource` 命中才写盘）。
 * - **两条车道分治**：目录预热只给最靠前的 `WARM_TOC_LIMIT` 个候选（每源 10+ 次请求），
 *   其余候选只补一次 `bookInfo`（1 次请求，用来填行内的「最新：xxx」），且**串行**派发，
 *   不跟抽屉自己的检索抢带宽。切换一开始就清掉未派发的补全。
 *
 * 目录爬回来时顺手算一次**目录体检**（`analyzeToc`，一次 O(n) 扫描）并随目录一起缓存，
 * 通过 `previewCandidate` 的 `onToc` 回调回填给候选行 —— 这是全 App 唯一
 * 「已经拿到整份目录、又还没决定用哪个源」的时机，所以体检在这里是零边际成本。
 * 判据与为什么只有「重复 URL」能在候选项之间做出区分，见 `model/TocQuality.ets` 文件头。
 */

/** 目录缓存条数上限（每个目录可达数百 KB）。 */
const MAX_TOC_ENTRIES: number = 2;
/** 预热有效期：过期即弃，宁可重新爬也不拿十分钟前的目录迁移进度。 */
const TTL_MS: number = 10 * 60 * 1000;

interface PrefetchedToc {
  tocUrl: string;
  chapters: Chapter[];
  at: number;
  /** 目录体检结论（`model/TocQuality.ets`）：随目录一起缓存，回填候选行用。 */
  quality: TocQuality;
}

/** 详情补全车道里的一个等待任务（每个候选只排一次）。 */
interface FillJob {
  key: string;
  source: BookSource;
  item: BookSearchItem;
  onInfo: (info: Book) => void;
}

const infoCache: Map<string, Book> = new Map();
const infoAt: Map<string, number> = new Map();
const tocCache: Map<string, PrefetchedToc> = new Map();
const infoTasks: Map<string, Promise<Book | undefined>> = new Map();
const tocTasks: Map<string, Promise<TocQuality | undefined>> = new Map();

const fills: FillJob[] = [];
let filling: boolean = false;

function keyOf(sourceUrl: string, bookUrl: string): string {
  return sourceUrl + '|' + bookUrl;
}

function fresh(at: number | undefined): boolean {
  return at !== undefined && at > 0 && Date.now() - at < TTL_MS;
}

/** 详情：命中缓存直接回，在飞则并到同一条请求上（同一个候选绝不发两次）。 */
function fetchInfo(source: BookSource, item: BookSearchItem): Promise<Book | undefined> {
  const key: string = keyOf(source.bookSourceUrl, item.bookUrl);
  const cached: Book | undefined = infoCache.get(key);
  if (cached !== undefined && fresh(infoAt.get(key))) {
    return Promise.resolve(cached);
  }
  const running: Promise<Book | undefined> | undefined = infoTasks.get(key);
  if (running !== undefined) {
    return running;
  }
  const task: Promise<Book | undefined> = bookEngine.bookInfo(
    source,
    item.bookUrl,
    ENGINE_INFO_TIMEOUT_MS
  ).then(
    (info: Book): Book | undefined => {
      infoCache.set(key, info);
      infoAt.set(key, Date.now());
      return info;
    },
    (): Book | undefined => undefined
  );
  infoTasks.set(key, task);
  task.then((): void => {
    infoTasks.delete(key);
  }, (): void => {
    infoTasks.delete(key);
  });
  return task;
}

/**
 * 目录：等详情拿 `tocUrl` 再爬（候选没爬过就爬一次，爬过就用缓存的）。
 * 顺带算一次目录体检（`analyzeToc`，一次 O(n) 扫描）并把结论存进缓存条目。
 *
 * 返回结论；空 = 详情拿不到 / 目录为空 / 爬取失败 —— 都当「没体检过」，
 * 候选行不显示徽标、也不参与排序（缺证据 ≠ 干净）。
 */
async function fetchToc(source: BookSource, item: BookSearchItem): Promise<TocQuality | undefined> {
  const info: Book | undefined = await fetchInfo(source, item);
  if (info === undefined) {
    return undefined;
  }
  const tocUrl: string = info.tocUrl.length > 0 ? info.tocUrl : item.bookUrl;
  const key: string = keyOf(source.bookSourceUrl, item.bookUrl);
  const cached: PrefetchedToc | undefined = tocCache.get(key);
  if (cached !== undefined && cached.tocUrl === tocUrl && fresh(cached.at)) {
    return cached.quality;
  }
  const tkey: string = key + '|' + tocUrl;
  let task: Promise<TocQuality | undefined> | undefined = tocTasks.get(tkey);
  if (task === undefined) {
    task = bookEngine.toc(source, tocUrl, ENGINE_TOC_TIMEOUT_MS).then(
      (chapters: Chapter[]): TocQuality | undefined => {
        if (chapters.length === 0) {
          return undefined;
        }
        const quality: TocQuality = analyzeToc(chapters);
        tocCache.set(key, { tocUrl: tocUrl, chapters: chapters, at: Date.now(), quality: quality });
        trimToc();
        return quality;
      },
      (): TocQuality | undefined => undefined
    );
    tocTasks.set(tkey, task);
    task.then((): void => {
      tocTasks.delete(tkey);
    }, (): void => {
      tocTasks.delete(tkey);
    });
  }
  return await task;
}

/** 只留最近用到的目录（换源一次只可能点一个候选）。 */
function trimToc(): void {
  while (tocCache.size > MAX_TOC_ENTRIES) {
    let oldestKey: string = '';
    let oldestAt: number = Number.MAX_SAFE_INTEGER;
    tocCache.forEach((v: PrefetchedToc, k: string): void => {
      if (v.at < oldestAt) {
        oldestAt = v.at;
        oldestKey = k;
      }
    });
    if (oldestKey.length === 0) {
      return;
    }
    tocCache.delete(oldestKey);
  }
}

/** 串行派发：一次只补一个候选的详情，避免十几条请求同时打出去。 */
async function pumpFills(): Promise<void> {
  if (filling) {
    return;
  }
  filling = true;
  while (fills.length > 0) {
    const job: FillJob | undefined = fills.shift();
    if (job === undefined) {
      break;
    }
    const info: Book | undefined = await fetchInfo(job.source, job.item);
    if (info !== undefined) {
      job.onInfo(info);
    }
  }
  filling = false;
}

/** 预热车道：详情 + 目录（顺序执行，详情先回，面板先能填「最新：xxx」，再接目录体检）。 */
async function runWarm(
  source: BookSource,
  item: BookSearchItem,
  onInfo: (info: Book) => void,
  onToc: (quality: TocQuality) => void
): Promise<void> {
  const info: Book | undefined = await fetchInfo(source, item);
  if (info !== undefined) {
    onInfo(info);
  }
  const quality: TocQuality | undefined = await fetchToc(source, item);
  if (quality !== undefined) {
    onToc(quality);
  }
}

/**
 * 预热一个候选。
 *
 * @param warmToc true = 连目录一起爬（点「切换」即可命中，代价是 10+ 次请求）；
 *                false = 只补一次 `bookInfo`（填行内最新章节，代价 1 次请求）。
 * @param onInfo 详情回来后的回调（面板据此把行内文案从「未提供」换成「最新：xxx」）。
 * @param onToc 目录体检回来后的回调（仅 `warmToc` 且目录非空/非失败时会触发，
 *              面板据此给候选行加徽标；`false` 的候选永远不体检）。
 */
export function previewCandidate(
  source: BookSource,
  item: BookSearchItem,
  onInfo: (info: Book) => void,
  warmToc: boolean,
  onToc: (quality: TocQuality) => void = () => {
  }
): void {
  if (warmToc) {
    runWarm(source, item, onInfo, onToc);
    return;
  }
  const key: string = keyOf(source.bookSourceUrl, item.bookUrl);
  for (const job of fills) {
    if (job.key === key) {
      return;
    }
  }
  fills.push({ key: key, source: source, item: item, onInfo: onInfo });
  pumpFills();
}

/** 切换开始 / 新一轮检索时调用：清掉未派发的详情补全（在飞的无法取消，最多 1 条）。 */
export function dropQueuedPrefetch(): void {
  fills.splice(0, fills.length);
}

/** 预热好的详情；空 = 没预热过/已过期，调用方照旧打网络。 */
export function takePrefetchedInfo(sourceUrl: string, bookUrl: string): Book | undefined {
  const key: string = keyOf(sourceUrl, bookUrl);
  const info: Book | undefined = infoCache.get(key);
  if (info === undefined || !fresh(infoAt.get(key))) {
    return undefined;
  }
  return info;
}

/** 预热好的目录（要求 `tocUrl` 与当前详情一致，否则视为过期）。 */
export function takePrefetchedToc(
  sourceUrl: string,
  bookUrl: string,
  tocUrl: string
): Chapter[] | undefined {
  const entry: PrefetchedToc | undefined = tocCache.get(keyOf(sourceUrl, bookUrl));
  if (entry === undefined || entry.tocUrl !== tocUrl || !fresh(entry.at)) {
    return undefined;
  }
  return entry.chapters;
}
