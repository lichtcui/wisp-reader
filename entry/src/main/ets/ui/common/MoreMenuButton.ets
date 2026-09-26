type AppMoreTone = 'normal' | 'onReader' | 'onBrand';

@ComponentV2
export struct MoreMenuButton {
  @Param items: MenuElement[] = [];
  @Param tone: AppMoreTone = 'normal';
  @Param label: string = '更多';
  /** Optional explicit dot color (e.g. the reader's day/night dim token). */
  @Param color: ResourceColor | undefined = undefined;

  @Local pressed: boolean = false;

  private dotColor(): ResourceColor {
    if (this.color !== undefined) {
      return this.color;
    }
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
    .scale(this.pressed ? { x: 0.92, y: 0.92 } : { x: 1, y: 1 })
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