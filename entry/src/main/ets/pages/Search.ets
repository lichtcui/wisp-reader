import { EmptyView } from '../components/EmptyView';

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
      Row() {
        TextInput({ placeholder: '搜索书名或作者' })
          .layoutWeight(1)
          .height(46)
          .fontSize(16)
          .fontColor($r('app.color.text_1'))
          .placeholderColor($r('app.color.text_5'))
          .backgroundColor($r('app.color.bg_card'))
          .borderRadius(23)
          .padding({ left: 18, right: 18 })
          .onChange((value: string) => {
            this.keyword = value;
          })
          .onSubmit(() => this.submit())
        Button('搜索')
          .height(46)
          .fontSize(16)
          .fontColor($r('app.color.on_brand'))
          .backgroundColor($r('app.color.brand'))
          .borderRadius(23)
          .margin({ left: 12 })
          .onClick(() => this.submit())
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 8 })

      Column() {
        EmptyView({
          title: '搜索你想看的小说',
          desc: '输入书名或作者，聚合全部已导入书源',
          actionText: '管理书源',
          onAction: () => this.onOpenSource()
        })
      }
      .layoutWeight(1)
      .width('100%')
      .justifyContent(FlexAlign.Center)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
  }
}