import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { applyThemeMode, readThemeMode } from '../common/Theme';
import { applyKeepScreenOn, readKeepScreenOn, setMainWindow } from '../common/Window';
import { scheduleStartupTrim } from '../model/CacheTrim';
import { initShelf } from '../model/ShelfRepository';
import { ensureSourceStore, MigrateResult } from '../model/SourceStoreMigration';
import { TtsController } from '../model/TtsController';
import { recoverPendingRestore, RestoreRecoveryResult } from '../model/BackupRecovery';

const DOMAIN: number = 0x0000;
const TAG: string = 'WispReader';

export default class EntryAbility extends UIAbility {
  private startupReady: Promise<void> = Promise.resolve();
  private recoveryFailed: boolean = false;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    applyThemeMode(this.context, readThemeMode(this.context));
    // A journal from an interrupted import must win before any normal page reads
    // either RDB store. UI content is loaded after this recovery barrier.
    this.startupReady = recoverPendingRestore(this.context)
      .then((result: RestoreRecoveryResult): void => {
        if (result.status === 'restored') {
          hilog.info(DOMAIN, TAG, 'startup restore recovered sources=%{public}d books=%{public}d progress=%{public}d',
            result.sources, result.books, result.progress);
        }
      })
      .catch((err: Error): void => {
        this.recoveryFailed = true;
        hilog.error(DOMAIN, TAG, 'startup restore failed msg=%{public}s', err.message);
      })
      .then((): void => {
        // Open the shelf DB eagerly so progress survives even when the user opens
        // a book from Search before ever visiting the Shelf tab.
        initShelf(this.context)
          .then((): void => {
            // Cache quota/TTL maintenance needs the progress table (it decides
            // which chapters count as "read"), so it waits for the DB.
            scheduleStartupTrim(this.context);
          })
          .catch((err: Error): void => {
            hilog.warn(DOMAIN, TAG, 'shelf db init failed: %{public}s', err.message);
          });
        ensureSourceStore(this.context)
          .then((result: MigrateResult): void => {
            hilog.info(
              DOMAIN,
              TAG,
              'source migration status=%{public}s count=%{public}d backup=%{public}s',
              result.status,
              result.count,
              result.backupPath
            );
          })
          .catch((err: Error): void => {
            hilog.warn(DOMAIN, TAG, 'source store migration failed: %{public}s', err.message);
          });
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
    this.startupReady.then((): void => {
      windowStage.loadContent('pages/Index', (err) => {
        if (err.code) {
          hilog.error(DOMAIN, TAG, 'Failed to load content: %{public}s', JSON.stringify(err) ?? '');
          return;
        }
        hilog.info(DOMAIN, TAG, '%{public}s', 'Succeeded in loading content');
        if (this.recoveryFailed) {
          windowStage.getMainWindowSync().getUIContext().getPromptAction().showToast({
            message: '上次恢复未完成，旧数据恢复失败，请重启应用重试'
          });
        }
      });
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
