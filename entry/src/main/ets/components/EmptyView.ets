@ComponentV2
export struct EmptyView {
  @Param title: string = '';
  @Param desc: string = '';
  @Param actionText: string = '';
  @Event onAction: () => void = () => {};

  build() {
    Column({ space: 14 }) {
      Stack() {
        Column()
          .width(64)
          .height(64)
          .borderRadius(18)
          .linearGradient({
            angle: 160,
            colors: [[$r('app.color.brand_grad_a'), 0], [$r('app.color.brand_grad_b'), 1]]
          })
        Text('源')
          .fontSize(26)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.on_brand'))
      }
      .width(64)
      .height(64)

      Text(this.title)
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_1'))

      if (this.desc.length > 0) {
        Text(this.desc)
          .fontSize(14)
          .fontColor($r('app.color.text_4'))
          .lineHeight(20)
          .textAlign(TextAlign.Center)
          .constraintSize({ maxWidth: 300 })
      }

      if (this.actionText.length > 0) {
        Button(this.actionText)
          .height(40)
          .fontSize(15)
          .fontColor($r('app.color.on_brand'))
          .backgroundColor($r('app.color.brand'))
          .borderRadius(20)
          .padding({ left: 24, right: 24 })
          .margin({ top: 6 })
          .onClick(() => this.onAction())
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
    .justifyContent(FlexAlign.Center)
  }
}