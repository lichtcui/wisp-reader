type AppSheetSize = 'medium' | 'large' | 'fit';
// 'overlay' draws inside the page (works when the page itself reaches the bottom
// edge, e.g. a NavDestination); 'cover' draws in the window-level modal layer so
// a drawer declared inside a bottom-tab page can slide over the tab bar without
// the tab bar moving; 'system' keeps the legacy bindSheet host.
type AppSheetMode = 'system' | 'overlay' | 'cover';

const SHEET_TOP_RADIUS: number = 20;
// Keep every drawer's open/close timing identical to the reading page drawer.
const OVERLAY_OPEN_MS: number = 260;
const OVERLAY_CLOSE_MS: number = 200;
// Fallback used only until the panel has been measured.
const PANEL_UNMEASURED: number = 3000;
// Grace period after the close animation before the panel leaves the render tree.
const PANEL_HIDE_DELAY_MS: number = 40;
// Two frames: long enough for a page relayout (bottom bar hiding) to be measured.
const MEASURE_WAIT_MS: number = 32;

@ComponentV2
export struct BottomDrawer {
  @Param visible: boolean = false;
  @Param title: string = '';
  @Param sheetSize: AppSheetSize = 'medium';
  @Param mode: AppSheetMode = 'system';
  @Param showHeader: boolean = true;
  @Param panelBackground: Resource = $r('app.color.bg_page');
  @Event onClose: () => void = () => {};
  @BuilderParam content: () => void = this.emptyContent;

  @Local overlayMounted: boolean = false;
  @Local overlayShown: boolean = false;
  @Local dragOffset: number = 0;
  @Local panelHeight: number = 0;
  // Whether the panel is in the render tree at all. While fully closed it is kept
  // laid out but not drawn: a mounted panel would otherwise leak its shadow past
  // the host clip and show up as a shadow band at the screen bottom.
  @Local panelShown: boolean = false;
  // Whether the panel size has ever been reported. Until then the panel is kept
  // Visible so the very first layout can measure it; while unmeasured it sits at
  // the PANEL_UNMEASURED offset anyway, i.e. far outside the viewport.
  @Local panelMeasured: boolean = false;

  @Builder
  emptyContent() {
  }

  // True while an open request is waiting for the panel to be measured.
  private pendingOpen: boolean = false;

  aboutToAppear(): void {
    if (this.mode === 'system') {
      return;
    }
    if (this.mode === 'overlay') {
      // Mount the panel up-front while it sits off-screen. This measures the panel
      // height before the first open, so every open slides up from the very bottom
      // edge over the full animation instead of "popping" into place.
      this.overlayMounted = true;
    }
    if (this.visible) {
      this.openOverlay();
    }
  }

  @Monitor('visible')
  onVisibleChange(): void {
    if (this.mode === 'system') {
      return;
    }
    if (this.visible) {
      this.openOverlay();
    } else {
      this.closeOverlay();
    }
  }

  private openOverlay(): void {
    this.dragOffset = 0;
    // 'cover' mounts the whole modal; 'overlay' keeps the panel mounted but shown.
    this.overlayMounted = true;
    if (this.mode === 'overlay') {
      this.panelShown = true;
    }
    // Opening may relayout the page, so always take a fresh measurement before
    // sliding; otherwise the first frame would use a stale panel height and start
    // the slide from the wrong offset.
    this.pendingOpen = true;
    setTimeout(() => this.flushPendingOpen(), MEASURE_WAIT_MS);
  }

  private flushPendingOpen(): void {
    if (!this.pendingOpen || !this.visible) {
      return;
    }
    this.pendingOpen = false;
    // One frame after the measured height is applied so the animation starts
    // from the real bottom-edge position rather than the placeholder offset.
    setTimeout(() => {
      if (this.visible && !this.overlayShown) {
        this.slideIn();
      }
    }, 16);
  }

  private slideIn(): void {
    this.getUIContext().animateTo({ duration: OVERLAY_OPEN_MS, curve: Curve.FastOutSlowIn }, () => {
      this.overlayShown = true;
    });
  }

  private closeOverlay(): void {
    this.pendingOpen = false;
    this.getUIContext().animateTo({ duration: OVERLAY_CLOSE_MS, curve: Curve.FastOutSlowIn }, () => {
      this.overlayShown = false;
    });
    // Once the panel is fully off-screen, drop it from the render tree (kills its
    // shadow) and unmount the modal layer for 'cover'.
    setTimeout(() => {
      if (this.overlayShown || this.visible) {
        return;
      }
      if (this.mode === 'cover') {
        this.overlayMounted = false;
      } else {
        this.panelShown = false;
      }
    }, OVERLAY_CLOSE_MS + PANEL_HIDE_DELAY_MS);
  }

  // Keeps the panel in the layout (and measurable) until its size is known once;
  // afterwards a closed panel is Hidden so neither it nor its shadow is painted.
  private panelVisibility(): Visibility {
    return (this.panelShown || !this.panelMeasured) ? Visibility.Visible : Visibility.Hidden;
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

  // Off-screen translate used while the panel is hidden; equal to the panel's own
  // height so it starts fully below the viewport and slides up into place.
  private panelSlideOut(): number {
    return this.panelHeight > 0 ? this.panelHeight : PANEL_UNMEASURED;
  }

  private endDrag(velocityY: number): void {
    const threshold: number = this.panelHeight * 0.3;
    if (this.dragOffset > threshold || velocityY > 1000) {
      this.getUIContext().animateTo({
        duration: 200,
        curve: Curve.FastOutSlowIn,
        onFinish: () => {
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
      if (this.showHeader) {
        this.titleBar()
        Divider()
          .color($r('app.color.divider'))
          .strokeWidth(1)
      }
      this.contentArea()
    }
    .width('100%')
  }

  @Builder
  sheetBody() {
    Column() {
      if (this.showHeader) {
        this.titleBar()
        Divider()
          .color($r('app.color.divider'))
          .strokeWidth(1)
      }
      this.contentArea()
    }
    .width('100%')
    .backgroundColor(this.panelBackground)
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
      backgroundColor: this.panelBackground,
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
      .backgroundColor(this.panelBackground)
      .borderRadius({ topLeft: SHEET_TOP_RADIUS, topRight: SHEET_TOP_RADIUS })
      .shadow({
        radius: 24,
        color: '#33000000',
        offsetX: 0,
        offsetY: -4
      })
      .clip(true)
      // Inside a modal page the layout stops above the bottom safe area and the
      // safe area cannot be detected (so `ignoreLayoutSafeArea` on the host is a
      // no-op). Extending the panel's own *drawing* instead lets its background
      // cover the safe area and pushes its bottom shadow off-screen.
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
    } else {
      Column() {
        this.panelBody()
      }
      .width('100%')
      .height(this.overlayHeight())
      .backgroundColor(this.panelBackground)
      .borderRadius({ topLeft: SHEET_TOP_RADIUS, topRight: SHEET_TOP_RADIUS })
      .shadow({
        radius: 24,
        color: '#33000000',
        offsetX: 0,
        offsetY: -4
      })
      .clip(true)
      // See the 'fit' branch above: a percentage height keeps the BOTTOM edge
      // expandable (a fixed/auto size would only allow TOP/START).
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
    }
  }

  @Builder
  overlayHost() {
    Stack() {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(Color.Transparent)
        // The panel stays mounted while closed, so the dim/close layer must not
        // swallow touches aimed at the page underneath.
        .hitTestBehavior(this.overlayShown ? HitTestMode.Default : HitTestMode.None)
        .onClick(() => this.onClose())

      Column() {
        this.overlayPanel()
      }
      .width('100%')
      .translate({ y: this.overlayShown ? this.dragOffset : this.panelSlideOut() })
      // Hidden while fully closed so neither the panel nor its shadow is painted.
      // Visibility.Hidden still lays the panel out, which keeps the measurement.
      .visibility(this.panelVisibility())
      // The panel stays mounted (off-screen) so its height is always known, which
      // keeps the slide-up exact. While hidden it must not take any input.
      .enabled(this.overlayShown)
      .hitTestBehavior(this.overlayShown ? HitTestMode.Default : HitTestMode.None)
      .onAreaChange((_old: Area, next: Area) => {
        this.panelHeight = Number(next.height);
        if (this.panelHeight > 0) {
          this.panelMeasured = true;
        }
        if (this.pendingOpen) {
          this.flushPendingOpen();
        }
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
    // `LayoutPolicy.matchParent` (not '100%') is required: with a percentage size
    // `ignoreLayoutSafeArea` may only shift the component's position, leaving its
    // box still ending at the top of the bottom safe area.
    .height(LayoutPolicy.matchParent)
    // The page area stops above the bottom safe area / tab bar. `expandSafeArea`
    // only extends the *draw* region (background), which alone leaves the panel
    // laid out above the navigation bar: its bottom shadow then shows as a grey
    // band at the top of the safe area. `ignoreLayoutSafeArea` extends the
    // *layout* so `alignContent(Bottom)` anchors the panel to the physical bottom
    // edge, covering the safe area and pushing the bottom shadow off-screen.
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.BOTTOM])
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
    .alignContent(Alignment.Bottom)
    .clip(true)
    // The host stays mounted so the panel can be measured while closed; it must
    // never consume touches aimed at the page underneath.
    .hitTestBehavior(HitTestMode.None)
  }

  @Builder
  coverBody() {
    Stack() {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(Color.Transparent)
        .onClick(() => this.onClose())

      Column() {
        this.overlayPanel()
      }
      .width('100%')
      .translate({ y: this.overlayShown ? this.dragOffset : this.panelSlideOut() })
      .onAreaChange((_old: Area, next: Area) => {
        this.panelHeight = Number(next.height);
        if (this.panelHeight > 0) {
          this.panelMeasured = true;
        }
        if (this.pendingOpen) {
          this.flushPendingOpen();
        }
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
    // matchParent (rather than '100%') so `ignoreLayoutSafeArea` can grow the box,
    // not merely move it (see the note in overlayHost).
    .height(LayoutPolicy.matchParent)
    .alignContent(Alignment.Bottom)
    // The modal is a window-level layer, but its layout still stops above the
    // window content bottom. Extend the *layout* into the navigation-bar safe
    // area so the panel is anchored to the physical bottom edge and its bottom
    // shadow does not linger as a grey band above the nav bar.
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.BOTTOM])
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
  }

  // A window-level modal layer: it sits above the bottom tab bar, so the drawer
  // can cover the tab bar (which stays exactly where it is) and its panel can be
  // anchored to the real bottom edge of the screen.
  @Builder
  coverHost() {
    Stack() {
    }
    .width(0)
    .height(0)
    .bindContentCover(this.overlayMounted, this.coverBody(), {
      modalTransition: ModalTransition.NONE,
      backgroundColor: Color.Transparent,
      onWillDismiss: (_action: DismissContentCoverAction) => {
        // Close through the page so the panel still animates out.
        this.onClose();
      }
    })
  }

  build() {
    if (this.mode === 'system') {
      this.systemHost()
    } else if (this.mode === 'cover') {
      this.coverHost()
    } else if (this.overlayMounted) {
      this.overlayHost()
    }
  }
}