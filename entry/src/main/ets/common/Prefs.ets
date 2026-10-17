import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';

export const PREFS_NAME: string = 'source_reader_settings';

let store: preferences.Preferences | undefined = undefined;

export function getPref(ctx: common.UIAbilityContext): preferences.Preferences | undefined {
  if (store === undefined) {
    try {
      store = preferences.getPreferencesSync(ctx, { name: PREFS_NAME });
    } catch (err) {
      return undefined;
    }
  }
  return store;
}

export function getNumber(ctx: common.UIAbilityContext, key: string, def: number): number {
  const p: preferences.Preferences | undefined = getPref(ctx);
  if (p === undefined) {
    return def;
  }
  try {
    const value: preferences.ValueType = p.getSync(key, def);
    return typeof value === 'number' ? value : def;
  } catch (err) {
    return def;
  }
}

export function putNumber(ctx: common.UIAbilityContext, key: string, value: number): void {
  const p: preferences.Preferences | undefined = getPref(ctx);
  if (p === undefined) {
    return;
  }
  try {
    p.putSync(key, value);
    p.flush();
  } catch (err) {
    return;
  }
}

export function getBoolean(ctx: common.UIAbilityContext, key: string, def: boolean): boolean {
  const p: preferences.Preferences | undefined = getPref(ctx);
  if (p === undefined) {
    return def;
  }
  try {
    const value: preferences.ValueType = p.getSync(key, def);
    return typeof value === 'boolean' ? value : def;
  } catch (err) {
    return def;
  }
}

export function putBoolean(ctx: common.UIAbilityContext, key: string, value: boolean): void {
  const p: preferences.Preferences | undefined = getPref(ctx);
  if (p === undefined) {
    return;
  }
  try {
    p.putSync(key, value);
    p.flush();
  } catch (err) {
    return;
  }
}

/** Boolean write for paths that must not report success until the value is flushed. */
export function putBooleanStrict(ctx: common.UIAbilityContext, key: string, value: boolean): void {
  const p: preferences.Preferences | undefined = getPref(ctx);
  if (p === undefined) {
    throw new Error('preferences unavailable');
  }
  p.putSync(key, value);
  p.flushSync();
}

export function getString(ctx: common.UIAbilityContext, key: string, def: string): string {
  const p: preferences.Preferences | undefined = getPref(ctx);
  if (p === undefined) {
    return def;
  }
  try {
    const value: preferences.ValueType = p.getSync(key, def);
    return typeof value === 'string' ? value : def;
  } catch (err) {
    return def;
  }
}

export function putString(ctx: common.UIAbilityContext, key: string, value: string): void {
  const p: preferences.Preferences | undefined = getPref(ctx);
  if (p === undefined) {
    return;
  }
  try {
    p.putSync(key, value);
    p.flush();
  } catch (err) {
    return;
  }
}
