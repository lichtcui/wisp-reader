// ─── 文件索引（改本文件先看这里；本文件约 2240 行）──────────────────────────
// 下面只列**成员名**，不列行号（行号会漂）；定位用 `grep -n "<名字>" entry/src/main/ets/pages/Reader.ets`。
//   状态（@Local）：chapters / chapterIndex / paragraphs / paragraphIndex / pages / pageIndex / sliderValue
//                   menuVisible / panel / tocDescending / tocContentRevision / fontSize / lineHeight / nightMode / oneHandMode / tts
//   生命周期：aboutToAppear / aboutToDisappear / onTtsProgress（@Monitor 听书进度 → 高亮 + 跟随滚动）
//   加载正文：loadToc / refreshToc / load / loadChapter / refreshCurrentChapter / applyChapter / fetchContent / fetchRemote / cachedContent / warmNeighbors / warmNeighbor
//             （正文清洗不在本文件：统一走 model/BookContent.sanitizeText，见 T-READ-1）
//   章内导航：isReadable / firstReadable / nextReadable / prevReadable / prevChapter / nextChapter / prevPage / nextPage / onPageChanged
//   分页测算（横向分页核心）：availWidthPx / availHeightPx / measureOptions / measureHeight / maxCharsFit / paraMargin / firstLineIndentFp
//                             paginateChapter / chapterPages / layoutKey / rebuildWindow / flatIndexOf / pageIdFor / indexOfPageId
//   翻页手势守卫（T-READ-7 手势路径）：beginSwipe / releaseSwipeGuard / scheduleWindowRebuild / settleSwipe / finishSwipe
//                                      （落点挂在 contentPager 的 .onTouch / .onAnimationStart / .onAnimationEnd）
//                             （PageSeg 与 Swiper 的懒数据源在 common/PageSeg.ets、common/PageDataSource.ets）
//   进度持久化：persistProgress / locateCurrentToc / tocPosition
//   主题：systemDark / resolveColorHex / applyFullScreen / toggleNight / bgColor / textColor / dimColor
//         changeFont / changeLineHeight
//   跳转：onContentTap / onTopBack / openPanel / openDetail / openListening / moreMenuItems / isSpeaking
//   下载：onDownloadChanged / refreshDownloadState / downloadMenuElement / startDownload / cancelDownload
//         exportMenuElement / exportDownloadedAsTxt
//   换源：openSourceSwitch / confirmSwitch / applySwitch / resetContentState / switchMessage（逻辑在 model/SourceSwitch.ets）
//   刷新本章：refreshCurrentChapter（绕过缓存重取正文，见 §Chapter content）
//   @Builder 子视图：topBar / bottomBar / contentPager（Swiper 分页）/ tocDrawerContent / settingsDrawerContent /
//                    iconButton / funcButton / moreButton / sourceSwitchButton / refreshChapterButton /
//                    buildTocItems / readableCount / toggleTocOrder
// ──────────────────────────────────────────────────────────────────────

import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { bookEngine } from '../engine/BookEngineNapi';
import { Book, BookSearchItem, BookSource, Chapter, ReadProgress } from '../engine/types';
import { ChapterDataSource } from '../common/ChapterDataSource';
import { PageDataSource } from '../common/PageDataSource';
import { PageSeg } from '../common/PageSeg';
import { BookCover } from '../components/BookCover';
import { BottomDrawer } from '../ui/common/BottomDrawer';
import {
  ENGINE_CONTENT_TIMEOUT_MS,
  ENGINE_TOC_TIMEOUT_MS,
  KEY_READER_FONT_SIZE,
  KEY_READER_LINE_HEIGHT,
  KEY_READER_NIGHT,
  KEY_READER_ONE_HAND_PAGE,
  LISTENING_FEATURE_ENABLED,
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
import { getProgress, isBookInShelf, saveProgress } from '../model/ShelfRepository';
import { ProgressWriter } from '../model/ProgressOwner';
import { protectBook } from '../model/CacheTrim';
import { ReaderTheme } from '../common/ReaderTheme';
import { getCachedChapter, putCachedChapter } from '../model/ChapterCache';
import { CachedToc, getCachedToc, isTocStale, putCachedToc } from '../model/TocCache';
import {
  hasLocalBookText,
  hasLocalBookToc,
  isLocalBook,
  loadLocalChapters,
  loadLocalContent,
  rebuildLocalToc,
  relinkLocalTxt
} from '../model/LocalBook';
import { sanitizeText } from '../model/BookContent';
import {
  BookDownloadState,
  getDownloadedChapter,
  inspectDownload,
  writeDownloadedChapter
} from '../model/DownloadStore';
import { BookDownloader } from '../model/BookDownloader';
import { exportDownloadedTxt } from '../model/BookTxtExport';
import { TtsController } from '../model/TtsController';
import { FloatingListenButton } from '../ui/common/FloatingListenButton';
import { AppBackButton } from '../ui/common/AppBackButton';
import { MoreMenuButton } from '../ui/common/MoreMenuButton';
import { SourceSwitchPanel } from '../components/SourceSwitchPanel';
import { SwitchOutcome, switchSource } from '../model/SourceSwitch';
import { TocQuality, tocQualityWarning } from '../model/TocQuality';
import { MeasureOptions } from '@ohos.measure';

const PANEL_NONE: string = '';
const PANEL_TOC: string = 'toc';
const DOMAIN: number = 0x0000;
const TAG: string = 'SourceReaderReader';
const PANEL_SETTINGS: string = 'settings';
const PANEL_SOURCE: string = 'source';
/** 滑动手势守卫的兜底时长：某次触摸没走到 onChange / onAnimationEnd 时别让守卫永久卡住。 */
const SWIPE_WATCHDOG_MS: number = 2000;
/** 顶栏自定义图标画板（vp）。SVG 内已按 20vp 墨迹 + 2vp 居中留白裁好，两个按钮共用同一尺寸。 */
const READER_TOP_ICON_SIZE: number = 24;

@ComponentV2
export struct ReaderPage {
  /** 路由传入的初始来源/书籍；换源后本页改用下面的 `source` / `book`（@Local 副本）。 */
  @Param initialSource: BookSource | undefined = undefined;
  @Param initialBook: Book | undefined = undefined;
  @Event onBack: () => void = () => {};
  /** 打开详情页；参数是本页**当前**的来源/书籍（换源后是新的那本）。 */
  @Event onMore: (source: BookSource, book: Book) => void = () => {};
  @Event onListen: (param: ListenParam) => void = () => {};
  @Event onOpenListening: () => void = () => {};

  /** 当前来源/书籍：初始来自 `initialSource` / `initialBook`，换源后被替换（见 `applySwitch`）。 */
  @Local source: BookSource | undefined = undefined;
  @Local book: Book | undefined = undefined;
  /** 换源抽屉的开启令牌（自增 → 面板重新读源并重新检索）。 */
  @Local sourcePanelToken: number = 0;
  /** 换源候选数：由 `SourceSwitchPanel.onCount` 上报，拼进抽屉标题（「换源 · N 个候选」）。 */
  @Local switchCount: number = 0;
  /** 换源执行中：抽屉列表整体禁用，避免连点两次。 */
  @Local switching: boolean = false;
  @Local chapters: Chapter[] = [];
  @Local chapterIndex: number = 0;
  @Local paragraphs: string[] = [];
  @Local paragraphIndex: number = 0;
  @Local loading: boolean = true;
  /** 顶栏「刷新本章」进行中：禁用连点、图标变淡；不动 `loading`，避免整页闪一次加载态。 */
  @Local refreshing: boolean = false;
  @Local failed: string = '';
  @Local menuVisible: boolean = false;
  @Local panel: string = PANEL_NONE;
  @Local tocDescending: boolean = false;
  // 目录抽屉的内容版本号：顺序状态在抽屉**外**（本组件），而 V2 下父组件普通 `@Local`
  // 变化不会让 `@BuilderParam` 内容重跑（子组件没变脏）→ 表头「正序/倒序」与列表仍旧。
  // 曾经靠 `if (this.tocDescending)` 分支重挂载整个抽屉绕过，代价是每次切序重播一次
  // 上滑开启动画（用户反馈「点正序/倒序又重开一次抽屉」）。改为切序时自增此值，
  // 抽屉因自己的 `@Param` 变化**原地**重渲染 → 内容刷新，开合状态不动。
  @Local tocContentRevision: number = 0;
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
  @Local downloader: BookDownloader = BookDownloader.instance();
  @Local downloadInShelf: boolean = false;
  @Local downloadStateReady: boolean = false;
  @Local downloadHasDirectory: boolean = false;
  @Local downloadComplete: boolean = false;
  @Local downloadNeedsUpdate: boolean = false;
  @Local downloadReadableCount: number = 0;
  @Local exportingTxt: boolean = false;
  /** The local TXT itself is gone; only then is relinking required. */
  @Local localTextMissing: boolean = false;
  @Local relinkingLocal: boolean = false;
  @Local loadingMessage: string = '';

  private swiperController: SwiperController = new SwiperController();
  private tocScroller: Scroller = new Scroller();
  /** 滑动手势开始时所在页，用于判定边界翻章（区分正常翻页与末页/首页回弹）。 */
  private swipeStartPage: number = 0;
  /**
   * 手势/翻页动画是否在飞（T-READ-7 手势路径的守卫）。在飞期间**冻结窗口重排**：
   * `warmNeighbors()` 回来重排会把「上一章」prepend 进页流、当前页下标整体平移，
   * 而 `.index(this.pageIndex)` 是声明式活 setter ⇒ Swiper 被拽回原页。
   */
  private swipeBusy: boolean = false;
  /** 因手势在飞而挂起的窗口重排，落定后由 `finishSwipe()` 补做（不丢）。 */
  private rebuildPending: boolean = false;
  /** 手势起始时的 `loadGen`：手势期间若发生显式载章，页流与锚点归 `applyChapter`，落定不再按旧落点改写。 */
  private gestureLoadGen: number = 0;
  /** 守卫兜底定时器（见 `beginSwipe`）。 */
  private swipeWatchdog: number = -1;
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
  /**
   * 分页结果缓存：章号 → 该章的页流。
   *
   * `rebuildWindow` 每次都会重排窗口内三章（上/本/下），暖载邻章回来还要再整体重排一次；
   * 没有缓存时本章在一次进入里会被排两遍（实测 25 万字级章节 ≈ 600ms × 2）。
   * 失效条件是**排版参数**（宽度/高度/字号/行距）任一变化，见 `layoutKey`。
   */
  private pageCache: Map<number, PageSeg[][]> = new Map();
  private pageCacheKey: string = '';
  /** Swiper 的懒加载数据源：页流变化时 `setItems` 通知重建，不再一次性挂载全部页。 */
  private pageSource: PageDataSource = new PageDataSource();
  /**
   * 在飞的引擎请求（key = `bookId#index`，与 `ChapterCache.memoryKey` 同形）。
   * 频繁切章时同一章会被多个调用方同时索要（新章 + 上一次 `warmNeighbors()` 的邻居 +
   * 下一次切章再暖同一批邻居），去重后共享同一个 promise（T-READ-3）。
   */
  private inflight: Map<string, Promise<string>> = new Map();
  private downloadStateGen: number = 0;
  private downloadWasRunning: boolean = false;
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
      // 与点击翻页同理：高亮跟随也是带动画跳页，提前把页身份挪到目标页，
      // 免得动画期间 `warmNeighbors()` 的重排拿旧页当锚点把 Swiper 拉回去（见 anchorToPage）。
      this.currentPageId = this.pageIdFor(this.pages[page][0]);
      this.swiperController.changeIndex(page, true);
    }
  }

  @Monitor('downloader.running', 'downloader.revision')
  onDownloadChanged(): void {
    if (!this.downloader.running && this.downloadWasRunning) {
      const message: string = this.downloader.message;
      if (message.length > 0) {
        this.toast(message);
      }
    }
    this.downloadWasRunning = this.downloader.running;
    this.refreshDownloadState();
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
    this.source = this.initialSource;
    this.book = this.initialBook;
    this.downloadWasRunning = this.downloader.running;
    this.applyFullScreen();
    this.load();
  }

  aboutToDisappear(): void {
    // 页面已离开：作废还在飞的目录重爬与手势守卫兜底定时器，避免它们回来写已销毁组件的状态。
    this.tocSession = this.tocSession + 1;
    this.releaseSwipeGuard();
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
    const chapters: Chapter[] = await bookEngine.toc(src, book.tocUrl, ENGINE_TOC_TIMEOUT_MS);
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
      chapters = await bookEngine.toc(src, book.tocUrl, ENGINE_TOC_TIMEOUT_MS);
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
    this.refreshDownloadState();
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
      this.failed = '';
      this.localTextMissing = false;
      this.loadingMessage = '';
      let chapters: Chapter[];
      if (isLocalBook(book)) {
        const c: common.UIAbilityContext | undefined = this.ctx();
        if (c !== undefined && !hasLocalBookText(c, book)) {
          this.localTextMissing = true;
          this.failed = '本地书籍正文缺失，请重新关联 TXT';
          this.loading = false;
          hilog.warn(DOMAIN, TAG, 'local book text missing book=%{public}s id=%{public}s',
            book.name, book.bookId);
          return;
        }
        chapters = c !== undefined ? await this.loadLocalToc(c, book) : [];
      } else {
        chapters = await this.loadToc(src, book);
      }
      this.loadingMessage = '';
      this.chapters = chapters;
      this.buildTocItems();
      await this.refreshDownloadState();
      const first: number = this.firstReadable();
      if (first < 0) {
        this.failed = '目录为空';
        this.loading = false;
        return;
      }
      const progress: ReadProgress | undefined = await getProgress(book.bookId);
      let start: number = first;
      let paragraph: number = 0;
      if (progress !== undefined) {
        const byTitle: number = this.findReadableChapterByTitle(progress.chapterTitle, progress.chapterIndex);
        if (byTitle >= 0) {
          // Local TXT TOCs can gain a 前言 entry, shifting every saved index by one.
          start = byTitle;
          paragraph = progress.paragraphIndex;
        } else if (this.isReadable(progress.chapterIndex)) {
          start = progress.chapterIndex;
          paragraph = progress.paragraphIndex;
        }
      }
      await this.loadChapter(start, paragraph);
    } catch (err) {
      const local: boolean = isLocalBook(book);
      const c: common.UIAbilityContext | undefined = this.ctx();
      const textExists: boolean = local && c !== undefined && hasLocalBookText(c, book);
      hilog.error(DOMAIN, TAG, 'reader load failed book=%{public}s local=%{public}s msg=%{public}s',
        book.name, local ? 'true' : 'false', (err as BusinessError).message);
      this.localTextMissing = local && !textExists;
      this.failed = local
        ? (textExists ? '本地书籍目录重新生成失败，点击重试' : '本地书籍正文缺失，请重新关联 TXT')
        : '目录加载失败';
      this.loadingMessage = '';
      this.loading = false;
    }
  }

  /**
   * Local TXT files are the source of truth. A missing or unreadable `toc.json`
   * is rebuilt from `book.txt`; only a missing TXT requires user relinking.
   */
  private async loadLocalToc(ctx: common.UIAbilityContext, book: Book): Promise<Chapter[]> {
    if (!hasLocalBookToc(ctx, book)) {
      await this.rebuildLocalTocFromText(ctx, book);
      return loadLocalChapters(ctx, book);
    }
    try {
      return loadLocalChapters(ctx, book);
    } catch (err) {
      if (!hasLocalBookText(ctx, book)) {
        throw new Error((err as Error).message);
      }
      hilog.warn(DOMAIN, TAG, 'local toc unreadable, rebuilding book=%{public}s msg=%{public}s',
        book.name, (err as BusinessError).message);
      await this.rebuildLocalTocFromText(ctx, book);
      return loadLocalChapters(ctx, book);
    }
  }

  private async rebuildLocalTocFromText(ctx: common.UIAbilityContext, book: Book): Promise<void> {
    this.loadingMessage = '正在重新生成目录…';
    this.loading = true;
    // Let ArkUI paint the explicit loading state before the synchronous TOC scan.
    await new Promise<void>((resolve: (value: void) => void): void => {
      setTimeout((): void => {
        resolve();
      }, 16);
    });
    rebuildLocalToc(ctx, book);
  }

  private findReadableChapterByTitle(title: string, near: number): number {
    const wanted: string = title.replace(/\s+/g, '').trim();
    if (wanted.length === 0) {
      return -1;
    }
    let found: number = -1;
    for (let i = 0; i < this.chapters.length; i++) {
      if (!this.isReadable(i)) {
        continue;
      }
      const current: string = this.chapters[i].title.replace(/\s+/g, '').trim();
      if (current !== wanted) {
        continue;
      }
      if (found < 0 || Math.abs(i - near) < Math.abs(found - near)) {
        found = i;
      }
    }
    return found;
  }

  private async retryLoad(): Promise<void> {
    if (this.localTextMissing) {
      await this.relinkLocal();
      return;
    }
    if (this.chapters.length === 0) {
      this.failed = '';
      this.loading = true;
      this.load();
      return;
    }
    this.loadChapter(this.chapterIndex, this.paragraphIndex);
  }

  private async relinkLocal(): Promise<void> {
    const book: Book | undefined = this.book;
    const ctx: common.UIAbilityContext | undefined = this.ctx();
    if (book === undefined || ctx === undefined || this.relinkingLocal) {
      return;
    }
    this.relinkingLocal = true;
    try {
      const relinked: Book | undefined = await relinkLocalTxt(ctx, book);
      if (relinked === undefined) {
        return;
      }
      this.book = relinked;
      this.failed = '';
      this.loading = true;
      await this.load();
      if (this.failed.length === 0) {
        this.toast('已重新关联《' + relinked.name + '》');
      }
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'local relink failed book=%{public}s msg=%{public}s',
        book.name, (err as Error).message);
      this.localTextMissing = true;
      this.loading = false;
      this.failed = (err as Error).message === 'mismatch'
        ? '所选 TXT 与当前书籍不匹配'
        : '重新关联失败，请选择这本书的 TXT';
    } finally {
      this.relinkingLocal = false;
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

  /**
   * Fetch one chapter body, single-flighting concurrent requests for the same
   * `bookId#index`.
   *
   * 没有去重时，同一章会被同时抓两次：`loadChapter` 要的新章 + 仍在飞的
   * `warmNeighbors()` 邻居 + 下一次切章再暖同一批邻居 —— 两边各发一次引擎请求、
   * 各写一次 `putCachedChapter`，而后到的结果还会被 `loadChapter` 的 `loadGen`
   * 守卫丢弃。去重后调用方共享同一个 promise：只请求一次、只写盘一次（T-READ-3）。
   *
   * `force=true` 只给「刷新本章」用：跳过 downloaded / cached 两层读路径，仍走
   * `inflight` 单飞（复用正在飞的同一章请求，那同样是从书源现取的最新正文）。
   */
  private async fetchContent(chapter: Chapter, index: number, force: boolean = false): Promise<string> {
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
    if (ctx !== undefined && !force) {
      const downloaded: string | undefined =
        getDownloadedChapter(ctx, book.bookId, index, chapter.url);
      if (downloaded !== undefined) {
        return downloaded;
      }
      const cached: string | undefined = getCachedChapter(ctx, book.bookId, index, chapter.url);
      if (cached !== undefined) {
        return cached;
      }
    }
    const key: string = book.bookId + '#' + index.toString();
    const running: Promise<string> | undefined = this.inflight.get(key);
    if (running !== undefined) {
      return running;
    }
    const task: Promise<string> = this.fetchRemote(src, ctx, book, chapter, index);
    this.inflight.set(key, task);
    try {
      return await task;
    } finally {
      // 落定即出表：后续调用应当命中它刚写下的文件缓存；失败也必须能重试。
      this.inflight.delete(key);
    }
  }

  /** Engine request + disk write for a single chapter; only reached from `fetchContent`. */
  private async fetchRemote(
    src: BookSource,
    ctx: common.UIAbilityContext | undefined,
    book: Book,
    chapter: Chapter,
    index: number
  ): Promise<string> {
    const result = await bookEngine.content(src, chapter.url, ENGINE_CONTENT_TIMEOUT_MS);
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
      cached = getDownloadedChapter(ctx, book.bookId, index, chapter.url);
      if (cached === undefined) {
        cached = getCachedChapter(ctx, book.bookId, index, chapter.url);
      }
    }
    return cached !== undefined && cached.length > 0 ? cached : undefined;
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

  /**
   * 顶栏「刷新本章」：重新向书源取当前章正文（对齐 Legado 阅读菜单里重新加载本章的语义）。
   *
   * 背景：目录有 stale 重爬（`refreshToc`），**正文缓存却不会自己过期** —— 书源在章节
   * 发布后又改过内容（错字修订 / 防盗章替换）时，本 App 没有任何入口能拿到新正文。
   *
   * 三层缓存必须一起覆盖，否则下次打开又读回旧文本：
   *  - `paraCache` / 页流：`applyChapter` 覆盖段落、删本章分页并就地重排；
   *  - `ChapterCache`（内存 + `filesDir/chapters`）：`fetchRemote` 的 `putCachedChapter`
   *    整体覆写条目，顺带作废跟着正文走的 TTS 预生成音频键；
   *  - `DownloadStore`（已下载章节，`cachedContent` 里优先级最高）：存在时显式覆写。
   *
   * 不复用 `loadChapter`：那条路径会命中缓存、失败时还会清空当前正文。这里保留段落锚点
   * 就地重排，失败只提示、正文原样留着。本地书正文来自导入的 TXT，没有可重取的源。
   *
   * 已知边界：听书播放中刷新不会重做已经生成的音频（音频与文本可能短暂不一致），
   * 且进度写入会被 `ProgressOwner` 丢弃，由音频时钟继续独占。
   */
  private async refreshCurrentChapter(): Promise<void> {
    if (this.refreshing || this.loading) {
      return;
    }
    const src: BookSource | undefined = this.source;
    const book: Book | undefined = this.book;
    const index: number = this.chapterIndex;
    if (src === undefined || book === undefined || !this.isReadable(index)) {
      return;
    }
    if (isLocalBook(book)) {
      this.toast('本地书籍无需刷新');
      return;
    }
    this.refreshing = true;
    // 作废在飞的 loadChapter / warmNeighbors，避免旧正文回来盖掉刷新结果。
    const gen: number = ++this.loadGen;
    try {
      const chapter: Chapter = this.chapters[index];
      // 留一份旧正文：书源偶发返回空串时，不把本章缓存和正在读的页面一起清掉。
      const previous: string | undefined = this.cachedContent(chapter, index);
      const content: string = await this.fetchContent(chapter, index, true);
      if (content.trim().length === 0) {
        const rollbackCtx: common.UIAbilityContext | undefined = this.ctx();
        if (rollbackCtx !== undefined && previous !== undefined) {
          putCachedChapter(rollbackCtx, book.bookId, index, chapter.url, previous);
        }
        hilog.warn(DOMAIN, TAG, 'refresh: empty body book=%{public}s index=%{public}d', book.name, index);
        if (gen === this.loadGen) {
          this.toast('书源返回空内容，已保留原正文');
        }
        return;
      }
      if (gen !== this.loadGen) {
        return; // 期间用户翻了章：结果丢弃，但缓存已更新，下次打开自然是新正文。
      }
      const ctx: common.UIAbilityContext | undefined = this.ctx();
      if (ctx !== undefined && getDownloadedChapter(ctx, book.bookId, index, chapter.url) !== undefined) {
        try {
          writeDownloadedChapter(ctx, book.bookId, index, chapter.url, content);
        } catch (err) {
          hilog.warn(DOMAIN, TAG, 'refresh: downloaded chapter rewrite failed: %{public}s',
            (err as BusinessError).message);
        }
      }
      // 同章刷新保留当前页身份：长段落跨页时只靠 paragraphIndex 会落回该段起始页，
      // 视觉上往回跳一页（pageId 含段内 start 偏移，可精确回到原页）。
      this.applyChapter(index, content, this.paragraphIndex, false, this.currentPageId);
      await this.persistProgress();
      this.toast('本章已刷新');
      hilog.info(DOMAIN, TAG, 'chapter refreshed book=%{public}s index=%{public}d len=%{public}d',
        book.name, index, content.length);
    } catch (err) {
      if (gen === this.loadGen) {
        hilog.warn(DOMAIN, TAG, 'chapter refresh failed book=%{public}s index=%{public}d msg=%{public}s',
          book.name, index, (err as BusinessError).message);
        this.toast('刷新失败，请稍后重试');
      }
    } finally {
      this.refreshing = false;
    }
  }

  /** Commit a loaded chapter body to the reading surface. */
  private applyChapter(index: number, content: string, restoreParagraph: number, restoreAtEnd: boolean = false,
    restorePageId: string = ''): void {
    const chapter: Chapter = this.chapters[index];
    const paragraphs: string[] = sanitizeText(content, chapter.title);
    this.chapterIndex = index;
    this.paragraphs = paragraphs;
    this.paraCache.set(index, paragraphs);
    // 正文可能变了（重试 / 换源 / 章节内容更新），旧页流不能再复用。
    this.pageCache.delete(index);
    this.sliderValue = index + 1;
    this.paragraphIndex = restoreAtEnd
      ? (paragraphs.length > 0 ? paragraphs.length - 1 : 0)
      : (paragraphs.length > 0 ? Math.min(Math.max(restoreParagraph, 0), paragraphs.length - 1) : 0);
    // 显式载入新章时清空“当前可视页身份”，否则 rebuildWindow 会用旧章的页身份
    // 在跨章页流里重新命中旧页（旧章常作为 prev 邻居仍保留在窗口内），导致
    // 「下一章」/目录点击相邻章时视觉上停在原地不跳转。
    // 同章刷新（restorePageId 非空）是例外：章节与内容位置不变，保留页身份才能
    // 精确回到长段落中间的当前页；若正文已变化导致该页不存在，rebuildWindow 会回退段落锚点。
    this.currentPageId = restorePageId;
    this.loading = false;
    // 首次进入时尺寸尚未测出（contentWidth/Height 还是默认值），若立即 rebuildWindow
    // 会用错误的默认尺寸排版，onAreaChange 再重排一次，就会先闪一帧“未铺满”页面。
    // 所以：尺寸未测出时先清空 pages，由 onAreaChange 用真实尺寸完成首次分页。
    // 本次整体重排已覆盖被手势冻结挂起的那次窗口重排。
    this.rebuildPending = false;
    if (this.sized) {
      this.rebuildWindow(restoreAtEnd);
    } else {
      this.pages = [];
      this.pageSource.setItems([]);
    }
  }

  /** 提前把相邻章（上一章/下一章）的段落文本暖载进 paraCache，供跨章连续页流拼接。 */
  private async warmNeighbors(): Promise<void> {
    const book: Book | undefined = this.book;
    if (book === undefined) {
      return;
    }
    const gen: number = this.loadGen;
    const targets: number[] = [];
    const prev: number = this.prevReadable(this.chapterIndex);
    const next: number = this.nextReadable(this.chapterIndex);
    if (prev >= 0) {
      targets.push(prev);
    }
    // 单章书 / 边界上 prev 与 next 可能同值，去重后只暖一次。
    if (next >= 0 && next !== prev) {
      targets.push(next);
    }
    // 两章互不依赖：并发取，未缓存时跨章可滑动的等待时间不再相加。
    await Promise.all(targets.map((n: number): Promise<void> => this.warmNeighbor(n)));
    if (gen === this.loadGen && this.sized) {
      // 手势/动画在飞时只挂起：立即重排会平移下标，把还在滑动的 Swiper 拽回原页（T-READ-7 手势路径）。
      this.scheduleWindowRebuild();
    }
  }

  /** 暖载单章（`warmNeighbors` 的并发单元）：已解析则跳过，缓存未命中再走引擎单飞。 */
  private async warmNeighbor(n: number): Promise<void> {
    if (n < 0 || this.paraCache.has(n)) {
      return;
    }
    const chapter: Chapter = this.chapters[n];
    const cached: string | undefined = this.cachedContent(chapter, n);
    let content: string | undefined = cached;
    if (content === undefined) {
      try {
        content = await this.fetchContent(chapter, n);
      } catch (err) {
        return;
      }
    }
    if (content !== undefined) {
      this.paraCache.set(n, sanitizeText(content, chapter.title));
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
      const target: number = this.pageIndex + 1;
      this.anchorToPage(target);
      this.swiperController.changeIndex(target, true);
    } else {
      // 本章最后一页：翻到下一章开头。
      this.nextChapter();
    }
  }

  private prevPage(): void {
    if (this.pageIndex > 0) {
      const target: number = this.pageIndex - 1;
      this.anchorToPage(target);
      this.swiperController.changeIndex(target, true);
    } else {
      // 越过本章首页继续往回：进入上一章最后一页，保持向后连续阅读。
      this.prevChapterEnd();
    }
  }

  private onPageChanged(index: number): void {
    this.pageIndex = index;
    if (index < 0 || index >= this.pages.length || this.pages[index].length === 0) {
      this.persistProgress();
      this.finishSwipe();
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
    // 落定：解除手势冻结并补做被挂起的窗口重排（T-READ-7 手势路径）。
    this.finishSwipe();
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

  /**
   * 段首缩进（首行缩进两格，单位 fp；与设计稿 `.read-content p { text-indent: 2em }` 一致）。
   *
   * 只对**段落的第一个片段**生效：`start > 0` 说明该 Text 是段落跨页后的续排片段，它的首行
   * 是上一行折行的延续，缩进会凭空多出两格空档。标题（para 0）左对齐、不缩进。
   */
  private firstLineIndentFp(para: number, start: number): number {
    return para === 0 || start > 0 ? 0 : this.fontSize * 2;
  }

  /** 构造度量选项，与渲染 Text 属性严格对齐（字号/字重/行高/约束宽度/对齐/首行缩进）。 */
  private measureOptions(para: number, start: number): MeasureOptions {
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
    // 缩进必须同时进度量：它挤掉首行两格宽度，段高会因此多出一行；
    // 度量与渲染不一致 ⇒ 页尾按「放得下」截断，实际渲染却溢出被裁。
    const indent: number = this.firstLineIndentFp(para, start);
    if (indent > 0) {
      options.textIndent = `${indent}fp`;
    }
    return options;
  }

  /** 实测段落在 [start, end) 文本的渲染高度（px）。 */
  private measureHeight(para: number, text: string, start: number, end: number): number {
    const options: MeasureOptions = this.measureOptions(para, start);
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
  /** 排版参数指纹：任一变化都必须废弃全部分页缓存（否则页数/截断点会对不上渲染）。 */
  private layoutKey(): string {
    // 段首缩进由 fontSize 推导（2 格），随 fontSize 一起失效，无需单列。
    return this.contentWidth.toString() + 'x' + this.contentHeight.toString() +
      '@' + this.fontSize.toString() + '/' + this.lineHeight.toString();
  }

  /**
   * 取某章的页流（带缓存）。
   *
   * 缓存是**必要**而非优化：窗口内三章每次 `rebuildWindow` 都会重排，而暖载邻章完成后
   * 还会整体再排一次，本章在单次进入里要排两遍；实测 13 万字/2400 段级章节单章 ≈ 600ms。
   */
  private chapterPages(chapterIndex: number, paras: string[]): PageSeg[][] {
    const key: string = this.layoutKey();
    if (key !== this.pageCacheKey) {
      this.pageCache.clear();
      this.pageCacheKey = key;
    }
    const hit: PageSeg[][] | undefined = this.pageCache.get(chapterIndex);
    if (hit !== undefined) {
      return hit;
    }
    const pages: PageSeg[][] = this.paginateChapter(paras, chapterIndex);
    this.pageCache.set(chapterIndex, pages);
    return pages;
  }

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
   * 翻页动画开始前，把「当前可视页身份」提前挪到**目标页**。
   *
   * 为什么必须提前：`changeIndex(±1, true)` 是带动画翻页，`onChange`（→ `onPageChanged`）
   * 要等**动画结束**才回写 `currentPageId` / `paragraphIndex`。而通过目录跳转到一个新章后，
   * `warmNeighbors()` 会异步暖载上一/下一章，暖载回来就 `rebuildWindow(false)` 重排页流；
   * 若这次重排正好落在翻页动画进行中，`rebuildWindow` 就会拿**已经被翻走的那一页**当锚点，
   * 经声明式 `.index(this.pageIndex)` 把 Swiper 拉回原页 —— 真机观感就是「上一页/下一页回弹」。
   * （目录跳转后邻章通常不在 `paraCache` 里，需真去网络/落盘取，暖载完成时刻随机 ⇒ 「有时」复现。）
   *
   * 提前挪锚点后，动画期间的重排会把**目标页**映射到新页流里的正确下标（含 prepend 上一章后的
   * 位移），动画落点不再被改写；动画正常结束时 `onPageChanged` 再回写一次，值相同。
   */
  private anchorToPage(index: number): void {
    if (index < 0 || index >= this.pages.length) {
      return;
    }
    const segs: PageSeg[] = this.pages[index];
    if (segs.length === 0) {
      return;
    }
    const seg: PageSeg = segs[0];
    this.currentPageId = this.pageIdFor(seg);
    this.paragraphIndex = seg.para;
  }

  /**
   * 手势守卫（T-READ-7 的手势路径）：手指落下即冻结窗口重排，落定后再补做（见 `finishSwipe`）。
   *
   * 为什么落手就要冻结：跟手拖动期间 `pageIndex` / `currentPageId` 都还停在**被拖走的那一页**
   * —— 带动画的 index 变化要等落定后才由 `onChange` → `onPageChanged` 回写。此时若
   * `warmNeighbors()` 回来重排窗口，prepend 上一章会让当前页下标整体平移，而
   * `.index(this.pageIndex)` 是声明式活 setter ⇒ Swiper 被拽回原页（真机观感 = 滑着滑着突然回弹）。
   */
  private beginSwipe(): void {
    this.swipeBusy = true;
    this.gestureLoadGen = this.loadGen;
    if (this.swipeWatchdog >= 0) {
      clearTimeout(this.swipeWatchdog);
    }
    // 兜底：某次触摸没走到 `onChange` / `onAnimationEnd` 时别让守卫永久卡住。只解除冻结、
    // **不**补做挂起的重排 —— 万一手势其实还在飞，补做会当场把 Swiper 拽回去。
    this.swipeWatchdog = setTimeout(() => {
      this.swipeWatchdog = -1;
      this.swipeBusy = false;
    }, SWIPE_WATCHDOG_MS);
  }

  /** 解除手势冻结（不补做挂起的重排；挂起的重排留给下一次落定补做）。 */
  private releaseSwipeGuard(): void {
    if (this.swipeWatchdog >= 0) {
      clearTimeout(this.swipeWatchdog);
      this.swipeWatchdog = -1;
    }
    this.swipeBusy = false;
  }

  /** 补做被手势冻结的窗口重排（`warmNeighbors()` 的异步重排只挂起、不丢）。 */
  private flushWindowRebuild(): void {
    if (!this.rebuildPending) {
      return;
    }
    this.rebuildPending = false;
    this.rebuildWindow(false);
  }

  /** 手势落定收尾：解除冻结并补做挂起的窗口重排。 */
  private finishSwipe(): void {
    this.releaseSwipeGuard();
    this.flushWindowRebuild();
  }

  /**
   * `warmNeighbors()` 的异步窗口重排：手势/翻页动画在飞时只挂起，落定后由 `finishSwipe()` 补做；
   * 静止时照旧立即重排（与修复前一致）。
   */
  private scheduleWindowRebuild(): void {
    if (this.swipeBusy) {
      this.rebuildPending = true;
      return;
    }
    this.rebuildWindow(false);
  }

  /**
   * Swiper 落定（`onAnimationEnd`）：按实际落点收尾手势。
   *
   * - 落点换了页：`onChange` 随后会带同一个 index 回来，由 `onPageChanged` 做完整重锚
   *   （跨章还会整体重排）。这里**不能**先补做重排 —— 下标一旦平移，随后的 `onChange(index)`
   *   就会指到别的页。
   * - 落点没换页（拖动没过阈值、spring-back，`onChange` 不触发）：把 `onAnimationStart` 可能
   *   提前挪到「没到达的目标页」的锚点还原回当前页，再补做挂起的重排。
   */
  private settleSwipe(index: number): void {
    if (!this.swipeBusy) {
      return;
    }
    // 手势期间发生过显式载章：锚点与页流归 `applyChapter` 说了算，别用旧落点覆盖。
    if (this.loadGen !== this.gestureLoadGen) {
      this.finishSwipe();
      return;
    }
    if (index !== this.pageIndex) {
      // 保持冻结：`onChange` 随后回来才由 `onPageChanged` 结清。这里若解冻，`onChange` 到达前
      // 落下的一次重排就会平移下标，让随后的 `onChange(index)` 指到别的页。万一 `onChange`
      // 没来，`beginSwipe` 的兜底定时器最多 2s 后解冻（挂起的重排留给下一次落定补做）。
      return;
    }
    // 页流在手势期间被冻结（异步重排只挂起、显式载章已被上面挡掉），这里的下标仍有效。
    if (index >= 0 && index < this.pages.length && this.pages[index].length > 0) {
      const seg: PageSeg = this.pages[index][0];
      this.currentPageId = this.pageIdFor(seg);
      this.paragraphIndex = seg.para;
    }
    this.finishSwipe();
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
        flat = flat.concat(this.chapterPages(prev, p));
      }
    }
    flat = flat.concat(this.chapterPages(this.chapterIndex, this.paragraphs));
    if (next >= 0) {
      const n: string[] | undefined = this.paraCache.get(next);
      if (n !== undefined && n.length > 0) {
        flat = flat.concat(this.chapterPages(next, n));
      }
    }
    this.pages = flat;
    this.pageSource.setItems(flat);
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
    if (mode === PANEL_SOURCE) {
      // 自增令牌而不是 `visible`：面板常驻挂载，只有令牌变化才会触发它重读书源 + 重新检索。
      this.sourcePanelToken = this.sourcePanelToken + 1;
      // 候选数归零：避免抽屉滑出的一瞬间还挂着上一次打开时的数量（本轮由面板 onCount 重新累计）。
      this.switchCount = 0;
    }
    this.panel = mode;
    this.menuVisible = true;
  }

  private openDetail(): void {
    const src: BookSource | undefined = this.source;
    const book: Book | undefined = this.book;
    this.panel = PANEL_NONE;
    this.menuVisible = false;
    if (src !== undefined && book !== undefined) {
      this.onMore(src, book);
    }
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  private async refreshDownloadState(): Promise<void> {
    const gen: number = ++this.downloadStateGen;
    const book: Book | undefined = this.book;
    const ctx: common.UIAbilityContext | undefined = this.ctx();
    if (book === undefined || ctx === undefined) {
      this.downloadStateReady = false;
      return;
    }
    let inShelf: boolean = false;
    try {
      inShelf = await isBookInShelf(book.bookId);
    } catch (err) {
      inShelf = false;
    }
    if (gen !== this.downloadStateGen || this.book === undefined ||
      this.book.bookId !== book.bookId) {
      return;
    }
    const state: BookDownloadState = inspectDownload(ctx, book, this.chapters);
    this.downloadInShelf = inShelf;
    this.downloadHasDirectory = state.hasDirectory;
    this.downloadComplete = state.complete;
    this.downloadNeedsUpdate = state.needsUpdate;
    this.downloadReadableCount = state.readableCount;
    this.downloadStateReady = true;
  }

  private downloadMenuElement(): MenuElement {
    const book: Book | undefined = this.book;
    if (book !== undefined && isLocalBook(book)) {
      return { value: '不支持下载', enabled: false, action: () => {} };
    }
    if (book === undefined || !this.downloadStateReady) {
      return { value: '下载书籍', enabled: false, action: () => {} };
    }
    if (!this.downloadInShelf) {
      return { value: '请先加入书架', enabled: false, action: () => {} };
    }
    if (this.downloader.isActiveFor(book.bookId)) {
      if (this.downloader.message === '正在取消') {
        return { value: '正在取消', enabled: false, action: () => {} };
      }
      return { value: '取消下载', enabled: true, action: () => this.cancelDownload() };
    }
    if (this.downloader.running) {
      return { value: '其他书籍下载中', enabled: false, action: () => {} };
    }
    if (this.downloadComplete) {
      return { value: '已下载', enabled: false, action: () => {} };
    }
    if (this.downloadNeedsUpdate) {
      return { value: '下载新章节', enabled: true, action: () => this.startDownload() };
    }
    if (this.downloadHasDirectory) {
      return { value: '重新下载', enabled: true, action: () => this.startDownload() };
    }
    return {
      value: '下载书籍',
      enabled: this.chapters.length > 0 && this.downloadReadableCount > 0,
      action: () => this.startDownload()
    };
  }

  private startDownload(): void {
    const ctx: common.UIAbilityContext | undefined = this.ctx();
    const src: BookSource | undefined = this.source;
    const book: Book | undefined = this.book;
    if (ctx === undefined || src === undefined || book === undefined || this.chapters.length === 0) {
      this.toast('无法开始下载');
      return;
    }
    if (!this.downloadInShelf) {
      this.toast('请先将书籍加入书架');
      this.refreshDownloadState();
      return;
    }
    if (this.downloader.start(ctx, src, book, this.chapters)) {
      this.downloadWasRunning = true;
      this.toast('开始下载');
      this.refreshDownloadState();
      return;
    }
    this.toast(this.downloader.running ? '已有下载任务进行中' : '无法开始下载');
  }

  private cancelDownload(): void {
    const book: Book | undefined = this.book;
    if (book === undefined || !this.downloader.cancelForBook(book.bookId)) {
      return;
    }
    this.toast('正在取消下载');
    this.refreshDownloadState();
  }

  private exportMenuElement(): MenuElement {
    if (this.exportingTxt) {
      return { value: '正在导出 TXT', enabled: false, action: () => {} };
    }
    return { value: '导出 TXT', enabled: this.downloadComplete, action: () => this.exportDownloadedAsTxt() };
  }

  private async exportDownloadedAsTxt(): Promise<void> {
    const book: Book | undefined = this.book;
    const ctx: common.UIAbilityContext | undefined = this.ctx();
    if (book === undefined || ctx === undefined || this.exportingTxt) {
      return;
    }
    this.exportingTxt = true;
    try {
      const saved: boolean = await exportDownloadedTxt(ctx, book, this.chapters);
      if (saved) {
        this.toast('TXT 已导出');
      }
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'txt export failed book=%{public}s msg=%{public}s',
        book.name, (err as Error).message);
      this.toast('导出 TXT 失败');
    } finally {
      this.exportingTxt = false;
    }
  }

  // ── 换源（v1.1）───────────────────────────────────────────────

  private openSourceSwitch(): void {
    const book: Book | undefined = this.book;
    if (book !== undefined && isLocalBook(book)) {
      this.toast('本地书籍不支持换源');
      return;
    }
    // 候选数归零由 openPanel 的 PANEL_SOURCE 分支负责（面板常驻，这里是同一入口）。
    this.openPanel(PANEL_SOURCE);
  }

  /**
   * 换源会删掉当前源的书架行与全部缓存，所以先要一次显式确认；
   * 真正的执行在 `applySwitch`（`model/SourceSwitch.switchSource`）。
   *
   * `quality`（`model/TocQuality.ets`）来自抽屉的目录体检，只有做过体检的候选才有；
   * **可疑级**（目录里有重复 URL 行）会在确认框里加一句警示——换源不消除它，
   * 但用户有权在删旧行之前知道「切过去也会碰到一样的问题」。
   */
  private confirmSwitch(target: BookSource, item: BookSearchItem, quality: TocQuality | undefined): void {
    if (this.switching || this.book === undefined) {
      return;
    }
    const name: string = target.bookSourceName.length > 0 ? target.bookSourceName : target.bookSourceUrl;
    const tocWarning: string = tocQualityWarning(quality);
    this.getUIContext().showAlertDialog({
      title: '切换到「' + name + '」',
      message: '当前源的书架记录与缓存会被清除，阅读进度将按章节对齐迁移到新源，此操作不可撤销。' +
        (tocWarning.length > 0 ? '\n\n⚠ ' + tocWarning : ''),
      autoCancel: true,
      primaryButton: {
        value: '取消',
        fontColor: $r('app.color.text_2'),
        action: () => {
        }
      },
      secondaryButton: {
        value: '切换',
        fontColor: $r('app.color.brand'),
        action: () => {
          this.applySwitch(target, item);
        }
      }
    });
  }

  private async applySwitch(target: BookSource, item: BookSearchItem): Promise<void> {
    const old: Book | undefined = this.book;
    const oldSrc: BookSource | undefined = this.source;
    if (old === undefined || oldSrc === undefined || this.switching) {
      return;
    }
    this.switching = true;
    try {
      const progress: ReadProgress | undefined = await getProgress(old.bookId);
      const out: SwitchOutcome = await switchSource(this.ctx(), old, oldSrc, progress, target, item);
      // 先丢弃旧书的正文状态，再切换身份并整体重载：`load()` 会用新 bookId 重新读目录与进度
      //（进度已由 `switchSource` 写好），因此落点就是迁移后的那一章。
      this.resetContentState();
      this.source = target;
      this.book = out.book;
      this.panel = PANEL_NONE;
      this.menuVisible = false;
      this.loading = true;
      await this.load();
      this.toast(this.switchMessage(target, out));
    } catch (err) {
      this.toast('换源失败：' + (err as Error).message);
    } finally {
      this.switching = false;
    }
  }

  private switchMessage(target: BookSource, out: SwitchOutcome): string {
    const name: string = target.bookSourceName.length > 0 ? target.bookSourceName : target.bookSourceUrl;
    const how: string = out.matchedBy === 'title'
      ? '按章节对齐'
      : (out.matchedBy === 'percent' ? '按进度对齐' : '从第一章开始');
    return '已切换到「' + name + '」，' + how + '到第 ' + (out.chapterIndex + 1).toString() + ' 章';
  }

  /**
   * 换源后必须整块丢弃的正文状态：`paraCache` / `pages` 都以**章节下标**为键，而新源的
   * 同一下标是完全不同的正文，留着会渲染出上一个源的文本；`inflight` 的 key 里含旧 bookId，
   * 不清的话新书的首次抓取可能命中旧书的在飞请求。
   */
  private resetContentState(): void {
    this.loadGen = this.loadGen + 1;
    this.tocSession = this.tocSession + 1;
    this.paraCache.clear();
    this.pageCache.clear();
    this.pageCacheKey = '';
    this.inflight.clear();
    this.releaseSwipeGuard();
    this.rebuildPending = false;
    this.currentPageId = '';
    this.pages = [];
    this.pageSource.setItems([]);
    this.pageIndex = 0;
    this.paragraphs = [];
    this.paragraphIndex = 0;
    this.chapterIndex = 0;
    this.chapters = [];
    this.sliderValue = 1;
    this.buildTocItems();
  }

  private openListening(): void {
    if (!LISTENING_FEATURE_ENABLED) {
      return;
    }
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
    const items: MenuElement[] = [
      {
        value: '书籍详情',
        action: () => this.openDetail()
      },
      this.downloadMenuElement()
    ];
    if (this.downloadComplete || this.exportingTxt) {
      items.push(this.exportMenuElement());
    }
    return items;
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
    // 通知常驻的目录抽屉原地重渲染（表头标签 + LazyForEach 重键）；见 `tocContentRevision`。
    this.tocContentRevision += 1;
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

  // 抽屉内的横线 / 拖拽指示条：必须跟着阅读日夜主题走（见 BottomDrawer.lineColor）。
  // 用全局 `divider` 会踩「系统深色 + 阅读白天」：深色资源是 #2A2A2A，画在白面板上就是一条黑线。
  // 与 reader_bg / reader_dim 同规格：base 与 dark 两份 color.json 里是同一组值（不随系统变）。
  private lineColor(): Resource {
    return this.nightMode ? $r('app.color.reader_divider') : $r('app.color.reader_divider_day');
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

  /**
   * 顶栏两个自定义 SVG 按钮刻意用 **0 参数 @Builder + 直读 @Local**：多参数 @Builder
   * 不会随父组件 @Local 动态刷新（见 Index.ets §5.3 K10），而图标颜色跟 `nightMode`、
   * 刷新态跟 `refreshing` 都必须实时变。
   *
   * 图标按日夜各放一份资源：阅读日夜是**页内状态**，不随系统主题，不能用资源限定词；
   * 且两个图标一个是 stroke、一个是 fill，`Image.fillColor` 对 stroke 是否覆盖没有可靠
   * 保证，双份资源最确定。色值与 color.json 的 reader_text_day / reader_text 一致。
   * 尺寸沿用 UI-SPEC §1.7：44×44 热区、`READER_TOP_ICON_SIZE` 24vp 画板。两个 SVG 内部
   * 已按 **20vp 墨迹 + 2vp 居中留白** 裁好（与既有 `refresh_ccw.svg` 一致），画板尺寸用
   * 同一个常量控制，不要单独放大某一个按钮；横向的换源图标高度按固有比例约 13.5vp，属正常。
   */
  @Builder
  sourceSwitchButton() {
    Row() {
      Image(this.nightMode
        ? $r('app.media.reader_switch_source_night')
        : $r('app.media.reader_switch_source_day'))
        .width(READER_TOP_ICON_SIZE)
        .height(READER_TOP_ICON_SIZE)
        .objectFit(ImageFit.Contain)
    }
    .width(44)
    .height(44)
    .justifyContent(FlexAlign.Center)
    .accessibilityText('换源')
    .accessibilityLevel('yes')
    .onClick(() => this.openSourceSwitch())
  }

  @Builder
  refreshChapterButton() {
    Row() {
      Image(this.nightMode
        ? $r('app.media.reader_refresh_chapter_night')
        : $r('app.media.reader_refresh_chapter_day'))
        .width(READER_TOP_ICON_SIZE)
        .height(READER_TOP_ICON_SIZE)
        .objectFit(ImageFit.Contain)
        .opacity(this.refreshing ? 0.4 : 1)
    }
    .width(44)
    .height(44)
    .justifyContent(FlexAlign.Center)
    .accessibilityText(this.refreshing ? '正在刷新本章' : '刷新本章')
    .accessibilityLevel('yes')
    .onClick(() => {
      this.refreshCurrentChapter();
    })
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
      this.sourceSwitchButton()
      this.refreshChapterButton()
      MoreMenuButton({
        items: this.moreMenuItems(),
        color: this.dimColor(),
        label: '更多',
        dotSize: 5
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
        if (LISTENING_FEATURE_ENABLED) {
          this.funcButton($r('sys.symbol.headphones'), '听书', this.tts.active,
            () => this.openListening())
        }
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
      // LazyForEach：只实例化可视页与预加载页。原先的 ForEach 在长章节（单章可达数百页）下
      // 会一次性挂载整个页流，首帧代价随页数线性增长。
      LazyForEach(this.pageSource, (page: PageSeg[], pageIdx: number) => {
        Column() {
          ForEach(page, (seg: PageSeg) => {
            Text(this.paragraphsOf(seg.chapterIndex)[seg.para].substring(seg.start, seg.end))
              .fontSize(seg.para === 0 ? this.fontSize + 3 : this.fontSize)
              .fontWeight(seg.para === 0 ? FontWeight.Bold : FontWeight.Normal)
              .lineHeight(this.fontSize * this.lineHeight)
              .fontColor(this.isSpeaking(seg) ? $r('app.color.brand') : this.textColor())
              // 段首空两格；跨页续排片段（seg.start > 0）不缩进，标题不缩进。
              // 与 `measureOptions` 的 textIndent 必须同步，否则度量/渲染不一致。
              .textIndent(this.firstLineIndentFp(seg.para, seg.start))
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
    // 手指落下即冻结窗口重排（T-READ-7 手势路径）；落定由 onAnimationEnd / onChange 结清。
    .onTouch((event: TouchEvent) => {
      if (event.type === TouchType.Down) {
        this.beginSwipe();
      }
    })
    // 松手起动画时把页身份提前挪到**目标页**（与 nextPage / prevPage 同一套锚点）：
    // 万一手势期间仍有重排走到这里（兜底定时器 / 竞态），映射的也是目标页而不是原页。
    .onAnimationStart((index: number, targetIndex: number) => {
      if (this.swipeBusy && this.loadGen === this.gestureLoadGen) {
        this.anchorToPage(targetIndex);
      }
    })
    .onAnimationEnd((index: number) => {
      this.settleSwipe(index);
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
          // 20vp 阈值之后才触发；手指刚落下的那段由 Swiper 的 onTouch(Down) 兜住。
          this.beginSwipe();
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
          if (this.loadingMessage.length > 0) {
            Text(this.loadingMessage)
              .fontSize(14)
              .fontColor(this.textColor())
              .margin({ top: 12 })
          }
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
      } else if (this.failed.length > 0) {
        Column() {
          Text(this.failed)
            .fontSize(15)
            .fontColor(this.textColor())
          Button(this.localTextMissing
            ? (this.relinkingLocal ? '正在关联…' : '重新关联 TXT')
            : '重试')
            .margin({ top: 12 })
            .backgroundColor($r('app.color.brand'))
            .fontColor($r('app.color.on_brand'))
            .enabled(!this.relinkingLocal)
            .onClick(() => {
              this.retryLoad();
            })
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
      if (LISTENING_FEATURE_ENABLED && this.tts.active) {
        FloatingListenButton({
          visible: true,
          onTap: () => this.onOpenListening()
        })
      }

      // 目录抽屉**常驻挂载**（UI-SPEC §1.1）：顺序刷新由 `buildTocItems()` 的
      // `setItems()` 完成，内容重建交给 `contentRevision`（原地重渲染）。
      // 曾经用 `if (this.tocDescending)` 分支持序重挂载：那会把整个抽屉销毁重建，
      // 新实例的 `@Local` 复位、`visible` 仍为 true ⇒ `aboutToAppear` 重播 260ms
      // 上滑开启动画（真机观感 = 点正序/倒序时抽屉又「重开」一次）。
      BottomDrawer({
        visible: this.panel === PANEL_TOC,
        sheetSize: 'large',
        mode: 'overlay',
        showHeader: false,
        contentRevision: this.tocContentRevision,
        panelBackground: this.bgColor(),
        lineColor: this.lineColor(),
        onClose: () => {
          this.panel = PANEL_NONE;
        }
      }) {
        this.tocDrawerContent()
      }

      BottomDrawer({
        visible: this.panel === PANEL_SETTINGS,
        sheetSize: 'fit',
        mode: 'overlay',
        showHeader: false,
        panelBackground: this.bgColor(),
        lineColor: this.lineColor(),
        onClose: () => {
          this.panel = PANEL_NONE;
        }
      }) {
        this.settingsDrawerContent()
      }

      BottomDrawer({
        visible: this.panel === PANEL_SOURCE,
        title: '换源 · ' + this.switchCount.toString() + ' 个候选',
        sheetSize: 'large',
        mode: 'overlay',
        // 面板底色跟随阅读页日夜主题（`reader_bg` 在浅色系统下也是深色），
        // 而标题栏默认用全局令牌（浅色系统下 `text_1` = #333333）→ 必须显式传色。
        titleColor: this.textColor(),
        iconColor: this.dimColor(),
        panelBackground: this.bgColor(),
        lineColor: this.lineColor(),
        onClose: () => {
          this.panel = PANEL_NONE;
        }
      }) {
        SourceSwitchPanel({
          runToken: this.sourcePanelToken,
          book: this.book,
          currentSourceUrl: this.source !== undefined ? this.source.bookSourceUrl : '',
          currentSourceName: this.source !== undefined
            ? (this.source.bookSourceName.length > 0 ? this.source.bookSourceName : this.source.bookSourceUrl)
            : '',
          textColor: this.textColor(),
          dimColor: this.dimColor(),
          busy: this.switching,
          onCount: (count: number) => {
            this.switchCount = count;
          },
          onPick: (source: BookSource, item: BookSearchItem, quality: TocQuality | undefined) =>
            this.confirmSwitch(source, item, quality)
        })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.bgColor())
  }
}
