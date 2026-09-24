import { common } from '@kit.AbilityKit';
import { GroupTitle, SegmentedCell } from '../components/ListCells';
import { THEME_OPTIONS } from '../common/Const';
import { readThemeMode, saveAndApplyThemeMode, ThemeMode } from '../common/Theme';

@ComponentV2
export struct GeneralSettingsPage {
  @Local themeMode: number = ThemeMode.System;

  aboutToAppear(): void {
    const ctx: common.UIAbilityContext | undefined = this.ctx();
    if (ctx !== undefined) {
      this.themeMode = readThemeMode(ctx);
    }
  }

  private ctx(): common.UIAbilityContext | undefined {
    return this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
  }

  private onThemeSelect(index: number): void {
    this.themeMode = index;
    const ctx: common.UIAbilityContext | undefined = this.ctx();
    if (ctx !== undefined) {
      saveAndApplyThemeMode(ctx, index as ThemeMode);
    }
  }

  build() {
    Column() {
      Scroll() {
        Column() {
          GroupTitle({ text: '外观' })
          Column() {
            Text('主题')
              .fontSize(16)
              .fontColor($r('app.color.text_1'))
              .width('100%')
            Row() {
              SegmentedCell({
                options: THEME_OPTIONS,
                selected: this.themeMode,
                onSelect: (index: number) => this.onThemeSelect(index)
              })
            }
            .width('100%')
            .margin({ top: 12 })
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 14, bottom: 16 })

          Text('跟随系统时随系统深色模式自动切换。')
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