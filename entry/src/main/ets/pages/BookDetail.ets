import { common } from '@kit.AbilityKit';
import { bookEngine } from '../engine/BookEngineNapi';
import { Book, BookSearchItem, BookSource } from '../engine/types';
import { BookCover } from '../components/BookCover';
import { computeBookId } from '../common/Format';
import { isInShelf, upsertBook } from '../model/ShelfRepository';

@ComponentV2
export struct BookDetailPage {
  @Param source: BookSource | undefined = undefined;
  @Param item: BookSearchItem | undefined = undefined;
  @Param book: Book | undefined = undefined;
  @Event onRead: (source: BookSource, book: Book) => void = () => {};

  @Local detail: Book | undefined = undefined;
  @Local loading: boolean = true;
  @Local inShelf: boolean = false;
  @Local expanded: boolean = false;

  aboutToAppear(): void {
    this.load();
  }

  private async load(): Promise<void> {
    const src: BookSource | undefined = this.source;
    const it: BookSearchItem | undefined = this.item;
    if (src === undefined) {
      this.loading = false;
      return;
    }
    if (it !== undefined) {
      try {
        const info: Book = await bookEngine.bookInfo(src, it.bookUrl);
        info.bookId = computeBookId(src.bookSourceUrl, it.bookUrl);
        info.intro = info.intro.length > 0 ? info.intro : it.intro;
        info.coverUrl = info.coverUrl.length > 0 ? info.coverUrl : it.coverUrl;
        this.detail = info;
      } catch (err) {
        this.detail = undefined;
      }
    } else if (this.book !== undefined) {
      this.detail = this.book;
    }
    this.loading = false;
    const d: Book | undefined = this.detail;
    if (d !== undefined) {
      if (this.book !== undefined) {
        this.inShelf = true;
      } else {
        this.inShelf = await isInShelf(d.name, d.author);
      }
    }
  }

  private async addToShelf(): Promise<void> {
    const d: Book | undefined = this.detail;
    const src: BookSource | undefined = this.source;
    if (d === undefined || src === undefined || this.inShelf) {
      return;
    }
    const book: Book = {
      bookId: d.bookId.length > 0 ? d.bookId : computeBookId(src.bookSourceUrl, d.tocUrl),
      sourceUrl: src.bookSourceUrl,
      name: d.name,
      author: d.author,
      coverUrl: d.coverUrl,
      intro: d.intro,
      kind: d.kind,
      wordCount: d.wordCount,
      status: d.status,
      lastChapterTitle: d.lastChapterTitle,
      tocUrl: d.tocUrl,
      inShelf: true,
      addedAt: Date.now()
    };
    await upsertBook(book);
    this.inShelf = true;
    this.getUIContext().getPromptAction().showToast({ message: '已加入书架' });
  }

  build() {
    Column() {
      if (this.loading) {
        Column() {
          LoadingProgress()
            .width(40)
            .height(40)
            .color($r('app.color.brand'))
        }
        .layoutWeight(1)
        .width('100%')
        .justifyContent(FlexAlign.Center)
      } else if (this.detail === undefined) {
        Column() {
          Text('加载失败')
            .fontSize(15)
            .fontColor($r('app.color.text_3'))
        }
        .layoutWeight(1)
        .width('100%')
        .justifyContent(FlexAlign.Center)
      } else {
        Scroll() {
          Column() {
            Row() {
              BookCover({
                source: this.source,
                coverUrl: this.detail.coverUrl,
                name: this.detail.name,
                coverWidth: 112,
                coverHeight: 150,
                radius: 8
              })
              Column({ space: 6 }) {
                Text(this.detail.name)
                  .fontSize(22)
                  .fontWeight(FontWeight.Bold)
                  .fontColor($r('app.color.text_1'))
                  .maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(this.detail.author.length > 0 ? this.detail.author : '佚名')
                  .fontSize(15)
                  .fontColor($r('app.color.text_3'))
                Text(this.metaLine())
                  .fontSize(13)
                  .fontColor($r('app.color.text_4'))
                  .maxLines(2)
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
              .margin({ left: 16 })
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 20, bottom: 16 })
            .alignItems(VerticalAlign.Top)

            Row() {
              Text('来源')
                .fontSize(13)
                .fontColor($r('app.color.text_4'))
              Text(this.source !== undefined ? this.source.bookSourceName : '')
                .fontSize(13)
                .fontColor($r('app.color.text_2'))
                .margin({ left: 8 })
              Text('（只读）')
                .fontSize(12)
                .fontColor($r('app.color.text_5'))
            }
            .width('100%')
            .padding({ left: 16, right: 16, bottom: 12 })

            Divider()
              .color($r('app.color.divider'))
              .strokeWidth(1)
              .margin({ left: 16, right: 16 })

            Text('简介')
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_1'))
              .width('100%')
              .padding({ left: 16, right: 16, top: 14, bottom: 6 })

            Text(this.detail.intro.length > 0 ? this.detail.intro : '暂无简介')
              .fontSize(15)
              .fontColor($r('app.color.text_2'))
              .lineHeight(24)
              .maxLines(this.expanded ? 100 : 4)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
              .padding({ left: 16, right: 16 })

            if (this.detail.intro.length > 40) {
              Text(this.expanded ? '收起' : '展开')
                .fontSize(13)
                .fontColor($r('app.color.brand'))
                .margin({ left: 16, top: 6 })
                .onClick(() => {
                  this.expanded = !this.expanded;
                })
            }

            Row()
              .height(80)
          }
          .width('100%')
        }
        .layoutWeight(1)
        .width('100%')
        .align(Alignment.Top)
        .scrollBar(BarState.Off)

        Row() {
          Button(this.inShelf ? '已在书架' : '加入书架')
            .layoutWeight(1)
            .height(48)
            .fontSize(16)
            .fontColor(this.inShelf ? $r('app.color.text_4') : $r('app.color.brand'))
            .backgroundColor(this.inShelf ? $r('app.color.bg_pill') : $r('app.color.bg_card'))
            .borderRadius(24)
            .enabled(!this.inShelf)
            .onClick(() => {
              this.addToShelf();
            })
          Button('立即阅读')
            .layoutWeight(1)
            .height(48)
            .fontSize(16)
            .fontColor($r('app.color.on_brand'))
            .backgroundColor($r('app.color.brand'))
            .borderRadius(24)
            .margin({ left: 12 })
            .onClick(() => {
              const d: Book | undefined = this.detail;
              const src: BookSource | undefined = this.source;
              if (d !== undefined && src !== undefined) {
                this.onRead(src, d);
              }
            })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 10, bottom: 16 })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
  }

  private metaLine(): string {
    const d: Book | undefined = this.detail;
    if (d === undefined) {
      return '';
    }
    const parts: string[] = [];
    if (d.kind.length > 0) {
      parts.push(d.kind);
    }
    if (d.status.length > 0) {
      parts.push(d.status);
    }
    if (d.wordCount.length > 0) {
      parts.push(d.wordCount);
    }
    if (d.lastChapterTitle.length > 0) {
      parts.push('最新：' + d.lastChapterTitle);
    }
    return parts.join(' · ');
  }
}