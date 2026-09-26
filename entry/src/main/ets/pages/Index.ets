import { common } from '@kit.AbilityKit';
import { EmptyView } from '../components/EmptyView';
import {
  DetailParam,
  ListenParam,
  PlaceholderParam,
  ROUTE_BOOK_DETAIL,
  ROUTE_CACHE_MANAGE,
  ROUTE_GENERAL_SETTINGS,
  ROUTE_LISTENING,
  ROUTE_LISTENING_SETTINGS,
  ROUTE_PLACEHOLDER,
  ROUTE_READER,
  ROUTE_READING_SETTINGS,
  ROUTE_SOURCE_MANAGE,
  TAB_SHELF,
  TAB_SEARCH,
  TAB_SETTINGS
} from '../common/Const';
import { Book, BookSearchItem, BookSource } from '../engine/types';
import { ReaderTheme } from '../common/ReaderTheme';
import { importLocalTxt } from '../model/LocalBook';
import { BookDetailPage } from './BookDetail';
import { BookSourceManagePage } from './BookSourceManage';
import { CacheManagePage } from './CacheManage';
import { GeneralSettingsPage } from './GeneralSettings';
import { ListeningPage } from './Listening';
import { ListeningSettingsPage } from './ListeningSettings';
import { ReaderPage } from './Reader';
import { ReadingSettingsPage } from './ReadingSettings';
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

  // ── Top navigation bar ────────────────────────────────────────

  @Builder
  topTab(label: string, index: number) {
    Text(label)
      .fontSize(18)
      .fontWeight(this.activeTab === index ? FontWeight.Bold : FontWeight.Normal)
      .fontColor(this.activeTab === index ? $r('app.color.text_1') : $r('app.color.text_2'))
      .onClick(() => {
        this.activeTab = index;
        this.tabsController.changeIndex(index);
      })
  }

  @Builder
  menuTrigger() {
    Row({ space: 3 }) {
      Row().width(4).height(4).borderRadius(2).backgroundColor($r('app.color.text_2'))
      Row().width(4).height(4).borderRadius(2).backgroundColor($r('app.color.text_2'))
      Row().width(4).height(4).borderRadius(2).backgroundColor($r('app.color.text_2'))
    }
    .padding({ left: 10, right: 10, top: 10, bottom: 10 })
    .bindMenu(this.shelfMenuItems())
  }

  @Builder
  topBar() {
    Row() {
      Row({ space: 20 }) {
        this.topTab('书架', TAB_SHELF)
        this.topTab('搜索', TAB_SEARCH)
        this.topTab('设置', TAB_SETTINGS)
      }
      Blank()
      if (this.activeTab === TAB_SHELF) {
        this.menuTrigger()
      }
    }
    .width('100%')
    .height(52)
    .padding({ left: 16, right: 16 })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  pageMap(name: string, param: object) {
    if (name === ROUTE_SOURCE_MANAGE) {
      NavDestination() {
        BookSourceManagePage()
      }
      .title('书源管理')
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
          source: (param as DetailParam).source,
          book: (param as DetailParam).book,
          onBack: () => {
            this.pathStack.pop();
            this.shelfRefresh = this.shelfRefresh + 1;
          },
          onMore: () => this.openDetail((param as DetailParam).source, undefined, (param as DetailParam).book),
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

  build() {
    Navigation(this.pathStack) {
      Column() {
        this.topBar()

        Tabs({ barPosition: BarPosition.Start, index: this.activeTab, controller: this.tabsController }) {
          TabContent() {
            ShelfPage({
              refreshToken: this.shelfRefresh,
              viewMode: this.shelfViewMode,
              onGoSearch: () => {
                this.activeTab = TAB_SEARCH;
                this.tabsController.changeIndex(TAB_SEARCH);
              },
              onOpenBook: (source: BookSource, book: Book) => this.openReader(source, book),
              onOpenListening: () => this.openListening()
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
        .scrollable(true)
        .onChange((index: number) => {
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