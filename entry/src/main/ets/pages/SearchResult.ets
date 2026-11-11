// ─── 文件索引（改本文件先看这里；本文件约 1041 行）──────────────────────────
// 下面只列**成员名**，不列行号（行号会漂）；定位用 `grep -n "<名字>" entry/src/main/ets/pages/SearchResult.ets`。
//   状态（@Local/@Param）：keyword / searchToken / groups / statuses / searching / total / enriching /
//                          statusVisible / shelfKeys / pickerVisible / pickerDs / expandedReason
//   搜索主流程（滑动窗口 + 并发 8 + 每源超时，见 docs/decisions.md D4）：
//     aboutToAppear / onSearchTokenChange（@Monitor）/ startSearch / drain / searchOne / searchGen（代次守卫）/ nextIndex
//   富化与合并：enrichMerged / enrichOne / infoCache / scheduleRebuild / cancelScheduledRebuild / rebuildGroups / bucketOf /
//               weightOf / metaLine / primaryOrigin（`作者：`/`最新章节：` 前缀清洗在 common/Format）
//   置信度（失败扣分/成功回分，持久化）：persistConfidence / confidenceLabel / failLabel / sourceSummary /
//                                        okCount / failCount / successPct / elapsedLabel
//   来源抽屉（状态/原因分组）：preparePicker / statusGroups / statusesOfReason / statusesOfGroup / statusRows /
//                              statusRowKey / isGroupExpanded / pickerRowView / pickerContent / statusSummary /
//                              statusGroupHeader / statusSourceRow / statusContent / statusFooter
//   行与跳转：resultItem / isInShelf / loadShelfKeys / shelfKey / handleTap / open / chapterNo /
//             pickerSubtitle / hostOf / pickOrigin
//   @Builder 子视图：searchBanner / statusSummary / statusContent / pickerContent / resultItem / build
// ──────────────────────────────────────────────────────────────────────

import { common } from '@kit.AbilityKit';
import { bookEngine } from '../engine/BookEngineNapi';
import { Book, BookSearchItem, BookSource, SourceStatus } from '../engine/types';
import { BookCover } from '../components/BookCover';
import { EmptyView } from '../components/EmptyView';
import {
  confidenceAfterStatus,
  ConfidenceUpdate,
  dedupeRowsByUrl,
  getSource,
  listRows,
  patchConfidences,
  penaltyFor,
  sortRowsByConfidence,
  SourceRow
} from '../model/SourceStore';
import { ensureSourceStore } from '../model/SourceStoreMigration';
import { getBooks } from '../model/ShelfRepository';
import { BottomDrawer } from '../ui/common/BottomDrawer';
import { PickerRow, SourceListDataSource } from '../common/SourceListDataSource';
import { cleanAuthor, cleanChapter } from '../common/Format';
import { ENGINE_INFO_TIMEOUT_MS } from '../common/Const';

const SEARCH_TIMEOUT_MS: number = 10_000;
/** 搜索并发上限：由 Rust `buffer_unordered` 按输入顺序调度（高置信先执行）。 */
const SEARCH_CONCURRENCY: number = 8;
/**
 * 逐源结果合并成一次全量重建的节流窗口。`rebuildGroups` 的代价与已累积条目数成正比，
 * 每源都重建在 3000 源场景是 O(源数²)，所以只置脏、按窗口合并。
 */
const MERGE_REBUILD_MS: number = 150;

/** Same name + author from several sources merged into one list entry. */
interface SearchGroup {
  name: string;
  author: string;
  coverUrl: string;
  /** Source that supplied `coverUrl` (its headers/referer are needed to fetch it). */
  coverSourceUrl: string;
  intro: string;
  lastChapter: string;
  origins: BookSearchItem[];
  weight: number;
  /** 0 = exact keyword match, 1 = contains, 2 = other. */
  bucket: number;
}

/**
 * One render row in the source-status drawer. Flattened so a single lazy `List`
 * can drive group headers and their (item-by-item) sources without materializing
 * thousands of rows up front.
 */
interface StatusRow {
  kind: string; // 'source' | 'reason' | 'ok'
  status?: SourceStatus;
  reason?: string;
  label?: string;
  count?: number;
  /** 源行的稳定唯一 key。不能用 `sourceUrl`：两个书源可以指向同一 URL（重复导入），
   *  同 key 会被 ForEach 静默去重 → 「3 源」只渲染出 2 行。 */
  id?: string;
}

@ComponentV2
export struct SearchResultPage {
  @Param keyword: string = '';
  @Param searchToken: number = 0;
  @Event onOpenDetail: (source: BookSource, item: BookSearchItem) => void = () => {};

  @Local searchKey: string = '';
  @Local groups: SearchGroup[] = [];
  @Local statuses: SourceStatus[] = [];
  @Local searching: boolean = false;
  @Local total: number = 0;
  @Local enriching: boolean = false;
  @Local statusVisible: boolean = false;
  @Local shelfKeys: Set<string> = new Set<string>();
  @Local pickerVisible: boolean = false;
  // 选择来源抽屉：行数据在打开时物化一次（见 preparePicker）；列表**平铺**，无分组、无折叠、无搜索。
  @Local pickerDs: SourceListDataSource = new SourceListDataSource();
  @Local pickerTotal: number = 0;
  // 源状态抽屉：按置信度影响排序的「成功 / 失败原因」分组下钻，默认（及每次打开）全部收起。
  @Local expandedReason: string = '';
  @Local expandedOk: boolean = false;

  private ctx: common.UIAbilityContext | undefined = undefined;
  private sources: SourceRow[] = [];
  private rowByUrl: Map<string, SourceRow> = new Map<string, SourceRow>();
  private sourceMap: Map<string, BookSource> = new Map<string, BookSource>();
  private rawItems: BookSearchItem[] = [];
  /** 合并重建的定时器；`-1` = 空闲。见 `scheduleRebuild`。 */
  private rebuildTimer: number = -1;
  private searchGen: number = 0;
  private nextIndex: number = 0;
  private infoCache: Map<string, Book> = new Map<string, Book>();

  aboutToAppear(): void {
    const ctx: common.UIAbilityContext | undefined =
      this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    if (ctx === undefined) {
      return;
    }
    this.ctx = ctx;
    this.prepareSearch();
  }

  aboutToDisappear(): void {
    // 页面已离开：停掉还在派发的搜索（`drain` 的每轮循环都验代次），
    // 并撤掉挂起的合并窗口 —— 都不该再写已销毁组件的 @Local。
    this.searchGen = this.searchGen + 1;
    this.cancelScheduledRebuild();
  }

  private async prepareSearch(): Promise<void> {
    const token: number = this.searchToken;
    // A token change starts a new projection read; drop results from the previous search now.
    this.searchGen = this.searchGen + 1;
    const ctx: common.UIAbilityContext | undefined = this.ctx;
    if (ctx === undefined) {
      return;
    }
    let rows: SourceRow[] = [];
    try {
      await ensureSourceStore(ctx);
      rows = await listRows({ enabled: true });
    } catch (err) {
      // A store failure leaves search empty; never fall back to the legacy full JSON blob.
    }
    if (token !== this.searchToken) {
      return;
    }
    // 同一 URL 只请求一次。排序后保留置信度最高的一条，id 仍是该行的稳定存储主键。
    this.sources = dedupeRowsByUrl(sortRowsByConfidence(rows));
    this.rowByUrl.clear();
    this.sourceMap.clear();
    for (const row of this.sources) {
      this.rowByUrl.set(row.url, row);
    }
    this.total = this.sources.length;
    this.searchKey = this.keyword;
    this.loadShelfKeys();
    this.startSearch();
  }

  @Monitor('searchToken')
  onSearchTokenChange(): void {
    const kw: string = this.keyword.trim();
    if (kw.length === 0) {
      return;
    }
    this.prepareSearch();
  }

  private async startSearch(): Promise<void> {
    this.searchGen = this.searchGen + 1;
    const gen: number = this.searchGen;
    // 上一轮可能还有未落地的合并窗口：结果集即将被清空，先撤掉它。
    this.cancelScheduledRebuild();
    this.rawItems = [];
    this.groups = [];
    this.statuses = [];
    this.enriching = false;
    this.statusVisible = false;
    this.pickerVisible = false;
    this.pickerDs = new SourceListDataSource();
    this.pickerTotal = 0;
    this.expandedReason = '';
    this.expandedOk = false;
    this.searching = true;
    this.nextIndex = 0;
    // 每次搜索前按最新置信度排序，保证高置信源排在前面先被调度。
    this.sources = sortRowsByConfidence(this.sources);
    if (this.sources.length === 0) {
      this.searching = false;
      return;
    }
    // 滑动窗口：最多 SEARCH_CONCURRENCY 个源并行，完成一个补下一个。
    // 每个源结果回来立即渲染（rebuildGroups），高置信源先出、先上屏。
    const window: number = Math.min(SEARCH_CONCURRENCY, this.sources.length);
    for (let w = 0; w < window; w++) {
      this.drain(gen);
    }
  }

  /** 窗口协程：循环从滑动指针取下一个源搜索，直到全部派发完或被新搜索替换。 */
  private async drain(gen: number): Promise<void> {
    while (gen === this.searchGen) {
      const i: number = this.nextIndex;
      if (i >= this.sources.length) {
        return;
      }
      this.nextIndex = i + 1;
      await this.searchOne(this.sources[i], gen);
    }
  }

  private async searchOne(row: SourceRow, gen: number): Promise<void> {
    let status: SourceStatus = {
      sourceUrl: row.url,
      sourceName: row.name,
      ok: false,
      count: 0,
      error: 'timeout',
      elapsedMs: SEARCH_TIMEOUT_MS
    };
    try {
      const source: BookSource | undefined = await getSource(row.id);
      if (gen !== this.searchGen) {
        return;
      }
      if (source === undefined) {
        status.error = 'store_error';
      } else {
        this.sourceMap.set(row.url, source);
        const result = await bookEngine.search([source], this.searchKey, {
          timeoutMs: SEARCH_TIMEOUT_MS,
          concurrency: 1
        });
        if (gen !== this.searchGen) {
          return;
        }
        if (result.sources.length > 0) {
          status = result.sources[0];
        }
        if (result.items.length > 0) {
          // 逐源只累积 + 标脏：`rebuildGroups` 是 O(累积条目)，3000 源时每源重建会 O(源数²)。
          for (let k: number = 0; k < result.items.length; k++) {
            this.rawItems.push(result.items[k]);
          }
          this.scheduleRebuild();
        }
      }
    } catch (err) {
      status.error = 'network_error';
    }
    if (gen !== this.searchGen) {
      return;
    }
    const next: SourceStatus[] = this.statuses.slice();
    next.push(status);
    this.statuses = next;
    if (this.statuses.length === this.sources.length) {
      this.searching = false;
      // 收尾强制同步重建一次：窗口内最后几个源的结果不能等定时器（可能在页面离开后才到点）。
      this.cancelScheduledRebuild();
      this.rebuildGroups();
      await this.persistConfidence(this.statuses.slice());
      this.enrichMerged(gen);
    }
  }

  private async loadShelfKeys(): Promise<void> {
    const books: Book[] = await getBooks();
    const keys: Set<string> = new Set<string>();
    for (const b of books) {
      keys.add(this.shelfKey(b.name, b.author));
    }
    this.shelfKeys = keys;
  }

  private shelfKey(name: string, author: string): string {
    return name.trim() + '|' + author.trim();
  }

  /** 一轮搜索结束：只把投影置信度变化写回列，不重新解析或序列化任何书源 JSON。 */
  private async persistConfidence(statuses: SourceStatus[]): Promise<void> {
    const byUrl: Map<string, SourceStatus> = new Map<string, SourceStatus>();
    for (const status of statuses) {
      byUrl.set(status.sourceUrl, status);
    }
    const updates: ConfidenceUpdate[] = [];
    for (const row of this.sources) {
      const status: SourceStatus | undefined = byUrl.get(row.url);
      if (status === undefined) {
        continue;
      }
      const value: number = confidenceAfterStatus(row.confidence, status);
      if (value === row.confidence) {
        continue;
      }
      row.confidence = value;
      updates.push({ url: row.url, name: row.name, confidence: value });
      const loaded: BookSource | undefined = this.sourceMap.get(row.url);
      if (loaded !== undefined) {
        loaded.confidence = value;
      }
    }
    this.sources = sortRowsByConfidence(this.sources);
    this.rowByUrl.clear();
    for (const row of this.sources) {
      this.rowByUrl.set(row.url, row);
    }
    if (updates.length === 0) {
      return;
    }
    try {
      await patchConfidences(updates);
    } catch (err) {
      // Results are already rendered; the next round still uses the in-memory values.
    }
  }

  /**
   * Search rules rarely expose `intro`/`coverUrl`; for merged (multi-source)
   * rows only, fetch `bookInfo` once from the best origin to fill the gaps.
   */
  private async enrichMerged(gen: number): Promise<void> {
    const targets: SearchGroup[] = [];
    for (const g of this.groups) {
      if (g.origins.length > 1 && (g.intro.length === 0 || g.coverUrl.length === 0)) {
        targets.push(g);
      }
    }
    if (targets.length === 0) {
      return;
    }
    this.enriching = true;
    const batchSize: number = 4;
    for (let i = 0; i < targets.length; i += batchSize) {
      if (gen !== this.searchGen) {
        return;
      }
      const batch: SearchGroup[] = targets.slice(i, i + batchSize);
      await Promise.all(batch.map((g: SearchGroup) => this.enrichOne(g, gen)));
      if (gen !== this.searchGen) {
        return;
      }
      this.rebuildGroups();
    }
    this.enriching = false;
  }

  private async enrichOne(g: SearchGroup, gen: number): Promise<void> {
    const item: BookSearchItem = this.primaryOrigin(g);
    const source: BookSource | undefined = this.sourceMap.get(item.sourceUrl);
    if (source === undefined || this.infoCache.has(this.infoKey(item))) {
      return;
    }
    try {
      const info: Book = await bookEngine.bookInfo(source, item.bookUrl, ENGINE_INFO_TIMEOUT_MS);
      if (gen !== this.searchGen) {
        return;
      }
      this.infoCache.set(this.infoKey(item), info);
    } catch (err) {
      // Enrichment is best-effort: leave the row as-is on failure.
    }
  }

  private infoKey(item: BookSearchItem): string {
    return item.sourceUrl + '|' + item.bookUrl;
  }

  private primaryOrigin(g: SearchGroup): BookSearchItem {
    let best: BookSearchItem = g.origins[0];
    let bestWeight: number = -1;
    for (const o of g.origins) {
      const s: BookSource | undefined = this.sourceMap.get(o.sourceUrl);
      const w: number = s !== undefined && s.weight !== undefined ? s.weight : 0;
      if (w > bestWeight) {
        bestWeight = w;
        best = o;
      }
    }
    return best;
  }

  // ── Merge + sort (Legado `SearchModel.mergeItems` semantics) ───

  /**
   * 合并窗口：搜索期间逐源结果只把 `rawItems` 标脏，窗口到点才全量重建一次。
   * 结果仍在持续上屏（最多晚 150 ms），但避免了「每源一次全量分组 + 排序 + 整列表刷新」。
   */
  private scheduleRebuild(): void {
    if (this.rebuildTimer >= 0) {
      return;
    }
    this.rebuildTimer = setTimeout((): void => {
      this.rebuildTimer = -1;
      this.rebuildGroups();
    }, MERGE_REBUILD_MS);
  }

  /** 撤掉挂起的合并窗口（新一轮搜索 / 收尾同步重建 / 页面离开）。 */
  private cancelScheduledRebuild(): void {
    if (this.rebuildTimer >= 0) {
      clearTimeout(this.rebuildTimer);
      this.rebuildTimer = -1;
    }
  }

  private rebuildGroups(): void {
    const key: string = this.searchKey.trim();
    const map: Map<string, SearchGroup> = new Map<string, SearchGroup>();
    for (const item of this.rawItems) {
      const name: string = item.name.trim();
      const author: string = cleanAuthor(item.author);
      const cached: Book | undefined = this.infoCache.get(this.infoKey(item));
      const cover: string = item.coverUrl.length > 0
        ? item.coverUrl
        : (cached !== undefined ? cached.coverUrl : '');
      const intro: string = item.intro.trim().length > 0
        ? item.intro.trim()
        : (cached !== undefined ? cached.intro : '');
      const rawChapter: string = cleanChapter(item.lastChapter);
      const chapter: string = rawChapter.length > 0
        ? rawChapter
        : (cached !== undefined ? cached.lastChapterTitle : '');
      const id: string = name + '|' + author;
      let g: SearchGroup | undefined = map.get(id);
      if (g === undefined) {
        g = {
          name: name,
          author: author,
          coverUrl: cover,
          coverSourceUrl: cover.length > 0 ? item.sourceUrl : '',
          intro: intro,
          lastChapter: chapter,
          origins: [],
          weight: 0,
          bucket: 0
        };
        map.set(id, g);
      }
      g.origins.push(item);
      if (g.coverUrl.length === 0 && cover.length > 0) {
        g.coverUrl = cover;
        g.coverSourceUrl = item.sourceUrl;
      }
      if (g.intro.length === 0) {
        g.intro = intro;
      }
      if (g.lastChapter.length === 0) {
        g.lastChapter = chapter;
      }
    }
    const groups: SearchGroup[] = [];
    map.forEach((g: SearchGroup) => {
      g.bucket = this.bucketOf(g, key);
      g.weight = this.weightOf(g);
      groups.push(g);
    });
    groups.sort((a: SearchGroup, b: SearchGroup): number => {
      if (a.bucket !== b.bucket) {
        return a.bucket - b.bucket;
      }
      if (a.origins.length !== b.origins.length) {
        return b.origins.length - a.origins.length;
      }
      if (a.weight !== b.weight) {
        return b.weight - a.weight;
      }
      if (a.name !== b.name) {
        return a.name < b.name ? -1 : 1;
      }
      return 0;
    });
    this.groups = groups;
  }

  private bucketOf(g: SearchGroup, key: string): number {
    const name: string = g.name.trim();
    const author: string = g.author.trim();
    if (name === key || author === key) {
      return 0;
    }
    if ((key.length > 0 && name.includes(key)) || (key.length > 0 && author.includes(key))) {
      return 1;
    }
    return 2;
  }

  /** Some sources keep the label inside the extracted field, e.g. "作者：唐家三少". */
  private weightOf(g: SearchGroup): number {
    let max: number = 0;
    for (const o of g.origins) {
      const s: BookSource | undefined = this.sourceMap.get(o.sourceUrl);
      const w: number = s !== undefined && s.weight !== undefined ? s.weight : 0;
      if (w > max) {
        max = w;
      }
    }
    return max;
  }

  private isInShelf(g: SearchGroup): boolean {
    return this.shelfKeys.has(this.shelfKey(g.name, g.author));
  }

  private metaLine(g: SearchGroup): string {
    const author: string = g.author.length > 0 ? g.author : '佚名';
    if (g.lastChapter.length > 0) {
      return author + ' · ' + g.lastChapter;
    }
    return author;
  }

  // ── 选择来源（可含数百甚至数千个命中源）────────────────────────
  //
  // 打开时一次性物化「命中源 → PickerRow」（join 置信度），之后不再重算；
  // `build` 里不逐行查表。列表**平铺**：不分组（分组头/折叠已移除）、无搜索框，
  // 行由 `LazyForEach` 虚拟化，行定高 60vp。

  private preparePicker(g: SearchGroup): void {
    const rows: PickerRow[] = [];
    for (let i = 0; i < g.origins.length; i++) {
      const o: BookSearchItem = g.origins[i];
      const row: SourceRow | undefined = this.rowByUrl.get(o.sourceUrl);
      const chapter: string = cleanChapter(o.lastChapter);
      rows.push({
        key: o.sourceUrl + '|' + i.toString(),
        item: o,
        name: o.sourceName.length > 0 ? o.sourceName : o.sourceUrl,
        confidence: row !== undefined ? row.confidence : 100,
        chapter: chapter,
        chapterNo: this.chapterNo(chapter)
      });
    }
    // 各源进度差异是选源的主要依据 → 章节号大的排前面；再按置信度、源名，保证稳定。
    rows.sort((a: PickerRow, b: PickerRow): number => {
      if (a.chapterNo !== b.chapterNo) {
        return b.chapterNo - a.chapterNo;
      }
      if (a.confidence !== b.confidence) {
        return b.confidence - a.confidence;
      }
      if (a.name !== b.name) {
        return a.name < b.name ? -1 : 1;
      }
      return 0;
    });
    // 每次打开都用全新数据源：上一次的监听器已随关闭的模态层作废，
    // 复用旧实例通知时会命中已卸载的视图。
    this.pickerDs = new SourceListDataSource();
    this.pickerDs.setItems(rows);
    this.pickerTotal = rows.length;
  }

  /** 章节名里最后一段数字（`第12卷 第1234章 完` → 1234）；取不到为 0。 */
  private chapterNo(chapter: string): number {
    let value: number = 0;
    let run: number = 0;
    for (let i = 0; i < chapter.length; i++) {
      const ch: string = chapter.charAt(i);
      if (ch >= '0' && ch <= '9') {
        run = run * 10 + (ch.charCodeAt(0) - 48);
      } else {
        if (run > 0) {
          value = run;
        }
        run = 0;
      }
    }
    return run > 0 ? run : value;
  }

  /** 副标题：优先「最新章节」，源没给时退回域名（同名源太多时用于区分）。 */
  private pickerSubtitle(row: PickerRow): string {
    if (row.chapter.length > 0) {
      return '最新：' + row.chapter;
    }
    return this.hostOf(row.item.bookUrl.length > 0 ? row.item.bookUrl : row.item.sourceUrl);
  }

  private hostOf(url: string): string {
    let rest: string = url;
    const scheme: number = rest.indexOf('://');
    if (scheme >= 0) {
      rest = rest.substring(scheme + 3);
    }
    const slash: number = rest.indexOf('/');
    if (slash >= 0) {
      rest = rest.substring(0, slash);
    }
    return rest;
  }

  private pickOrigin(item: BookSearchItem): void {
    this.pickerVisible = false;
    this.open(item);
  }

  private handleTap(g: SearchGroup): void {
    if (g.origins.length === 1) {
      this.open(g.origins[0]);
      return;
    }
    this.preparePicker(g);
    this.pickerVisible = true;
  }

  private open(item: BookSearchItem): void {
    const source: BookSource | undefined = this.sourceMap.get(item.sourceUrl);
    if (source !== undefined) {
      this.onOpenDetail(source, item);
    }
  }

  // ── UI ────────────────────────────────────────────────────────

  private isSearching(): boolean {
    return this.searching || this.enriching;
  }

  private sourceSummary(): string {
    let ok: number = 0;
    for (const s of this.statuses) {
      if (s.ok) {
        ok += 1;
      }
    }
    return `源 ${ok}/${this.statuses.length} 成功`;
  }

  private confidenceLabel(status: SourceStatus): string {
    const row: SourceRow | undefined = this.rowByUrl.get(status.sourceUrl);
    return row === undefined ? '—' : row.confidence.toString();
  }

  /** Rust `FailReason` 短码 → 中文。与 rust/legado-engine/src/status.rs `fail_message` 保持同步。 */
  private failLabel(reason: string): string {
    switch (reason) {
      case 'no_results': return '未搜索到结果';
      case 'blocked': return '被站点拦截';
      case 'not_found': return '页面不存在';
      case 'rate_limited': return '请求过于频繁';
      case 'network_error': return '网络错误';
      case 'server_error': return '服务器错误';
      case 'timeout': return '超时';
      case 'builder_error': return '无法构建搜索请求';
      case 'http_error': return 'HTTP 错误';
      case 'needs_js': return '需要 JS（v1 不支持）';
      case 'needs_login': return '需要登录（v1 不支持）';
      default: return reason.length > 0 ? reason : '未知错误';
    }
  }

  private okCount(): number {
    let n: number = 0;
    for (const s of this.statuses) {
      if (s.ok) {
        n += 1;
      }
    }
    return n;
  }

  private failCount(): number {
    return this.statuses.length - this.okCount();
  }

  private successPct(): number {
    if (this.statuses.length === 0) {
      return 0;
    }
    return Math.round(this.okCount() * 100 / this.statuses.length);
  }

  private okStatuses(): SourceStatus[] {
    const arr: SourceStatus[] = [];
    for (const s of this.statuses) {
      if (s.ok) {
        arr.push(s);
      }
    }
    return arr;
  }

  /**
   * 组排序分 = 该组对置信度的「影响」（复用计分用的 `penaltyFor`）：
   * 成功为正向影响 → `1`（置顶）；`no_results` 等不计分 → `0`；其余为扣分负值。
   * 因此顺序为：成功 → 未搜索到 → 超时 → 网络错误 → 服务器错误 → 被拦截。
   */
  private groupScore(row: StatusRow): number {
    if (row.kind === 'ok') {
      return 1;
    }
    return -penaltyFor(row.reason ?? '');
  }

  /** 分组：成功组 + 失败源按错误原因聚合；按置信度影响从好到坏排序（成功置顶）。 */
  private statusGroups(): StatusRow[] {
    const map: Map<string, number> = new Map<string, number>();
    for (const s of this.statuses) {
      if (s.ok) {
        continue;
      }
      const reason: string = s.error.length > 0 ? s.error : 'unknown';
      map.set(reason, (map.get(reason) ?? 0) + 1);
    }
    const rows: StatusRow[] = [];
    rows.push({ kind: 'ok', count: this.okCount() });
    map.forEach((count: number, reason: string) => {
      rows.push({ kind: 'reason', reason: reason, label: this.failLabel(reason), count: count });
    });
    rows.sort((a: StatusRow, b: StatusRow): number => {
      const byScore: number = this.groupScore(b) - this.groupScore(a);
      if (byScore !== 0) {
        return byScore;
      }
      // 影响相同时源多的靠前，再退化到名称，保证顺序稳定。
      const byCount: number = (b.count ?? 0) - (a.count ?? 0);
      return byCount !== 0 ? byCount : (a.label ?? '').localeCompare(b.label ?? '');
    });
    return rows;
  }

  private statusesOfReason(reason: string): SourceStatus[] {
    const arr: SourceStatus[] = [];
    for (const s of this.statuses) {
      if (!s.ok && (s.error.length > 0 ? s.error : 'unknown') === reason) {
        arr.push(s);
      }
    }
    return arr;
  }

  /** 展平的渲染行：「组头 → （展开时）组内源」。默认全部收起。 */
  private statusRows(): StatusRow[] {
    const rows: StatusRow[] = [];
    for (const g of this.statusGroups()) {
      const reason: string = g.reason ?? '';
      const groupKey: string = g.kind === 'ok' ? 'ok' : reason;
      rows.push(g);
      // 组内保持 `statuses` 顺序（追加序 = 置信度降序的派发序），使行 key 稳定。
      const members: SourceStatus[] = this.isGroupExpanded(g) ? this.statusesOfGroup(g) : [];
      for (let i = 0; i < members.length; i++) {
        rows.push({ kind: 'source', status: members[i], id: 's:' + groupKey + '#' + i.toString() });
      }
    }
    return rows;
  }

  private isGroupExpanded(g: StatusRow): boolean {
    return g.kind === 'ok' ? this.expandedOk : this.expandedReason === (g.reason ?? '');
  }

  private statusesOfGroup(g: StatusRow): SourceStatus[] {
    return g.kind === 'ok' ? this.okStatuses() : this.statusesOfReason(g.reason ?? '');
  }

  private statusRowKey(row: StatusRow): string {
    if (row.kind === 'source') {
      return row.id ?? '';
    }
    // 把展开态编进 key：否则 ForEach 复用同 key 的组头，`expanded` 参数不会
    // 重新求值，chevron 会停在旧方向。
    if (row.kind === 'ok') {
      return 'g:ok' + (this.expandedOk ? ':o' : ':c');
    }
    const reason: string = row.reason ?? '';
    return 'g:' + reason + (this.expandedReason === reason ? ':o' : ':c');
  }

  private elapsedLabel(ms: number): string {
    if (ms <= 0) {
      return '';
    }
    if (ms < 1000) {
      return ms.toString() + 'ms';
    }
    return (ms / 1000).toFixed(1) + 's';
  }

  @Builder
  searchBanner() {
    Row({ space: 8 }) {
      if (this.isSearching()) {
        LoadingProgress()
          .width(14)
          .height(14)
          .color($r('app.color.brand'))
      }
      Text(this.isSearching() ? '正在搜索…结果仍在更新，排序可能变化' : `共 ${this.groups.length} 条结果`)
        .fontSize(12)
        .fontColor(this.isSearching() ? $r('app.color.text_3') : $r('app.color.text_4'))
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 8, bottom: 8 })
    .opacity(this.isSearching() ? 1 : 0.7)
    .animation({ duration: 260, curve: Curve.FastOutSlowIn })
  }

  @Builder
  resultItem(g: SearchGroup) {
    Row() {
      BookCover({
        source: this.sourceMap.get(g.coverSourceUrl.length > 0 ? g.coverSourceUrl : g.origins[0].sourceUrl),
        coverUrl: g.coverUrl,
        name: g.name,
        coverWidth: 84,
        coverHeight: 112,
        radius: 6
      })
      Column({ space: 4 }) {
        Text(g.name)
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.brand'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.metaLine(g))
          .fontSize(13)
          .fontColor($r('app.color.text_4'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(g.intro.length > 0 ? g.intro : '暂无简介')
          .fontSize(13)
          .fontColor($r('app.color.text_3'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Row() {
          if (g.origins.length > 1) {
            Text(g.origins.length.toString() + '个来源')
              .fontSize(11)
              .fontColor($r('app.color.text_4'))
          }
          if (this.isInShelf(g)) {
            Text('已在书架')
              .fontSize(11)
              .fontColor($r('app.color.brand'))
              .margin({ left: g.origins.length > 1 ? 8 : 0 })
          }
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .margin({ left: 12 })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
    .alignItems(VerticalAlign.Top)
    .onClick(() => this.handleTap(g))
  }

  @Builder
  statusSummary() {
    Column({ space: 8 }) {
      Row() {
        Text('成功率 ' + this.successPct().toString() + '%')
          .fontSize(13)
          .fontColor($r('app.color.text_2'))
        Blank()
        Text(this.statuses.length.toString() + ' 源')
          .fontSize(12)
          .fontColor($r('app.color.text_4'))
      }
      .width('100%')

      Stack({ alignContent: Alignment.Start }) {
        Row()
          .width('100%')
          .height(6)
          .borderRadius(3)
          .backgroundColor($r('app.color.bg_pill'))
        Row()
          .width(this.successPct().toString() + '%')
          .height(6)
          .borderRadius(3)
          .backgroundColor($r('app.color.success'))
      }
      .width('100%')

      Row({ space: 12 }) {
        Text(this.okCount().toString() + ' 成功')
          .fontSize(12)
          .fontColor($r('app.color.success'))
        Text(this.failCount().toString() + ' 失败')
          .fontSize(12)
          .fontColor($r('app.color.warning'))
        Blank()
      }
      .width('100%')
    }
    .width('100%')
    // 上 16vp：与标题栏分割线拉开（内容区本身无顶部内边距，见 UI-SPEC §1.5）；
    // 下 24vp：把统计区与下方分组列表分成两块（下方接 1px 分割线）。
    .padding({ top: 16, bottom: 24 })
  }

  @Builder
  statusGroupHeader(label: string, count: number, kind: string, reasonKey: string, expanded: boolean) {
    Row({ space: 8 }) {
      Row()
        .width(8)
        .height(8)
        .borderRadius(4)
        .backgroundColor(kind === 'ok' ? $r('app.color.success') : $r('app.color.warning'))
      Text(label)
        .fontSize(14)
        .fontColor($r('app.color.text_1'))
        .layoutWeight(1)
      Text(count.toString() + ' 源')
        .fontSize(12)
        .fontColor($r('app.color.text_4'))
      Text(expanded ? '▾' : '▸')
        .fontSize(14)
        .fontColor($r('app.color.text_4'))
    }
    .width('100%')
    .padding({ top: 14, bottom: 14 })
    .onClick(() => {
      if (kind === 'ok') {
        this.expandedOk = !this.expandedOk;
      } else {
        this.expandedReason = this.expandedReason === reasonKey ? '' : reasonKey;
      }
    })
  }

  @Builder
  statusSourceRow(status: SourceStatus) {
    // 不带状态色点：展开后整列都是点，干扰阅读（状态已由组头表达）。
    Row({ space: 8 }) {
      Text(status.sourceName.length > 0 ? status.sourceName : status.sourceUrl)
        .fontSize(13)
        .fontColor($r('app.color.text_2'))
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      if (status.ok) {
        Text(status.count.toString() + ' 条')
          .fontSize(12)
          .fontColor($r('app.color.success'))
      }
      Text('置信 ' + this.confidenceLabel(status))
        .fontSize(11)
        .fontColor($r('app.color.text_4'))
      if (status.elapsedMs > 0) {
        Text(this.elapsedLabel(status.elapsedMs))
          .fontSize(11)
          .fontColor($r('app.color.text_5'))
      }
    }
    .width('100%')
    .padding({ top: 10, bottom: 10 })
  }

  @Builder
  statusContent() {
    Column() {
      this.statusSummary()

      // 统计区与分组列表之间的分隔线（-16 与外层内容区的左右 padding 相抵消 → 通栏）。
      Divider()
        .color($r('app.color.divider'))
        .strokeWidth(1)
        .margin({ left: -16, right: -16 })

      List({ space: 0 }) {
        ForEach(this.statusRows(), (row: StatusRow) => {
          ListItem() {
            if (row.kind === 'source' && row.status !== undefined) {
              this.statusSourceRow(row.status)
            } else if (row.kind === 'reason' && row.reason !== undefined
              && row.label !== undefined && row.count !== undefined) {
              this.statusGroupHeader(row.label, row.count, 'reason', row.reason, this.expandedReason === row.reason)
            } else if (row.kind === 'ok' && row.count !== undefined) {
              this.statusGroupHeader('成功', row.count, 'ok', '', this.expandedOk)
            }
          }
        }, (row: StatusRow) => this.statusRowKey(row))
      }
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  pickerRowView(row: PickerRow) {
    Row({ space: 8 }) {
      Column({ space: 3 }) {
        Text(row.name)
          .fontSize(15)
          .fontColor($r('app.color.text_1'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.pickerSubtitle(row))
          .fontSize(12)
          .fontColor($r('app.color.text_4'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      Text('›')
        .fontSize(20)
        .fontColor($r('app.color.arrow'))
    }
    .width('100%')
    // 定高：`LazyForEach` 才能按固定行高估算可视区，滚动不抖。
    .height(60)
    .alignItems(VerticalAlign.Center)
    .onClick(() => this.pickOrigin(row.item))
  }

  @Builder
  pickerContent() {
    Column() {
      List() {
        LazyForEach(this.pickerDs, (row: PickerRow) => {
          ListItem() {
            this.pickerRowView(row)
          }
        }, (row: PickerRow) => row.key)
      }
      .layoutWeight(1)
      .width('100%')
      .divider({
        strokeWidth: 1,
        color: $r('app.color.divider'),
        startMargin: 16
      })
      .cachedCount(6)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  statusFooter() {
    Row() {
      Text(this.sourceSummary())
        .fontSize(12)
        .fontColor($r('app.color.text_4'))
      Blank()
      Text('源状态')
        .fontSize(12)
        .fontColor($r('app.color.brand'))
        .onClick(() => {
          this.statusVisible = true;
        })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 8, bottom: 8 })
  }

  build() {
    Stack() {
      Column() {
        if (this.groups.length === 0) {
          Column() {
            if (this.searching || this.enriching) {
              LoadingProgress()
                .width(40)
                .height(40)
                .color($r('app.color.brand'))
              Text('正在聚合书源…')
                .fontSize(14)
                .fontColor($r('app.color.text_4'))
                .margin({ top: 12 })
            } else {
              EmptyView({ title: '没有找到结果', desc: '换个关键词，或检查书源是否可用' })
            }
          }
          .layoutWeight(1)
          .width('100%')
          .justifyContent(FlexAlign.Center)
        } else {
          this.searchBanner()
          List({ space: 0 }) {
            ForEach(this.groups, (g: SearchGroup) => {
              ListItem() {
                Column() {
                  this.resultItem(g)
                  Divider()
                    .color($r('app.color.divider'))
                    .strokeWidth(1)
                    .margin({ left: 112 })
                }
              }
            }, (g: SearchGroup) => g.name + '|' + g.author + '|' + g.origins.length.toString() + '|' + g.lastChapter + '|' + g.coverUrl + '|' + g.intro)
          }
          .layoutWeight(1)
          .width('100%')
          .scrollBar(BarState.Off)
        }

        if (this.statuses.length > 0) {
          this.statusFooter()
        }
      }
      .width('100%')
      .height('100%')

      BottomDrawer({
        visible: this.statusVisible,
        title: '源状态',
        // Same size as the reader's table-of-contents drawer ('large' = 90%).
        sheetSize: 'large',
        // 'cover': drawn in the window layer so the panel covers the bottom tab
        // bar while the tab bar itself stays put (see UI-SPEC.md §1.2.1).
        mode: 'cover',
        onClose: () => {
          this.statusVisible = false;
          // 关闭即回到「全部收起」：下次打开不看上次的展开状态。
          // 必须在此处（内容仍挂载）复位；放到 `@Monitor('statusVisible')` 里会在
          // cover 模态层尚未挂载时报 `No views to update`。
          this.expandedReason = '';
          this.expandedOk = false;
        }
      }) {
        this.statusContent()
      }

      BottomDrawer({
        visible: this.pickerVisible,
        title: '选择来源 · ' + this.pickerTotal.toString(),
        sheetSize: 'large',
        mode: 'cover',
        onClose: () => {
          this.pickerVisible = false;
        }
      }) {
        this.pickerContent()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
  }
}
