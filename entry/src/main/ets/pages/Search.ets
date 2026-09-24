@ComponentV2
export struct SearchPage {
  @Local keyword: string = '';
  @Event onSearch: (keyword: string) => void = () => {};
  @Event onOpenSource: () => void = () => {};

  private submit(): void {
    const kw: string = this.keyword.trim();
    if (kw.length === 0) {
      return;
    }
    this.onSearch(kw);
  }

  build() {
    Column() {
      Column({ space: 24 }) {
        Row() {
          SymbolGlyph($r('sys.symbol.magnifyingglass'))
            .fontSize(20)
            .fontColor([$r('app.color.text_4')])
          TextInput({ placeholder: '输入小说名称、作者' })
            .layoutWeight(1)
            .height(52)
            .fontSize(16)
            .fontColor($r('app.color.text_1'))
            .placeholderColor($r('app.color.text_5'))
            .backgroundColor(Color.Transparent)
            .padding({ left: 10, right: 0 })
            .enterKeyType(EnterKeyType.Search)
            .onChange((value: string) => {
              this.keyword = value;
            })
            .onSubmit(() => this.submit())
        }
        .width('100%')
        .height(52)
        .padding({ left: 18, right: 18 })
        .backgroundColor($r('app.color.bg_card'))
        .borderRadius(26)

        Text('管理书源')
          .fontSize(15)
          .fontColor($r('app.color.brand'))
          .onClick(() => this.onOpenSource())
      }
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .padding({ left: 20, right: 20 })
    .justifyContent(FlexAlign.Center)
    .backgroundColor($r('app.color.bg_page'))
  }
}