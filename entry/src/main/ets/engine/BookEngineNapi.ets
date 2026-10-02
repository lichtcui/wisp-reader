import {
  bookInfo as nativeBookInfo,
  content as nativeContent,
  detect as nativeDetect,
  downloadCover as nativeDownloadCover,
  fetchText as nativeFetchText,
  gateSources as nativeGate,
  parse as nativeParse,
  parseWithDiagnostics as nativeParseWithDiagnostics,
  search as nativeSearch,
  toc as nativeToc
} from 'liblegado_core.so';
import { Book, BookInfo, BookSource, Chapter, DetectResult, GateResult, ParseOutput } from './types';
import { ContentResult, IBookEngine, SearchOptions, SearchResult } from './IBookEngine';

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

  async bookInfo(source: BookSource, bookUrl: string): Promise<Book> {
    const raw: string = await nativeBookInfo(JSON.stringify(source), bookUrl);
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

  async toc(source: BookSource, tocUrl: string): Promise<Chapter[]> {
    const raw: string = await nativeToc(JSON.stringify(source), tocUrl);
    return JSON.parse(raw) as Chapter[];
  }

  async content(source: BookSource, chapterUrl: string): Promise<ContentResult> {
    const key: string = source.bookSourceUrl + '|' + chapterUrl;
    const pending: Promise<ContentResult> | undefined = this.inFlight.get(key);
    if (pending !== undefined) {
      return pending;
    }
    const task: Promise<ContentResult> = nativeContent(JSON.stringify(source), chapterUrl)
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

  /** Verify the reading chain of each source. */
  async detect(sources: BookSource[], keyword: string): Promise<DetectResult[]> {
    const raw: string = await nativeDetect(JSON.stringify(sources), JSON.stringify({ keyword: keyword, concurrency: 4 }));
    return JSON.parse(raw) as DetectResult[];
  }

  /** Download a cover into the app sandbox cache dir; returns the file path. */
  async downloadCover(source: BookSource, coverUrl: string, destDir: string): Promise<string> {
    return nativeDownloadCover(JSON.stringify(source), coverUrl, destDir);
  }

  /** Fetch a URL as text (used for importing a source list from a link). */
  async fetchText(url: string): Promise<string> {
    return nativeFetchText(url);
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