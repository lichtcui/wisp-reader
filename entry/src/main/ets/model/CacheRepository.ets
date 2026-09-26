import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';

/**
 * Read-only accounting for the on-disk caches written by the app, plus a
 * deletion helper used by the "清理缓存" page.
 *
 * Scope (aligned with the actual writers; this module never writes cache):
 * - 图片缓存：`cacheDir/cover_<hash>.img` written by Rust `download_cover`.
 * - 章节内容缓存：`filesDir/chapters/<bookId>_<index>.json` written by `ChapterCache`.
 * - TTS 音频缓存：`cacheDir/tts` — reserved for the on-device TTS PCM cache
 *   (TTS-PLAN); the current system-TTS pipeline is memory-only, so it is 0 B
 *   until a writer lands there.
 */
export interface CacheCategory {
  bytes: number;
  count: number;
}

export interface CacheStats {
  image: CacheCategory;
  chapter: CacheCategory;
  tts: CacheCategory;
  totalBytes: number;
  totalCount: number;
}

const CHAPTER_DIR_NAME: string = 'chapters';
const TTS_DIR_NAME: string = 'tts';
const COVER_PREFIX: string = 'cover_';
const COVER_SUFFIX: string = '.img';

function chapterDir(ctx: common.UIAbilityContext): string {
  return ctx.filesDir + '/' + CHAPTER_DIR_NAME;
}

function ttsDir(ctx: common.UIAbilityContext): string {
  return ctx.cacheDir + '/' + TTS_DIR_NAME;
}

/** Sum the sizes of the entries in `dir` accepted by `match`. Missing dir → 0. */
function sumDir(dir: string, match: (name: string) => boolean): CacheCategory {
  const result: CacheCategory = { bytes: 0, count: 0 };
  try {
    if (!fileIo.accessSync(dir)) {
      return result;
    }
  } catch (err) {
    return result;
  }
  let names: string[] = [];
  try {
    names = fileIo.listFileSync(dir);
  } catch (err) {
    return result;
  }
  for (const name of names) {
    if (!match(name)) {
      continue;
    }
    try {
      const stat: fileIo.Stat = fileIo.statSync(dir + '/' + name);
      if (stat.isFile()) {
        result.bytes += stat.size;
        result.count += 1;
      }
    } catch (err) {
      continue;
    }
  }
  return result;
}

function isCoverFile(name: string): boolean {
  return name.startsWith(COVER_PREFIX) && name.endsWith(COVER_SUFFIX);
}

function isChapterFile(name: string): boolean {
  return name.endsWith('.json');
}

/** Compute the current on-disk footprint of every managed cache. */
export function getCacheStats(ctx: common.UIAbilityContext): CacheStats {
  const image: CacheCategory = sumDir(ctx.cacheDir, isCoverFile);
  const chapter: CacheCategory = sumDir(chapterDir(ctx), isChapterFile);
  const tts: CacheCategory = sumDir(ttsDir(ctx), () => true);
  return {
    image: image,
    chapter: chapter,
    tts: tts,
    totalBytes: image.bytes + chapter.bytes + tts.bytes,
    totalCount: image.count + chapter.count + tts.count
  };
}

/** Delete every cover file in `dir`; leaves unrelated cache entries intact. */
function clearCoverFiles(dir: string): void {
  try {
    if (!fileIo.accessSync(dir)) {
      return;
    }
  } catch (err) {
    return;
  }
  let names: string[] = [];
  try {
    names = fileIo.listFileSync(dir);
  } catch (err) {
    return;
  }
  for (const name of names) {
    if (!isCoverFile(name)) {
      continue;
    }
    try {
      fileIo.unlinkSync(dir + '/' + name);
    } catch (err) {
      continue;
    }
  }
}

/** Remove a cache directory and everything under it; missing dir is a no-op. */
function removeDir(dir: string): void {
  try {
    if (fileIo.accessSync(dir)) {
      fileIo.rmdirSync(dir);
    }
  } catch (err) {
    return;
  }
}

/**
 * Delete all managed cache files. In-memory layers (`ChapterCache`, `BookCover`)
 * are intentionally left untouched: they are session-scoped and will not be
 * re-persisted, so the on-disk figure stays at 0 B after this call.
 */
export function clearCache(ctx: common.UIAbilityContext): void {
  clearCoverFiles(ctx.cacheDir);
  removeDir(chapterDir(ctx));
  removeDir(ttsDir(ctx));
}