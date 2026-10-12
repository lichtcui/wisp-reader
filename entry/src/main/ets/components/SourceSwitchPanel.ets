import { common } from '@kit.AbilityKit';
import { bookEngine } from '../engine/BookEngineNapi';
import { Book, BookSearchItem, BookSource } from '../engine/types';
import { dedupeByUrl, enabledSources, loadSources } from '../model/SourceRepository';
import { confidenceOf, sortByConfidence } from '../model/SourceConfidence';
import { isSameBook } from '../model/SourceSwitch';

const SEARCH_TIMEOUT_MS: number = 10_000;
/** 滑动窗口宽度：候选搜索是「一源一次 search」，并发太多会同时压垮小站。 */
const SWITCH_CONCURRENCY: number = 6;

/** 换源抽屉的一行 = 「某个书源收录了这本书」。 */
interface SwitchRow {
  /** 稳定 key：同一源可能返回多条同名结果，不能只用 URL。 */
  key: string;
  source: BookSource;
  item: BookSearchItem;
  label: string;
  confidence: number;
  chapter: string;
  current: boolean;
}

function stripLatest(raw: string): string {
  const s: string = raw.trim();
  if (s.startsWith('最新：')) {
    return s.substring(3);
  }
  if (s.startsWith('最新:')) {
    return s.substring(3);
  }
  return s;
}

/**
 * 换源抽屉内容（阅读页专用）：跨源检索同名书 → 列出候选 → 交给宿主执行切换。
 *
 * 搜索是**渐进**的（`SourceResultPage` 同款滑动窗口：每源一次 `search` 调用，
 * 谁先回来谁先上屏），因为聚合调用要等最慢的源到 10s 超时，抽屉会长时间空白。
 *
 * 组件常驻挂载（BottomDrawer 规范）：`runToken` 每次打开自增，`@Monitor` 里重读书源
 * 列表并重新搜索 —— 关闭期间不主动取消在飞的请求，靠 `gen` 令牌丢弃过期结果。
 */
@ComponentV2
export struct SourceSwitchPanel {
  /** 每次抽屉打开自增；0 = 尚未打开过。 */
  @Param runToken: number = 0;
  @Param book: Book | undefined = undefined;
  @Param currentSourceUrl: string = '';
  @Param currentSourceName: string = '';
  @Param textColor: ResourceColor = Color.Black;
  @Param dimColor: ResourceColor = Color.Gray;
  /** 宿主正在执行切换：列表整体不可点，避免连点两次。 */
  @Param busy: boolean = false;
  @Event onPick: (source: BookSource, item: BookSearchItem) => void = () => {};

  @Local rows: SwitchRow[] = [];
  @Local searching: boolean = false;
  @Local scanned: number = 0;
  @Local total: number = 0;

  private ctx: common.UIAbilityContext | undefined = undefined;
  private sources: BookSource[] = [];
  /** 搜索代次：新一次搜索/页面离开后，旧结果直接丢弃。 */
  private gen: number = 0;
  private nextIndex: number = 0;

  aboutToAppear(): void {
    this.ctx = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    this.reloadSources();
  }

  @Monitor('runToken')
  onRunTokenChange(): void {
    if (this.runToken <= 0) {
      return;
    }
    this.reloadSources();
    this.startSearch();
  }

  /** 每次打开都重读书源：期间可能在书源管理页导入/删除了源。 */
  private reloadSources(): void {
    const ctx: common.UIAbilityContext | undefined = this.ctx;
    if (ctx === undefined) {
      return;
    }
    this.sources = dedupeByUrl(sortByConfidence(enabledSources(loadSources(ctx))));
  }

  private startSearch(): void {
    this.gen = this.gen + 1;
    const gen: number = this.gen;
    this.rows = [];
    this.scanned = 0;
    this.nextIndex = 0;
    this.total = this.sources.length;
    const book: Book | undefined = this.book;
    if (book === undefined || book.name.trim().length === 0 || this.sources.length === 0) {
      this.searching = false;
      return;
    }
    this.searching = true;
    const window: number = Math.min(SWITCH_CONCURRENCY, this.sources.length);
    for (let w = 0; w < window; w++) {
      this.drain(gen, book);
    }
  }

  /** 窗口协程：取下一个源，搜完一个补下一个，直到派发完或被新搜索替换。 */
  private async drain(gen: number, book: Book): Promise<void> {
    while (gen === this.gen) {
      const i: number = this.nextIndex;
      if (i >= this.sources.length) {
        return;
      }
      this.nextIndex = i + 1;
      await this.searchOne(gen, book, this.sources[i]);
    }
  }

  private async searchOne(gen: number, book: Book, source: BookSource): Promise<void> {
    let items: BookSearchItem[] = [];
    try {
      const result = await bookEngine.search([source], book.name, {
        timeoutMs: SEARCH_TIMEOUT_MS,
        concurrency: 1
      });
      items = result.items;
    } catch (err) {
      // 单源失败不影响其余候选：这一源就是「没收录/不可用」。
      items = [];
    }
    if (gen !== this.gen) {
      return;
    }
    const added: SwitchRow[] = [];
    for (const it of items) {
      if (isSameBook(book, it)) {
        added.push(this.makeRow(source, it, this.rows.length + added.length));
      }
    }
    if (added.length > 0) {
      this.rows = this.rows.concat(added);
    }
    this.scanned = this.scanned + 1;
    if (this.scanned >= this.total) {
      this.searching = false;
    }
  }

  private makeRow(source: BookSource, item: BookSearchItem, seq: number): SwitchRow {
    return {
      key: source.bookSourceUrl + '#' + seq.toString(),
      source: source,
      item: item,
      label: source.bookSourceName.length > 0 ? source.bookSourceName : source.bookSourceUrl,
      confidence: confidenceOf(source),
      chapter: stripLatest(item.lastChapter),
      current: source.bookSourceUrl === this.currentSourceUrl
    };
  }

  private statusText(): string {
    if (this.total === 0) {
      return '没有启用的书源';
    }
    if (this.searching) {
      return '已检索 ' + this.scanned.toString() + '/' + this.total.toString() + ' 个书源';
    }
    return '共 ' + this.rows.length.toString() + ' 个候选';
  }

  @Builder
  header() {
    Row() {
      Text('换源')
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.textColor)
      Text(this.currentSourceName.length > 0 ? ' · 当前 ' + this.currentSourceName : '')
        .fontSize(13)
        .fontColor(this.dimColor)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      Text(this.statusText())
        .fontSize(12)
        .fontColor(this.dimColor)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 10 })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  row(r: SwitchRow) {
    Row() {
      Column() {
        Row() {
          Text(r.label)
            .fontSize(15)
            .fontColor(this.textColor)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (r.current) {
            Text('当前源')
              .fontSize(11)
              .fontColor($r('app.color.brand'))
              .border({ width: 1, color: $r('app.color.brand'), radius: 4 })
              .padding({ left: 4, right: 4, top: 1, bottom: 1 })
              .margin({ left: 6 })
          }
          Blank()
          Text('置信 ' + r.confidence.toString())
            .fontSize(11)
            .fontColor(this.dimColor)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        Text(r.chapter.length > 0 ? '最新：' + r.chapter : '（该源未返回最新章节）')
          .fontSize(12)
          .fontColor(this.dimColor)
          .width('100%')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 4 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      if (!r.current) {
        Text(this.busy ? '切换中' : '切换')
          .fontSize(13)
          .fontColor(this.busy ? this.dimColor : $r('app.color.brand'))
          .padding({ left: 10, right: 10, top: 6, bottom: 6 })
          .margin({ left: 8 })
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      if (this.busy || r.current) {
        return;
      }
      this.onPick(r.source, r.item);
    })
  }

  build() {
    Column() {
      this.header()
      Divider()
        .color($r('app.color.divider'))
        .strokeWidth(1)
        .margin({ left: -16, right: -16 })

      if (this.rows.length === 0) {
        Column() {
          if (this.searching) {
            LoadingProgress()
              .width(36)
              .height(36)
              .color($r('app.color.brand'))
            Text('正在检索同名书…')
              .fontSize(13)
              .fontColor(this.dimColor)
              .margin({ top: 10 })
          } else {
            Text('没有其它书源收录这本书')
              .fontSize(14)
              .fontColor(this.dimColor)
            Text('换源按书名 + 作者精确匹配；换个源名试试搜索页')
              .fontSize(12)
              .fontColor(this.dimColor)
              .margin({ top: 8 })
          }
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        List({ space: 0 }) {
          ForEach(this.rows, (r: SwitchRow) => {
            ListItem() {
              Column() {
                this.row(r)
                Divider()
                  .color($r('app.color.divider'))
                  .strokeWidth(1)
                  .margin({ left: 16 })
              }
            }
          }, (r: SwitchRow) => r.key)
        }
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .layoutWeight(1)
  }
}
