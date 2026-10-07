/**
 * Upper bound for the `percent` reverse-derivation below. Real books stay far
 * under it; the constant only exists to reject degenerate `percent` values whose
 * derived total would otherwise be printed verbatim (「1章/1000000000章」).
 */
const MAX_DERIVED_CHAPTERS: number = 100000;

/**
 * Reverse-derive a book's chapter count from its stored progress.
 *
 * Both writers store `percent = (chapterIndex + 1) / chapters.length`
 * (`Reader.persistProgress` / `TtsController.persistProgress`), and the shelf must
 * show 「已读到最新章」 / `{i+1}章/{total}章` without loading a TOC — so the total has
 * to come back out of that ratio. Inside the range the app itself writes
 * (`percent ∈ (0, 1]`, chapter counts of at most a few 万) the round-trip is exact.
 * The guards reject only what the app never writes: a hand-edited / foreign backup
 * row (`percent` ≤ 0, `NaN`, `Infinity`, `> 1`) or a degenerate tiny value whose
 * derived total would be absurd.
 *
 * Returns 0 for 「总数不可信」; `shelfProgressText(…, 0, true)` then degrades to the
 * chapter-only label 「第N章」 — the honest answer when the total is unknown.
 */
export function deriveTotalChapters(chapterIndex: number, percent: number): number {
  const read: number = chapterIndex + 1;
  if (read <= 0) {
    return 0;
  }
  // percent = (chapterIndex + 1) / 总章数 ≤ 1 恒成立；越界即是脏数据。
  if (!Number.isFinite(percent) || percent <= 0 || percent > 1) {
    return 0;
  }
  if (percent < 1 / MAX_DERIVED_CHAPTERS) {
    return 0;
  }
  const total: number = Math.round(read / percent);
  // 反推结果小于「已读章数」说明 percent 与 chapter_index 不同源，宁可不显示总数，
  // 也不能让 shelfProgressText 误判成「已读到最新章」。
  return total >= read ? total : 0;
}

export function shelfProgressText(chapterIndex: number, totalChapters: number, hasProgress: boolean): string {
  if (!hasProgress || chapterIndex < 0) {
    return '未读过';
  }
  if (totalChapters > 0 && chapterIndex >= totalChapters - 1) {
    return '已读到最新章';
  }
  if (totalChapters > 0) {
    return (chapterIndex + 1).toString() + '章/' + totalChapters.toString() + '章';
  }
  return '第' + (chapterIndex + 1).toString() + '章';
}

function normalizeUrl(url: string): string {
  return url.trim().replace(/\/+$/, '').toLowerCase();
}

/** FNV-1a 32-bit hash, hex string. */
function fnv1a(input: string): string {
  let hash: number = 0x811c9dc5;
  for (let i = 0; i < input.length; i++) {
    hash = hash ^ input.charCodeAt(i);
    hash = Math.imul(hash, 0x01000193);
  }
  return (hash >>> 0).toString(16);
}

/**
 * Stable book identity: `hash(normalize(sourceUrl + bookUrl))`.
 * Normalizing to absolute URLs first keeps the id stable across source base
 * changes; same source+book always maps to the same id.
 */
export function computeBookId(sourceUrl: string, bookUrl: string): string {
  return fnv1a(normalizeUrl(sourceUrl) + '|' + normalizeUrl(bookUrl));
}

export function formatBytes(n: number): string {
  if (n <= 0) {
    return '0 B';
  }
  const units: string[] = ['B', 'KB', 'MB', 'GB'];
  let value: number = n;
  let i: number = 0;
  while (value >= 1024 && i < units.length - 1) {
    value = value / 1024;
    i += 1;
  }
  const rounded: number = i === 0 ? value : Math.round(value * 10) / 10;
  return rounded.toString() + ' ' + units[i];
}