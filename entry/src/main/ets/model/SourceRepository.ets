import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { getString, putString } from '../common/Prefs';
import { BookSource } from '../engine/types';

export const KEY_SOURCES: string = 'book_sources_v1';
const BUNDLED_RAWFILE: string = 'bundled-sources.json';

/** Read the bundled v1-compatible sources shipped in resources/rawfile. */
export function loadBundled(ctx: common.UIAbilityContext): BookSource[] {
  try {
    const bytes: Uint8Array = ctx.resourceManager.getRawFileContentSync(BUNDLED_RAWFILE);
    const text: string = util.TextDecoder.create('utf-8').decodeToString(bytes);
    const list: BookSource[] = JSON.parse(text) as BookSource[];
    return list === undefined ? [] : list;
  } catch (err) {
    return [];
  }
}

/** Load user sources, seeding from the bundled set on first run. */
export function loadSources(ctx: common.UIAbilityContext): BookSource[] {
  const stored: string = getString(ctx, KEY_SOURCES, '');
  if (stored.length > 0) {
    try {
      const list: BookSource[] = JSON.parse(stored) as BookSource[];
      if (list !== undefined) {
        return list;
      }
    } catch (err) {
      // fall through to bundled
    }
  }
  const bundled: BookSource[] = loadBundled(ctx);
  saveSources(ctx, bundled);
  return bundled;
}

export function saveSources(ctx: common.UIAbilityContext, sources: BookSource[]): void {
  putString(ctx, KEY_SOURCES, JSON.stringify(sources));
}

export function resetToBundled(ctx: common.UIAbilityContext): BookSource[] {
  const bundled: BookSource[] = loadBundled(ctx);
  saveSources(ctx, bundled);
  return bundled;
}

export function enabledSources(sources: BookSource[]): BookSource[] {
  return sources.filter((s: BookSource) => s.enabled !== false);
}

/**
 * 同一 `bookSourceUrl` 只保留一条。
 *
 * 书源集合里常见「同一站点的重复导入」（内置集就有 bbiquge8 / 笔趣阁8 同指 m.bbiquge8.net）：
 * 不去重会重复请求同一站点、搜索结果重复，且 `Map<url, source>` 取值会被后写入的那条覆盖
 * （表现为分组/置信度张冠李戴）。
 *
 * 入参需已按优先级排序（如置信度从高到低），本函数保留其中**首个**。
 */
export function dedupeByUrl(sources: BookSource[]): BookSource[] {
  const seen: Set<string> = new Set<string>();
  const out: BookSource[] = [];
  for (const s of sources) {
    if (seen.has(s.bookSourceUrl)) {
      continue;
    }
    seen.add(s.bookSourceUrl);
    out.push(s);
  }
  return out;
}