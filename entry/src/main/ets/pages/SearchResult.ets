import { common } from '@kit.AbilityKit';
import { bookEngine } from '../engine/BookEngineNapi';
import { Book, BookSearchItem, BookSource, SourceStatus } from '../engine/types';
import { BookCover } from '../components/BookCover';
import { EmptyView } from '../components/EmptyView';
import { enabledSources, loadSources } from '../model/SourceRepository';
import { getBooks } from '../model/ShelfRepository';

const SEARCH_TIMEOUT_MS: number = 10_000;

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

@ComponentV2
export struct SearchResultPage {
  @Param keyword: string = '';
  @Event onOpenDetail: (source: BookSource, item: BookSearchItem) => void = () => {};
  @Event onBack: () => void = () => {};

  @Local searchKey: string = '';
  @Local groups: SearchGroup[] = [];
  @Local statuses: SourceStatus[] = [];
  @Local pending: number = 0;
  @Local total: number = 0;
  @Local showSources: boolean = false;
  @Local shelfKeys: Set<string> = new Set<string>();
  @Local pickerVisible: boolean = false;
  @Local pickerGroup: SearchGroup | undefined = undefined;

  private sources: BookSource[] = [];
  private sourceMap: Map<string, BookSource> = new Map<string, BookSource>();
  private rawItems: BookSearchItem[] = [];
  private searchGen: number = 0;
  private infoCache: Map<string, Book> = new Map<string, Book>();

  aboutToAppear(): void {
    const ctx: common.UIAbilityContext | undefined =
      this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    if (ctx === undefined) {
      return;
    }
    this.sources = enabledSources(loadSources(ctx));
    for (const s of this.sources) {
      this.sourceMap.set(s.bookSourceUrl, s);
    }
    this.total = this.sources.length;
    this.searchKey = this.keyword;
    this.loadShelfKeys();
    this.startSearch();
  }

  private startSearch(): void {
    this.searchGen = this.searchGen + 1;
    const gen: number = this.searchGen;
    this.rawItems = [];
    this.groups = [];
    this.statuses = [];
    this.pending = this.sources.length;
    for (const s of this.sources) {
      this.searchOne(s, gen);
    }
  }

  private submit(): void {
    const kw: string = this.searchKey.trim();
    if (kw.length === 0) {
      return;
    }
    this.searchKey = kw;
    this.startSearch();
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

  private async searchOne(source: BookSource, gen: number): Promise<void> {
    let status: SourceStatus = {
      sourceUrl: source.bookSourceUrl,
      sourceName: source.bookSourceName,
      ok: false,
      count: 0,
      error: 'timeout',
      elapsedMs: SEARCH_TIMEOUT_MS
    };
    try {
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
        this.rawItems = this.rawItems.concat(result.items);
        this.rebuildGroups();
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
    this.pending = this.pending - 1;
    if (this.pending === 0) {
      this.enrichMerged(gen);
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
  }

  private async enrichOne(g: SearchGroup, gen: number): Promise<void> {
    const item: BookSearchItem = this.primaryOrigin(g);
    const source: BookSource | undefined = this.sourceMap.get(item.sourceUrl);
    if (source === undefined || this.infoCache.has(this.infoKey(item))) {
      return;
    }
    try {
      const info: Book = await bookEngine.bookInfo(source, item.bookUrl);
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

  private rebuildGroups(): void {
    const key: string = this.searchKey.trim();
    const map: Map<string, SearchGroup> = new Map<string, SearchGroup>();
    for (const item of this.rawItems) {
      const name: string = item.name.trim();
      const author: string = this.cleanAuthor(item.author);
      const cached: Book | undefined = this.infoCache.get(this.infoKey(item));
      const cover: string = item.coverUrl.length > 0
        ? item.coverUrl
        : (cached !== undefined ? cached.coverUrl : '');
      const intro: string = item.intro.trim().length > 0
        ? item.intro.trim()
        : (cached !== undefined ? cached.intro : '');
      const rawChapter: string = this.cleanChapter(item.lastChapter);
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
  private cleanAuthor(raw: string): string {
    return this.stripPrefix(raw.trim(), ['作者：', '作者:', '作者', '作家：', '作家:']);
  }

  /** e.g. "最新章节：第123章 完" / "最新章节.第123章 完". */
  private cleanChapter(raw: string): string {
    return this.stripPrefix(raw.trim(), ['最新章节：', '最新章节:', '最新章节.', '最新章节', '最新：', '最新:', '最新.']);
  }

  private stripPrefix(value: string, labels: string[]): string {
    let out: string = value;
    for (const label of labels) {
      if (out.startsWith(label)) {
        out = out.substring(label.length).trim();
      }
    }
    return out;
  }

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

  private pickerOrigins(): BookSearchItem[] {
    const g: SearchGroup | undefined = this.pickerGroup;
    return g !== undefined ? g.origins : [];
  }

  private pickerChapter(o: BookSearchItem): string {
    const chapter: string = this.cleanChapter(o.lastChapter);
    return chapter.length > 0 ? '最新：' + chapter : '';
  }

  private handleTap(g: SearchGroup): void {
    if (g.origins.length === 1) {
      this.open(g.origins[0]);
      return;
    }
    this.pickerGroup = g;
    this.pickerVisible = true;
  }

  private open(item: BookSearchItem): void {
    const source: BookSource | undefined = this.sourceMap.get(item.sourceUrl);
    if (source !== undefined) {
      this.onOpenDetail(source, item);
    }
  }

  // ── UI ────────────────────────────────────────────────────────

  @Builder
  topBar() {
    Row({ space: 4 }) {
      Text('‹')
        .fontSize(28)
        .fontColor($r('app.color.text_1'))
        .width(40)
        .height(44)
        .textAlign(TextAlign.Center)
        .accessibilityText('返回')
        .onClick(() => this.onBack())
      Row() {
        SymbolGlyph($r('sys.symbol.magnifyingglass'))
          .fontSize(18)
          .fontColor([$r('app.color.text_4')])
        TextInput({ text: this.searchKey, placeholder: '输入小说名称、作者' })
          .layoutWeight(1)
          .height(44)
          .fontSize(15)
          .fontColor($r('app.color.text_1'))
          .placeholderColor($r('app.color.text_5'))
          .backgroundColor(Color.Transparent)
          .padding({ left: 8, right: 0 })
          .enterKeyType(EnterKeyType.Search)
          .onChange((value: string) => {
            this.searchKey = value;
          })
          .onSubmit(() => this.submit())
        if (this.searchKey.length > 0) {
          Text('✕')
            .fontSize(14)
            .fontColor($r('app.color.text_4'))
            .padding({ left: 6, right: 4, top: 8, bottom: 8 })
            .onClick(() => {
              this.searchKey = '';
            })
        }
      }
      .layoutWeight(1)
      .height(44)
      .padding({ left: 14, right: 8 })
      .backgroundColor($r('app.color.bg_card'))
      .borderRadius(22)
    }
    .width('100%')
    .height(56)
    .padding({ left: 8, right: 16 })
    .alignItems(VerticalAlign.Center)
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
  pickerSheet() {
    Column() {
      Text('选择来源')
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_1'))
        .width('100%')
        .padding({ left: 20, right: 20, top: 8, bottom: 12 })
      List() {
        ForEach(this.pickerOrigins(), (o: BookSearchItem) => {
          ListItem() {
            Column({ space: 2 }) {
              Text(o.sourceName.length > 0 ? o.sourceName : o.sourceUrl)
                .fontSize(15)
                .fontColor($r('app.color.text_1'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(this.pickerChapter(o))
                .fontSize(12)
                .fontColor($r('app.color.text_4'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            .padding({ left: 20, right: 20, top: 10, bottom: 10 })
          }
          .onClick(() => {
            this.pickerVisible = false;
            this.open(o);
          })
        }, (o: BookSearchItem, index: number) => o.sourceUrl + '|' + index.toString())
      }
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
  }

  build() {
    Column() {
      this.topBar()

      if (this.groups.length === 0) {
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
    .bindSheet($$this.pickerVisible, this.pickerSheet(), {
      height: SheetSize.MEDIUM,
      dragBar: true,
      showClose: true
    })
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