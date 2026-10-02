import { common, ConfigurationConstant } from '@kit.AbilityKit';
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
import { ReaderTheme } from '../common/ReaderTheme';
import { getCachedChapter, putCachedChapter } from '../model/ChapterCache';
import { isLocalBook, loadLocalChapters, loadLocalContent } from '../model/LocalBook';
import { TtsController } from '../model/TtsController';
import { FloatingListenButton } from '../ui/common/FloatingListenButton';
import { AppBackButton } from '../ui/common/AppBackButton';
import { MoreMenuButton } from '../ui/common/MoreMenuButton';

const PANEL_NONE: string = '';
const PANEL_TOC: string = 'toc';
const PANEL_SETTINGS: string = 'settings';

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
  @Local sliderValue: number = 1;
  @Local tts: TtsController = TtsController.instance();

  private contentScroller: Scroller = new Scroller();
  private tocScroller: Scroller = new Scroller();
  @Local dataSource: ChapterDataSource = new ChapterDataSource();
  /** Monotonic token so a slow chapter fetch cannot overwrite a newer one. */
  private loadGen: number = 0;

  @Monitor('tts.paragraphIndex', 'tts.chapterIndex')
  onTtsProgress(): void {
    const book: Book | undefined = this.book;
    if (book === undefined || !this.tts.isActiveFor(book.bookId)) {
      return;
    }
    if (this.tts.chapterIndex !== this.chapterIndex) {
      this.loadChapter(this.tts.chapterIndex);
      return;
    }
    try {
      this.contentScroller.scrollToIndex(this.tts.paragraphIndex);
    } catch (err) {
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

  private async load(): Promise<void> {
    const src: BookSource | undefined = this.source;
    const book: Book | undefined = this.book;
    if (src === undefined || book === undefined) {
      this.failed = '缺少书籍信息';
      this.loading = false;
      return;
    }
    try {
      let chapters: Chapter[];
      if (isLocalBook(book)) {
        const c: common.UIAbilityContext | undefined = this.ctx();
        chapters = c !== undefined ? loadLocalChapters(c, book) : [];
      } else {
        chapters = await bookEngine.toc(src, book.tocUrl);
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

  private async loadChapter(index: number, restoreParagraph: number = 0): Promise<void> {
    if (!this.isReadable(index)) {
      return;
    }
    const gen: number = ++this.loadGen;
    this.failed = '';
    const chapter: Chapter = this.chapters[index];
    const cached: string | undefined = this.cachedContent(chapter, index);
    if (cached !== undefined) {
      this.applyChapter(index, cached, restoreParagraph);
      await this.persistProgress();
      if (gen !== this.loadGen) {
        return;
      }
      this.prefetch(this.nextReadable(index));
      return;
    }
    this.loading = true;
    try {
      const content: string = await this.fetchContent(chapter, index);
      if (gen !== this.loadGen) {
        return;
      }
      this.applyChapter(index, content, restoreParagraph);
      await this.persistProgress();
      if (gen !== this.loadGen) {
        return;
      }
      this.prefetch(this.nextReadable(index));
    } catch (err) {
      if (gen === this.loadGen) {
        this.failed = '正文加载失败，点击重试';
        this.paragraphs = [];
        this.loading = false;
      }
    }
  }

  /** Commit a loaded chapter body to the reading surface. */
  private applyChapter(index: number, content: string, restoreParagraph: number): void {
    const chapter: Chapter = this.chapters[index];
    const paragraphs: string[] = this.sanitize(content, chapter.title);
    this.chapterIndex = index;
    this.paragraphs = paragraphs;
    this.sliderValue = index + 1;
    this.paragraphIndex = paragraphs.length > 0
      ? Math.min(Math.max(restoreParagraph, 0), paragraphs.length - 1)
      : 0;
    this.loading = false;
    const target: number = this.paragraphIndex;
    setTimeout(() => {
      try {
        this.contentScroller.scrollToIndex(target);
      } catch (err) {
      }
    }, 60);
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
    });
  }

  private prevChapter(): void {
    this.loadChapter(this.prevReadable(this.chapterIndex));
  }

  private nextChapter(): void {
    this.loadChapter(this.nextReadable(this.chapterIndex));
  }

  private onScrollIndex(start: number): void {
    if (this.paragraphs.length === 0) {
      this.paragraphIndex = 0;
      return;
    }
    this.paragraphIndex = Math.min(Math.max(start, 0), this.paragraphs.length - 1);
  }

  private onContentTap(x: number, width: number): void {
    if (this.menuVisible) {
      return;
    }
    if (this.oneHandMode) {
      if (x < width * 0.45) {
        this.prevChapter();
      } else if (x > width * 0.55) {
        this.nextChapter();
      } else {
        this.menuVisible = true;
      }
      return;
    }
    // 竖向滚动下左右热区是「翻章」，误触成本远高于翻页，故中间菜单区放宽到 1/2（番茄/起点默认三分法适合分页阅读）。
    if (x < width * 0.25) {
      this.prevChapter();
    } else if (x < width * 0.75) {
      this.menuVisible = true;
    } else {
      this.nextChapter();
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

  private isSpeaking(index: number): boolean {
    const book: Book | undefined = this.book;
    if (book === undefined || !this.tts.isActiveFor(book.bookId)) {
      return false;
    }
    return this.tts.chapterIndex === this.chapterIndex
      && this.tts.paragraphIndex === index;
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
    const next: ChapterDataSource = new ChapterDataSource();
    next.setItems(ordered);
    this.dataSource = next;
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
  }

  private changeLineHeight(delta: number): void {
    const next: number = Math.round(Math.min(2.6, Math.max(1.2, this.lineHeight + delta)) * 10) / 10;
    this.lineHeight = next;
    const ctx: common.UIAbilityContext | undefined = this.ctx();
    if (ctx !== undefined) {
      putNumber(ctx, KEY_READER_LINE_HEIGHT, next);
    }
  }

  // ── Colors (reader keeps its own day/night, independent of global theme) ──

  private bgColor(): Resource {
    return this.nightMode ? $r('app.color.reader_bg') : $r('app.color.reader_bg_day');
  }

  private textColor(): Resource {
    return this.nightMode ? $r('app.color.reader_text') : $r('app.color.reader_text_day');
  }

  private panelColor(): Resource {
    return this.nightMode ? $r('app.color.reader_panel') : $r('app.color.reader_panel_day');
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
          .trackColor(this.panelColor())
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
      .backgroundColor(this.panelColor())
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
    .backgroundColor(this.bgColor())
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

      Text('阅读页独立于全局主题；设置即时生效并持久化。')
        .fontSize(12)
        .fontColor(this.dimColor())
        .width('100%')
        .padding({ left: 16, right: 16, top: 12 })
    }
    .width('100%')
    .backgroundColor(this.bgColor())
  }

  @Builder
  contentList() {
    List({ space: 0, scroller: this.contentScroller }) {
      ForEach(this.paragraphs, (p: string, index: number) => {
        ListItem() {
          Text(p)
            .fontSize(index === 0 ? this.fontSize + 3 : this.fontSize)
            .fontWeight(index === 0 ? FontWeight.Bold : FontWeight.Normal)
            .lineHeight(this.fontSize * this.lineHeight)
            .fontColor(this.isSpeaking(index) ? $r('app.color.brand') : this.textColor())
            .width('100%')
            .margin({ bottom: index === 0 ? this.fontSize : this.fontSize * 0.6 })
        }
      }, (p: string, index: number) => this.chapterIndex.toString() + '_' + index.toString())
    }
    .width('100%')
    .height('100%')
    .padding({ left: 20, right: 20, top: 20, bottom: 40 })
    .scrollBar(BarState.Off)
    .onScrollIndex((start: number) => {
      this.onScrollIndex(start);
    })
    .onScrollStop(() => {
      this.persistProgress();
    })
    .onAreaChange((oldValue: Area, newValue: Area) => {
      this.contentWidth = Number(newValue.width);
    })
    .onClick((event: ClickEvent) => {
      this.onContentTap(event.x, this.contentWidth);
    })
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
        this.contentList()
      }

      if (this.menuVisible && !this.loading && this.failed.length === 0) {
        Column() {
          this.topBar()
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
          title: '目录',
          sheetSize: 'large',
          mode: 'overlay',
          onClose: () => {
            this.panel = PANEL_NONE;
          }
        }) {
          this.tocDrawerContent()
        }
      } else {
        BottomDrawer({
          visible: this.panel === PANEL_TOC,
          title: '目录',
          sheetSize: 'large',
          mode: 'overlay',
          onClose: () => {
            this.panel = PANEL_NONE;
          }
        }) {
          this.tocDrawerContent()
        }
      }

      BottomDrawer({
        visible: this.panel === PANEL_SETTINGS,
        title: '阅读设置',
        sheetSize: 'fit',
        mode: 'overlay',
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