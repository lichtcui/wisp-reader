import { bookEngine } from '../engine/BookEngineNapi';
import { Book, BookSearchItem, BookSource } from '../engine/types';
import { BookCover } from '../components/BookCover';
import { computeBookId } from '../common/Format';
import { ENGINE_INFO_TIMEOUT_MS } from '../common/Const';
import { isInShelf, upsertBook } from '../model/ShelfRepository';
import { AppBackButton } from '../ui/common/AppBackButton';

@ComponentV2
export struct BookDetailPage {
  @Param source: BookSource | undefined = undefined;
  @Param item: BookSearchItem | undefined = undefined;
  @Param book: Book | undefined = undefined;
  @Event onRead: (source: BookSource, book: Book) => void = () => {};
  @Event onBack: () => void = () => {};

  @Local detail: Book | undefined = undefined;
  @Local loading: boolean = true;
  @Local inShelf: boolean = false;

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
        const info: Book = await bookEngine.bookInfo(src, it.bookUrl, ENGINE_INFO_TIMEOUT_MS);
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

  private startRead(): void {
    const d: Book | undefined = this.detail;
    const src: BookSource | undefined = this.source;
    if (d !== undefined && src !== undefined) {
      this.onRead(src, d);
    }
  }

  @Builder
  topBar(light: boolean) {
    Row() {
      AppBackButton({
        label: '返回',
        tone: light ? 'onBrand' : 'normal',
        onTap: () => this.onBack()
      })
    }
    .width('100%')
    .height(52)
    .padding({ left: 4 })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  header(d: Book) {
    Column() {
      this.topBar(true)
      Row() {
        BookCover({
          source: this.source,
          coverUrl: d.coverUrl,
          name: d.name,
          coverWidth: 112,
          coverHeight: 150,
          radius: 8
        })
        Column({ space: 8 }) {
          Text(d.name)
            .fontSize(22)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.on_brand'))
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(d.author.length > 0 ? d.author : '佚名')
            .fontSize(15)
            .fontColor($r('app.color.on_brand'))
            .opacity(0.9)
          Row() {
            Text('来源：')
              .fontSize(13)
              .fontColor($r('app.color.on_brand'))
              .opacity(0.75)
            Text(this.source !== undefined ? this.source.bookSourceName : '')
              .fontSize(13)
              .fontColor($r('app.color.on_brand'))
              .opacity(0.95)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
          }
          .width('100%')
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        .margin({ left: 16 })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 4 })
      .alignItems(VerticalAlign.Top)
    }
    .width('100%')
    .padding({ bottom: 32 })
    .linearGradient({
      angle: 160,
      colors: [[$r('app.color.detail_header_a'), 0], [$r('app.color.detail_header_b'), 1]]
    })
  }

  @Builder
  contentPanel(d: Book) {
    Column() {
      Row() {
        Text('目录')
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_1'))
        Blank()
        Text(this.latestText(d))
          .fontSize(13)
          .fontColor($r('app.color.text_4'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
          .textAlign(TextAlign.End)
          .margin({ left: 12 })
        Text('›')
          .fontSize(16)
          .fontColor($r('app.color.arrow'))
          .margin({ left: 6 })
      }
      .width('100%')
      .onClick(() => this.startRead())

      Divider()
        .color($r('app.color.divider'))
        .strokeWidth(1)
        .margin({ top: 12, bottom: 12 })

      Text(d.intro.length > 0 ? d.intro : '暂无简介')
        .fontSize(15)
        .fontColor($r('app.color.text_2'))
        .lineHeight(24)
        .width('100%')
    }
    .width('100%')
    .padding({ left: 20, right: 20, top: 20, bottom: 24 })
    .backgroundColor($r('app.color.bg_page'))
    .borderRadius({ topLeft: 20, topRight: 20 })
    .margin({ top: -16 })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  bottomBar() {
    Row() {
      Row() {
        if (this.inShelf) {
          Text('✓')
            .fontSize(11)
            .fontColor($r('app.color.brand'))
            .width(20)
            .height(20)
            .textAlign(TextAlign.Center)
            .border({ width: 1.5, color: $r('app.color.brand'), radius: 10 })
            .margin({ right: 6 })
        }
        Text(this.inShelf ? '已在书架' : '加入书架')
          .fontSize(15)
          .fontColor(this.inShelf ? $r('app.color.text_3') : $r('app.color.brand'))
      }
      .padding({ left: 4, right: 16, top: 12, bottom: 12 })
      .alignItems(VerticalAlign.Center)
      .onClick(() => {
        if (!this.inShelf) {
          this.addToShelf();
        }
      })
      Blank()
      Button('立即阅读')
        .width(160)
        .height(46)
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.on_brand'))
        .borderRadius(23)
        .linearGradient({
          angle: 180,
          colors: [[$r('app.color.brand_grad_a'), 0], [$r('app.color.brand_grad_b'), 1]]
        })
        .onClick(() => this.startRead())
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 10, bottom: 16 })
    .alignItems(VerticalAlign.Center)
    .backgroundColor($r('app.color.bg_page'))
  }

  build() {
    Column() {
      if (this.loading) {
        this.topBar(false)
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
        this.topBar(false)
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
            this.header(this.detail)
            this.contentPanel(this.detail)
          }
          .width('100%')
        }
        .layoutWeight(1)
        .width('100%')
        .align(Alignment.Top)
        .scrollBar(BarState.Off)

        Divider()
          .color($r('app.color.divider'))
          .strokeWidth(1)

        this.bottomBar()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
  }

  private latestText(d: Book): string {
    if (d.lastChapterTitle.length > 0) {
      return '最新：' + d.lastChapterTitle;
    }
    return d.status.length > 0 ? d.status : '查看目录';
  }
}
