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

export function formatWordCount(value: string): string {
  const n: number = Number(value);
  if (!isFinite(n) || n <= 0) {
    return '';
  }
  if (n >= 10000) {
    return (Math.round(n / 1000) / 10).toString() + '万字';
  }
  return n.toString() + '字';
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