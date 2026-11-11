import { bundleManager, common } from '@kit.AbilityKit';
import { GroupTitle, InsetDivider, NavCell } from '../components/ListCells';
import { readThemeMode, themeModeLabel } from '../common/Theme';
import { formatBytes } from '../common/Format';
import { LISTENING_FEATURE_ENABLED } from '../common/Const';
import { getCacheStats } from '../model/CacheRepository';

@ComponentV2
export struct SettingsPage {
  @Param refreshToken: number = 0;
  @Local themeMode: number = 0;
  @Local version: string = '';
  @Local cacheText: string = '0 B';
  @Event onNavigate: (title: string) => void = () => {};

  aboutToAppear(): void {
    this.version = this.readVersion();
    this.reloadTheme();
    this.reloadCache();
  }

  @Monitor('refreshToken')
  onRefreshToken(): void {
    this.reloadTheme();
    this.reloadCache();
  }

  private ctx(): common.UIAbilityContext | undefined {
    return this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
  }

  private reloadTheme(): void {
    const ctx: common.UIAbilityContext | undefined = this.ctx();
    if (ctx !== undefined) {
      this.themeMode = readThemeMode(ctx);
    }
  }

  private reloadCache(): void {
    const ctx: common.UIAbilityContext | undefined = this.ctx();
    if (ctx !== undefined) {
      this.cacheText = formatBytes(getCacheStats(ctx).totalBytes);
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

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  build() {
    Column() {
      Scroll() {
        Column() {
          GroupTitle({ text: '设置' })
          NavCell({
            label: '阅读设置',
            value: '',
            showArrow: true,
            onTap: () => this.onNavigate('阅读设置')
          })
          if (LISTENING_FEATURE_ENABLED) {
            InsetDivider()
            NavCell({
              label: '听书设置',
              value: '',
              showArrow: true,
              onTap: () => this.onNavigate('听书设置')
            })
          }
          InsetDivider()
          NavCell({
            label: '书源管理',
            value: '',
            showArrow: true,
            onTap: () => this.onNavigate('书源管理')
          })
          InsetDivider()
          NavCell({
            label: '通用设置',
            value: themeModeLabel(this.themeMode),
            showArrow: true,
            onTap: () => this.onNavigate('通用设置')
          })

          GroupTitle({ text: '数据' })
          NavCell({
            label: '清理缓存',
            value: this.cacheText,
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
          InsetDivider()
          NavCell({
            label: '应用更新',
            value: '已是最新',
            showArrow: false,
            onTap: () => this.toast('当前已是最新版本')
          })

          GroupTitle({ text: '关于' })
          NavCell({ label: '应用版本', value: this.version, showArrow: false, onTap: () => {} })
          InsetDivider()
          NavCell({
            label: '书源来源',
            value: 'legado-source-filter',
            showArrow: false,
            onTap: () => {}
          })
          InsetDivider()
          NavCell({ label: '作者', value: 'lichtcui', showArrow: false, onTap: () => {} })
          InsetDivider()
          NavCell({
            label: 'GitHub',
            value: 'lichtcui/wisp-reader',
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

          Text('幽光阅读 · 兼容 Legado 书源 · 仅供学习交流')
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
