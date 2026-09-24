@ComponentV2
export struct GroupTitle {
  @Param text: string = '';

  build() {
    Text(this.text)
      .fontSize(13)
      .fontColor($r('app.color.text_4'))
      .width('100%')
      .padding({ left: 16, right: 16 })
      .margin({ top: 22, bottom: 6 })
  }
}

@ComponentV2
export struct InsetDivider {
  build() {
    Divider()
      .color($r('app.color.divider'))
      .strokeWidth(1)
      .margin({ left: 16 })
  }
}

@ComponentV2
export struct NavCell {
  @Param label: string = '';
  @Param value: string = '';
  @Param showArrow: boolean = true;
  @Param valueColor: ResourceColor = $r('app.color.text_4');
  @Event onTap: () => void = () => {};

  build() {
    Row() {
      Text(this.label)
        .fontSize(16)
        .fontColor($r('app.color.text_1'))
      Blank()
      if (this.value.length > 0) {
        Text(this.value)
          .fontSize(14)
          .fontColor(this.valueColor)
          .margin({ right: 6 })
      }
      if (this.showArrow) {
        Text('›')
          .fontSize(20)
          .fontColor($r('app.color.arrow'))
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 15, bottom: 15 })
    .onClick(() => this.onTap())
  }
}

@ComponentV2
export struct SwitchCell {
  @Param label: string = '';
  @Param isOn: boolean = false;
  @Event onToggle: (on: boolean) => void = () => {};

  build() {
    Row() {
      Text(this.label)
        .fontSize(16)
        .fontColor($r('app.color.text_1'))
      Blank()
      Toggle({ type: ToggleType.Switch, isOn: this.isOn })
        .selectedColor($r('app.color.brand'))
        .onChange((on: boolean) => this.onToggle(on))
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 10, bottom: 10 })
  }
}

@ComponentV2
export struct SegmentedCell {
  @Param options: string[] = [];
  @Param selected: number = 0;
  @Event onSelect: (index: number) => void = () => {};

  build() {
    Row({ space: 8 }) {
      ForEach(this.options, (option: string, index: number) => {
        Text(option)
          .fontSize(14)
          .fontWeight(index === this.selected ? FontWeight.Medium : FontWeight.Normal)
          .fontColor(index === this.selected ? $r('app.color.on_brand') : $r('app.color.text_2'))
          .backgroundColor(index === this.selected ? $r('app.color.brand') : $r('app.color.bg_pill'))
          .textAlign(TextAlign.Center)
          .layoutWeight(1)
          .height(36)
          .borderRadius(18)
          .onClick(() => this.onSelect(index))
      }, (option: string, index: number) => index.toString() + '_' + option)
    }
    .width('100%')
  }
}