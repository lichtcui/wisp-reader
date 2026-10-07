import { common } from '@kit.AbilityKit';
import { removeBooks } from './ShelfRepository';
import { deleteBookChapters } from './ChapterCache';
import { deleteBookToc } from './TocCache';
import { deleteLocalBookData } from './LocalBook';
import { TtsController } from './TtsController';

/**
 * Permanently delete shelf books and everything they own.
 *
 * Order matters: DB rows first (source of truth → the shelf reload cannot show
 * a deleted book even if the file cleanup fails), then the on-disk caches
 * (chapter bodies, TOC, local TXT) and their in-memory layers. Cache cleanup is
 * best-effort — a failure is swallowed, matching `CacheRepository`'s style, and
 * the leftover can always be swept by 清理缓存.
 *
 * Cover images are intentionally left behind: their filename is a Rust-side hash
 * of the cover URL (`runtime.rs::download_cover`), so ArkTS cannot locate the
 * file for a given book. They are handled by the 清理缓存 page.
 *
 * @returns the number of books removed from the shelf.
 */
export async function deleteBooks(ctx: common.UIAbilityContext, bookIds: string[]): Promise<number> {
  if (bookIds.length === 0) {
    return 0;
  }
  const tts: TtsController = TtsController.instance();
  for (const bookId of bookIds) {
    if (tts.isActiveFor(bookId)) {
      tts.stop();
    }
  }
  await removeBooks(bookIds);
  for (const bookId of bookIds) {
    deleteBookChapters(ctx, bookId);
    deleteBookToc(ctx, bookId);
    deleteLocalBookData(ctx, bookId);
  }
  return bookIds.length;
}
