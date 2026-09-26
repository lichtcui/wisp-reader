import { BookSearchItem, BookSource } from '../engine/types';
import { SearchResultPage } from './SearchResult';

@ComponentV2
export struct SearchPage {
  @Local keyword: string = '';
  @Local submittedKeyword: string = '';
  @Local searchToken: number = 0;

  @Event onOpenDetail: (source: BookSource, item: BookSearchItem) => void = () => {};

  private submit(): void {
    const kw: string = this.keyword.trim();
    if (kw.length === 0) {
      return;
    }
    this.submittedKeyword = kw;
    this.searchToken = this.searchToken + 1;
  }

  @Builder
  searchBar() {
    Row() {
      SymbolGlyph($r('sys.symbol.magnifyingglass'))
        .fontSize(18)
        .fontColor([$r('app.color.text_4')])
      TextInput({ text: this.keyword, placeholder: '输入小说名称、作者' })
        .layoutWeight(1)
        .height(44)
        .fontSize(15)
        .fontColor($r('app.color.text_1'))
        .placeholderColor($r('app.color.text_5'))
        .backgroundColor(Color.Transparent)
        .padding({ left: 8, right: 0 })
        .enterKeyType(EnterKeyType.Search)
        .onChange((value: string) => {
          this.keyword = value;
        })
        .onSubmit(() => this.submit())
      if (this.keyword.length > 0) {
        Text('✕')
          .fontSize(14)
          .fontColor($r('app.color.text_4'))
          .padding({ left: 6, right: 4, top: 8, bottom: 8 })
          .onClick(() => {
            this.keyword = '';
          })
      }
    }
    .width('100%')
    .height(44)
    .padding({ left: 14, right: 8 })
    .backgroundColor($r('app.color.bg_card'))
    .borderRadius(22)
  }

  @Builder
  idleHint() {
    Column({ space: 12 }) {
      SymbolGlyph($r('sys.symbol.magnifyingglass'))
        .fontSize(40)
        .fontColor([$r('app.color.text_5')])
      Text('输入书名或作者开始搜索')
        .fontSize(14)
        .fontColor($r('app.color.text_4'))
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
  }

  build() {
    Column() {
      Row() {
        this.searchBar()
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 8, bottom: 8 })

      if (this.submittedKeyword.length === 0) {
        Column() {
          this.idleHint()
        }
        .layoutWeight(1)
        .width('100%')
        .justifyContent(FlexAlign.Center)
      } else {
        Column() {
          SearchResultPage({
            keyword: this.submittedKeyword,
            searchToken: this.searchToken,
            onOpenDetail: (source: BookSource, item: BookSearchItem) => this.onOpenDetail(source, item)
          })
        }
        .layoutWeight(1)
        .width('100%')
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
  }
}