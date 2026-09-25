const FAB_SIZE: number = 52;
const FAB_MARGIN: number = 16;
/** Idle time after a drag before the button slides back to the right edge. */
const SNAP_IDLE_MS: number = 2500;
/** Snap animation, reusing the UI-SPEC overlay-open timing. */
const SNAP_DURATION_MS: number = 260;

/**
 * Draggable "continue listening" bubble. Floats over a page's root Stack,
 * follows the finger, and snaps back to the right edge after a short idle.
 * The root fills the parent but is `HitTestMode.None`, so only the bubble
 * consumes touches and the page underneath stays interactive.
 */
@ComponentV2
export struct FloatingListenButton {
  @Param visible: boolean = false;
  @Event onTap: () => void = () => {};

  @Local posX: number = -1;
  @Local posY: number = -1;
  @Local areaWidth: number = 0;
  @Local areaHeight: number = 0;
  private startX: number = 0;
  private startY: number = 0;
  private dragging: boolean = false;
  private snapTimerId: number = -1;

  aboutToDisappear(): void {
    this.clearSnap();
  }

  private clearSnap(): void {
    if (this.snapTimerId >= 0) {
      clearTimeout(this.snapTimerId);
      this.snapTimerId = -1;
    }
  }

  private maxX(): number {
    return Math.max(this.areaWidth - FAB_SIZE - FAB_MARGIN, FAB_MARGIN);
  }

  private maxY(): number {
    return Math.max(this.areaHeight - FAB_SIZE - FAB_MARGIN, FAB_MARGIN);
  }

  private clampX(value: number): number {
    return Math.min(Math.max(value, FAB_MARGIN), this.maxX());
  }

  private clampY(value: number): number {
    return Math.min(Math.max(value, FAB_MARGIN), this.maxY());
  }

  /** Slide to the right edge once the user stops interacting. */
  private scheduleSnap(): void {
    this.clearSnap();
    this.snapTimerId = setTimeout(() => {
      this.snapTimerId = -1;
      if (this.dragging) {
        return;
      }
      this.getUIContext().animateTo({ duration: SNAP_DURATION_MS, curve: Curve.FastOutSlowIn }, () => {
        this.posX = this.maxX();
      });
    }, SNAP_IDLE_MS);
  }

  private onArea(area: Area): void {
    const w: number = Number(area.width);
    const h: number = Number(area.height);
    if (w <= 0 || h <= 0) {
      return;
    }
    this.areaWidth = w;
    this.areaHeight = h;
    if (this.posX < 0) {
      this.posX = this.maxX();
      this.posY = this.clampY(h * 0.55);
    }
  }

  build() {
    if (this.visible && this.posX >= 0) {
      Stack() {
        Row() {
          SymbolGlyph($r('sys.symbol.headphones'))
            .fontSize(24)
            .fontColor([$r('app.color.on_brand')])
        }
        .width(FAB_SIZE)
        .height(FAB_SIZE)
        .borderRadius(FAB_SIZE / 2)
        .backgroundColor($r('app.color.brand'))
        .justifyContent(FlexAlign.Center)
        .shadow({ radius: 12, color: $r('app.color.shadow'), offsetX: 0, offsetY: 4 })
        .position({ x: this.posX, y: this.posY })
        .accessibilityText('继续听书')
        .onClick(() => this.onTap())
        .gesture(
          PanGesture({ direction: PanDirection.All })
            .onActionStart(() => {
              this.dragging = true;
              this.startX = this.posX;
              this.startY = this.posY;
              this.clearSnap();
            })
            .onActionUpdate((event: GestureEvent) => {
              this.posX = this.clampX(this.startX + event.offsetX);
              this.posY = this.clampY(this.startY + event.offsetY);
            })
            .onActionEnd(() => {
              this.dragging = false;
              this.scheduleSnap();
            })
        )
      }
      .width('100%')
      .height('100%')
      .hitTestBehavior(HitTestMode.None)
      .onAreaChange((_old: Area, next: Area) => this.onArea(next))
    }
  }
}