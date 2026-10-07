// ─── 文件索引（改本文件先看这里；本文件约 1426 行）──────────────────────────
// 下面只列**成员名**，不列行号（行号会漂）；定位用 `grep -n "<名字>" entry/src/main/ets/pages/Reader.ets`。
//   状态（@Local）：chapters / chapterIndex / paragraphs / paragraphIndex / pages / pageIndex / sliderValue
//                   menuVisible / panel / tocDescending / fontSize / lineHeight / nightMode / oneHandMode / tts
//   生命周期：aboutToAppear / aboutToDisappear / onTtsProgress（@Monitor 听书进度 → 高亮 + 跟随滚动）
//   加载正文：loadToc / refreshToc / load / loadChapter / applyChapter / fetchContent / cachedContent / sanitize / warmNeighbors / prefetch
//   章内导航：isReadable / firstReadable / nextReadable / prevReadable / prevChapter / nextChapter / prevPage / nextPage / onPageChanged
//   分页测算（横向分页核心）：availWidthPx / availHeightPx / measureOptions / measureHeight / maxCharsFit / paraMargin
//                             paginateChapter / rebuildWindow / flatIndexOf / pageIdFor / indexOfPageId / PageSeg
//   进度持久化：persistProgress / locateCurrentToc / tocPosition
//   主题：systemDark / resolveColorHex / applyFullScreen / toggleNight / bgColor / textColor / dimColor
//         changeFont / changeLineHeight
//   跳转：onContentTap / onTopBack / openPanel / openDetail / openListening / moreMenuItems / isSpeaking
//   @Builder 子视图：topBar / bottomBar / contentPager（Swiper 分页）/ tocDrawerContent / settingsDrawerContent /
//                    iconButton / funcButton / moreButton / buildTocItems / readableCount / toggleTocOrder
// ──────────────────────────────────────────────────────────────────────

import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { bookEngine } from '../engine/BookEngineNapi';
import { Book, BookSource, Chapter, ReadProgress } from '../engine/types';
import { ChapterDataSource } from '../common/ChapterDataSource';
import { BookCover } from '../components/BookCover';
import { BottomDrawer } from '../ui/common/BottomDrawer';
import {
  KEY_READER_FONT_SIZE,
  KEY_READER_LINE_HEIGHT,
  KEY_READER_NIGHT,
  KEY_READER_ONE_HAND_PAGE,
  ListenParam,
  READER_FONT_SIZE_DEFAULT,
  READER_LINE_HEIGHT_DEFAULT,
  READER_NIGHT_DEFAULT,
  READER_ONE_HAND_PAGE_DEFAULT
} from '../common/Const';
import { getBoolean, getNumber, putBoolean, putNumber } from '../common/Prefs';
import {
  setLayoutFullScreen,
  setStatusBarContentColor,
  setWindowBackgroundColor
} from '../common/Window';
import { getProgress, saveProgress } from '../model/ShelfRepository';
import { ProgressWriter } from '../model/ProgressOwner';
import { protectBook } from '../model/CacheTrim';
import { ReaderTheme } from '../common/ReaderTheme';
import { getCachedChapter, putCachedChapter } from '../model/ChapterCache';
import { CachedToc, getCachedToc, isTocStale, putCachedToc } from '../model/TocCache';
import { isLocalBook, loadLocalChapters, loadLocalContent } from '../model/LocalBook';
import { TtsController } from '../model/TtsController';
import { FloatingListenButton } from '../ui/common/FloatingListenButton';
import { AppBackButton } from '../ui/common/AppBackButton';
import { MoreMenuButton } from '../ui/common/MoreMenuButton';
import { MeasureOptions } from '@ohos.measure';

const PANEL_NONE: string = '';
const PANEL_TOC: string = 'toc';
const DOMAIN: number = 0x0000;
const TAG: string = 'SourceReaderReader';
const PANEL_SETTINGS: string = 'settings';

/** 一页中的一个段落片段：指向某章某段落的一段字符区间（段落可跨页拆分）。 */
class PageSeg {
  /** 所属章节在 this.chapters 里的下标（跨章连续页流需要据此取对应章的段落文本）。 */
  chapterIndex: number;
  para: number;
  start: number;
  end: number;

  constructor(chapterIndex: number, para: number, start: number, end: number) {
    this.chapterIndex = chapterIndex;
    this.para = para;
    this.start = start;
    this.end = end;
  }
}



@ComponentV2
export struct ReaderPage {
  @Param source: BookSource | undefined = undefined;
  @Param book: Book | undefined = undefined;
  @Event onBack: () => void = () => {};
  @Event onMore: () => void = () => {};
  @Event onListen: (param: ListenParam) => void = () => {};
  @Event onOpenListening: () => void = () => {};

  @Local chapters: Chapter[] = [];
  @Local chapterIndex: number = 0;
  @Local paragraphs: string[] = [];
  @Local paragraphIndex: number = 0;
  @Local loading: boolean = true;
  @Local failed: string = '';
  @Local menuVisible: boolean = false;
  @Local panel: string = PANEL_NONE;
  @Local tocDescending: boolean = false;
  @Local fontSize: number = READER_FONT_SIZE_DEFAULT;
  @Local lineHeight: number = READER_LINE_HEIGHT_DEFAULT;
  @Local nightMode: boolean = READER_NIGHT_DEFAULT;
  @Local oneHandMode: boolean = READER_ONE_HAND_PAGE_DEFAULT;
  @Local contentWidth: number = 360;
  @Local contentHeight: number = 640;
  /** 是否已由 onAreaChange 测量到真实可用尺寸（首次分页前防用默认值）。 */
  @Local sized: boolean = false;
  @Local pages: PageSeg[][] = [];
  @Local pageIndex: number = 0;
  @Local sliderValue: number = 1;
  @Local tts: TtsController = TtsController.instance();

  private swiperController: SwiperController = new SwiperController();
  private tocScroller: Scroller = new Scroller();
  /** 滑动手势开始时所在页，用于判定边界翻章（区分正常翻页与末页/首页回弹）。 */
  private swipeStartPage: number = 0;
  @Local dataSource: ChapterDataSource = new ChapterDataSource();
  /** Monotonic token so a slow chapter fetch cannot overwrite a newer one. */
  private loadGen: number = 0;
  /**
   * Invalidation token for the background TOC re-crawl: bumped by every `load()`
   * and by the page disappearing. Deliberately **not** `loadGen` — that one moves
   * on every chapter load, which would cancel the re-crawl in nearly every case.
   */
  private tocSession: number = 0;
  /** 各章已 sanitize 的段落缓存（key=章节下标）。跨章连续页流需要同时分页上一章/本章/下一章。 */
  private paraCache: Map<number, string[]> = new Map();
  /** 当前可视页的身份（首段 chapterIndex@para@start）。重排窗口后用它对回同一页，
      长段落跨页拆分时 start 能区分“同一段落的最后一页”与“倒数第二页”。 */
  private currentPageId: string = '';

  @Monitor('tts.paragraphIndex', 'tts.chapterIndex')
  onTtsProgress(): void {
    const book: Book | undefined = this.book;
    if (book === undefined || !this.tts.isActiveFor(book.bookId)) {
      return;
    }
    if (this.tts.chapterIndex !== this.chapterIndex) {
      // 带上段落锚点：不传就会落到章首（paragraphIndex=0），而音频还在本章第 N 段；
      // 音频下一次推进段落前，高亮/进度都会停在章首（T-CROSS-3）。
      this.loadChapter(this.tts.chapterIndex, this.tts.paragraphIndex);
      return;
    }
    const page: number = this.flatIndexOf(this.chapterIndex, this.tts.paragraphIndex);
    if (page >= 0 && page < this.pages.length && page !== this.pageIndex) {
      this.pageIndex = page;
      this.paragraphIndex = this.pages[page][0].para;
      this.swiperController.changeIndex(page, true);
    }
  }

  aboutToAppear(): void {
    const ctx: common.UIAbilityContext | undefined =
      this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    if (ctx !== undefined) {
      this.fontSize = getNumber(ctx, KEY_READER_FONT_SIZE, READER_FONT_SIZE_DEFAULT);
      this.lineHeight = getNumber(ctx, KEY_READER_LINE_HEIGHT, READER_LINE_HEIGHT_DEFAULT);
      this.nightMode = getBoolean(ctx, KEY_READER_NIGHT, READER_NIGHT_DEFAULT);
      this.oneHandMode = getBoolean(ctx, KEY_READER_ONE_HAND_PAGE, READER_ONE_HAND_PAGE_DEFAULT);
    }
    this.applyFullScreen();
    this.load();
  }

  aboutToDisappear(): void {
    // 页面已离开：作废还在飞的目录重爬，避免它回来写已销毁组件的状态。
    this.tocSession = this.tocSession + 1;
    setLayoutFullScreen(false);
    setWindowBackgroundColor(this.resolveColorHex($r('app.color.bg_page')));
    setStatusBarContentColor(this.systemDark() ? '#FFFFFF' : '#000000');
  }

  private systemDark(): boolean {
    const ctx: common.UIAbilityContext | undefined = this.ctx();
    if (ctx === undefined) {
      return false;
    }
    return ctx.config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
  }

  /**
   * Full-bleed reader background while keeping the content safe area: the
   * status-bar strip is a transparent (window-level) box, so painting the window
   * background with the reader color fills top/bottom edges without switching the
   * page to immersive layout (which would drop the content's safe inset).
   */
  private applyFullScreen(): void {
    const bg: string = this.resolveColorHex(this.bgColor());
    setLayoutFullScreen(false);
    setWindowBackgroundColor(bg);
    ReaderTheme.instance().bgHex = bg;
    setStatusBarContentColor(this.nightMode ? '#FFFFFF' : '#000000');
  }

  private resolveColorHex(res: Resource): string {
    const ctx: common.UIAbilityContext | undefined = this.ctx();
    if (ctx === undefined) {
      return '#FFFFFF';
    }
    try {
      const value: number = ctx.resourceManager.getColorSync(res.id);
      return '#' + (value >>> 0).toString(16).padStart(8, '0').toUpperCase();
    } catch (err) {
      return '#FFFFFF';
    }
  }

  private ctx(): common.UIAbilityContext | undefined {
    return this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
  }

  /**
   * Fetch the chapter list, serving a previously cached TOC when the book's
   * `tocUrl` is unchanged so re-opening a long book doesn't re-crawl every TOC
   * page over the network.
   *
   * The cache has no expiry of its own beyond `tocUrl`, so a serialized book would
   * never show chapters published after its first open. A stale entry (older than
   * `TOC_REFRESH_AFTER_MS`) is therefore also re-crawled — in the background, so
   * the first paint is never blocked (see `refreshToc`).
   */
  private async loadToc(src: BookSource, book: Book): Promise<Chapter[]> {
    const ctx: common.UIAbilityContext | undefined = this.ctx();
    if (ctx !== undefined) {
      const cached: CachedToc | undefined = getCachedToc(ctx, book.bookId, book.tocUrl);
      if (cached !== undefined && cached.chapters.length > 0) {
        if (isTocStale(cached)) {
          this.refreshToc(src, book, this.tocSession);
        }
        return cached.chapters;
      }
    }
    const chapters: Chapter[] = await bookEngine.toc(src, book.tocUrl);
    if (ctx !== undefined) {
      putCachedToc(ctx, book.bookId, book.tocUrl, chapters);
    }
    return chapters;
  }

  /**
   * Re-crawl a stale cached TOC in the background and adopt the result when the
   * chapter count changed. Never blocks the first paint; failures are silent (the
   * cached list keeps working and the next open retries).
   *
   * Adopting matters beyond the new chapters themselves: `percent` is written as
   * `(chapterIndex + 1) / chapters.length` and the shelf reverse-derives its
   * 「{i+1}章/{total}章」 / 「已读到最新章」 from it, so a stale denominator means a
   * stale shelf label until the book is opened again. Rewriting the progress row
   * here with the fresh denominator is what heals it (T-SHELF-6) — the shelf still
   * does no I/O of its own.
   *
   * 已知边界：听书（`TtsController`）持有开启听书那一刻的 `chapters` **引用**（没有 setter），
   * 重爬结果不会同步给它；且播放中阅读页的进度写会被 `ProgressOwner` 丢弃（音频独占），
   * 所以听书期间书架不会自愈 —— 停播后的下一次进度写入自愈。
   */
  private async refreshToc(src: BookSource, book: Book, session: number): Promise<void> {
    let chapters: Chapter[] = [];
    try {
      chapters = await bookEngine.toc(src, book.tocUrl);
    } catch (err) {
      // 静默（只记一条日志）：缓存目录继续用，下次打开再试。
      hilog.warn(DOMAIN, TAG, 'toc refresh failed: %{public}s', (err as BusinessError).message);
      return;
    }
    if (session !== this.tocSession || chapters.length === 0) {
      return;
    }
    if (this.chapterIndex >= chapters.length) {
      // 目录变短到不含当前章：可能源只返回了不完整目录。宁可继续用（可能陈旧的）
      // 缓存，也不能让下一次打开按更短的目录定位而丢掉阅读位置 —— 连缓存都不覆盖。
      return;
    }
    const ctx: common.UIAbilityContext | undefined = this.ctx();
    if (ctx !== undefined) {
      putCachedToc(ctx, book.bookId, book.tocUrl, chapters);
    }
    // 每次成功重爬都记一行（含「章数未变」），否则无法区分「没重爬」与「重爬了没变化」。
    hilog.info(DOMAIN, TAG, 'toc refresh: %{public}d chapters (cached %{public}d, book=%{public}s)',
      chapters.length, this.chapters.length, book.name);
    if (chapters.length === this.chapters.length) {
      return; // 章数未变：不动列表，避免打断正在读的页（标题变化靠下次打开生效）
    }
    this.chapters = chapters;
    this.buildTocItems();
    this.persistProgress();
  }

  private async load(): Promise<void> {
    const src: BookSource | undefined = this.source;
    const book: Book | undefined = this.book;
    if (src === undefined || book === undefined) {
      this.failed = '缺少书籍信息';
      this.loading = false;
      return;
    }
    // 本次加载的目录重爬令牌（作废上一次页面停留期间还在飞的刷新）。
    this.tocSession = this.tocSession + 1;
    // 缓存整理时保护这本书的章节文件（会话级，30 分钟未更新自动失效）。
    protectBook(book.bookId);
    try {
      let chapters: Chapter[];
      if (isLocalBook(book)) {
        const c: common.UIAbilityContext | undefined = this.ctx();
        chapters = c !== undefined ? loadLocalChapters(c, book) : [];
      } else {
        chapters = await this.loadToc(src, book);
      }
      this.chapters = chapters;
      this.buildTocItems();
      const first: number = this.firstReadable();
      if (first < 0) {
        this.failed = '目录为空';
        this.loading = false;
        return;
      }
      const progress: ReadProgress | undefined = await getProgress(book.bookId);
      let start: number = first;
      let paragraph: number = 0;
      if (progress !== undefined && this.isReadable(progress.chapterIndex)) {
        start = progress.chapterIndex;
        paragraph = progress.paragraphIndex;
      }
      await this.loadChapter(start, paragraph);
    } catch (err) {
      this.failed = '目录加载失败';
      this.loading = false;
    }
  }

  // ── Chapter navigation (volumes are not readable) ──────────────

  private isReadable(index: number): boolean {
    return index >= 0 && index < this.chapters.length && this.chapters[index].isVolume !== true;
  }

  private firstReadable(): number {
    for (let i = 0; i < this.chapters.length; i++) {
      if (this.isReadable(i)) {
        return i;
      }
    }
    return -1;
  }

  private nextReadable(from: number): number {
    for (let i = from + 1; i < this.chapters.length; i++) {
      if (this.isReadable(i)) {
        return i;
      }
    }
    return -1;
  }

  private prevReadable(from: number): number {
    for (let i = from - 1; i >= 0; i--) {
      if (this.isReadable(i)) {
        return i;
      }
    }
    return -1;
  }

  // ── Chapter content ───────────────────────────────────────────

  private async fetchContent(chapter: Chapter, index: number): Promise<string> {
    const src: BookSource | undefined = this.source;
    const book: Book | undefined = this.book;
    if (src === undefined || book === undefined) {
      return '';
    }
    if (isLocalBook(book)) {
      const localCtx: common.UIAbilityContext | undefined = this.ctx();
      return localCtx !== undefined ? loadLocalContent(localCtx, book, index) : '';
    }
    const ctx: common.UIAbilityContext | undefined = this.ctx();
    if (ctx !== undefined) {
      const cached: string | undefined = getCachedChapter(ctx, book.bookId, index, chapter.url);
      if (cached !== undefined) {
        return cached;
      }
    }
    const result = await bookEngine.content(src, chapter.url);
    if (ctx !== undefined) {
      putCachedChapter(ctx, book.bookId, index, chapter.url, result.content);
    }
    return result.content;
  }

  /**
   * Synchronous cache probe (memory/file) used to decide whether a spinner is
   * needed. Returns undefined on a miss; an already-cached chapter is applied
   * immediately so opening it never flashes the loading animation.
   */
  private cachedContent(chapter: Chapter, index: number): string | undefined {
    const book: Book | undefined = this.book;
    if (book === undefined) {
      return undefined;
    }
    const ctx: common.UIAbilityContext | undefined = this.ctx();
    if (ctx === undefined) {
      return undefined;
    }
    let cached: string | undefined = undefined;
    if (isLocalBook(book)) {
      try {
        cached = loadLocalContent(ctx, book, index);
      } catch (err) {
        return undefined;
      }
    } else {
      cached = getCachedChapter(ctx, book.bookId, index, chapter.url);
    }
    return cached !== undefined && cached.length > 0 ? cached : undefined;
  }

  /**
   * Some sources render the chapter body inside a container that also carries
   * the site breadcrumb ("当前位置：/作者/书名/章节名") and repeats the title on
   * every paginated sub-page. Keep exactly one title heading, drop the rest.
   */
  private sanitize(raw: string, title: string): string[] {
    const text: string = raw.replace(/\r\n/g, '\n').replace(/\r/g, '\n');
    const target: string = title.trim().replace(/\s/g, '');
    const out: string[] = [];
    for (const rawLine of text.split('\n')) {
      const line: string = rawLine.trim();
      if (line.length === 0) {
        continue;
      }
      if (line.indexOf('当前位置') >= 0) {
        continue;
      }
      const compact: string = line.replace(/\s/g, '');
      if (compact === '/' || line.endsWith('/')) {
        continue;
      }
      if (target.length > 0 && compact === target) {
        continue;
      }
      out.push(line);
    }
    if (title.trim().length > 0) {
      out.unshift(title.trim());
    }
    return out;
  }

  private async loadChapter(index: number, restoreParagraph: number = 0, restoreAtEnd: boolean = false): Promise<void> {
    if (!this.isReadable(index)) {
      return;
    }
    const gen: number = ++this.loadGen;
    this.failed = '';
    const chapter: Chapter = this.chapters[index];
    const cached: string | undefined = this.cachedContent(chapter, index);
    if (cached !== undefined) {
      this.applyChapter(index, cached, restoreParagraph, restoreAtEnd);
      await this.persistProgress();
      if (gen !== this.loadGen) {
        return;
      }
      this.warmNeighbors();
      return;
    }
    this.loading = true;
    try {
      const content: string = await this.fetchContent(chapter, index);
      if (gen !== this.loadGen) {
        return;
      }
      this.applyChapter(index, content, restoreParagraph, restoreAtEnd);
      await this.persistProgress();
      if (gen !== this.loadGen) {
        return;
      }
      this.warmNeighbors();
    } catch (err) {
      if (gen === this.loadGen) {
        this.failed = '正文加载失败，点击重试';
        this.paragraphs = [];
        this.loading = false;
      }
    }
  }

  /** Commit a loaded chapter body to the reading surface. */
  private applyChapter(index: number, content: string, restoreParagraph: number, restoreAtEnd: boolean = false): void {
    const chapter: Chapter = this.chapters[index];
    const paragraphs: string[] = this.sanitize(content, chapter.title);
    this.chapterIndex = index;
    this.paragraphs = paragraphs;
    this.paraCache.set(index, paragraphs);
    this.sliderValue = index + 1;
    this.paragraphIndex = restoreAtEnd
      ? (paragraphs.length > 0 ? paragraphs.length - 1 : 0)
      : (paragraphs.length > 0 ? Math.min(Math.max(restoreParagraph, 0), paragraphs.length - 1) : 0);
    // 显式载入新章时清空“当前可视页身份”，否则 rebuildWindow 会用旧章的页身份
    // 在跨章页流里重新命中旧页（旧章常作为 prev 邻居仍保留在窗口内），导致
    // 「下一章」/目录点击相邻章时视觉上停在原地不跳转。
    this.currentPageId = '';
    this.loading = false;
    // 首次进入时尺寸尚未测出（contentWidth/Height 还是默认值），若立即 rebuildWindow
    // 会用错误的默认尺寸排版，onAreaChange 再重排一次，就会先闪一帧“未铺满”页面。
    // 所以：尺寸未测出时先清空 pages，由 onAreaChange 用真实尺寸完成首次分页。
    if (this.sized) {
      this.rebuildWindow(restoreAtEnd);
    } else {
      this.pages = [];
    }
  }

  /** 提前把相邻章（上一章/下一章）的段落文本暖载进 paraCache，供跨章连续页流拼接。 */
  private async warmNeighbors(): Promise<void> {
    const book: Book | undefined = this.book;
    if (book === undefined) {
      return;
    }
    const gen: number = this.loadGen;
    const targets: number[] = [this.prevReadable(this.chapterIndex), this.nextReadable(this.chapterIndex)];
    for (const n of targets) {
      if (n < 0 || this.paraCache.has(n)) {
        continue;
      }
      const chapter: Chapter = this.chapters[n];
      const cached: string | undefined = this.cachedContent(chapter, n);
      let content: string | undefined = cached;
      if (content === undefined) {
        try {
          content = await this.fetchContent(chapter, n);
        } catch (err) {
          continue;
        }
      }
      if (content !== undefined) {
        this.paraCache.set(n, this.sanitize(content, chapter.title));
      }
    }
    if (gen === this.loadGen && this.sized) {
      this.rebuildWindow(false);
    }
  }

  /** Warm the file cache for the next chapter in the background. */
  private async prefetch(index: number): Promise<void> {
    const book: Book | undefined = this.book;
    if (index < 0 || book === undefined) {
      return;
    }
    try {
      await this.fetchContent(this.chapters[index], index);
    } catch (err) {
    }
  }

  /**
   * Persist the visible-page position. Writes as `ProgressWriter.READER`: while the
   * TTS plays this book the audio clock owns the position and this write is dropped
   * by `saveProgress` (`model/ProgressOwner.ets`) — the page turn below only moves
   * the view, never the stored position, while listening.
   */
  private async persistProgress(): Promise<void> {
    const book: Book | undefined = this.book;
    if (book === undefined || this.chapterIndex < 0 || this.chapterIndex >= this.chapters.length) {
      return;
    }
    await saveProgress({
      bookId: book.bookId,
      chapterIndex: this.chapterIndex,
      chapterTitle: this.chapters[this.chapterIndex].title,
      paragraphIndex: this.paragraphIndex,
      charOffset: 0,
      percent: (this.chapterIndex + 1) / this.chapters.length,
      updatedAt: Date.now()
    }, ProgressWriter.READER);
  }

  private prevChapter(): void {
    // 「上一章」按钮：跳到上一章开头（第一页），与 nextChapter 对称。
    this.loadChapter(this.prevReadable(this.chapterIndex));
  }

  private prevChapterEnd(): void {
    // 连续往回翻页（点按左区/右滑越过本章首页）：进入上一章最后一页，继续向后读。
    this.loadChapter(this.prevReadable(this.chapterIndex), 0, true);
  }

  private nextChapter(): void {
    this.loadChapter(this.nextReadable(this.chapterIndex));
  }

  private nextPage(): void {
    if (this.pageIndex < this.pages.length - 1) {
      this.swiperController.changeIndex(this.pageIndex + 1, true);
    } else {
      // 本章最后一页：翻到下一章开头。
      this.nextChapter();
    }
  }

  private prevPage(): void {
    if (this.pageIndex > 0) {
      this.swiperController.changeIndex(this.pageIndex - 1, true);
    } else {
      // 越过本章首页继续往回：进入上一章最后一页，保持向后连续阅读。
      this.prevChapterEnd();
    }
  }

  private onPageChanged(index: number): void {
    this.pageIndex = index;
    if (index < 0 || index >= this.pages.length || this.pages[index].length === 0) {
      this.persistProgress();
      return;
    }
    const seg: PageSeg = this.pages[index][0];
    if (seg.chapterIndex !== this.chapterIndex) {
      // 滑进了相邻章：以当前可视页（首段身份）为锚，把视觉页不变地“重锚”到该章。
      this.chapterIndex = seg.chapterIndex;
      this.sliderValue = seg.chapterIndex + 1;
      const paras: string[] | undefined = this.paraCache.get(seg.chapterIndex);
      if (paras !== undefined) {
        this.paragraphs = paras;
      }
      this.currentPageId = this.pageIdFor(seg);
      this.paragraphIndex = seg.para;
      this.rebuildWindow(false);
      this.warmNeighbors();
    } else {
      this.currentPageId = this.pageIdFor(seg);
      this.paragraphIndex = seg.para;
    }
    this.persistProgress();
  }

  /** 可用内容宽度（去左右 padding 各 20），单位 vp，与 measure 约束宽度、渲染宽度对齐。 */
  private availWidthPx(): number {
    const w: number = this.contentWidth > 0 ? this.contentWidth : 360;
    return Math.max(120, w - 40);
  }

  /** 可用内容高度（去上下 padding 各 20），单位 vp。 */
  private availHeightPx(): number {
    const h: number = this.contentHeight > 0 ? this.contentHeight : 640;
    return Math.max(120, h - 40);
  }

  /** 段落下边距（渲染里标题用 fontSize、正文用 fontSize*0.6；margin 数值单位为 vp）。 */
  private paraMargin(para: number): number {
    return para === 0 ? this.fontSize : this.fontSize * 0.6;
  }

  /** 构造度量选项，与渲染 Text 属性严格对齐（字号/字重/行高/约束宽度/对齐）。 */
  private measureOptions(para: number): MeasureOptions {
    const isTitle: boolean = para === 0;
    const options: MeasureOptions = {
      textContent: '',
      constraintWidth: this.availWidthPx(),
      // 显式 fp 单位，与渲染 Text 的 .fontSize/.lineHeight（number 均为 fp）严格对齐。
      fontSize: `${isTitle ? this.fontSize + 3 : this.fontSize}fp`,
      fontWeight: isTitle ? FontWeight.Bold : FontWeight.Normal,
      lineHeight: `${this.fontSize * this.lineHeight}fp`,
      textAlign: TextAlign.Start
    };
    return options;
  }

  /** 实测段落在 [start, end) 文本的渲染高度（px）。 */
  private measureHeight(para: number, text: string, start: number, end: number): number {
    const options: MeasureOptions = this.measureOptions(para);
    options.textContent = text.substring(start, end);
    const size: SizeOptions = this.getUIContext().getMeasureUtils().measureTextSize(options);
    return Number(size.height);
  }

  /** 二分查找：段落从 pos 起、实测高度不超过 budgetPx 的最大字符截断位置（高度随长度单调不减）。 */
  private maxCharsFit(para: number, text: string, pos: number, budgetPx: number): number {
    let lo: number = pos;
    let hi: number = text.length;
    while (lo < hi) {
      const mid: number = Math.floor((lo + hi + 1) / 2);
      if (this.measureHeight(para, text, pos, mid) <= budgetPx) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo;
  }

  /**
   * 用 measureTextSize 实测每段/每片段渲染高度（px）并贪心打包成页。
   * 容量用 vp2px(可用高度)、段下边距同样 vp2px 换算，保持与渲染完全一致：
   * 既不会页面排不满，也不会末行被裁。
   */
  private paginateChapter(paras: string[], chapterIndex: number): PageSeg[][] {
    const capacity: number = this.getUIContext().vp2px(this.availHeightPx());
    const pages: PageSeg[][] = [];
    let cur: PageSeg[] = [];
    let curH: number = 0;
    const n: number = paras.length;

    for (let para = 0; para < n; para++) {
      const text: string = paras[para];
      if (text.length === 0) {
        continue;
      }
      const margin: number = this.getUIContext().vp2px(this.paraMargin(para));
      let pos: number = 0;
      while (pos < text.length) {
        const budget: number = capacity - curH - margin;
        if (budget <= 0) {
          // 本页放不下本段（连同边距）：翻页重试；空页时至少塞 1 字符避免死循环。
          if (cur.length > 0) {
            pages.push(cur);
            cur = [];
            curH = 0;
            continue;
          }
          const one: number = Math.min(text.length, pos + 1);
          cur.push(new PageSeg(chapterIndex, para, pos, one));
          curH = capacity;
          pos = one;
          continue;
        }
        // 先测剩余整段高度：绝大多数段落整段可放入当前页，只需 1 次测量；
        // 只有真的超出一页的超长段才退化为二分逐字符找截断点（避免每段都二分拖慢翻章）。
        const fullH: number = this.measureHeight(para, text, pos, text.length);
        let end: number = text.length;
        let segH: number = fullH;
        if (fullH > budget) {
          end = this.maxCharsFit(para, text, pos, budget);
          segH = this.measureHeight(para, text, pos, end);
        }
        if (end <= pos) {
          // 连一个字符都超预算（罕见）：翻页，或空页时塞 1 字符。
          if (cur.length > 0) {
            pages.push(cur);
            cur = [];
            curH = 0;
            continue;
          }
          const one: number = Math.min(text.length, pos + 1);
          cur.push(new PageSeg(chapterIndex, para, pos, one));
          curH = capacity;
          pos = one;
          continue;
        }
        cur.push(new PageSeg(chapterIndex, para, pos, end));
        curH += segH + margin;
        pos = end;
        if (curH >= capacity - 1 && (pos < text.length || para < n - 1)) {
          pages.push(cur);
          cur = [];
          curH = 0;
        }
      }
    }
    if (cur.length > 0) {
      pages.push(cur);
    }
    return pages;
  }

  /** 扁平页流里，查找“首个末段 para>=目标、且属于章节 ch”的页的下标（在 ch 章内定位段落）。 */
  private flatIndexOf(ch: number, para: number): number {
    let first: number = -1;
    for (let p = 0; p < this.pages.length; p++) {
      const arr: PageSeg[] = this.pages[p];
      if (arr.length === 0 || arr[0].chapterIndex !== ch) {
        continue;
      }
      if (first < 0) {
        first = p;
      }
      if (para <= arr[arr.length - 1].para) {
        return p;
      }
    }
    return first >= 0 ? first : 0;
  }

  /** 扁平页流里，章节 ch 的最后一页下标。 */
  private lastIndexOf(ch: number): number {
    let last: number = -1;
    for (let p = 0; p < this.pages.length; p++) {
      if (this.pages[p].length > 0 && this.pages[p][0].chapterIndex === ch) {
        last = p;
      }
    }
    return last >= 0 ? last : 0;
  }

  /** 页身份：首段 chapterIndex@para@start（唯一标识一页，含长段落跨页拆分场景）。 */
  private pageIdFor(seg: PageSeg): string {
    return `${seg.chapterIndex}@${seg.para}@${seg.start}`;
  }

  private indexOfPageId(id: string): number {
    for (let p = 0; p < this.pages.length; p++) {
      const arr: PageSeg[] = this.pages[p];
      if (arr.length > 0 && this.pageIdFor(arr[0]) === id) {
        return p;
      }
    }
    return -1;
  }

  /**
   * 重建「上一章 + 本章 + 下一章」的连续页流（跨章页流）。
   * 只有本地/缓存里已有段落文本的邻居章才会并入（否则以待后续异步暖载后再重建）。
   * 以当前段落为锚点定位本章页面；atEnd 时定位到本章最后一页。
   */
  private rebuildWindow(atEnd: boolean = false): void {
    const prev: number = this.prevReadable(this.chapterIndex);
    const next: number = this.nextReadable(this.chapterIndex);
    let flat: PageSeg[][] = [];
    if (prev >= 0) {
      const p: string[] | undefined = this.paraCache.get(prev);
      if (p !== undefined && p.length > 0) {
        flat = flat.concat(this.paginateChapter(p, prev));
      }
    }
    flat = flat.concat(this.paginateChapter(this.paragraphs, this.chapterIndex));
    if (next >= 0) {
      const n: string[] | undefined = this.paraCache.get(next);
      if (n !== undefined && n.length > 0) {
        flat = flat.concat(this.paginateChapter(n, next));
      }
    }
    this.pages = flat;
    if (atEnd) {
      this.pageIndex = this.lastIndexOf(this.chapterIndex);
      const segs: PageSeg[] | undefined = this.pages[this.pageIndex];
      if (segs !== undefined && segs.length > 0) {
        const tail: PageSeg = segs[segs.length - 1];
        this.currentPageId = this.pageIdFor(segs[0]);
        this.paragraphIndex = tail.para;
      }
    } else {
      // 优先用当前可视页身份精确回找（避免长段落跨页拆分时用 para 定位漂到倒数第二页），
      // 找不到（如首次进入）再退回段落锚点。
      let page: number = this.currentPageId !== '' ? this.indexOfPageId(this.currentPageId) : -1;
      if (page < 0) {
        page = this.flatIndexOf(this.chapterIndex, this.paragraphIndex);
      }
      this.pageIndex = page;
      const segs: PageSeg[] | undefined = this.pages[this.pageIndex];
      if (segs !== undefined && segs.length > 0) {
        this.currentPageId = this.pageIdFor(segs[0]);
        this.paragraphIndex = segs[0].para;
      }
    }
    // index 用声明式 .index(this.pageIndex) 绑定（见 contentPager），与 this.pages 同为 @Local，
    // 在同一同步块内更新、同一渲染帧原子生效，避免命令式 changeIndex 作用在旧树/下一帧才生效
    // 的竞态导致的“闪一帧满页”。
  }

  private onContentTap(x: number, width: number): void {
    if (this.menuVisible) {
      return;
    }
    if (this.oneHandMode) {
      // 单手：左右都是下一页，中间窄条呼出菜单。
      if (x < width * 0.45 || x > width * 0.55) {
        this.nextPage();
      } else {
        this.menuVisible = true;
      }
      return;
    }
    // 非单手：左 1/3 上一页、中 1/3 呼出菜单、右 1/3 下一页。
    if (x < width * 0.33) {
      this.prevPage();
    } else if (x < width * 0.66) {
      this.menuVisible = true;
    } else {
      this.nextPage();
    }
  }

  // ── Overlay panels ────────────────────────────────────────────

  private onTopBack(): void {
    if (this.panel !== PANEL_NONE) {
      this.panel = PANEL_NONE;
      return;
    }
    this.onBack();
  }

  private openPanel(mode: string): void {
    if (this.panel === mode) {
      this.panel = PANEL_NONE;
      return;
    }
    this.panel = mode;
    this.menuVisible = true;
  }

  private openDetail(): void {
    this.panel = PANEL_NONE;
    this.menuVisible = false;
    this.onMore();
  }

  private openListening(): void {
    const src: BookSource | undefined = this.source;
    const book: Book | undefined = this.book;
    if (src === undefined || book === undefined || this.chapters.length === 0) {
      return;
    }
    this.panel = PANEL_NONE;
    this.menuVisible = false;
    this.onListen(new ListenParam(
      this.chapters,
      this.chapterIndex,
      this.paragraphs,
      this.paragraphIndex,
      src,
      book
    ));
  }

  private isSpeaking(seg: PageSeg): boolean {
    const book: Book | undefined = this.book;
    if (book === undefined || !this.tts.isActiveFor(book.bookId)) {
      return false;
    }
    return this.tts.chapterIndex === seg.chapterIndex
      && this.tts.paragraphIndex === seg.para;
  }

  /** 取章节 ch 的段落文本（当前章用 this.paragraphs，邻居章用 paraCache）。 */
  private paragraphsOf(ch: number): string[] {
    if (ch === this.chapterIndex) {
      return this.paragraphs;
    }
    const p: string[] | undefined = this.paraCache.get(ch);
    return p !== undefined ? p : [];
  }

  private toggleNight(): void {
    this.nightMode = !this.nightMode;
    const ctx: common.UIAbilityContext | undefined = this.ctx();
    if (ctx !== undefined) {
      putBoolean(ctx, KEY_READER_NIGHT, this.nightMode);
    }
    const bg: string = this.resolveColorHex(this.bgColor());
    setWindowBackgroundColor(bg);
    ReaderTheme.instance().bgHex = bg;
    setStatusBarContentColor(this.nightMode ? '#FFFFFF' : '#000000');
  }

  private moreMenuItems(): MenuElement[] {
    return [
      {
        value: '书籍详情',
        action: () => this.openDetail()
      }
    ];
  }

  // ── TOC ordering / positioning ────────────────────────────────

  private buildTocItems(): void {
    const total: number = this.chapters.length;
    const ordered: Chapter[] = [];
    for (let i = 0; i < total; i++) {
      const pos: number = this.tocDescending ? total - 1 - i : i;
      ordered.push(this.chapters[pos]);
    }
    // 复用同一个实例 + `setItems`（内部 `onDataReloaded`）而不是换新实例：LazyForEach
    // 只在创建时读一次数据源，换实例**不会**让已挂载的目录抽屉重渲染——那会出现
    // 「目录 · N 章」计数已变、列表却还是旧章数（T-SHELF-6 后台重爬时踩到）。
    this.dataSource.setItems(ordered);
  }

  private readableCount(): number {
    let n: number = 0;
    for (const c of this.chapters) {
      if (c.isVolume !== true) {
        n += 1;
      }
    }
    return n;
  }

  private locateCurrentToc(): void {
    if (this.chapterIndex < 0) {
      return;
    }
    try {
      this.tocScroller.scrollToIndex(this.tocPosition());
    } catch (err) {
    }
  }

  /** Display-order index of the current chapter (order-aware). */
  private tocPosition(): number {
    if (this.chapterIndex < 0 || this.chapterIndex >= this.chapters.length) {
      return 0;
    }
    return this.tocDescending
      ? this.chapters.length - 1 - this.chapterIndex
      : this.chapterIndex;
  }

  private toggleTocOrder(): void {
    this.tocDescending = !this.tocDescending;
    this.buildTocItems();
    // Keep the current chapter in view after the list flips order.
    setTimeout(() => {
      try {
        this.tocScroller.scrollToIndex(this.tocPosition());
      } catch (err) {
      }
    }, 60);
  }

  // ── Reader settings ───────────────────────────────────────────

  private changeFont(delta: number): void {
    const next: number = Math.min(28, Math.max(14, this.fontSize + delta));
    this.fontSize = next;
    const ctx: common.UIAbilityContext | undefined = this.ctx();
    if (ctx !== undefined) {
      putNumber(ctx, KEY_READER_FONT_SIZE, next);
    }
    this.rebuildWindow();
  }

  private changeLineHeight(delta: number): void {
    const next: number = Math.round(Math.min(2.6, Math.max(1.2, this.lineHeight + delta)) * 10) / 10;
    this.lineHeight = next;
    const ctx: common.UIAbilityContext | undefined = this.ctx();
    if (ctx !== undefined) {
      putNumber(ctx, KEY_READER_LINE_HEIGHT, next);
    }
    this.rebuildWindow();
  }

  // ── Colors (reader keeps its own day/night, independent of global theme) ──

  private bgColor(): Resource {
    return this.nightMode ? $r('app.color.reader_bg') : $r('app.color.reader_bg_day');
  }

  private textColor(): Resource {
    return this.nightMode ? $r('app.color.reader_text') : $r('app.color.reader_text_day');
  }

  private dimColor(): Resource {
    return this.nightMode ? $r('app.color.reader_dim') : $r('app.color.reader_dim_day');
  }

  // ── UI builders ───────────────────────────────────────────────

  @Builder
  iconButton(icon: Resource, label: string, action: () => void) {
    Row() {
      SymbolGlyph(icon)
        .fontSize(24)
        .fontColor([this.textColor()])
    }
    .width(44)
    .height(44)
    .justifyContent(FlexAlign.Center)
    .accessibilityText(label)
    .onClick(action)
  }

  @Builder
  moreButton() {
    MoreMenuButton({
      items: this.moreMenuItems(),
      color: this.dimColor(),
      label: '更多'
    })
  }

  @Builder
  topBar() {
    Row() {
      AppBackButton({
        label: '返回',
        color: this.textColor(),
        onTap: () => this.onTopBack()
      })
      Text(this.chapters.length > 0 && this.chapterIndex < this.chapters.length
        ? this.chapters[this.chapterIndex].title
        : '')
        .fontSize(16)
        .fontColor(this.textColor())
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .padding({ left: 4 })
      MoreMenuButton({
        items: this.moreMenuItems(),
        color: this.dimColor(),
        label: '更多'
      })
    }
    .width('100%')
    .height(52)
    .padding({ left: 4, right: 4 })
    .alignItems(VerticalAlign.Center)
    .backgroundColor(this.bgColor())
  }

  @Builder
  funcButton(icon: Resource, label: string, active: boolean, action: () => void) {
    Row() {
      SymbolGlyph(icon)
        .fontSize(22)
        .fontColor([active ? $r('app.color.brand') : this.textColor()])
    }
    .width(64)
    .height(48)
    .justifyContent(FlexAlign.Center)
    .accessibilityText(label)
    .onClick(action)
  }

  @Builder
  bottomBar() {
    Column() {
      Row() {
        this.iconButton($r('sys.symbol.chevron_left'), '上一章', () => this.prevChapter())
        Slider({
          value: this.sliderValue,
          min: 1,
          max: Math.max(this.chapters.length, 1),
          step: 1
        })
          .layoutWeight(1)
          .trackThickness(3)
          .blockColor($r('app.color.brand'))
          .selectedColor($r('app.color.brand'))
          .trackColor(this.dimColor())
          .onChange((value: number, mode: SliderChangeMode) => {
            this.sliderValue = value;
            if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
              const target: number = Math.round(value) - 1;
              if (target !== this.chapterIndex) {
                this.loadChapter(target);
              }
            }
          })
        this.iconButton($r('sys.symbol.chevron_right'), '下一章', () => this.nextChapter())
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Row() {
        this.funcButton($r('sys.symbol.line_3_horizontal'), '目录', this.panel === PANEL_TOC,
          () => this.openPanel(PANEL_TOC))
        this.funcButton($r('sys.symbol.headphones'), '听书', this.tts.active,
          () => this.openListening())
        this.funcButton(this.nightMode ? $r('sys.symbol.sun_max') : $r('sys.symbol.moon'),
          this.nightMode ? '日间模式' : '夜间模式', false, () => this.toggleNight())
        this.funcButton($r('sys.symbol.gearshape'), '设置', this.panel === PANEL_SETTINGS,
          () => this.openPanel(PANEL_SETTINGS))
      }
      .width('100%')
      .justifyContent(FlexAlign.SpaceEvenly)
      .margin({ top: 4 })
    }
    .width('100%')
    .padding({ left: 8, right: 8, top: 12, bottom: 20 })
    .backgroundColor(this.bgColor())
  }

  @Builder
  tocDrawerContent() {
    Column() {
      Row() {
        BookCover({
          source: this.source,
          coverUrl: this.book !== undefined ? this.book.coverUrl : '',
          name: this.book !== undefined ? this.book.name : '',
          coverWidth: 44,
          coverHeight: 58,
          radius: 6
        })
        Column() {
          Text(this.book !== undefined ? this.book.name : '')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.textColor())
            .width('100%')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.book !== undefined ? this.book.author : '')
            .fontSize(13)
            .fontColor(this.dimColor())
            .width('100%')
            .margin({ top: 4 })
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        .margin({ left: 12 })
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(18)
          .fontColor([this.dimColor()])
      }
      .width('100%')
      .padding(12)
      .alignItems(VerticalAlign.Center)
      .onClick(() => this.openDetail())

      Row() {
        Text('目录')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.textColor())
        Text(` · ${this.readableCount()} 章`)
          .fontSize(13)
          .fontColor(this.dimColor())
        Blank()
        Text('定位')
          .fontSize(13)
          .fontColor($r('app.color.brand'))
          .padding({ left: 10, right: 10, top: 4, bottom: 4 })
          .onClick(() => this.locateCurrentToc())
        Text(this.tocDescending ? '倒序' : '正序')
          .fontSize(13)
          .fontColor($r('app.color.brand'))
          .padding({ left: 10, right: 10, top: 4, bottom: 4 })
          .onClick(() => this.toggleTocOrder())
      }
      .width('100%')
      .padding({ left: 16, right: 12, top: 10, bottom: 6 })

      List({ space: 0, scroller: this.tocScroller, initialIndex: this.tocPosition() }) {
        LazyForEach(this.dataSource, (chapter: Chapter) => {
          ListItem() {
            if (chapter.isVolume === true) {
              Text(chapter.title)
                .fontSize(13)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.dimColor())
                .width('100%')
                .padding({ left: 16, right: 16, top: 14, bottom: 6 })
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            } else {
              Text(chapter.title)
                .fontSize(15)
                .fontColor(chapter.index === this.chapterIndex
                  ? $r('app.color.brand')
                  : this.textColor())
                .width('100%')
                .padding({ left: 16, right: 16, top: 12, bottom: 12 })
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .onClick(() => {
                  this.panel = PANEL_NONE;
                  this.loadChapter(chapter.index);
                })
            }
          }
        }, (chapter: Chapter) => (this.tocDescending ? 'd_' : 'a_') + chapter.index.toString())
      }
      .layoutWeight(1)
      .width('100%')
      .cachedCount(20)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .layoutWeight(1)
  }

  @Builder
  settingsDrawerContent() {
    Column() {
      Row() {
        Text('字号')
          .fontSize(15)
          .fontColor(this.textColor())
        Blank()
        Text('A-')
          .fontSize(15)
          .fontColor($r('app.color.brand'))
          .padding(10)
          .onClick(() => this.changeFont(-1))
        Text(`${this.fontSize}`)
          .fontSize(15)
          .fontColor(this.dimColor())
          .width(40)
          .textAlign(TextAlign.Center)
        Text('A+')
          .fontSize(17)
          .fontColor($r('app.color.brand'))
          .padding(10)
          .onClick(() => this.changeFont(1))
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 8, bottom: 8 })

      Row() {
        Text('行距')
          .fontSize(15)
          .fontColor(this.textColor())
        Blank()
        Text('−')
          .fontSize(18)
          .fontColor($r('app.color.brand'))
          .padding(10)
          .onClick(() => this.changeLineHeight(-0.1))
        Text(this.lineHeight.toFixed(1))
          .fontSize(15)
          .fontColor(this.dimColor())
          .width(40)
          .textAlign(TextAlign.Center)
        Text('+')
          .fontSize(18)
          .fontColor($r('app.color.brand'))
          .padding(10)
          .onClick(() => this.changeLineHeight(0.1))
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 8, bottom: 8 })

      Row() {
        Text('单手翻页')
          .fontSize(15)
          .fontColor(this.textColor())
        Blank()
        Toggle({ type: ToggleType.Switch, isOn: this.oneHandMode })
          .selectedColor($r('app.color.brand'))
          .onChange((isOn: boolean) => {
            this.oneHandMode = isOn;
            const ctx: common.UIAbilityContext | undefined = this.ctx();
            if (ctx !== undefined) {
              putBoolean(ctx, KEY_READER_ONE_HAND_PAGE, isOn);
            }
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 8, bottom: 8 })

      Text('设置即时生效并持久化；单手翻页：左右点按均翻下一页、中间窄条呼出菜单。')
        .fontSize(12)
        .fontColor(this.dimColor())
        .width('100%')
        .padding({ left: 16, right: 16, top: 12 })
    }
    .width('100%')
  }

  @Builder
  contentPager() {
    Swiper(this.swiperController) {
      ForEach(this.pages, (page: PageSeg[], pageIdx: number) => {
        Column() {
          ForEach(page, (seg: PageSeg) => {
            Text(this.paragraphsOf(seg.chapterIndex)[seg.para].substring(seg.start, seg.end))
              .fontSize(seg.para === 0 ? this.fontSize + 3 : this.fontSize)
              .fontWeight(seg.para === 0 ? FontWeight.Bold : FontWeight.Normal)
              .lineHeight(this.fontSize * this.lineHeight)
              .fontColor(this.isSpeaking(seg) ? $r('app.color.brand') : this.textColor())
              .width('100%')
              .margin({ bottom: seg.para === 0 ? this.fontSize : this.fontSize * 0.6 })
          }, (seg: PageSeg) => seg.chapterIndex.toString() + '_' + seg.para.toString() + '_' + seg.start.toString() + '_' + seg.end.toString())
        }
        .width('100%')
        .height('100%')
        .alignItems(HorizontalAlign.Start)
      }, (page: PageSeg[], pageIdx: number) => page.length > 0
        ? page[0].chapterIndex.toString() + '_' + page[0].para.toString() + '_' + page[0].start.toString()
        : ('empty_' + pageIdx.toString()))
    }
    .width('100%')
    .height('100%')
    .padding({ left: 20, right: 20, top: 20, bottom: 20 })
    .loop(false)
    .index(this.pageIndex)
    .indicator(false)
    .onChange((index: number) => {
      this.onPageChanged(index);
    })
    .onAreaChange((oldValue: Area, newValue: Area) => {
      const w: number = Number(newValue.width);
      const h: number = Number(newValue.height);
      if (w !== this.contentWidth || h !== this.contentHeight || !this.sized) {
        this.contentWidth = w;
        this.contentHeight = h;
        this.sized = true;
        this.rebuildWindow();
      }
    })
    .onClick((event: ClickEvent) => {
      this.onContentTap(event.x, this.contentWidth);
    })
    .parallelGesture(
      PanGesture({ direction: PanDirection.Horizontal, distance: 20 })
        .onActionStart(() => {
          this.swipeStartPage = this.pageIndex;
        })
        .onActionEnd((event: GestureEvent) => {
          if (this.menuVisible || this.panel !== PANEL_NONE || this.loading || this.failed.length > 0) {
            return;
          }
          const fromPage: number = this.swipeStartPage;
          const dx: number = event.offsetX;
          if (dx < -60 && fromPage >= this.pages.length - 1) {
            // 本章最后一页向左滑：翻到下一章开头。
            this.nextChapter();
          } else if (dx > 60 && fromPage <= 0) {
            // 越过本章首页向右滑：进入上一章最后一页，继续向后读。
            this.prevChapterEnd();
          }
        })
    )
  }

  build() {
    Stack() {
      if (this.loading) {
        Column() {
          LoadingProgress()
            .width(40)
            .height(40)
            .color($r('app.color.brand'))
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
      } else if (this.failed.length > 0) {
        Column() {
          Text(this.failed)
            .fontSize(15)
            .fontColor(this.textColor())
          Button('重试')
            .margin({ top: 12 })
            .backgroundColor($r('app.color.brand'))
            .fontColor($r('app.color.on_brand'))
            .onClick(() => this.loadChapter(this.chapterIndex, this.paragraphIndex))
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
      } else {
        this.contentPager()
      }

      if (this.menuVisible && !this.loading && this.failed.length === 0) {
        Column() {
          Column() {
            this.topBar()
          }
          .width('100%')
          .translate({ y: this.panel !== PANEL_NONE ? -60 : 0 })
          .animation({ duration: 260, curve: Curve.FastOutSlowIn })

          Column()
            .width('100%')
            .layoutWeight(1)
            .onClick(() => {
              this.menuVisible = false;
            })
          this.bottomBar()
        }
        .width('100%')
        .height('100%')
        .clip(true)
      }

      // Quick return to the listening page once a session is running. Kept
      // below the drawers so their mask covers it.
      if (this.tts.active) {
        FloatingListenButton({
          visible: true,
          onTap: () => this.onOpenListening()
        })
      }

      // @BuilderParam content is not re-evaluated on plain state change under
      // V2, so flip between two drawer instances to re-run the LazyForEach with
      // the freshly ordered data source.
      if (this.tocDescending) {
        BottomDrawer({
          visible: this.panel === PANEL_TOC,
          sheetSize: 'large',
          mode: 'overlay',
          showHeader: false,
          panelBackground: this.bgColor(),
          onClose: () => {
            this.panel = PANEL_NONE;
          }
        }) {
          this.tocDrawerContent()
        }
      } else {
        BottomDrawer({
          visible: this.panel === PANEL_TOC,
          sheetSize: 'large',
          mode: 'overlay',
          showHeader: false,
          panelBackground: this.bgColor(),
          onClose: () => {
            this.panel = PANEL_NONE;
          }
        }) {
          this.tocDrawerContent()
        }
      }

      BottomDrawer({
        visible: this.panel === PANEL_SETTINGS,
        sheetSize: 'fit',
        mode: 'overlay',
        showHeader: false,
        panelBackground: this.bgColor(),
        onClose: () => {
          this.panel = PANEL_NONE;
        }
      }) {
        this.settingsDrawerContent()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.bgColor())
  }
}