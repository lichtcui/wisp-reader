import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { applyThemeMode, readThemeMode } from '../common/Theme';
import { applyKeepScreenOn, readKeepScreenOn, setMainWindow } from '../common/Window';
import { initShelf } from '../model/ShelfRepository';
import { TtsController } from '../model/TtsController';

const DOMAIN: number = 0x0000;
const TAG: string = 'SourceReader';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    applyThemeMode(this.context, readThemeMode(this.context));
    // Open the shelf DB eagerly so progress survives even when the user opens a
    // book from Search before ever visiting the Shelf tab.
    initShelf(this.context).catch((err: Error) => {
      hilog.warn(DOMAIN, TAG, 'shelf db init failed: %{public}s', err.message);
    });
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onCreate');
  }

  onDestroy(): void {
    TtsController.instance().stop();
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onWindowStageCreate');
    this.setupWindow(windowStage);
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'Failed to load content: %{public}s', JSON.stringify(err) ?? '');
        return;
      }
      hilog.info(DOMAIN, TAG, '%{public}s', 'Succeeded in loading content');
    });
  }

  private setupWindow(windowStage: window.WindowStage): void {
    try {
      const win: window.Window = windowStage.getMainWindowSync();
      win.setWindowLayoutFullScreen(false);
      setMainWindow(win);
      applyKeepScreenOn(readKeepScreenOn(this.context));
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'window setup failed: %{public}s', JSON.stringify(err));
    }
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onForeground');
  }

  onBackground(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onBackground');
  }
}