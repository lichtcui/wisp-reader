import { common } from '@kit.AbilityKit';
import { BookCover } from '../components/BookCover';
import { EmptyView } from '../components/EmptyView';
import { Book, BookSource, ReadProgress } from '../engine/types';
import { getAllProgress, getBooks, initShelf } from '../model/ShelfRepository';
import { ShelfEditState } from '../model/ShelfEditState';
import { loadSources } from '../model/SourceRepository';
import { isLocalBook, localSource } from '../model/LocalBook';
import { deriveTotalChapters, shelfProgressText } from '../common/Format';
import { TtsController } from '../model/TtsController';
import { FloatingListenButton } from '../ui/common/FloatingListenButton';

export interface ShelfBookItem {
  book: Book;
  source: BookSource | undefined;
  progress: ReadProgress | undefined;
}

@ComponentV2
export struct ShelfPage {
  @Param refreshToken: number = 0;
  @Param viewMode: number = 0;
  /** Owned by Index; shared so the top bar, the action bar and the rows stay in sync. */
  @Param edit: ShelfEditState = new ShelfEditState();
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

  /** Monotonic guard: a slow earlier reload must not overwrite a newer shelf. */
  private reloadGen: number = 0;

  private async reload(): Promise<void> {
    this.reloadGen = this.reloadGen + 1;
    const gen: number = this.reloadGen;
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
    const progressMap: Map<string, ReadProgress> = await getAllProgress();
    const entries: ShelfBookItem[] = [];
    for (const book of books) {
      const progress: ReadProgress | undefined = progressMap.get(book.bookId);
      let source: BookSource | undefined = byUrl.get(book.sourceUrl);
      if (source === undefined && isLocalBook(book)) {
        source = localSource();
      }
      entries.push({ book: book, source: source, progress: progress });
    }
    if (gen !== this.reloadGen) {
      return; // 已被更新的刷新取代，丢弃本次结果
    }
    this.entries = entries;
    this.edit.setBooks(entries.map((entry: ShelfBookItem) => entry.book.bookId));
  }

  build() {
    Stack({ alignContent: Alignment.BottomEnd }) {
      Column() {
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

      if (this.tts.active && !this.edit.editing) {
        FloatingListenButton({
          visible: true,
          onTap: () => this.onOpenListening()
        })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
  }

  @Builder
  gridView() {
    Grid() {
      ForEach(this.entries, (entry: ShelfBookItem) => {
        GridItem() {
          Column() {
            Stack({ alignContent: Alignment.TopEnd }) {
              BookCover({
                source: entry.source,
                coverUrl: entry.book.coverUrl,
                name: entry.book.name,
                coverWidth: 96,
                coverHeight: 128,
                radius: 8,
                dimmed: this.edit.editing && this.edit.isSelected(entry.book.bookId)
              })
              if (this.edit.editing) {
                this.selectBadge(this.edit.isSelected(entry.book.bookId), { top: 4, right: 4 })
              }
            }
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
          .accessibilityText(this.itemA11yText(entry))
          .onClick(() => this.onItemTap(entry))
          .onTouch((event: TouchEvent) => this.onItemTouch(event))
          .parallelGesture(
            LongPressGesture({ repeat: false, duration: 500 })
              .onAction(() => this.onLongPress(entry))
          )
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
              radius: 6,
              dimmed: this.edit.editing && this.edit.isSelected(entry.book.bookId)
            })
            Column({ space: 6 }) {
              Text(entry.book.name)
                .fontSize(16)
                .fontColor($r('app.color.text_1'))
                .lineHeight(22)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
              Text(this.progressText(entry))
                .fontSize(12)
                .fontColor($r('app.color.text_4'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
            }
            .layoutWeight(1)
            .justifyContent(FlexAlign.Start)
            .alignItems(HorizontalAlign.Start)
            .margin({ left: 12 })
            if (this.edit.editing) {
              this.selectBadge(this.edit.isSelected(entry.book.bookId), { left: 12 })
            }
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 12, bottom: 12 })
          .accessibilityText(this.itemA11yText(entry))
          .onClick(() => this.onItemTap(entry))
          .onTouch((event: TouchEvent) => this.onItemTouch(event))
          .parallelGesture(
            LongPressGesture({ repeat: false, duration: 500 })
              .onAction(() => this.onLongPress(entry))
          )
        }
      }, (entry: ShelfBookItem) => this.entryKey(entry))
    }
    .layoutWeight(1)
    .width('100%')
    .scrollBar(BarState.Off)
  }

  /**
   * Long press opened edit mode for the current press; swallows the click that
   * may follow it (K13). Plain field — no need to be reactive.
   */
  private longPressFired: boolean = false;

  @Builder
  selectBadge(selected: boolean, margin: Margin) {
    // 计划 §8 S1-3e 写的是 `.justifyContent/.alignItems`，但 `StackAttribute` 在
    // 本 SDK 没有这两个属性（居中只能用构造参数 `alignContent`）——照编译器修正。
    Stack({ alignContent: Alignment.Center }) {
      if (selected) {
        SymbolGlyph($r('sys.symbol.checkmark'))
          .fontSize(12)
          .fontColor([$r('app.color.on_brand')])
      }
    }
    .width(22)
    .height(22)
    .borderRadius(11)
    .backgroundColor(selected ? $r('app.color.brand') : $r('app.color.mask'))
    .border({ width: selected ? 0 : 1.5, color: $r('app.color.on_brand') })
    .margin(margin)
    // 纯装饰：真实语义由所在行/宫的 accessibilityText 承担。
    .accessibilityLevel('no')
  }

  private onItemTap(entry: ShelfBookItem): void {
    // 长按（已进入编辑态）后可能还会补送一次 click，用 onTouch(Down) 复位的标志吞掉它（见 K13）。
    if (this.longPressFired) {
      return;
    }
    if (this.edit.editing) {
      this.edit.toggle(entry.book.bookId);
      return;
    }
    if (entry.source !== undefined) {
      this.onOpenBook(entry.source, entry.book);
    }
  }

  /** 无障碍文本：编辑态下把选中情况并入行语义（角标自身对读屏不可见）。 */
  private itemA11yText(entry: ShelfBookItem): string {
    const base: string = entry.book.name + '，' + this.progressText(entry);
    if (!this.edit.editing) {
      return base;
    }
    return base + (this.edit.isSelected(entry.book.bookId) ? '，已选中' : '，未选中');
  }

  /** Long press opens edit mode; inside edit mode long press is a no-op (K13). */
  private onLongPress(entry: ShelfBookItem): void {
    this.longPressFired = true;
    if (!this.edit.editing) {
      this.edit.enter(entry.book.bookId);
    }
  }

  /**
   * 每次按下的 Down 都复位 `longPressFired`，保证标志不会泄漏到下一次点击：
   * 同一根手指的长按（Down → 500ms 动作 → Up → 可能的 click）里，click 会被吞掉；
   * 下一次点击先发 Down（置 false），再正常走 tap 分支。
   */
  private onItemTouch(event: TouchEvent): void {
    if (event.type === TouchType.Down) {
      this.longPressFired = false;
    }
  }

  private entryKey(entry: ShelfBookItem): string {
    const p: ReadProgress | undefined = entry.progress;
    const sig: string = p === undefined ? 'none' : `${p.chapterIndex}_${p.percent}`;
    // 第三段三态：0 = 普通态，1 = 编辑态未选中，2 = 编辑态已选中。
    // 必须含「编辑态」这一维：长按 A 进入编辑态时，A 的选中位 0→1 ✓，
    // 但其余未选中的书选中位仍是 0；若 key 不含 editing，它们的 key 不变 →
    // 不重建 → 那一行不会出现空角标（而 §3.1 要求编辑态所有书都有角标）。
    const state: string = this.edit.editing
      ? (this.edit.isSelected(entry.book.bookId) ? '2' : '1')
      : '0';
    return entry.book.bookId + '#' + sig + '#' + state;
  }

  private progressText(entry: ShelfBookItem): string {
    const p: ReadProgress | undefined = entry.progress;
    if (p === undefined) {
      return '未读过';
    }
    // 章节总数不入库、书架也不读目录 → 只能由 percent 反推；脏数据/退化值回 0，
    // 由 shelfProgressText 降级为「第N章」（见 `Format.deriveTotalChapters`）。
    const total: number = deriveTotalChapters(p.chapterIndex, p.percent);
    return shelfProgressText(p.chapterIndex, total, true);
  }
}