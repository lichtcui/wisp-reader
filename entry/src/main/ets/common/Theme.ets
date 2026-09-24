import { ConfigurationConstant, common } from '@kit.AbilityKit';
import { getNumber, putNumber } from './Prefs';

export const KEY_THEME_MODE: string = 'theme_mode';

export enum ThemeMode {
  System = 0,
  Light = 1,
  Dark = 2
}

function toColorMode(mode: ThemeMode): ConfigurationConstant.ColorMode {
  if (mode === ThemeMode.Light) {
    return ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT;
  }
  if (mode === ThemeMode.Dark) {
    return ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
  }
  return ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
}

export function readThemeMode(ctx: common.UIAbilityContext): ThemeMode {
  const value: number = getNumber(ctx, KEY_THEME_MODE, ThemeMode.System);
  if (value === ThemeMode.Light || value === ThemeMode.Dark) {
    return value as ThemeMode;
  }
  return ThemeMode.System;
}

export function applyThemeMode(ctx: common.UIAbilityContext, mode: ThemeMode): void {
  try {
    ctx.getApplicationContext().setColorMode(toColorMode(mode));
  } catch (err) {
    return;
  }
}

export function saveAndApplyThemeMode(ctx: common.UIAbilityContext, mode: ThemeMode): void {
  putNumber(ctx, KEY_THEME_MODE, mode);
  applyThemeMode(ctx, mode);
}