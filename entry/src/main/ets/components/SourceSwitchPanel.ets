import { common } from '@kit.AbilityKit';
import { bookEngine } from '../engine/BookEngineNapi';
import { Book, BookSearchItem, BookSource } from '../engine/types';
import {
  dedupeRowsByUrl,
  getSource,
  listRows,
  sortRowsByConfidence,
  SourceRow
} from '../model/SourceStore';
import { ensureSourceStore } from '../model/SourceStoreMigration';
import { isSameBook } from '../model/SourceSwitch';
import { dropQueuedPrefetch, previewCandidate } from '../model/SourcePrefetch';
import { cleanChapter } from '../common/Format';

/** 单源搜索超时：真机实测 13 个内置源最慢 2.0s，6s 足够；死源罚站一整轮的代价要压住。 */
const SEARCH_TIMEOUT_MS: number = 6_000;
/** 滑动窗口宽度：候选搜索是「一源一次 search」，并发太多会同时压垮小站。 */
const SWITCH_CONCURRENCY: number = 6;
/** 检索总预算：超预算只停「派发新源」，已派发的照旧收结果（用户等的是结果，不是穷举）。 */
const SEARCH_BUDGET_MS: number = 10_000;
/** 候选够用即提前收尾：面板要的是「能切的其它源」，不是把 13 个源全扫完。 */
const EARLY_STOP_ROWS: number = 3;
/** 预热目录的候选个数：一个候选 = 一次完整目录爬取（bbiquge8《剑来》实为 13 页 / 5.9s）。 */
const WARM_TOC_LIMIT: number = 2;
/** 候选结果会话缓存：刚搜过的书重开抽屉直接上屏，不再白等一轮 3.3s。 */
const CACHE_TTL_MS: number = 30 * 60 * 1000;

/** 换源抽屉的一行 = 「某个书源收录了这本书」。 */
interface SwitchRow {
  /** 稳定 key：同一源可能返回多条同名结果，不能只用 URL。 */
  key: string;
  source: BookSource;
  item: BookSearchItem;
  label: string;
  confidence: number;
  chapter: string;
  current: boolean;
}

/** 候选结果缓存（模块级：抽屉重开时还在，30 分钟内有效）。 */
interface CachedSearch {
  at: number;
  /** 书源集合指纹：书源增删/改配置后缓存立即失效。 */
  signature: string;
  rows: SwitchRow[];
  scanned: number;
  total: number;
}

let cachedSearch: CachedSearch | undefined = undefined;

function hostOf(url: string): string {
  const m: RegExpMatchArray | null = url.trim().toLowerCase().match(/^[a-z][a-z0-9+.-]*:\/\/([^/?#]+)/);
  return m !== null ? m[1] : '';
}

/**
 * 同域去重：`m.bbiquge8.net` 在书源列表里有两条（`bbiquge8` / `笔趣阁8`，
 * `bookSourceUrl` 一字不差），投影行按 URL 去重已能吃掉完全同 URL 的那种；
 * 这里再按 **域名 + 搜索模板** 兜一层，覆盖「同一站点两个入口」（http/https、
 * 镜像域名不同路径首页）——同一个站搜两遍没有意义，只会多一倍流量和重复行。
 */
function siteKeyOf(source: BookSource): string {
  const key: string = hostOf(source.bookSourceUrl) + '|' + (source.searchUrl ?? '').trim();
  return key === '|' ? '' : key;
}

/** 书源集合指纹（顺序无关：书源管理页重排不该让缓存失效）。 */
function signatureOf(rows: SourceRow[]): string {
  const keys: string[] = rows.map((r: SourceRow): string =>
    r.id.toString() + '\u0000' + r.url + '\u0000' + r.name).sort();
  return keys.join('\u0001');
}

function makeRow(
  source: BookSource,
  item: BookSearchItem,
  seq: number,
  currentSourceUrl: string,
  chapter: string,
  confidence: number
): SwitchRow {
  return {
    key: source.bookSourceUrl + '#' + seq.toString(),
    source: source,
    item: item,
    label: source.bookSourceName.length > 0 ? source.bookSourceName : source.bookSourceUrl,
    confidence: confidence,
    chapter: chapter,
    current: source.bookSourceUrl === currentSourceUrl
  };
}

/** 只换行内文案，保持 `key` 字段稳定（预热回填时用；列表的 `ForEach` key **另加 chapter**，见列表处的注释）。 */
function withChapter(r: SwitchRow, chapter: string): SwitchRow {
  return {
    key: r.key,
    source: r.source,
    item: r.item,
    label: r.label,
    confidence: r.confidence,
    chapter: chapter,
    current: r.current
  };
}

/**
 * 换源抽屉内容（阅读页专用）：跨源检索同名书 → 列出候选 → 交给宿主执行切换。
 *
 * 搜索是**渐进**的（`SourceResultPage` 同款滑动窗口：每源一次 `search` 调用，
 * 谁先回来谁先上屏），因为聚合调用要等最慢的源到超时，抽屉会长时间空白。
 * 用户在等结果，所以只按下面三条收着来，不做穷举：
 * ① 单源超时 6s；② 全局派发预算 10s；③ 候选够 3 条即收尾（文案里说明原因）。
 *
 * **预热**（`SourcePrefetch`）：行一上屏就顺手把「最靠前的 2 个候选」的详情+目录爬好，
 * 其余候选只补一次 `bookInfo` 用来填行内「最新：xxx」（原来这里恒显「该源无最新章节规则」，
 * 因为换源面板不像搜索结果页有详情缓存可回退）。点「切换」时若命中预热，宿主那 7s 直接省掉。
 *
 * 文案分工：候选数由 `onCount` 上报宿主拼进抽屉标题（「换源 · N 个候选」，与搜索结果
 * 「选择来源 · N」同规格），内容区顶部只剩进度行（**始终占位**：检索中显示 x/y，检索完留空，
 * 避免列表在搜索结束时上跳）；当前源不用文字徽标，而是行首品牌色竖条 + 品牌色源名（见 `row`）。
 *
 * 组件常驻挂载（BottomDrawer 规范）：`runToken` 每次打开自增，`@Monitor` 里重读书源
 * 列表并重新搜索；`busy` 变 true（用户点了「切换」）就**停派发 + 丢在飞结果 + 清预热队列**，
 * 别和刚刚开始的目录翻页抢带宽。
 */
@ComponentV2
export struct SourceSwitchPanel {
  /** 每次抽屉打开自增；0 = 尚未打开过。 */
  @Param runToken: number = 0;
  @Param book: Book | undefined = undefined;
  @Param currentSourceUrl: string = '';
  @Param currentSourceName: string = '';
  @Param textColor: ResourceColor = Color.Black;
  @Param dimColor: ResourceColor = Color.Gray;
  /** 宿主正在执行切换：列表整体不可点，避免连点两次。 */
  @Param busy: boolean = false;
  /** 候选行数上报：宿主拼进抽屉标题（检索中会随上屏逐次上报）。 */
  @Event onCount: (count: number) => void = () => {};
  @Event onPick: (source: BookSource, item: BookSearchItem) => void = () => {};

  @Local rows: SwitchRow[] = [];
  @Local searching: boolean = false;
  @Local scanned: number = 0;
  @Local total: number = 0;
  /** 本轮提前收尾的原因（'候选已够用' / '已超时收尾'），拼进进度行。 */
  @Local earlyNote: string = '';
  /** 当前 rows 来自会话缓存（不是本轮检索的结果）→ 进度行给一个「重新检索」。 */
  @Local fromCache: boolean = false;

  private ctx: common.UIAbilityContext | undefined = undefined;
  private sources: SourceRow[] = [];
  private rowByUrl: Map<string, SourceRow> = new Map<string, SourceRow>();
  /** 已派发过的站点（域名 + 搜索模板）；完整规则等到真正搜索时才按行读取。 */
  private searchedSites: Set<string> = new Set<string>();
  /** 搜索代次：新一次搜索/页面离开后，旧结果直接丢弃。 */
  private gen: number = 0;
  private reloadGen: number = 0;
  private nextIndex: number = 0;
  private startedAt: number = 0;
  /** 提前收尾后不再派发新源（在飞的结果仍会收）。 */
  private dispatchStopped: boolean = false;
  /** 已排过预热的候选（源|书 URL），避免同一行反复入队。 */
  private asked: Set<string> = new Set<string>();
  /** 已用掉的「详情+目录」预热名额（上限 `WARM_TOC_LIMIT`）。 */
  private warmed: number = 0;

  aboutToAppear(): void {
    this.ctx = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    this.reloadProjection();
  }

  @Monitor('runToken')
  onRunTokenChange(): void {
    if (this.runToken <= 0) {
      return;
    }
    this.reloadAndSearch(this.runToken);
  }

  /** 用户点了「切换」：停止派发、丢弃在飞结果、清掉未派发的预热。 */
  @Monitor('busy')
  onBusyChange(): void {
    if (!this.busy) {
      return;
    }
    this.gen = this.gen + 1;
    this.dispatchStopped = true;
    this.searching = false;
    dropQueuedPrefetch();
  }

  /**
   * 继续把剩下的源搜完（提前收尾后才出现）：提前收尾只是「不再等」，不是「不再要」，
   * 所以留一条回头路 —— 否则用户永远看不到第 4 个以后的候选。
   */
  private resumeSearch(): void {
    const book: Book | undefined = this.book;
    if (book === undefined || this.busy) {
      return;
    }
    this.gen = this.gen + 1;
    const gen: number = this.gen;
    this.dispatchStopped = false;
    this.earlyNote = '';
    this.fromCache = false;
    this.searching = true;
    this.startedAt = Date.now();
    const left: number = Math.max(1, this.sources.length - this.nextIndex);
    const window: number = Math.min(SWITCH_CONCURRENCY, left);
    for (let w = 0; w < window; w++) {
      this.drain(gen, book);
    }
  }

  /** 每次打开都重读书源：期间可能在书源管理页导入/删除了源。 */
  private async reloadProjection(): Promise<void> {
    const ctx: common.UIAbilityContext | undefined = this.ctx;
    if (ctx === undefined) {
      return;
    }
    this.reloadGen = this.reloadGen + 1;
    const gen: number = this.reloadGen;
    let rows: SourceRow[] = [];
    try {
      await ensureSourceStore(ctx);
      rows = await listRows({ enabled: true });
    } catch (err) {
      // A store failure leaves the panel empty; switching never falls back to the legacy blob.
    }
    if (gen !== this.reloadGen) {
      return;
    }
    this.sources = dedupeRowsByUrl(sortRowsByConfidence(rows));
    this.rowByUrl.clear();
    for (const row of this.sources) {
      this.rowByUrl.set(row.url, row);
    }
  }

  private async reloadAndSearch(token: number): Promise<void> {
    await this.reloadProjection();
    if (token !== this.runToken || this.busy) {
      return;
    }
    this.startSearch();
  }

  private confidenceFor(url: string, fallback: number): number {
    const row: SourceRow | undefined = this.rowByUrl.get(url);
    return row === undefined ? fallback : row.confidence;
  }

  /** 刚搜过的同一本书 + 同一批书源 → 直接上屏缓存（30 分钟内）。 */
  private restoreCache(): boolean {
    const cached: CachedSearch | undefined = cachedSearch;
    if (cached === undefined || Date.now() - cached.at > CACHE_TTL_MS) {
      return false;
    }
    if (cached.signature !== signatureOf(this.sources) || cached.rows.length === 0) {
      return false;
    }
    this.gen = this.gen + 1;
    const gen: number = this.gen;
    this.rows = cached.rows.map((r: SwitchRow, i: number): SwitchRow =>
      makeRow(r.source, r.item, i, this.currentSourceUrl, r.chapter, this.confidenceFor(r.source.bookSourceUrl, r.confidence)));
    this.scanned = cached.scanned;
    this.total = cached.total;
    this.searching = false;
    this.dispatchStopped = true;
    this.earlyNote = '';
    this.fromCache = true;
    this.onCount(this.rows.length);
    this.queuePrefetch(gen, this.rows);
    return true;
  }

  /**
   * `forceFresh` = 用户点了「重新检索」（缓存不认账，重搜一遍）；面板每次打开走默认值，命中缓存就秒上屏。
   */
  private startSearch(forceFresh: boolean = false): void {
    this.gen = this.gen + 1;
    const gen: number = this.gen;
    this.rows = [];
    this.scanned = 0;
    this.nextIndex = 0;
    this.total = this.sources.length;
    this.earlyNote = '';
    this.fromCache = false;
    this.dispatchStopped = false;
    this.asked.clear();
    this.searchedSites.clear();
    this.warmed = 0;
    this.startedAt = Date.now();
    // 标题里的候选数不在本轮开头归零：宿主在 `openPanel` 里已重置为 0（`Reader.switchCount`），
    // 这里只在结果上屏时递增上报（避免在 `@Monitor` 回调里回写宿主状态）。
    const book: Book | undefined = this.book;
    if (book === undefined || book.name.trim().length === 0 || this.sources.length === 0) {
      this.searching = false;
      return;
    }
    if (!forceFresh && this.restoreCache()) {
      return;
    }
    this.searching = true;
    const window: number = Math.min(SWITCH_CONCURRENCY, this.sources.length);
    for (let w = 0; w < window; w++) {
      this.drain(gen, book);
    }
  }

  /** 窗口协程：取下一个源，搜完一个补下一个，直到派发完/预算用完/候选够用/被替换。 */
  private async drain(gen: number, book: Book): Promise<void> {
    while (gen === this.gen && !this.dispatchStopped) {
      if (this.rows.length >= EARLY_STOP_ROWS) {
        this.finishSearch('候选已够用');
        return;
      }
      if (Date.now() - this.startedAt >= SEARCH_BUDGET_MS) {
        this.finishSearch('已超时收尾');
        return;
      }
      const i: number = this.nextIndex;
      if (i >= this.sources.length) {
        return;
      }
      this.nextIndex = i + 1;
      await this.searchOne(gen, book, this.sources[i]);
    }
  }

  private finishSearch(note: string): void {
    this.dispatchStopped = true;
    this.earlyNote = note;
    this.searching = false;
    this.saveCache();
  }

  private async searchOne(gen: number, book: Book, row: SourceRow): Promise<void> {
    let loaded: BookSource | undefined = undefined;
    try {
      loaded = await getSource(row.id);
    } catch (err) {
      loaded = undefined;
    }
    if (gen !== this.gen) {
      return;
    }
    let items: BookSearchItem[] = [];
    if (loaded !== undefined) {
      const source: BookSource = loaded;
      const sourceSite: string = siteKeyOf(source);
      if (sourceSite.length === 0 || !this.searchedSites.has(sourceSite)) {
        if (sourceSite.length > 0) {
          this.searchedSites.add(sourceSite);
        }
        try {
          const result = await bookEngine.search([source], book.name, {
            timeoutMs: SEARCH_TIMEOUT_MS,
            concurrency: 1
          });
          items = result.items;
        } catch (err) {
          // 单源失败不影响其余候选：这一源就是「没收录/不可用」。
          items = [];
        }
      }
      if (gen !== this.gen) {
        return;
      }
      const added: SwitchRow[] = [];
      const sites: Set<string> = new Set<string>();
      for (const r of this.rows) {
        sites.add(hostOf(r.item.bookUrl.length > 0 ? r.item.bookUrl : r.item.sourceUrl));
      }
      for (const it of items) {
        if (!isSameBook(book, it)) {
          continue;
        }
        // 同域去重：同一个站已经有候选了就不再排一行。
        const site: string = hostOf(it.bookUrl.length > 0 ? it.bookUrl : it.sourceUrl);
        if (site.length > 0 && sites.has(site)) {
          continue;
        }
        sites.add(site);
        added.push(makeRow(source, it, this.rows.length + added.length, this.currentSourceUrl,
          cleanChapter(it.lastChapter), row.confidence));
      }
      if (added.length > 0) {
        this.rows = this.rows.concat(added);
        this.onCount(this.rows.length);
        this.queuePrefetch(gen, added);
        this.saveCache();
      }
    }
    this.scanned = this.scanned + 1;
    if (this.scanned >= this.total) {
      this.searching = false;
      this.saveCache();
    }
  }

  /**
   * 预热：最靠前的 `WARM_TOC_LIMIT` 个候选连目录一起爬（点「切换」即命中），
   * 其余候选只补一次 `bookInfo` 填行内最新章节（串行派发，见 `SourcePrefetch`）。
   */
  private queuePrefetch(gen: number, rows: SwitchRow[]): void {
    for (const r of rows) {
      if (r.current) {
        continue;
      }
      const key: string = r.source.bookSourceUrl + '|' + r.item.bookUrl;
      if (this.asked.has(key)) {
        continue;
      }
      this.asked.add(key);
      const warm: boolean = this.warmed < WARM_TOC_LIMIT;
      if (warm) {
        this.warmed = this.warmed + 1;
      }
      previewCandidate(r.source, r.item, (info: Book): void => {
        this.fillChapter(gen, r.key, info.lastChapterTitle);
      }, warm);
    }
  }

  /** 预热回来的详情：只补空着的行内文案（用户手快先点了切换也算命中）。 */
  private fillChapter(gen: number, key: string, raw: string): void {
    if (gen !== this.gen) {
      return;
    }
    const chapter: string = cleanChapter(raw);
    if (chapter.length === 0) {
      return;
    }
    let hit: boolean = false;
    this.rows = this.rows.map((r: SwitchRow): SwitchRow => {
      if (r.key !== key || r.chapter.length > 0) {
        return r;
      }
      hit = true;
      return withChapter(r, chapter);
    });
    if (hit) {
      this.saveCache();
    }
  }

  private saveCache(): void {
    if (this.rows.length === 0) {
      return;
    }
    cachedSearch = {
      at: Date.now(),
      signature: signatureOf(this.sources),
      rows: this.rows,
      scanned: this.scanned,
      total: this.total
    };
  }

  /** 当前源若本轮没被检索到，固定补一行「我在哪」，避免抽屉里完全失去当前位置。 */
  private showCurrentFallback(): boolean {
    if (this.searching || this.currentSourceName.length === 0) {
      return false;
    }
    return !this.rows.some((r: SwitchRow): boolean => r.current);
  }

  /** 检索进度文案；候选总数不在这里（已上移到标题栏）。 */
  private progressText(): string {
    if (this.fromCache) {
      return '上次检索到的 ' + this.rows.length.toString() + ' 个候选';
    }
    const progress: string = '已检索 ' + this.scanned.toString() + '/' + this.total.toString() + ' 个书源';
    if (this.searching) {
      return progress;
    }
    if (this.earlyNote.length > 0) {
      return progress + ' · ' + this.earlyNote;
    }
    // 非检索中返回一个空格（而不是空串）：保证这一行仍是满行高，不塌成 16vp。
    return ' ';
  }

  // 与搜索结果页「选择来源」的状态行同一规格：12fp、次要色、上下 padding 8。
  // 检索完仍留这一行（文本为空），保证列表不会在搜索结束时上跳。
  // 缓存命中时右侧多一个「重新检索」（缓存不是「结果」，得给用户一条重来的路）。
  @Builder
  statusBar() {
    Row() {
      Text(this.progressText())
        .fontSize(12)
        .fontColor(this.dimColor)
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      if (this.fromCache) {
        Text('重新检索')
          .fontSize(12)
          .fontColor($r('app.color.brand'))
          .padding({ left: 12, top: 2, bottom: 2 })
          .onClick(() => {
            if (this.busy) {
              return;
            }
            this.startSearch(true);
          })
      }
      if (!this.fromCache && this.earlyNote.length > 0 && this.nextIndex < this.sources.length) {
        Text('继续检索')
          .fontSize(12)
          .fontColor($r('app.color.brand'))
          .padding({ left: 12, top: 2, bottom: 2 })
          .onClick(() => {
            this.resumeSearch();
          })
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ top: 8, bottom: 8 })
  }

  @Builder
  currentFallbackRow() {
    Row() {
      Row()
        .width(3)
        .height(36)
        .borderRadius(2)
        .backgroundColor($r('app.color.brand'))
        .margin({ right: 8 })

      Column({ space: 3 }) {
        Text(this.currentSourceName)
          .fontSize(15)
          .fontColor($r('app.color.brand'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text('本轮检索未返回当前源')
          .fontSize(12)
          .fontColor(this.dimColor)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Text('当前')
        .fontSize(13)
        .fontColor(this.dimColor)
        .padding({ left: 10, right: 10 })
    }
    .width('100%')
    .height(60)
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  row(r: SwitchRow) {
    Row() {
      // 当前源标记槽：品牌色竖条；其余行留同宽透明占位，保证所有源名左对齐。
      // 不用「当前源」文字徽标，也不加整行底色（12% 品牌底色真机观感脏）：靠竖条 + 品牌色源名。
      Row()
        .width(3)
        .height(36)
        .borderRadius(2)
        .backgroundColor(r.current ? $r('app.color.brand') : Color.Transparent)
        .margin({ right: 8 })

      Column({ space: 3 }) {
        Row() {
          Text(r.label)
            .fontSize(15)
            .fontColor(r.current ? $r('app.color.brand') : this.textColor)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Blank()
          Text('置信 ' + r.confidence.toString())
            .fontSize(11)
            .fontColor(this.dimColor)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        // 空 = 该源的搜索规则里没有 `lastChapter`，或检索还没回填（上屏即预热详情，
        // 通常几百毫秒后这行会变成「最新：xxx」）—— 不是源故障。
        Text(r.chapter.length > 0 ? '最新：' + r.chapter : '（该源未提供最新章节）')
          .fontSize(12)
          .fontColor(this.dimColor)
          .width('100%')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      if (!r.current) {
        Text(this.busy ? '切换中' : '切换')
          .fontSize(13)
          .fontColor(this.busy ? this.dimColor : $r('app.color.brand'))
          .padding({ left: 10, right: 10, top: 6, bottom: 6 })
      }
    }
    .width('100%')
    // 定高 60vp：「选择来源」同一行规格，且虚拟化按定高估算可视区。
    // 当前源靠行首竖条 + 品牌色源名区分（刻意不加整行高亮底色）。
    .height(60)
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      if (this.busy || r.current) {
        return;
      }
      this.onPick(r.source, r.item);
    })
  }

  build() {
    Column() {
      // 进度行常驻（检索完只有空文本）：避免检索结束时列表上跳约 33vp。
      // 这一行下面**不画分割线**（真机上紧贴标题栏分割线的第二条横线观感多余）。
      this.statusBar()

      if (this.showCurrentFallback()) {
        this.currentFallbackRow()
      }

      if (this.rows.length === 0) {
        Column() {
          if (this.searching) {
            LoadingProgress()
              .width(36)
              .height(36)
              .color($r('app.color.brand'))
            Text('正在检索同名书…')
              .fontSize(13)
              .fontColor(this.dimColor)
              .margin({ top: 10 })
          } else if (this.total === 0) {
            Text('没有启用的书源')
              .fontSize(14)
              .fontColor(this.dimColor)
            Text('到「书源管理」启用至少一个书源')
              .fontSize(12)
              .fontColor(this.dimColor)
              .margin({ top: 8 })
          } else {
            Text('没有其它书源收录这本书')
              .fontSize(14)
              .fontColor(this.dimColor)
            Text('换源按书名 + 作者精确匹配；换个源名试试搜索页')
              .fontSize(12)
              .fontColor(this.dimColor)
              .margin({ top: 8 })
          }
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        List({ space: 0 }) {
          // key **必须带上会变的字段**（这里：预热回填的 `chapter`）：ArkUI 的 ForEach 按 key 复用子组件，
          // key 不变就不重建 —— 只换数组里的对象（`this.rows = rows.map(...)`）不会刷新行内文案。
          // 真机踩过：预热拿到「第83章 今日无事」、日志显示已回调，界面上那一行仍是占位文案。
          ForEach(this.rows, (r: SwitchRow) => {
            ListItem() {
              this.row(r)
            }
          }, (r: SwitchRow) => r.key + '|' + r.chapter)
        }
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .layoutWeight(1)
  }
}
