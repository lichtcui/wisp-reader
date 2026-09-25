import { window } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { KEY_KEEP_SCREEN_ON } from './Const';
import { getBoolean, putBoolean } from './Prefs';

const DOMAIN: number = 0x0000;
const TAG: string = 'Window';

let mainWindow: window.Window | null = null;

export function setMainWindow(win: window.Window): void {
  mainWindow = win;
}

/** Switch the main window between immersive and non-immersive layout. */
export function setLayoutFullScreen(on: boolean): void {
  const win: window.Window | null = mainWindow;
  if (win === null) {
    return;
  }
  try {
    win.setWindowLayoutFullScreen(on)
      .then((): void => {
        hilog.info(DOMAIN, TAG, 'setWindowLayoutFullScreen %{public}s ok', on ? 'true' : 'false');
      })
      .catch((err: Object): void => {
        hilog.warn(DOMAIN, TAG, 'setWindowLayoutFullScreen failed: %{public}s', JSON.stringify(err));
      });
  } catch (err) {
    hilog.warn(DOMAIN, TAG, 'setWindowLayoutFullScreen threw: %{public}s', JSON.stringify(err));
  }
}

/** Tint the status-bar icons so they stay legible over the reader background. */
export function setStatusBarContentColor(color: string): void {
  const win: window.Window | null = mainWindow;
  if (win === null) {
    return;
  }
  try {
    win.setWindowSystemBarProperties({ statusBarContentColor: color });
  } catch (err) {
    hilog.warn(DOMAIN, TAG, 'setWindowSystemBarProperties failed: %{public}s', JSON.stringify(err));
  }
}

/**
 * Paint the window background. In immersive mode the transparent status-bar
 * area shows this color, so the reader's top safe area blends with its page.
 */
export function setWindowBackgroundColor(color: string): void {
  const win: window.Window | null = mainWindow;
  if (win === null) {
    return;
  }
  try {
    win.setWindowBackgroundColor(color);
  } catch (err) {
    hilog.warn(DOMAIN, TAG, 'setWindowBackgroundColor failed: %{public}s', JSON.stringify(err));
  }
}

/** 读取「屏幕常亮」开关（持久化于 preferences）。 */
export function readKeepScreenOn(ctx: common.UIAbilityContext): boolean {
  return getBoolean(ctx, KEY_KEEP_SCREEN_ON, false);
}

/** 应用「屏幕常亮」到主窗口（不持久化）。 */
export function applyKeepScreenOn(on: boolean): void {
  const win: window.Window | null = mainWindow;
  if (win === null) {
    return;
  }
  try {
    win.setWindowKeepScreenOn(on);
  } catch (err) {
    hilog.warn(DOMAIN, TAG, 'setWindowKeepScreenOn failed: %{public}s', JSON.stringify(err));
  }
}

/** 持久化并立即应用「屏幕常亮」。 */
export function saveAndApplyKeepScreenOn(ctx: common.UIAbilityContext, on: boolean): void {
  putBoolean(ctx, KEY_KEEP_SCREEN_ON, on);
  applyKeepScreenOn(on);
}