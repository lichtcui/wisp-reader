import { Book, BookSearchItem, BookSource, Chapter } from '../engine/types';

export const APP_NAME: string = '源阅读';
export const GITHUB_URL: string = 'https://github.com/lichtcui';

export const TAB_SHELF: number = 0;
export const TAB_SEARCH: number = 1;
export const TAB_SETTINGS: number = 2;

export const ROUTE_PLACEHOLDER: string = 'Placeholder';
export const ROUTE_SOURCE_MANAGE: string = 'BookSourceManage';
export const ROUTE_BOOK_DETAIL: string = 'BookDetail';
export const ROUTE_READER: string = 'Reader';
export const ROUTE_READING_SETTINGS: string = 'ReadingSettings';
export const ROUTE_GENERAL_SETTINGS: string = 'GeneralSettings';
export const ROUTE_LISTENING: string = 'Listening';
export const ROUTE_LISTENING_SETTINGS: string = 'ListeningSettings';

export const KEY_READER_FONT_SIZE: string = 'reader_font_size';
export const KEY_READER_LINE_HEIGHT: string = 'reader_line_height';
export const KEY_READER_NIGHT: string = 'reader_night';
export const KEY_READER_ONE_HAND_PAGE: string = 'reader_one_hand_page';
export const KEY_KEEP_SCREEN_ON: string = 'keep_screen_on';
export const READER_FONT_SIZE_DEFAULT: number = 18;
export const READER_LINE_HEIGHT_DEFAULT: number = 1.8;
export const READER_NIGHT_DEFAULT: boolean = true;
export const READER_ONE_HAND_PAGE_DEFAULT: boolean = false;

/** 听书（M5）：语速 / 音色（textToSpeech person）/ 定时关闭。 */
export const KEY_TTS_SPEED: string = 'tts_speed';
export const KEY_TTS_VOICE: string = 'tts_voice';
export const TTS_SPEED_DEFAULT: number = 1.0;
export const TTS_VOICE_DEFAULT: number = 13;
export const TTS_SPEED_OPTIONS: number[] = [0.5, 0.8, 1.0, 1.2, 1.5, 2.0];
export const TTS_VOICE_OPTIONS: number[] = [13, 21];
export const TTS_TIMER_OPTIONS: number[] = [0, 15, 30, 60];

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

/** In-memory payload handed to the listening page to start a TTS session. */
export class ListenParam {
  source?: BookSource;
  book?: Book;
  chapters: Chapter[];
  chapterIndex: number;
  paragraphs: string[];
  paragraphIndex: number;

  constructor(
    chapters: Chapter[],
    chapterIndex: number,
    paragraphs: string[],
    paragraphIndex: number,
    source?: BookSource,
    book?: Book
  ) {
    this.chapters = chapters;
    this.chapterIndex = chapterIndex;
    this.paragraphs = paragraphs;
    this.paragraphIndex = paragraphIndex;
    this.source = source;
    this.book = book;
  }
}