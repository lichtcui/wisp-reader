import { common } from '@kit.AbilityKit';
import { bookEngine } from '../engine/BookEngineNapi';
import { Book, BookSearchItem, BookSource, SourceStatus } from '../engine/types';
import { BookCover } from '../components/BookCover';
import { EmptyView } from '../components/EmptyView';
import { enabledSources, loadSources } from '../model/SourceRepository';
import { getBooks } from '../model/ShelfRepository';

const SEARCH_TIMEOUT_MS: number = 10_000;

@ComponentV2
export struct SearchResultPage {
  @Param keyword: string = '';
  @Event onOpenDetail: (source: BookSource, item: BookSearchItem) => void = () => {};

  @Local items: BookSearchItem[] = [];
  @Local statuses: SourceStatus[] = [];
  @Local pending: number = 0;
  @Local total: number = 0;
  @Local showSources: boolean = false;
  @Local shelfKeys: Set<string> = new Set<string>();

  private sourceMap: Map<string, BookSource> = new Map<string, BookSource>();

  aboutToAppear(): void {
    const ctx: common.UIAbilityContext | undefined =
      this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    if (ctx === undefined) {
      return;
    }
    const sources: BookSource[] = enabledSources(loadSources(ctx));
    for (const s of sources) {
      this.sourceMap.set(s.bookSourceUrl, s);
    }
    this.total = sources.length;
    this.pending = sources.length;
    this.loadShelfKeys();
    for (const s of sources) {
      this.searchOne(s);
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

  private async searchOne(source: BookSource): Promise<void> {
    let status: SourceStatus = {
      sourceUrl: source.bookSourceUrl,
      sourceName: source.bookSourceName,
      ok: false,
      count: 0,
      error: 'timeout',
      elapsedMs: SEARCH_TIMEOUT_MS
    };
    try {
      const result = await bookEngine.search([source], this.keyword, {
        timeoutMs: SEARCH_TIMEOUT_MS,
        concurrency: 1
      });
      if (result.sources.length > 0) {
        status = result.sources[0];
      }
      if (result.items.length > 0) {
        this.items = this.items.concat(result.items);
      }
    } catch (err) {
      status.error = 'network_error';
    }
    const next: SourceStatus[] = this.statuses.slice();
    next.push(status);
    this.statuses = next;
    this.pending = this.pending - 1;
  }

  private isInShelf(item: BookSearchItem): boolean {
    return this.shelfKeys.has(this.shelfKey(item.name, item.author));
  }

  @Builder
  resultItem(item: BookSearchItem) {
    Row() {
      BookCover({
        source: this.sourceMap.get(item.sourceUrl),
        coverUrl: item.coverUrl,
        name: item.name,
        coverWidth: 84,
        coverHeight: 112,
        radius: 6
      })
      Column({ space: 4 }) {
        Text(item.name)
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.brand'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.metaLine(item))
          .fontSize(13)
          .fontColor($r('app.color.text_4'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(item.intro.length > 0 ? item.intro : item.lastChapter)
          .fontSize(13)
          .fontColor($r('app.color.text_3'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Row() {
          Text(item.sourceName)
            .fontSize(11)
            .fontColor($r('app.color.text_3'))
            .padding({ left: 8, right: 8, top: 2, bottom: 2 })
            .borderRadius(9)
            .backgroundColor($r('app.color.bg_pill'))
          if (this.isInShelf(item)) {
            Text('已在书架')
              .fontSize(11)
              .fontColor($r('app.color.brand'))
              .margin({ left: 6 })
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
    .onClick(() => {
      const source: BookSource | undefined = this.sourceMap.get(item.sourceUrl);
      if (source !== undefined) {
        this.onOpenDetail(source, item);
      }
    })
  }

  private metaLine(item: BookSearchItem): string {
    const parts: string[] = [];
    if (item.author.length > 0) {
      parts.push(item.author);
    }
    if (item.kind.length > 0) {
      parts.push(item.kind);
    }
    if (item.wordCount.length > 0) {
      parts.push(item.wordCount);
    }
    return parts.join(' · ');
  }

  build() {
    Column() {
      Row() {
        Text('“' + this.keyword + '”')
          .fontSize(15)
          .fontColor($r('app.color.text_1'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Blank()
        Text(this.pending > 0 ? `搜索中 ${this.total - this.pending}/${this.total}` : `共 ${this.items.length} 条`)
          .fontSize(13)
          .fontColor($r('app.color.text_4'))
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 8 })

      if (this.items.length === 0) {
        Column() {
          if (this.pending > 0) {
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
        List({ space: 0 }) {
          ForEach(this.items, (item: BookSearchItem) => {
            ListItem() {
              Column() {
                this.resultItem(item)
                Divider()
                  .color($r('app.color.divider'))
                  .strokeWidth(1)
                  .margin({ left: 112 })
              }
            }
          }, (item: BookSearchItem, index: number) => item.sourceUrl + '|' + item.bookUrl + '|' + index.toString())
        }
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Off)
      }

      if (this.statuses.length > 0) {
        Row() {
          Text(this.sourceSummary())
            .fontSize(12)
            .fontColor($r('app.color.text_4'))
          Blank()
          Text(this.showSources ? '收起' : '源状态')
            .fontSize(12)
            .fontColor($r('app.color.brand'))
            .onClick(() => {
              this.showSources = !this.showSources;
            })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 8, bottom: 8 })

        if (this.showSources) {
          Scroll() {
            Column() {
              ForEach(this.statuses, (status: SourceStatus) => {
                Row() {
                  Text(status.sourceName.length > 0 ? status.sourceName : status.sourceUrl)
                    .fontSize(13)
                    .fontColor($r('app.color.text_2'))
                    .layoutWeight(1)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(status.ok ? `✓ ${status.count}` : status.error)
                    .fontSize(12)
                    .fontColor(status.ok ? $r('app.color.brand') : $r('app.color.warning'))
                }
                .width('100%')
                .padding({ left: 16, right: 16, top: 5, bottom: 5 })
              }, (status: SourceStatus) => status.sourceUrl)
            }
            .width('100%')
          }
          .height(140)
          .width('100%')
          .scrollBar(BarState.Off)
        }
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
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
}