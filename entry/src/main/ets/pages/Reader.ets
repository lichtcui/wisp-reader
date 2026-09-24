import { common } from '@kit.AbilityKit';
import { bookEngine } from '../engine/BookEngineNapi';
import { Book, BookSource, Chapter, ReadProgress } from '../engine/types';
import { ChapterDataSource } from '../common/ChapterDataSource';
import {
  KEY_READER_FONT_SIZE,
  KEY_READER_LINE_HEIGHT,
  READER_FONT_SIZE_DEFAULT,
  READER_LINE_HEIGHT_DEFAULT
} from '../common/Const';
import { getNumber, putNumber } from '../common/Prefs';
import { getProgress, saveProgress } from '../model/ShelfRepository';
import { getCachedChapter, putCachedChapter } from '../model/ChapterCache';

@ComponentV2
export struct ReaderPage {
  @Param source: BookSource | undefined = undefined;
  @Param book: Book | undefined = undefined;
  @Event onBack: () => void = () => {};
  @Event onMore: () => void = () => {};

  @Local chapters: Chapter[] = [];
  @Local chapterIndex: number = 0;
  @Local paragraphs: string[] = [];
  @Local paragraphIndex: number = 0;
  @Local loading: boolean = true;
  @Local failed: string = '';
  @Local menuVisible: boolean = false;
  @Local sheetVisible: boolean = false;
  @Local sheetMode: string = 'toc';
  @Local tocDescending: boolean = false;
  @Local fontSize: number = READER_FONT_SIZE_DEFAULT;
  @Local lineHeight: number = READER_LINE_HEIGHT_DEFAULT;
  @Local contentWidth: number = 360;

  private contentScroller: Scroller = new Scroller();
  private tocScroller: Scroller = new Scroller();
  private dataSource: ChapterDataSource = new ChapterDataSource();

  aboutToAppear(): void {
    const ctx: common.UIAbilityContext | undefined =
      this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    if (ctx !== undefined) {
      this.fontSize = getNumber(ctx, KEY_READER_FONT_SIZE, READER_FONT_SIZE_DEFAULT);
      this.lineHeight = getNumber(ctx, KEY_READER_LINE_HEIGHT, READER_LINE_HEIGHT_DEFAULT);
    }
    this.load();
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
      const chapters: Chapter[] = await bookEngine.toc(src, book.tocUrl);
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

  private async loadChapter(index: number, restoreParagraph: number = 0): Promise<void> {
    if (!this.isReadable(index)) {
      return;
    }
    this.loading = true;
    this.failed = '';
    try {
      const chapter: Chapter = this.chapters[index];
      const content: string = await this.fetchContent(chapter, index);
      this.paragraphs = content.split('\n');
      this.chapterIndex = index;
      this.paragraphIndex = restoreParagraph;
      this.loading = false;
      const target: number = restoreParagraph > 0 && this.paragraphs.length > 0
        ? Math.min(restoreParagraph, this.paragraphs.length - 1)
        : 0;
      setTimeout(() => {
        try {
          this.contentScroller.scrollToIndex(target);
        } catch (err) {
        }
      }, 60);
      await this.persistProgress();
      this.prefetch(this.nextReadable(index));
    } catch (err) {
      this.failed = '正文加载失败，点击重试';
      this.paragraphs = [];
      this.loading = false;
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
    if (x < width / 3) {
      this.prevChapter();
    } else if (x < width * 2 / 3) {
      this.menuVisible = !this.menuVisible;
    } else {
      this.nextChapter();
    }
  }

  // ── TOC ordering / positioning ────────────────────────────────

  private buildTocItems(): void {
    const ordered: Chapter[] = this.tocDescending
      ? this.chapters.slice().reverse()
      : this.chapters.slice();
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
    const pos: number = this.tocDescending
      ? this.chapters.length - 1 - this.chapterIndex
      : this.chapterIndex;
    try {
      this.tocScroller.scrollToIndex(pos);
    } catch (err) {
    }
  }

  private toggleTocOrder(): void {
    this.tocDescending = !this.tocDescending;
    this.buildTocItems();
    setTimeout(() => this.locateCurrentToc(), 60);
  }

  private openToc(): void {
    this.sheetMode = 'toc';
    this.sheetVisible = true;
    setTimeout(() => this.locateCurrentToc(), 120);
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

  // ── UI builders ───────────────────────────────────────────────

  @Builder
  topBar() {
    Row() {
      Text('‹')
        .fontSize(26)
        .fontColor($r('app.color.reader_text'))
        .width(44)
        .height(44)
        .textAlign(TextAlign.Center)
        .onClick(() => this.onBack())
      Text(this.chapters.length > 0 ? this.chapters[this.chapterIndex].title : '')
        .fontSize(16)
        .fontColor($r('app.color.reader_text'))
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text('更多')
        .fontSize(14)
        .fontColor($r('app.color.reader_text'))
        .width(56)
        .textAlign(TextAlign.Center)
        .onClick(() => this.onMore())
    }
    .width('100%')
    .height(56)
    .padding({ left: 4, right: 8 })
    .backgroundColor($r('app.color.reader_panel'))
  }

  @Builder
  bottomBar() {
    Column() {
      Row() {
        Text(`${this.chapterIndex + 1} / ${this.chapters.length}`)
          .fontSize(13)
          .fontColor($r('app.color.reader_text'))
        Blank()
        Progress({ value: this.chapterIndex + 1, total: Math.max(this.chapters.length, 1) })
          .layoutWeight(1)
          .color($r('app.color.brand'))
          .backgroundColor($r('app.color.reader_panel'))
          .margin({ left: 12, right: 12 })
        Text(`${Math.round((this.chapterIndex + 1) / Math.max(this.chapters.length, 1) * 100)}%`)
          .fontSize(13)
          .fontColor($r('app.color.reader_text'))
      }
      .width('100%')
      .margin({ bottom: 16 })

      Row() {
        this.barButton('上一章', () => this.prevChapter())
        this.barButton('目录', () => this.openToc())
        this.barButton('设置', () => {
          this.sheetMode = 'settings';
          this.sheetVisible = true;
        })
        this.barButton('下一章', () => this.nextChapter())
      }
      .width('100%')
      .justifyContent(FlexAlign.SpaceAround)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 16, bottom: 24 })
    .backgroundColor($r('app.color.reader_panel'))
  }

  @Builder
  barButton(label: string, action: () => void) {
    Text(label)
      .fontSize(14)
      .fontColor($r('app.color.reader_text'))
      .padding({ left: 12, right: 12, top: 8, bottom: 8 })
      .onClick(action)
  }

  @Builder
  tocSheet() {
    Column() {
      Row() {
        Text('目录')
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_1'))
        Text(` · ${this.readableCount()} 章`)
          .fontSize(13)
          .fontColor($r('app.color.text_4'))
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
      .padding({ left: 16, right: 16, top: 14, bottom: 8 })

      List({ space: 0, scroller: this.tocScroller }) {
        LazyForEach(this.dataSource, (chapter: Chapter, index: number) => {
          ListItem() {
            if (chapter.isVolume === true) {
              Text(chapter.title)
                .fontSize(13)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_4'))
                .width('100%')
                .padding({ left: 16, right: 16, top: 14, bottom: 6 })
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            } else {
              Text(chapter.title)
                .fontSize(15)
                .fontColor(chapter.index === this.chapterIndex ? $r('app.color.brand') : $r('app.color.text_2'))
                .width('100%')
                .padding({ left: 16, right: 16, top: 12, bottom: 12 })
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .onClick(() => {
                  this.sheetVisible = false;
                  this.loadChapter(chapter.index);
                })
            }
          }
        }, (chapter: Chapter, index: number) => index.toString() + '_' + chapter.index.toString())
      }
      .layoutWeight(1)
      .width('100%')
      .cachedCount(20)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
  }

  @Builder
  sheetContent() {
    if (this.sheetMode === 'settings') {
      this.settingsSheet()
    } else {
      this.tocSheet()
    }
  }

  @Builder
  settingsSheet() {
    Column() {
      Text('阅读设置')
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_1'))
        .width('100%')
        .padding({ left: 16, top: 16, bottom: 8 })

      Row() {
        Text('字号')
          .fontSize(15)
          .fontColor($r('app.color.text_1'))
        Blank()
        Text('A-')
          .fontSize(15)
          .fontColor($r('app.color.brand'))
          .padding(10)
          .onClick(() => this.changeFont(-1))
        Text(`${this.fontSize}`)
          .fontSize(15)
          .fontColor($r('app.color.text_2'))
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
          .fontColor($r('app.color.text_1'))
        Blank()
        Text('−')
          .fontSize(18)
          .fontColor($r('app.color.brand'))
          .padding(10)
          .onClick(() => this.changeLineHeight(-0.1))
        Text(this.lineHeight.toFixed(1))
          .fontSize(15)
          .fontColor($r('app.color.text_2'))
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
        .fontColor($r('app.color.text_4'))
        .width('100%')
        .padding({ left: 16, right: 16, top: 12 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
  }

  build() {
    Column() {
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
              .fontColor($r('app.color.reader_text'))
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
          List({ space: 0, scroller: this.contentScroller }) {
            ForEach(this.paragraphs, (p: string, index: number) => {
              ListItem() {
                Text(p)
                  .fontSize(this.fontSize)
                  .lineHeight(this.fontSize * this.lineHeight)
                  .fontColor($r('app.color.reader_text'))
                  .width('100%')
                  .margin({ bottom: this.fontSize * 0.6 })
              }
            }, (p: string, index: number) => index.toString() + '_' + p.length.toString())

            ListItem() {
              Text(this.nextReadable(this.chapterIndex) >= 0 ? '下一章 ›' : '已是最后一章')
                .fontSize(15)
                .fontColor($r('app.color.brand'))
                .width('100%')
                .textAlign(TextAlign.Center)
                .padding({ top: 24, bottom: 24 })
                .onClick(() => this.nextChapter())
            }
          }
          .width('100%')
          .height('100%')
          .padding({ left: 20, right: 20, top: 20, bottom: 40 })
          .scrollBar(BarState.Off)
          .onScrollIndex((start: number, end: number, center: number) => {
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

        if (this.menuVisible && !this.loading && this.failed.length === 0) {
          Column() {
            this.topBar()
            Blank()
            this.bottomBar()
          }
          .width('100%')
          .height('100%')
        }
      }
      .layoutWeight(1)
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.reader_bg'))
    .bindSheet($$this.sheetVisible, this.sheetContent(), {
      height: SheetSize.MEDIUM,
      dragBar: true,
      showClose: false
    })
  }
}