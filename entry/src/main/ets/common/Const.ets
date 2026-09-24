import { Book, BookSearchItem, BookSource } from '../engine/types';

export const APP_NAME: string = '源阅读';
export const GITHUB_URL: string = 'https://github.com/lichtcui';

export const TAB_SHELF: number = 0;
export const TAB_SEARCH: number = 1;
export const TAB_SETTINGS: number = 2;

export const ROUTE_PLACEHOLDER: string = 'Placeholder';
export const ROUTE_SOURCE_MANAGE: string = 'BookSourceManage';
export const ROUTE_SEARCH_RESULT: string = 'SearchResult';
export const ROUTE_BOOK_DETAIL: string = 'BookDetail';
export const ROUTE_READER: string = 'Reader';

export const KEY_READER_FONT_SIZE: string = 'reader_font_size';
export const KEY_READER_LINE_HEIGHT: string = 'reader_line_height';
export const READER_FONT_SIZE_DEFAULT: number = 18;
export const READER_LINE_HEIGHT_DEFAULT: number = 1.8;

/** Keyword used by the book-source availability detector. */
export const DEFAULT_DETECT_KEYWORD: string = '重生';

export const CONTENT_MAX_WIDTH: number = 600;
export const PAGE_H_PADDING: number = 16;

export const VIEW_MODE_OPTIONS: string[] = ['宫格', '列表'];
export const SORT_OPTIONS: string[] = ['最近阅读', '添加时间', '书名'];
export const THEME_OPTIONS: string[] = ['跟随系统', '浅色', '深色'];

export class PlaceholderParam {
  title: string;

  constructor(title: string) {
    this.title = title;
  }
}

export class SearchParam {
  keyword: string;

  constructor(keyword: string) {
    this.keyword = keyword;
  }
}

export class DetailParam {
  source: BookSource;
  item?: BookSearchItem;
  book?: Book;

  constructor(source: BookSource, item?: BookSearchItem, book?: Book) {
    this.source = source;
    this.item = item;
    this.book = book;
  }
}