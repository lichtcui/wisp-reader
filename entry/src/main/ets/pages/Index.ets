import { common } from '@kit.AbilityKit';
import { EmptyView } from '../components/EmptyView';
import {
  DetailParam,
  ListenParam,
  PlaceholderParam,
  ROUTE_BACKUP_MANAGE,
  ROUTE_BOOK_DETAIL,
  ROUTE_CACHE_MANAGE,
  ROUTE_GENERAL_SETTINGS,
  ROUTE_LISTENING,
  ROUTE_LISTENING_SETTINGS,
  ROUTE_PLACEHOLDER,
  ROUTE_READER,
  ROUTE_READING_SETTINGS,
  ROUTE_RULE_DEBUGGER,
  ROUTE_SOURCE_MANAGE,
  TAB_SHELF,
  TAB_SEARCH,
  TAB_SETTINGS
} from '../common/Const';
import { Book, BookSearchItem, BookSource } from '../engine/types';
import { ReaderTheme } from '../common/ReaderTheme';
import { importLocalTxt } from '../model/LocalBook';
import { deleteBooks } from '../model/BookRemoval';
import { ShelfEditState } from '../model/ShelfEditState';
import { getBooks, initShelf } from '../model/ShelfRepository';
import { sourcesForUrls } from '../model/SourceStore';
import { ensureSourceStore } from '../model/SourceStoreMigration';
import {
  checkShelfUpdates,
  shelfProgressText,
  shelfUpdateResultText,
  ShelfUpdateOutcome
} from '../model/ShelfUpdater';
import { MoreMenuButton } from '../ui/common/MoreMenuButton';
import { BookDetailPage } from './BookDetail';
import { BookSourceManagePage } from './BookSourceManage';
import { BackupManagePage } from './BackupManage';
import { CacheManagePage } from './CacheManage';
import { GeneralSettingsPage } from './GeneralSettings';
import { ListeningPage } from './Listening';
import { ListeningSettingsPage } from './ListeningSettings';
import { ReaderPage } from './Reader';
import { ReadingSettingsPage } from './ReadingSettings';
import { RuleDebuggerPage } from './RuleDebugger';
import { SearchPage } from './Search';
import { SettingsPage } from './Settings';
import { ShelfPage } from './Shelf';

@Entry
@ComponentV2
struct Index {
  @Local activeTab: number = TAB_SHELF;
  @Local shelfRefresh: number = 0;
  @Local settingsRefresh: number = 0;
  @Local shelfViewMode: number = 0;
  @Local edit: ShelfEditState = new ShelfEditState();
  /** Guards the delete flow against a double tap on the dialog button. */
  @Local deleting: boolean = false;
  /** 书架「更新」进行中（防重入 + 顶栏进度，T-SHELF-7）。 */
  @Local shelfUpdating: boolean = false;
  @Local shelfUpdateProgress: string = '';
  @Local pathStack: NavPathStack = new NavPathStack();
  private tabsController: TabsController = new TabsController();

  private pushPlaceholder(title: string): void {
    this.pathStack.pushPath({ name: ROUTE_PLACEHOLDER, param: new PlaceholderParam(title) });
  }

  private openSourceManage(): void {
    this.pathStack.pushPath({ name: ROUTE_SOURCE_MANAGE });
  }

  private onSettingsNavigate(title: string): void {
    if (title === '书源管理') {
      this.openSourceManage();
    } else if (title === '阅读设置') {
      this.pathStack.pushPath({ name: ROUTE_READING_SETTINGS });
    } else if (title === '通用设置') {
      this.pathStack.pushPath({ name: ROUTE_GENERAL_SETTINGS });
    } else if (title === '听书设置') {
      this.pathStack.pushPath({ name: ROUTE_LISTENING_SETTINGS });
    } else if (title === '清理缓存') {
      this.pathStack.pushPath({ name: ROUTE_CACHE_MANAGE });
    } else if (title === '备份与恢复') {
      this.pathStack.pushPath({ name: ROUTE_BACKUP_MANAGE });
    } else {
      this.pushPlaceholder(title);
    }
  }

  private openListening(param?: ListenParam): void {
    this.pathStack.pushPath({ name: ROUTE_LISTENING, param: param });
  }

  private openDetail(source: BookSource, item?: BookSearchItem, book?: Book): void {
    this.pathStack.pushPath({ name: ROUTE_BOOK_DETAIL, param: new DetailParam(source, item, book) });
  }

  private openReader(source: BookSource, book: Book): void {
    this.pathStack.pushPath({ name: ROUTE_READER, param: new DetailParam(source, undefined, book) });
  }

  private async doImportLocal(): Promise<void> {
    const ctx: common.UIAbilityContext | undefined =
      this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    if (ctx === undefined) {
      return;
    }
    try {
      const book: Book | undefined = await importLocalTxt(ctx);
      if (book !== undefined) {
        this.getUIContext().getPromptAction().showToast({ message: '已导入《' + book.name + '》' });
        this.shelfRefresh = this.shelfRefresh + 1;
      }
    } catch (err) {
      this.getUIContext().getPromptAction().showToast({ message: '导入失败，请选择 TXT 文本文件' });
    }
  }

  /**
   * 书架「更新」：批量查新章（T-SHELF-7）。
   *
   * 顶栏进度文案由 `shelfProgressText()` 生成：纯网络书架显示 `检查中 1/2`；
   * 混合书架显示 `网络 1/2 · 本地 2`，失败时追 ` · N 本未检查`；
   * 结束一次 toast（不逐本书弹）。
   * 回写基线后刷新书架：`books.last_chapter_title` 目前没有 UI 读（书架标签走
   * `progress.percent`），刷新只为让可能的行内角标/文案后续改动自然生效。
   */
  private async doShelfUpdate(): Promise<void> {
    if (this.shelfUpdating) {
      return;
    }
    const ctx: common.UIAbilityContext | undefined =
      this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    if (ctx === undefined) {
      return;
    }
    this.shelfUpdating = true;
    this.shelfUpdateProgress = '检查中…';
    let outcome: ShelfUpdateOutcome | undefined = undefined;
    try {
      await initShelf(ctx);
      await ensureSourceStore(ctx);
      const books: Book[] = await getBooks();
      const urls: string[] = [];
      for (const book of books) {
        urls.push(book.sourceUrl);
      }
      const byUrl: Map<string, BookSource> = await sourcesForUrls(urls);
      const sources: BookSource[] = [];
      const seen: Set<string> = new Set<string>();
      for (const book of books) {
        if (!seen.has(book.sourceUrl)) {
          seen.add(book.sourceUrl);
          const source: BookSource | undefined = byUrl.get(book.sourceUrl);
          if (source !== undefined) {
            sources.push(source);
          }
        }
      }
      outcome = await checkShelfUpdates(books, sources,
        (done: number, total: number, failed: number, local: number): void => {
          this.shelfUpdateProgress = shelfProgressText(done, total, failed, local);
        });
    } catch (err) {
      outcome = undefined;
    }
    this.shelfUpdating = false;
    this.shelfUpdateProgress = '';
    if (outcome === undefined) {
      this.getUIContext().getPromptAction().showToast({ message: '更新失败，请稍后重试' });
      return;
    }
    const result: string = shelfUpdateResultText(outcome);
    this.shelfRefresh = this.shelfRefresh + 1;
    this.getUIContext().getPromptAction().showToast({ message: result });
  }

  private confirmDelete(): void {
    const n: number = this.edit.count();
    if (n === 0 || this.deleting) {
      return;
    }
    const message: string = n === 1
      ? '删除后，该书的阅读进度与缓存将一并清除，且不可恢复。'
      : '删除后，这 ' + n.toString() + ' 本书的阅读进度与缓存将一并清除，且不可恢复。';
    this.getUIContext().showAlertDialog({
      title: '删除书籍',
      message: message,
      autoCancel: true,
      primaryButton: {
        value: '取消',
        fontColor: $r('app.color.text_2'),
        action: () => {
        }
      },
      secondaryButton: {
        value: '删除',
        fontColor: $r('app.color.brand'),
        action: () => {
          this.doDelete();
        }
      }
    });
  }

  private async doDelete(): Promise<void> {
    const ctx: common.UIAbilityContext | undefined =
      this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    const ids: string[] = this.edit.selected.slice();
    if (ctx === undefined || ids.length === 0 || this.deleting) {
      return;
    }
    this.deleting = true;
    let ok: boolean = true;
    try {
      await deleteBooks(ctx, ids);
    } catch (err) {
      ok = false;
    }
    this.deleting = false;
    this.edit.exit();
    this.shelfRefresh = this.shelfRefresh + 1;
    this.getUIContext().getPromptAction().showToast({
      message: ok ? '已删除 ' + ids.length.toString() + ' 本书' : '删除失败，请重试'
    });
  }

  private shelfMenuItems(): MenuElement[] {
    return [
      {
        value: '导入本地书籍',
        action: () => {
          this.doImportLocal();
        }
      },
      {
        value: this.shelfViewMode === 0 ? '切换列表模式' : '切换宫格模式',
        action: () => {
          this.shelfViewMode = this.shelfViewMode === 0 ? 1 : 0;
        }
      }
    ];
  }

  // ── Shelf header (title + 更多 menu) ───────────────────────────

  @Builder
  shelfHeader() {
    if (this.edit.editing) {
      this.shelfEditHeader()
    } else {
      this.shelfNormalHeader()
    }
  }

  @Builder
  shelfNormalHeader() {
    Row() {
      Text('书架')
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_1'))
      Blank()
      if (this.shelfUpdating) {
        Text(this.shelfUpdateProgress)
          .fontSize(13)
          .fontColor($r('app.color.text_3'))
          .maxLines(1)
          .margin({ right: 8 })
      }
      this.shelfUpdateAction()
      MoreMenuButton({ items: this.shelfMenuItems() })
    }
    .width('100%')
    .height(52)
    .padding({ left: 16, right: 16 })
    .alignItems(VerticalAlign.Center)
  }

  /**
   * 书架「更新」按钮（T-SHELF-7）。
   *
   * 0 参数 + 直读 `@Local`：与 `deleteAction()` 同形 —— `@Builder` 传 2 个及以上参数
   * 就不会动态刷新（见本文件 §5.3）。热区 44 高、`brand` 令牌、`accessibilityText` 走
   * [`specs/UI-SPEC.md`](../../../../../docs/specs/UI-SPEC.md) §1.7 的既有令牌，未新造样式。
   */
  @Builder
  shelfUpdateAction() {
    Row() {
      Text('更新')
        .fontSize(16)
        .fontColor(this.shelfUpdating ? $r('app.color.text_3') : $r('app.color.brand'))
        .maxLines(1)
    }
    .height(44)
    .padding({ left: 8, right: 8 })
    .justifyContent(FlexAlign.Center)
    .accessibilityText(this.shelfUpdating ? '正在检查更新' : '更新全部书籍')
    .accessibilityLevel('yes')
    .onClick(() => {
      if (!this.shelfUpdating) {
        this.doShelfUpdate();
      }
    })
  }

  /** 编辑态顶栏：全选 / 已选择 X 本书 / 完成（左右等宽 76，保证中间真居中）。 */
  @Builder
  shelfEditHeader() {
    Row() {
      Row() {
        Text(this.edit.allSelected() ? '取消全选' : '全选')
          .fontSize(16)
          .fontColor($r('app.color.brand'))
          .maxLines(1)
      }
      .width(76)
      .height(44)
      .justifyContent(FlexAlign.Start)
      .alignItems(VerticalAlign.Center)
      .accessibilityText(this.edit.allSelected() ? '取消全选' : '全选')
      .accessibilityLevel('yes')
      .onClick(() => this.edit.toggleAll())

      Text('已选择 ' + this.edit.count().toString() + ' 本书')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_1'))
        .maxLines(1)
        .layoutWeight(1)
        .textAlign(TextAlign.Center)

      Row() {
        Text('完成')
          .fontSize(16)
          .fontColor($r('app.color.brand'))
          .maxLines(1)
      }
      .width(76)
      .height(44)
      .justifyContent(FlexAlign.End)
      .alignItems(VerticalAlign.Center)
      .accessibilityText('完成')
      .accessibilityLevel('yes')
      .onClick(() => this.edit.exit())
    }
    .width('100%')
    .height(52)
    .padding({ left: 16, right: 16 })
    .alignItems(VerticalAlign.Center)
  }

  // ── Bottom navigation bar ─────────────────────────────────────

  @Builder
  bottomTab(icon: Resource, label: string, index: number) {
    Column({ space: 2 }) {
      SymbolGlyph(icon)
        .fontSize(24)
        .fontColor([this.activeTab === index ? $r('app.color.brand') : $r('app.color.text_3')])
      Text(label)
        .fontSize(11)
        .fontColor(this.activeTab === index ? $r('app.color.brand') : $r('app.color.text_3'))
    }
    .layoutWeight(1)
    .height(60)
    .justifyContent(FlexAlign.Center)
    .accessibilityText(label)
    .onClick(() => {
      this.activeTab = index;
      this.tabsController.changeIndex(index);
    })
  }

  @Builder
  // The bar is the last thing above the bottom safe area, so extending its own
  // background into that area is what keeps the system navigation-bar strip (a
  // grey band) from showing up right below the page. The inner Row keeps the
  // 60vp tab height, so the icons stay exactly where they were.
  bottomBar() {
    Column() {
      Row() {
        if (this.edit.editing) {
          this.deleteAction()
          // TODO(S3+): 「移动到分组」再加一个**同形的 0 参数 builder**（如 groupAction()）；
          // 不要改成“带参数的通用 action builder”——多参数 builder 不会动态刷新（§5.3 K10）。
        } else {
          this.bottomTab($r('sys.symbol.bookshelf'), '书架', TAB_SHELF)
          this.bottomTab($r('sys.symbol.magnifyingglass'), '搜索', TAB_SEARCH)
          this.bottomTab($r('sys.symbol.gearshape'), '设置', TAB_SETTINGS)
        }
      }
      .width('100%')
      .height(60)
    }
    .width('100%')
    .backgroundColor($r('app.color.bg_page'))
    .border({ width: { top: 1 }, color: $r('app.color.divider') })
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
  }

  /**
   * 删除按钮是否可点。**只能在 0 参数 builder 的属性表达式里直接调用**。
   * 官方限制：`@Builder` 传两个及以上参数就不会动态刷新，把 enabled 当形参传入
   * 会在「已选择 0 本 ↔ N 本」之间不变色（见 §5.3）。
   */
  private canDelete(): boolean {
    return !this.deleting && this.edit.count() > 0;
  }

  /** 编辑态 · 删除按钮。0 参数 + 状态直读 → 与已验证可用的 `bottomBar()` 同形。 */
  @Builder
  deleteAction() {
    Column({ space: 2 }) {
      SymbolGlyph($r('sys.symbol.trash'))
        .fontSize(24)
        .fontColor([this.canDelete() ? $r('app.color.brand') : $r('app.color.text_5')])
      Text('删除')
        .fontSize(11)
        .fontColor(this.canDelete() ? $r('app.color.brand') : $r('app.color.text_5'))
    }
    .layoutWeight(1)
    .height(60)
    .justifyContent(FlexAlign.Center)
    .accessibilityText('删除')
    .accessibilityLevel('yes')
    .onClick(() => {
      if (this.canDelete()) {
        this.confirmDelete();
      }
    })
  }

  @Builder
  pageMap(name: string, param: object) {
    if (name === ROUTE_SOURCE_MANAGE) {
      NavDestination() {
        BookSourceManagePage({
          onOpenDebugger: () => this.pathStack.pushPath({ name: ROUTE_RULE_DEBUGGER })
        })
      }
      .title('书源管理')
      .backgroundColor($r('app.color.bg_page'))
    } else if (name === ROUTE_RULE_DEBUGGER) {
      NavDestination() {
        RuleDebuggerPage()
      }
      .title('规则调试器')
      .backgroundColor($r('app.color.bg_page'))
    } else if (name === ROUTE_BACKUP_MANAGE) {
      NavDestination() {
        BackupManagePage()
      }
      .title('备份与恢复')
      .backgroundColor($r('app.color.bg_page'))
    } else if (name === ROUTE_READING_SETTINGS) {
      NavDestination() {
        ReadingSettingsPage()
      }
      .title('阅读设置')
      .backgroundColor($r('app.color.bg_page'))
    } else if (name === ROUTE_GENERAL_SETTINGS) {
      NavDestination() {
        GeneralSettingsPage()
      }
      .title('通用设置')
      .backgroundColor($r('app.color.bg_page'))
    } else if (name === ROUTE_LISTENING_SETTINGS) {
      NavDestination() {
        ListeningSettingsPage()
      }
      .title('听书设置')
      .backgroundColor($r('app.color.bg_page'))
    } else if (name === ROUTE_CACHE_MANAGE) {
      NavDestination() {
        CacheManagePage()
      }
      .title('清理缓存')
      .backgroundColor($r('app.color.bg_page'))
    } else if (name === ROUTE_LISTENING) {
      NavDestination() {
        ListeningPage({
          param: param as ListenParam,
          onBack: () => this.pathStack.pop()
        })
      }
      .hideTitleBar(true)
      .backgroundColor($r('app.color.listen_bg'))
    } else if (name === ROUTE_BOOK_DETAIL) {
      NavDestination() {
        BookDetailPage({
          source: (param as DetailParam).source,
          item: (param as DetailParam).item,
          book: (param as DetailParam).book,
          onRead: (source: BookSource, book: Book) => this.openReader(source, book),
          onBack: () => this.pathStack.pop()
        })
      }
      .hideTitleBar(true)
      .backgroundColor($r('app.color.bg_page'))
    } else if (name === ROUTE_READER) {
      NavDestination() {
        ReaderPage({
          initialSource: (param as DetailParam).source,
          initialBook: (param as DetailParam).book,
          onBack: () => {
            this.pathStack.pop();
            this.shelfRefresh = this.shelfRefresh + 1;
          },
          // 阅读页可能已经换过源，所以详情页用**它传回的**来源/书籍，而不是路由参数。
          onMore: (source: BookSource, book: Book) => this.openDetail(source, undefined, book),
          onListen: (listen: ListenParam) => this.openListening(listen),
          onOpenListening: () => this.openListening()
        })
      }
      .hideTitleBar(true)
      .backgroundColor(ReaderTheme.instance().bgHex)
    } else {
      NavDestination() {
        Column() {
          EmptyView({
            title: (param as PlaceholderParam).title,
            desc: '该页面将在后续里程碑实现'
          })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
      }
      .title((param as PlaceholderParam).title)
      .backgroundColor($r('app.color.bg_page'))
    }
  }

  /** 编辑态内的系统返回：只退出编辑态，不退出页面。 */
  onBackPress(): boolean {
    if (this.edit.editing) {
      this.edit.exit();
      return true;
    }
    return false;
  }

  build() {
    Navigation(this.pathStack) {
      Column() {
        if (this.activeTab === TAB_SHELF) {
          this.shelfHeader()
        }

        Tabs({ barPosition: BarPosition.Start, index: this.activeTab, controller: this.tabsController }) {
          TabContent() {
            ShelfPage({
              refreshToken: this.shelfRefresh,
              viewMode: this.shelfViewMode,
              shelfUpdating: this.shelfUpdating,
              edit: this.edit,
              onGoSearch: () => {
                this.activeTab = TAB_SEARCH;
                this.tabsController.changeIndex(TAB_SEARCH);
              },
              onOpenBook: (source: BookSource, book: Book) => this.openReader(source, book),
              onOpenListening: () => this.openListening(),
              onRefreshShelf: () => this.doShelfUpdate()
            })
          }
          .tabBar('')

          TabContent() {
            SearchPage({
              onOpenDetail: (source: BookSource, item: BookSearchItem) => this.openDetail(source, item)
            })
          }
          .tabBar('')

          TabContent() {
            SettingsPage({
              refreshToken: this.settingsRefresh,
              onNavigate: (title: string) => this.onSettingsNavigate(title)
            })
          }
          .tabBar('')
        }
        .barMode(BarMode.Fixed)
        .barHeight(0)
        .scrollable(!this.edit.editing)
        .onChange((index: number) => {
          if (this.edit.editing) {
            this.edit.exit();
          }
          this.activeTab = index;
          if (index === TAB_SHELF) {
            this.shelfRefresh = this.shelfRefresh + 1;
          } else if (index === TAB_SETTINGS) {
            this.settingsRefresh = this.settingsRefresh + 1;
          }
        })
        .layoutWeight(1)
        .width('100%')
        .backgroundColor($r('app.color.bg_page'))

        // The bottom bar is always laid out here; a drawer that must show above it
        // uses BottomDrawer's 'cover' mode (window-level layer), so the bar never
        // moves (see docs/specs/UI-SPEC.md §1.2.1).
        this.bottomBar()
      }
      .width('100%')
      .height('100%')
    }
    .mode(NavigationMode.Stack)
    .hideTitleBar(true)
    .navDestination(this.pageMap)
    .onNavBarStateChange((isVisible: boolean) => {
      if (isVisible && this.activeTab === TAB_SHELF) {
        this.shelfRefresh = this.shelfRefresh + 1;
      }
      if (isVisible && this.activeTab === TAB_SETTINGS) {
        this.settingsRefresh = this.settingsRefresh + 1;
      }
    })
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
  }
}
