import { EmptyView } from '../components/EmptyView';
import {
  DetailParam,
  PlaceholderParam,
  ROUTE_BOOK_DETAIL,
  ROUTE_PLACEHOLDER,
  ROUTE_READER,
  ROUTE_SEARCH_RESULT,
  ROUTE_SOURCE_MANAGE,
  SearchParam
} from '../common/Const';
import { Book, BookSearchItem, BookSource } from '../engine/types';
import { BookDetailPage } from './BookDetail';
import { BookSourceManagePage } from './BookSourceManage';
import { ReaderPage } from './Reader';
import { SearchPage } from './Search';
import { SearchResultPage } from './SearchResult';
import { SettingsPage } from './Settings';
import { ShelfPage } from './Shelf';

@Entry
@ComponentV2
struct Index {
  @Local activeTab: number = 0;
  @Local shelfRefresh: number = 0;
  @Local pathStack: NavPathStack = new NavPathStack();

  private pushPlaceholder(title: string): void {
    this.pathStack.pushPath({ name: ROUTE_PLACEHOLDER, param: new PlaceholderParam(title) });
  }

  private openSourceManage(): void {
    this.pathStack.pushPath({ name: ROUTE_SOURCE_MANAGE });
  }

  private openSearchResult(keyword: string): void {
    this.pathStack.pushPath({ name: ROUTE_SEARCH_RESULT, param: new SearchParam(keyword) });
  }

  private openDetail(source: BookSource, item?: BookSearchItem, book?: Book): void {
    this.pathStack.pushPath({ name: ROUTE_BOOK_DETAIL, param: new DetailParam(source, item, book) });
  }

  private openReader(source: BookSource, book: Book): void {
    this.pathStack.pushPath({ name: ROUTE_READER, param: new DetailParam(source, undefined, book) });
  }

  @Builder
  tabItem(label: string, index: number) {
    Column() {
      Text(label)
        .fontSize(17)
        .fontWeight(this.activeTab === index ? FontWeight.Bold : FontWeight.Normal)
        .fontColor(this.activeTab === index ? $r('app.color.brand') : $r('app.color.text_2'))
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  pageMap(name: string, param: object) {
    if (name === ROUTE_SOURCE_MANAGE) {
      NavDestination() {
        BookSourceManagePage()
      }
      .title('书源管理')
      .backgroundColor($r('app.color.bg_page'))
    } else if (name === ROUTE_SEARCH_RESULT) {
      NavDestination() {
        SearchResultPage({
          keyword: (param as SearchParam).keyword,
          onOpenDetail: (source: BookSource, item: BookSearchItem) => this.openDetail(source, item)
        })
      }
      .title('搜索结果')
      .backgroundColor($r('app.color.bg_page'))
    } else if (name === ROUTE_BOOK_DETAIL) {
      NavDestination() {
        BookDetailPage({
          source: (param as DetailParam).source,
          item: (param as DetailParam).item,
          book: (param as DetailParam).book,
          onRead: (source: BookSource, book: Book) => this.openReader(source, book)
        })
      }
      .title('书籍详情')
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
          onMore: () => this.openDetail((param as DetailParam).source, undefined, (param as DetailParam).book)
        })
      }
      .hideTitleBar(true)
      .backgroundColor($r('app.color.reader_bg'))
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
      Tabs({ barPosition: BarPosition.Start, index: this.activeTab }) {
        TabContent() {
          ShelfPage({
            refreshToken: this.shelfRefresh,
            onGoSearch: () => {
              this.activeTab = 1;
            },
            onOpenBook: (source: BookSource, book: Book) => this.openDetail(source, undefined, book)
          })
        }
        .tabBar(this.tabItem('书架', 0))

        TabContent() {
          SearchPage({
            onSearch: (keyword: string) => this.openSearchResult(keyword),
            onOpenSource: () => this.openSourceManage()
          })
        }
        .tabBar(this.tabItem('搜索', 1))

        TabContent() {
          SettingsPage({
            onNavigate: (title: string) => {
              if (title === '书源管理') {
                this.openSourceManage();
              } else {
                this.pushPlaceholder(title);
              }
            }
          })
        }
        .tabBar(this.tabItem('设置', 2))
      }
      .barMode(BarMode.Fixed)
      .barHeight(52)
      .scrollable(true)
      .onChange((index: number) => {
        this.activeTab = index;
        if (index === 0) {
          this.shelfRefresh = this.shelfRefresh + 1;
        }
      })
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.bg_page'))
    }
    .mode(NavigationMode.Stack)
    .hideTitleBar(true)
    .navDestination(this.pageMap)
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
  }
}