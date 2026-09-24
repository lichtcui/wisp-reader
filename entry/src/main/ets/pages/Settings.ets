import { bundleManager, common } from '@kit.AbilityKit';
import { GroupTitle, InsetDivider, NavCell, SegmentedCell, SwitchCell } from '../components/ListCells';
import { THEME_OPTIONS } from '../common/Const';
import { readThemeMode, saveAndApplyThemeMode, ThemeMode } from '../common/Theme';

@ComponentV2
export struct SettingsPage {
  @Local themeMode: number = ThemeMode.System;
  @Local keepScreenOn: boolean = false;
  @Local version: string = '';
  @Event onNavigate: (title: string) => void = () => {};

  aboutToAppear(): void {
    this.version = this.readVersion();
    const ctx: common.UIAbilityContext | undefined =
      this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    if (ctx !== undefined) {
      this.themeMode = readThemeMode(ctx);
    }
  }

  private readVersion(): string {
    try {
      const info: bundleManager.BundleInfo =
        bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      return info.versionName;
    } catch (err) {
      return '';
    }
  }

  private onThemeSelect(index: number): void {
    this.themeMode = index;
    const ctx: common.UIAbilityContext | undefined =
      this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    if (ctx !== undefined) {
      saveAndApplyThemeMode(ctx, index as ThemeMode);
    }
  }

  build() {
    Column() {
      Scroll() {
        Column() {
          GroupTitle({ text: '阅读' })
          NavCell({
            label: '阅读设置',
            value: '',
            showArrow: true,
            onTap: () => this.onNavigate('阅读设置')
          })
          InsetDivider()
          SwitchCell({
            label: '屏幕常亮',
            isOn: this.keepScreenOn,
            onToggle: (on: boolean) => {
              this.keepScreenOn = on;
            }
          })

          GroupTitle({ text: '听书' })
          NavCell({
            label: '听书设置',
            value: '',
            showArrow: true,
            onTap: () => this.onNavigate('听书设置')
          })

          GroupTitle({ text: '书源' })
          NavCell({
            label: '书源管理',
            value: '',
            showArrow: true,
            onTap: () => this.onNavigate('书源管理')
          })
          GroupTitle({ text: '通用' })
          Column() {
            Text('外观')
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
            .margin({ top: 10 })
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 12, bottom: 12 })
          InsetDivider()
          NavCell({
            label: '清理缓存',
            value: '0 B',
            showArrow: true,
            onTap: () => this.onNavigate('清理缓存')
          })
          InsetDivider()
          NavCell({
            label: '备份与恢复',
            value: '',
            showArrow: true,
            onTap: () => this.onNavigate('备份与恢复')
          })

          GroupTitle({ text: '关于' })
          NavCell({ label: '版本', value: this.version, showArrow: false, onTap: () => {} })
          InsetDivider()
          NavCell({
            label: 'GitHub',
            value: 'lichtcui',
            showArrow: true,
            onTap: () => this.onNavigate('GitHub')
          })
          InsetDivider()
          NavCell({
            label: '法律与免责声明',
            value: '',
            showArrow: true,
            onTap: () => this.onNavigate('法律与免责声明')
          })

          Text('源阅读 · 兼容 Legado 书源 · 仅供学习交流')
            .fontSize(12)
            .fontColor($r('app.color.text_5'))
            .margin({ top: 32, bottom: 40 })
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