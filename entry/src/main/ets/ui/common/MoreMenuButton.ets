type AppMoreTone = 'normal' | 'onReader' | 'onBrand';

@ComponentV2
export struct MoreMenuButton {
  @Param items: MenuElement[] = [];
  @Param tone: AppMoreTone = 'normal';
  @Param label: string = '更多';

  @Local pressed: boolean = false;

  private dotColor(): Resource {
    if (this.tone === 'onBrand') {
      return $r('app.color.on_brand');
    }
    if (this.tone === 'onReader') {
      return $r('app.color.reader_dim');
    }
    return $r('app.color.text_2');
  }

  private setPressed(value: boolean): void {
    this.getUIContext().animateTo({ duration: 100, curve: Curve.EaseInOut }, () => {
      this.pressed = value;
    });
  }

  build() {
    Row({ space: 3 }) {
      Row().width(4).height(4).borderRadius(2).backgroundColor(this.dotColor())
      Row().width(4).height(4).borderRadius(2).backgroundColor(this.dotColor())
      Row().width(4).height(4).borderRadius(2).backgroundColor(this.dotColor())
    }
    .width(44)
    .height(44)
    .justifyContent(FlexAlign.Center)
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
    .bindMenu(this.items)
  }
}