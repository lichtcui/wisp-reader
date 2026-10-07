/**
 * Single-writer arbitration for a book's reading position (T-CROSS-3 / R3).
 *
 * Problem: two modules wrote the same `progress` row unconditionally, and their
 * positions mean different things — the Reader writes the **first paragraph of the
 * visible page** (`Reader.persistProgress`), the TTS writes the **paragraph the
 * audio clock is at** (`TtsController.tickProgress`, every second). The last write
 * won, so while listening, the Reader's page-turn/follow path could stamp a stale
 * position over the live one (`lastWriteAt` cannot stop it: the stale write is
 * newer in wall-clock time).
 *
 * Rule: while the audio is **playing** a book, only the audio clock may write that
 * book's progress; otherwise nobody holds it and the Reader may write.
 *
 * Tied to `playing`, not to `TtsController.active`: `active` also covers
 * 「暂停 / 播完」, and in both of those states the TTS no longer writes — holding
 * the claim there would silently drop every progress write from a reader session
 * that continues after pausing the audio.
 *
 * Pure state, no imports: both `ShelfRepository` (guard) and `TtsController`
 * (claim/release) can depend on it without a cycle.
 */

export enum ProgressWriter {
  /** Nobody writing; only used as a "no owner" marker, never as an argument. */
  NONE = 0,
  READER = 1,
  TTS = 2,
  /** 备份导入「全量覆盖」：绕过仲裁（导入的是用户数据本身，不是会话位置）。 */
  RESTORE = 3
}

/** bookId → current writer, only for books held by the TTS. */
const owners: Map<string, ProgressWriter> = new Map<string, ProgressWriter>();

/** Take the claim for `bookId` (overrides whatever held it: the newest claim is the live one). */
export function claimProgress(bookId: string, writer: ProgressWriter): void {
  owners.set(bookId, writer);
}

/** Give the claim back, but only if this writer still holds it (no cross-module release). */
export function releaseProgress(bookId: string, writer: ProgressWriter): void {
  if (owners.get(bookId) === writer) {
    owners.delete(bookId);
  }
}

/** True when `writer` is allowed to write `bookId` (claim free, owned by it, or a restore). */
export function canWriteProgress(bookId: string, writer: ProgressWriter): boolean {
  if (writer === ProgressWriter.RESTORE) {
    return true;
  }
  const owner: ProgressWriter | undefined = owners.get(bookId);
  return owner === undefined || owner === writer;
}

/**
 * Drop the claim of a deleted book. Required for the same reason as
 * `lastWriteAt.delete()` in `removeBooks`: a leftover claim would silently swallow
 * every progress write of that book after it is re-added to the shelf.
 */
export function forgetProgressOwner(bookId: string): void {
  owners.delete(bookId);
}
