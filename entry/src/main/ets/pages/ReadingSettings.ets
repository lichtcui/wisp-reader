import { common } from '@kit.AbilityKit';
import { GroupTitle, InsetDivider, SwitchCell } from '../components/ListCells';
import {
  KEY_READER_FONT_SIZE,
  KEY_READER_LINE_HEIGHT,
  KEY_READER_ONE_HAND_PAGE,
  READER_FONT_SIZE_DEFAULT,
  READER_LINE_HEIGHT_DEFAULT,
  READER_ONE_HAND_PAGE_DEFAULT
} from '../common/Const';
import { getBoolean, getNumber, putBoolean, putNumber } from '../common/Prefs';
import { readKeepScreenOn, saveAndApplyKeepScreenOn } from '../common/Window';

@ComponentV2
export struct ReadingSettingsPage {
  @Local keepScreenOn: boolean = false;
  @Local fontSize: number = READER_FONT_SIZE_DEFAULT;
  @Local lineHeight: number = READER_LINE_HEIGHT_DEFAULT;
  @Local oneHandPage: boolean = READER_ONE_HAND_PAGE_DEFAULT;

  aboutToAppear(): void {
    const ctx: common.UIAbilityContext | undefined = this.ctx();
    if (ctx !== undefined) {
      this.keepScreenOn = readKeepScreenOn(ctx);
      this.fontSize = getNumber(ctx, KEY_READER_FONT_SIZE, READER_FONT_SIZE_DEFAULT);
      this.lineHeight = getNumber(ctx, KEY_READER_LINE_HEIGHT, READER_LINE_HEIGHT_DEFAULT);
      this.oneHandPage = getBoolean(ctx, KEY_READER_ONE_HAND_PAGE, READER_ONE_HAND_PAGE_DEFAULT);
    }
  }

  private ctx(): common.UIAbilityContext | undefined {
    return this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
  }

  private onKeepScreenToggle(on: boolean): void {
    this.keepScreenOn = on;
    const ctx: common.UIAbilityContext | undefined = this.ctx();
    if (ctx !== undefined) {
      saveAndApplyKeepScreenOn(ctx, on);
    }
  }

  private onOneHandToggle(on: boolean): void {
    this.oneHandPage = on;
    const ctx: common.UIAbilityContext | undefined = this.ctx();
    if (ctx !== undefined) {
      putBoolean(ctx, KEY_READER_ONE_HAND_PAGE, on);
    }
  }

  private changeFont(delta: number): void {
    const next: number = Math.min(28, Math.max(14, this.fontSize + delta));
    this.fontSize = next;
    const ctx: common.UIAbilityContext | undefined = this.ctx();
    if (ctx !== undefined) {
      putNumber(ctx, KEY_READER_FONT_SIZE, next);
    }
  }

  private changeLineHeight(delta: number): void {
    const next: number = Math.round(Math.min(2.6, Math.max(1.2, this.lineHeight + delta)) * 10) / 10;
    this.lineHeight = next;
    const ctx: common.UIAbilityContext | undefined = this.ctx();
    if (ctx !== undefined) {
      putNumber(ctx, KEY_READER_LINE_HEIGHT, next);
    }
  }

  @Builder
  stepButton(label: string, action: () => void) {
    Text(label)
      .fontSize(18)
      .fontColor($r('app.color.brand'))
      .width(40)
      .height(40)
      .textAlign(TextAlign.Center)
      .onClick(action)
  }

  build() {
    Column() {
      Scroll() {
        Column() {
          GroupTitle({ text: '阅读' })
          SwitchCell({
            label: '屏幕常亮',
            isOn: this.keepScreenOn,
            onToggle: (on: boolean) => this.onKeepScreenToggle(on)
          })
          InsetDivider()

          SwitchCell({
            label: '单手翻页',
            isOn: this.oneHandPage,
            onToggle: (on: boolean) => this.onOneHandToggle(on)
          })
          InsetDivider()

          Row() {
            Text('字号')
              .fontSize(16)
              .fontColor($r('app.color.text_1'))
            Blank()
            this.stepButton('A−', () => this.changeFont(-1))
            Text(`${this.fontSize}`)
              .fontSize(14)
              .fontColor($r('app.color.text_4'))
              .width(44)
              .textAlign(TextAlign.Center)
            this.stepButton('A+', () => this.changeFont(1))
          }
          .width('100%')
          .padding({ left: 16, right: 12, top: 8, bottom: 8 })
          InsetDivider()

          Row() {
            Text('行距')
              .fontSize(16)
              .fontColor($r('app.color.text_1'))
            Blank()
            this.stepButton('−', () => this.changeLineHeight(-0.1))
            Text(this.lineHeight.toFixed(1))
              .fontSize(14)
              .fontColor($r('app.color.text_4'))
              .width(44)
              .textAlign(TextAlign.Center)
            this.stepButton('+', () => this.changeLineHeight(0.1))
          }
          .width('100%')
          .padding({ left: 16, right: 12, top: 8, bottom: 8 })

          Text('字号与行距即时生效并持久化；屏幕常亮仅在本应用内生效；单手翻页放大左右翻页热区、保留中间菜单区。')
            .fontSize(12)
            .fontColor($r('app.color.text_4'))
            .width('100%')
            .padding({ left: 16, right: 16, top: 16 })
        }
        .width('100%')
      }
      .layoutWeight(1)
      .width('100%')
      .align(Alignment.Top)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
  }
}