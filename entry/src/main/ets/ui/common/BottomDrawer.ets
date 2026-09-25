type AppSheetSize = 'medium' | 'large' | 'fit';
type AppSheetMode = 'system' | 'overlay';

const SHEET_TOP_RADIUS: number = 20;

@ComponentV2
export struct BottomDrawer {
  @Param visible: boolean = false;
  @Param title: string = '';
  @Param sheetSize: AppSheetSize = 'medium';
  @Param mode: AppSheetMode = 'system';
  @Event onClose: () => void = () => {};
  @BuilderParam content: () => void = this.emptyContent;

  @Local overlayMounted: boolean = false;
  @Local overlayShown: boolean = false;
  @Local dragOffset: number = 0;
  @Local panelHeight: number = 0;

  @Builder
  emptyContent() {
  }

  aboutToAppear(): void {
    if (this.mode === 'overlay' && this.visible) {
      this.overlayMounted = true;
      this.overlayShown = true;
    }
  }

  @Monitor('visible')
  onVisibleChange(): void {
    if (this.mode !== 'overlay') {
      return;
    }
    if (this.visible) {
      this.dragOffset = 0;
      this.overlayMounted = true;
      this.getUIContext().animateTo({ duration: 260, curve: Curve.FastOutSlowIn }, () => {
        this.overlayShown = true;
      });
    } else {
      this.getUIContext().animateTo({ duration: 200, curve: Curve.FastOutSlowIn }, () => {
        this.overlayShown = false;
      });
      setTimeout(() => {
        if (!this.visible) {
          this.dragOffset = 0;
          this.overlayMounted = false;
        }
      }, 200);
    }
  }

  private sheetSizeValue(): SheetSize | Length {
    if (this.sheetSize === 'large') {
      return SheetSize.LARGE;
    }
    if (this.sheetSize === 'fit') {
      return SheetSize.FIT_CONTENT;
    }
    return SheetSize.MEDIUM;
  }

  private overlayHeight(): Length {
    return this.sheetSize === 'large' ? '90%' : '70%';
  }

  private endDrag(velocityY: number): void {
    const threshold: number = this.panelHeight * 0.3;
    if (this.dragOffset > threshold || velocityY > 1000) {
      this.getUIContext().animateTo({
        duration: 200,
        curve: Curve.FastOutSlowIn,
        onFinish: () => {
          this.dragOffset = 0;
          this.onClose();
        }
      }, () => {
        this.dragOffset = this.panelHeight;
      });
    } else {
      this.getUIContext().animateTo({ duration: 200, curve: Curve.FastOutSlowIn }, () => {
        this.dragOffset = 0;
      });
    }
  }

  @Builder
  closeButton() {
    Row() {
      SymbolGlyph($r('sys.symbol.xmark'))
        .fontSize(20)
        .fontColor([$r('app.color.text_3')])
    }
    .width(40)
    .height(40)
    .justifyContent(FlexAlign.Center)
    .accessibilityText('关闭')
    .accessibilityLevel('yes')
    .onClick(() => this.onClose())
  }

  @Builder
  titleBar() {
    Row() {
      Text(this.title)
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_1'))
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      this.closeButton()
    }
    .width('100%')
    .height(48)
    .padding({ left: 20, right: 8 })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  dragBar() {
    Row() {
      Row()
        .width(36)
        .height(4)
        .borderRadius(2)
        .backgroundColor($r('app.color.divider'))
    }
    .width('100%')
    .margin({ top: 8 })
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  contentArea() {
    Column() {
      this.content()
    }
    .layoutWeight(this.sheetSize === 'fit' ? 0 : 1)
    .width('100%')
    .padding({ left: 16, right: 16, bottom: 24 })
  }

  @Builder
  panelBody() {
    Column() {
      this.dragBar()
      this.titleBar()
      Divider()
        .color($r('app.color.divider'))
        .strokeWidth(1)
      this.contentArea()
    }
    .width('100%')
  }

  @Builder
  sheetBody() {
    Column() {
      this.titleBar()
      Divider()
        .color($r('app.color.divider'))
        .strokeWidth(1)
      this.contentArea()
    }
    .width('100%')
    .backgroundColor($r('app.color.bg_page'))
    .borderRadius({ topLeft: SHEET_TOP_RADIUS, topRight: SHEET_TOP_RADIUS })
    .clip(true)
  }

  @Builder
  systemHost() {
    Stack() {
    }
    .width(1)
    .height(1)
    .bindSheet(this.visible, this.sheetBody(), {
      height: this.sheetSizeValue(),
      dragBar: true,
      showClose: false,
      blurStyle: BlurStyle.NONE,
      maskColor: $r('app.color.mask'),
      backgroundColor: $r('app.color.bg_page'),
      preferType: SheetType.BOTTOM,
      enableOutsideInteractive: false,
      onWillDismiss: (action: DismissSheetAction) => {
        action.dismiss();
        this.onClose();
      }
    })
  }

  @Builder
  overlayPanel() {
    if (this.sheetSize === 'fit') {
      Column() {
        this.panelBody()
      }
      .width('100%')
      .constraintSize({ maxHeight: '90%' })
      .backgroundColor($r('app.color.bg_page'))
      .borderRadius({ topLeft: SHEET_TOP_RADIUS, topRight: SHEET_TOP_RADIUS })
      .clip(true)
    } else {
      Column() {
        this.panelBody()
      }
      .width('100%')
      .height(this.overlayHeight())
      .backgroundColor($r('app.color.bg_page'))
      .borderRadius({ topLeft: SHEET_TOP_RADIUS, topRight: SHEET_TOP_RADIUS })
      .clip(true)
    }
  }

  @Builder
  overlayHost() {
    Stack() {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor($r('app.color.mask'))
        .opacity(this.overlayShown ? 1 : 0)
        .animation({ duration: this.overlayShown ? 200 : 160, curve: Curve.Linear })
        .onClick(() => this.onClose())

      Column() {
        this.overlayPanel()
      }
      .width('100%')
      .translate({ y: this.overlayShown ? this.dragOffset : 24 })
      .opacity(this.overlayShown ? 1 : 0)
      .onAreaChange((_old: Area, next: Area) => {
        this.panelHeight = Number(next.height);
      })
      .gesture(
        PanGesture({ direction: PanDirection.Vertical })
          .onActionUpdate((event: GestureEvent) => {
            this.dragOffset = Math.max(0, event.offsetY);
          })
          .onActionEnd((event: GestureEvent) => {
            this.endDrag(event.velocityY);
          })
      )
    }
    .width('100%')
    .height('100%')
    .alignContent(Alignment.Bottom)
  }

  build() {
    if (this.mode === 'system') {
      this.systemHost()
    } else if (this.overlayMounted) {
      this.overlayHost()
    }
  }
}