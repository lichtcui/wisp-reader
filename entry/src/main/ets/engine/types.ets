export interface BookSource {
  bookSourceName: string;
  bookSourceUrl: string;
  bookSourceGroup?: string;
  bookSourceType: number;
  bookSourceComment?: string;
  enabled?: boolean;
  enabledExplore?: boolean;
  weight?: number;
  searchUrl?: string;
  exploreUrl?: string;
  header?: string;
  loginUrl?: string;
  loginUi?: string;
  loginCheckJs?: string;
  bookUrlPattern?: string;
  concurrentRate?: string | object;
  ruleSearch?: object;
  ruleBookInfo?: object;
  ruleToc?: object;
  ruleContent?: object;
}

export interface Book {
  bookId: string;
  sourceUrl: string;
  name: string;
  author: string;
  coverUrl: string;
  intro: string;
  kind: string;
  wordCount: string;
  status: string;
  lastChapterTitle: string;
  tocUrl: string;
  inShelf: boolean;
  addedAt: number;
}

export interface Chapter {
  bookId: string;
  index: number;
  title: string;
  url: string;
  isVip: boolean;
  isVolume?: boolean;
}

export interface ReadProgress {
  bookId: string;
  chapterIndex: number;
  chapterTitle: string;
  paragraphIndex: number;
  charOffset: number;
  percent: number;
  updatedAt: number;
}

export interface ChapterCache {
  bookId: string;
  index: number;
  content: string;
  fetchedAt: number;
}

export interface BookSearchItem {
  sourceUrl: string;
  sourceName: string;
  name: string;
  author: string;
  bookUrl: string;
  coverUrl: string;
  intro: string;
  kind: string;
  wordCount: string;
  lastChapter: string;
}

export interface SourceStatus {
  sourceUrl: string;
  sourceName: string;
  ok: boolean;
  count: number;
  error: string;
  elapsedMs: number;
}

/** Rust `BookInfo` (runtime book detail). */
export interface BookInfo {
  sourceUrl: string;
  bookUrl: string;
  name: string;
  author: string;
  coverUrl: string;
  intro: string;
  kind: string;
  wordCount: string;
  status: string;
  lastChapterTitle: string;
  tocUrl: string;
}

/** A source rejected by the v1 import gate. */
export interface ExcludedSource {
  bookSourceName: string;
  bookSourceUrl: string;
  reason: string;
  detail: string;
  recoverable: boolean;
}

/** Result of applying the v1 import gate. */
export interface GateResult {
  total: number;
  eligible: BookSource[];
  excluded: ExcludedSource[];
}

/** Reading-chain detection result. */
export interface DetectResult {
  sourceUrl: string;
  sourceName: string;
  ok: boolean;
  stage: string;
  detail: string;
  contentLen: number;
  elapsedMs: number;
}

/** Rule diagnostics for the debugger. */
export interface RuleDiagnostic {
  kind: string;
  rule: string;
  message: string;
}

export interface ParseOutput {
  values: string[];
  diagnostics: RuleDiagnostic[];
}