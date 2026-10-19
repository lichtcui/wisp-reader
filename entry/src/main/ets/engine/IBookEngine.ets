import { Book, BookSource, BookSearchItem, Chapter, ParseOutput, SourceStatus } from './types';

export interface SearchOptions {
  timeoutMs: number;
  concurrency: number;
}

export interface SearchResult {
  items: BookSearchItem[];
  sources: SourceStatus[];
}

export interface ContentResult {
  content: string;
  nextUrl: string;
}

export interface IBookEngine {
  search(sources: BookSource[], keyword: string, opts: SearchOptions): Promise<SearchResult>;

  bookInfo(source: BookSource, bookUrl: string, timeoutMs?: number): Promise<Book>;

  toc(source: BookSource, tocUrl: string, timeoutMs?: number): Promise<Chapter[]>;

  content(source: BookSource, chapterUrl: string, timeoutMs?: number): Promise<ContentResult>;

  /** Download a cover into the app sandbox; returns the cached file path. */
  downloadCover(
    source: BookSource,
    coverUrl: string,
    destDir: string,
    timeoutMs?: number
  ): Promise<string>;

  /** Fetch a URL as text (used for importing a source list from a link). */
  fetchText(url: string, timeoutMs?: number): Promise<string>;

  /** Extract values from HTML/JSON applying a Legado DSL rule (sync). */
  parse(content: string, contentType: string, rule: string): string[];

  /** Like `parse`, but also returns rule diagnostics for the debugger. */
  parseWithDiagnostics(content: string, contentType: string, rule: string): Promise<ParseOutput>;
}
