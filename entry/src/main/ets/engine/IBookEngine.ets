import { Book, BookSource, BookSearchItem, Chapter, SourceStatus } from './types';

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

  bookInfo(source: BookSource, bookUrl: string): Promise<Book>;

  toc(source: BookSource, tocUrl: string): Promise<Chapter[]>;

  content(source: BookSource, chapterUrl: string): Promise<ContentResult>;
}