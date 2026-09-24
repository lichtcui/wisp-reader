import { common } from '@kit.AbilityKit';
import { BookCover } from '../components/BookCover';
import { EmptyView } from '../components/EmptyView';
import { Book, BookSource, ReadProgress } from '../engine/types';
import { getBooks, getProgress, initShelf } from '../model/ShelfRepository';
import { loadSources } from '../model/SourceRepository';
import { isLocalBook, localSource } from '../model/LocalBook';
import { shelfProgressText } from '../common/Format';
import { TtsController } from '../model/TtsController';

export interface ShelfBookItem {
  book: Book;
  source: BookSource | undefined;
  progress: ReadProgress | undefined;
}

@ComponentV2
export struct ShelfPage {
  @Param refreshToken: number = 0;
  @Param viewMode: number = 0;
  @Local entries: ShelfBookItem[] = [];
  @Local tts: TtsController = TtsController.instance();
  @Event onGoSearch: () => void = () => {};
  @Event onOpenBook: (source: BookSource, book: Book) => void = () => {};
  @Event onOpenListening: () => void = () => {};

  aboutToAppear(): void {
    this.reload();
  }

  @Monitor('refreshToken')
  onRefresh(): void {
    this.reload();
  }

  private async reload(): Promise<void> {
    const ctx: common.UIAbilityContext | undefined =
      this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    if (ctx === undefined) {
      return;
    }
    await initShelf(ctx);
    const books: Book[] = await getBooks();
    const sources: BookSource[] = loadSources(ctx);
    const byUrl: Map<string, BookSource> = new Map<string, BookSource>();
    for (const s of sources) {
      byUrl.set(s.bookSourceUrl, s);
    }
    const entries: ShelfBookItem[] = [];
    for (const book of books) {
      const progress: ReadProgress | undefined = await getProgress(book.bookId);
      let source: BookSource | undefined = byUrl.get(book.sourceUrl);
      if (source === undefined && isLocalBook(book)) {
        source = localSource();
      }
      entries.push({ book: book, source: source, progress: progress });
    }
    this.entries = entries;
  }

  build() {
    Stack({ alignContent: Alignment.BottomEnd }) {
      Column() {
        Row() {
          Text(`全部书籍 · ${this.entries.length}`)
            .fontSize(13)
            .fontColor($r('app.color.text_4'))
          Blank()
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 12, bottom: 8 })

        if (this.entries.length === 0) {
          Column() {
            EmptyView({
              title: '书架空空如也',
              desc: '去搜索并添加你想读的书吧',
              actionText: '去搜索',
              onAction: () => this.onGoSearch()
            })
          }
          .layoutWeight(1)
          .width('100%')
          .justifyContent(FlexAlign.Center)
        } else if (this.viewMode === 1) {
          this.listView()
        } else {
          this.gridView()
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.bg_page'))

      if (this.tts.active) {
        this.listenFab()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
  }

  @Builder
  listenFab() {
    Row() {
      SymbolGlyph($r('sys.symbol.headphones'))
        .fontSize(24)
        .fontColor([$r('app.color.on_brand')])
    }
    .width(52)
    .height(52)
    .borderRadius(26)
    .margin({ right: 20, bottom: 20 })
    .backgroundColor($r('app.color.brand'))
    .justifyContent(FlexAlign.Center)
    .shadow({ radius: 12, color: $r('app.color.shadow'), offsetX: 0, offsetY: 4 })
    .accessibilityText('继续听书')
    .onClick(() => this.onOpenListening())
  }

  @Builder
  gridView() {
    Grid() {
      ForEach(this.entries, (entry: ShelfBookItem) => {
        GridItem() {
          Column() {
            BookCover({
              source: entry.source,
              coverUrl: entry.book.coverUrl,
              name: entry.book.name,
              coverWidth: 96,
              coverHeight: 128,
              radius: 8
            })
            Text(entry.book.name)
              .fontSize(13)
              .fontColor($r('app.color.text_1'))
              .lineHeight(18)
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .constraintSize({ minHeight: 36 })
              .margin({ top: 8 })
            Text(this.progressText(entry))
              .fontSize(12)
              .fontColor($r('app.color.text_4'))
              .margin({ top: 2 })
          }
          .width('100%')
          .onClick(() => {
            if (entry.source !== undefined) {
              this.onOpenBook(entry.source, entry.book);
            }
          })
        }
      }, (entry: ShelfBookItem) => this.entryKey(entry))
    }
    .columnsTemplate('1fr 1fr 1fr')
    .columnsGap(12)
    .rowsGap(16)
    .layoutWeight(1)
    .width('100%')
    .padding({ left: 16, right: 16 })
    .scrollBar(BarState.Off)
  }

  @Builder
  listView() {
    List({ space: 0 }) {
      ForEach(this.entries, (entry: ShelfBookItem) => {
        ListItem() {
          Row() {
            BookCover({
              source: entry.source,
              coverUrl: entry.book.coverUrl,
              name: entry.book.name,
              coverWidth: 56,
              coverHeight: 76,
              radius: 6
            })
            Column({ space: 4 }) {
              Text(entry.book.name)
                .fontSize(15)
                .fontColor($r('app.color.text_1'))
                .lineHeight(21)
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .constraintSize({ minHeight: 42 })
                .width('100%')
              Text(entry.book.author.length > 0 ? entry.book.author : '佚名')
                .fontSize(12)
                .fontColor($r('app.color.text_4'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
              Text(this.progressText(entry))
                .fontSize(12)
                .fontColor($r('app.color.text_4'))
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            .margin({ left: 12 })
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 12, bottom: 12 })
          .onClick(() => {
            if (entry.source !== undefined) {
              this.onOpenBook(entry.source, entry.book);
            }
          })
        }
      }, (entry: ShelfBookItem) => this.entryKey(entry))
    }
    .layoutWeight(1)
    .width('100%')
    .scrollBar(BarState.Off)
  }

  private entryKey(entry: ShelfBookItem): string {
    const p: ReadProgress | undefined = entry.progress;
    const sig: string = p === undefined ? 'none' : `${p.chapterIndex}_${p.percent}`;
    return entry.book.bookId + '#' + sig;
  }

  private progressText(entry: ShelfBookItem): string {
    const p: ReadProgress | undefined = entry.progress;
    if (p === undefined) {
      return '未读过';
    }
    const total: number = p.percent > 0 ? Math.round((p.chapterIndex + 1) / p.percent) : 0;
    return shelfProgressText(p.chapterIndex, total, true);
  }
}