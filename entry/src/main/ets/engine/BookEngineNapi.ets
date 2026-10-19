import {
  bookInfo as nativeBookInfo,
  content as nativeContent,
  detect as nativeDetect,
  downloadCover as nativeDownloadCover,
  fetchTextWithTimeout as nativeFetchTextWithTimeout,
  gateSources as nativeGate,
  parse as nativeParse,
  parseWithDiagnostics as nativeParseWithDiagnostics,
  search as nativeSearch,
  toc as nativeToc
} from 'liblegado_core.so';
import {
  Book,
  BookInfo,
  BookSource,
  Chapter,
  DetectMode,
  DetectResult,
  GateResult,
  ParseOutput
} from './types';
import { ContentResult, IBookEngine, SearchOptions, SearchResult } from './IBookEngine';
import {
  DETECT_CONCURRENCY,
  ENGINE_CONTENT_TIMEOUT_MS,
  ENGINE_COVER_TIMEOUT_MS,
  ENGINE_FETCH_TIMEOUT_MS,
  ENGINE_INFO_TIMEOUT_MS,
  ENGINE_TOC_TIMEOUT_MS
} from '../common/Const';

const MIN_OPERATION_TIMEOUT_MS: number = 3_000;
const MAX_OPERATION_TIMEOUT_MS: number = 120_000;

/** Match the Rust clamp so cache keys treat equivalent budgets as identical. */
function normalizeTimeout(timeoutMs: number): number {
  return Math.min(Math.max(Math.round(timeoutMs), MIN_OPERATION_TIMEOUT_MS), MAX_OPERATION_TIMEOUT_MS);
}

/**
 * `IBookEngine` implementation backed by the Rust engine (`liblegado_core.so`).
 * All structured data crosses the NAPI boundary as JSON strings.
 */
export class BookEngineNapi implements IBookEngine {
  private inFlight: Map<string, Promise<ContentResult>> = new Map();

  async search(sources: BookSource[], keyword: string, opts: SearchOptions): Promise<SearchResult> {
    const sourcesJson: string = JSON.stringify(sources);
    const optsJson: string = JSON.stringify({
      timeoutMs: opts.timeoutMs,
      concurrency: opts.concurrency
    });
    const raw: string = await nativeSearch(sourcesJson, keyword, optsJson);
    return JSON.parse(raw) as SearchResult;
  }

  async bookInfo(source: BookSource, bookUrl: string, timeoutMs: number = ENGINE_INFO_TIMEOUT_MS): Promise<Book> {
    const raw: string = await nativeBookInfo(
      JSON.stringify(source),
      bookUrl,
      normalizeTimeout(timeoutMs)
    );
    const info: BookInfo = JSON.parse(raw) as BookInfo;
    const book: Book = {
      bookId: info.sourceUrl + '|' + info.bookUrl,
      sourceUrl: info.sourceUrl,
      name: info.name,
      author: info.author,
      coverUrl: info.coverUrl,
      intro: info.intro,
      kind: info.kind,
      wordCount: info.wordCount,
      status: info.status,
      lastChapterTitle: info.lastChapterTitle,
      tocUrl: info.tocUrl,
      inShelf: false,
      addedAt: 0
    };
    return book;
  }

  async toc(source: BookSource, tocUrl: string, timeoutMs: number = ENGINE_TOC_TIMEOUT_MS): Promise<Chapter[]> {
    const raw: string = await nativeToc(
      JSON.stringify(source),
      tocUrl,
      normalizeTimeout(timeoutMs)
    );
    return JSON.parse(raw) as Chapter[];
  }

  async content(
    source: BookSource,
    chapterUrl: string,
    timeoutMs: number = ENGINE_CONTENT_TIMEOUT_MS
  ): Promise<ContentResult> {
    const budget: number = normalizeTimeout(timeoutMs);
    const key: string = source.bookSourceUrl + '|' + chapterUrl + '|' + budget.toString();
    const pending: Promise<ContentResult> | undefined = this.inFlight.get(key);
    if (pending !== undefined) {
      return pending;
    }
    const task: Promise<ContentResult> = nativeContent(JSON.stringify(source), chapterUrl, budget)
      .then((raw: string): ContentResult => JSON.parse(raw) as ContentResult)
      .finally((): void => {
        this.inFlight.delete(key);
      });
    this.inFlight.set(key, task);
    return task;
  }

  /** v1 import gate: split eligible / excluded sources (sync). */
  gate(sources: BookSource[]): GateResult {
    const raw: string = nativeGate(JSON.stringify(sources));
    return JSON.parse(raw) as GateResult;
  }

  /** Detect source availability; omitted mode keeps the legacy full chain. */
  async detect(
    sources: BookSource[],
    keyword: string,
    mode: DetectMode = 'full'
  ): Promise<DetectResult[]> {
    const raw: string = await nativeDetect(
      JSON.stringify(sources),
      JSON.stringify({ keyword: keyword, concurrency: DETECT_CONCURRENCY, mode: mode })
    );
    return JSON.parse(raw) as DetectResult[];
  }

  /** Download a cover into the app sandbox cache dir; returns the file path. */
  async downloadCover(
    source: BookSource,
    coverUrl: string,
    destDir: string,
    timeoutMs: number = ENGINE_COVER_TIMEOUT_MS
  ): Promise<string> {
    return nativeDownloadCover(
      JSON.stringify(source),
      coverUrl,
      destDir,
      normalizeTimeout(timeoutMs)
    );
  }

  /** Fetch a URL as text (used for importing a source list from a link). */
  async fetchText(url: string, timeoutMs: number = ENGINE_FETCH_TIMEOUT_MS): Promise<string> {
    return nativeFetchTextWithTimeout(url, normalizeTimeout(timeoutMs));
  }

  parse(content: string, contentType: string, rule: string): string[] {
    return nativeParse(content, contentType, rule);
  }

  async parseWithDiagnostics(content: string, contentType: string, rule: string): Promise<ParseOutput> {
    const raw: string = nativeParseWithDiagnostics(content, contentType, rule);
    return JSON.parse(raw) as ParseOutput;
  }
}

/** Shared engine instance (lazy native load happens on first call). */
export const bookEngine: BookEngineNapi = new BookEngineNapi();
