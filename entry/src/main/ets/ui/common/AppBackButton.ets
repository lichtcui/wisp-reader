type AppBackTone = 'normal' | 'onBrand';

@ComponentV2
export struct AppBackButton {
  @Param label: string = '返回';
  @Param tone: AppBackTone = 'normal';
  @Event onTap: () => void = () => {};

  @Local pressed: boolean = false;

  private toneColor(): Resource {
    return this.tone === 'onBrand' ? $r('app.color.on_brand') : $r('app.color.text_1');
  }

  private setPressed(value: boolean): void {
    this.getUIContext().animateTo({ duration: 100, curve: Curve.EaseInOut }, () => {
      this.pressed = value;
    });
  }

  build() {
    Row() {
      SymbolGlyph($r('sys.symbol.arrow_left'))
        .fontSize(24)
        .fontColor([this.toneColor()])
    }
    .width(44)
    .height(44)
    .justifyContent(FlexAlign.Center)
    .backgroundColor(Color.Transparent)
    .scale(this.pressed ? 0.92 : 1)
    .accessibilityText(this.label)
    .accessibilityLevel('yes')
    .onTouch((event: TouchEvent) => {
      if (event.type === TouchType.Down) {
        this.setPressed(true);
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.setPressed(false);
      }
    })
    .onClick(() => this.onTap())
  }
}