import { common } from '@kit.AbilityKit';
import { SegmentedCell } from '../components/ListCells';
import { BookCover } from '../components/BookCover';
import { EmptyView } from '../components/EmptyView';
import { SORT_OPTIONS, VIEW_MODE_OPTIONS } from '../common/Const';
import { Book, BookSource, ReadProgress } from '../engine/types';
import { getBooks, getProgress, initShelf } from '../model/ShelfRepository';
import { loadSources } from '../model/SourceRepository';
import { shelfProgressText } from '../common/Format';

export interface ShelfBookItem {
  book: Book;
  source: BookSource | undefined;
  progress: ReadProgress | undefined;
}

@ComponentV2
export struct ShelfPage {
  @Param refreshToken: number = 0;
  @Local viewMode: number = 0;
  @Local entries: ShelfBookItem[] = [];
  @Event onGoSearch: () => void = () => {};
  @Event onOpenBook: (source: BookSource, book: Book) => void = () => {};

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
      entries.push({ book: book, source: byUrl.get(book.sourceUrl), progress: progress });
    }
    this.entries = entries;
  }

  build() {
    Column() {
      Row() {
        Text(`全部书籍 · ${this.entries.length}`)
          .fontSize(13)
          .fontColor($r('app.color.text_4'))
        Blank()
        SegmentedCell({
          options: VIEW_MODE_OPTIONS,
          selected: this.viewMode,
          onSelect: (index: number) => {
            this.viewMode = index;
          }
        })
          .width(140)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 4 })

      Row() {
        Text(SORT_OPTIONS[0])
          .fontSize(13)
          .fontColor($r('app.color.text_4'))
          .padding({ top: 4, bottom: 4, right: 12 })
        Blank()
      }
      .width('100%')
      .padding({ left: 16, right: 16, bottom: 8 })

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
      } else {
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
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
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
          }, (entry: ShelfBookItem) => entry.book.bookId)
        }
        .columnsTemplate('1fr 1fr 1fr')
        .columnsGap(12)
        .rowsGap(16)
        .layoutWeight(1)
        .width('100%')
        .padding({ left: 16, right: 16 })
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
  }

  private progressText(entry: ShelfBookItem): string {
    const p: ReadProgress | undefined = entry.progress;
    if (p === undefined) {
      return '未读过';
    }
    // `percent` is chapterIndex+1/total, so total is recoverable without a
    // stored column; percent==1 on the last chapter yields the "latest" state.
    const total: number = p.percent > 0 ? Math.round((p.chapterIndex + 1) / p.percent) : 0;
    return shelfProgressText(p.chapterIndex, total, true);
  }
}