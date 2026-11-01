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
export const ROUTE_CACHE_MANAGE: string = 'CacheManage';
export const ROUTE_RULE_DEBUGGER: string = 'RuleDebugger';
export const ROUTE_BACKUP_MANAGE: string = 'BackupManage';

/**
 * Temporary product switch: hide every user-reachable listening entry.
 * TTS pages, routes and engine code stay in place so the feature can be restored later.
 */
export const LISTENING_FEATURE_ENABLED: boolean = false;

// T1.6 debug-only storage benchmark. Dataset/backup files live in the app sandbox and
// are intentionally never committed to the repository.
export const T16_BENCH_ROW_COUNT: number = 3000;
export const T16_BENCH_DATA_FILE: string = 't1.6-sources.json';
export const T16_BENCH_BACKUP_FILE: string = 't1.6-sources-backup.json';
export const T16_BENCH_MARKER_FILE: string = 't1.6-benchmark.marker';
export const T16_READY_LIMIT_MS: number = 300;
export const T16_SINGLE_WRITE_LIMIT_MS: number = 16;
export const T16_UPSERT_LIMIT_MS: number = 2000;

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
/**
 * 远端引擎的语速上限。VPS（4C）单字合成成本实测 0.13–0.16 s，而有效语速 = 本值 × 服务端
 * `SPEED_SCALE`（0.75），有效语速 >1.0 时合成追不上播放 → 段间空档。1.2 × 0.75 = 0.9，留了余量。
 * 见 `docs/remote-tts-deploy.md` §0。
 */
export const TTS_REMOTE_SPEED_MAX: number = 1.2;

/** 按引擎夹取有效语速（远端见 `TTS_REMOTE_SPEED_MAX`；系统 TTS 原样返回）。 */
export function effectiveSpeed(speed: number, engineKind: number): number {
  return engineKind === TTS_ENGINE_REMOTE && speed > TTS_REMOTE_SPEED_MAX ? TTS_REMOTE_SPEED_MAX : speed;
}
export const TTS_VOICE_OPTIONS: number[] = [13, 21];
export const TTS_TIMER_OPTIONS: number[] = [0, 15, 30, 60];

/**
 * 朗读引擎：系统 TTS（默认，断网/失败兜底）或远端 VPS 合成。
 * 取值 1 曾用于端侧 ZipVoice（已封存），此处保留空洞以免与既有 pref 冲突。
 */
export const KEY_TTS_ENGINE: string = 'tts_engine';
export const TTS_ENGINE_SYSTEM: number = 0;
export const TTS_ENGINE_REMOTE: number = 2;

/** 远端 TTS（VPS + sherpa-onnx ZipVoice）：服务地址 / API Key / 音色。 */
export const KEY_TTS_SERVER: string = 'tts_server';
export const TTS_SERVER_DEFAULT: string = '';
export const KEY_TTS_API_KEY: string = 'tts_api_key';
export const TTS_API_KEY_DEFAULT: string = '';
export const KEY_TTS_REMOTE_VOICE: string = 'tts_remote_voice';
export const TTS_REMOTE_VOICE_DEFAULT: string = '钟离';
/** 服务端 `voices`（`GET /health`）的同一张表；改这里要同步 VPS 的 `VITS_VOICES`。 */
export const TTS_REMOTE_VOICE_OPTIONS: string[] = ['刻晴', '甘雨', '胡桃', '钟离', '雷电将军'];
/**
 * 旧远端音色名（VITS 之前的 ZipVoice 参考音频）→ 现用名。
 * 服务端有同一张别名表兜底（`server/app.py` 的 `VITS_VOICE_ALIASES`，只保证能出声）；
 * 这份是为了让 preferences 里存过的旧名在 UI 上仍能高亮，用户不必重选。
 */
const REMOTE_VOICE_RENAMES: string[][] = [
  ['流萤', '甘雨'],
  ['花火', '胡桃'],
  ['卡芙卡', '雷电将军']
];

/** 把偏好里的远端音色名收敛到 `TTS_REMOTE_VOICE_OPTIONS` 之一（旧名迁移 / 未知名回默认）。 */
export function normalizeRemoteVoice(voice: string): string {
  for (const pair of REMOTE_VOICE_RENAMES) {
    if (pair[0] === voice) {
      return pair[1];
    }
  }
  for (const name of TTS_REMOTE_VOICE_OPTIONS) {
    if (name === voice) {
      return voice;
    }
  }
  return TTS_REMOTE_VOICE_DEFAULT;
}
/** 远端每段合成的预取深度（比系统 TTS 的 AHEAD=2 略深，抵消网络往返）。 */
export const AHEAD_REMOTE: number = 3;

// ── TTS 预生成（T-TTS-7 阶段二；契约与播放路径见 research/TTS-PREGEN-IMPL.md §1/§3）──
// 两套声线：实时链路是 VITS 的 5 个标签音色，预生成是 GPT-SoVITS 的 3 个微调音色（跨章会换，章内不换）。

/** 预生成音色（服务端 worker 的 `--voice`）；默认建议实时音色选「甘雨」，跨章切换仍在女声同一区。 */
export const KEY_TTS_PREGEN_VOICE: string = 'tts_pregen_voice';
export const TTS_PREGEN_VOICE_DEFAULT: string = '流萤';
/** 服务端 worker 只加载一个音色（当前 `--voice 流萤`）；换音色要先重启 worker，否则条目被判失败。 */
export const TTS_PREGEN_VOICE_OPTIONS: string[] = ['流萤', '花火', '卡芙卡'];

/** 把偏好里的预生成音色收敛到 `TTS_PREGEN_VOICE_OPTIONS` 之一（未知名回默认）。 */
export function normalizePregenVoice(voice: string): string {
  for (const name of TTS_PREGEN_VOICE_OPTIONS) {
    if (name === voice) {
      return voice;
    }
  }
  return TTS_PREGEN_VOICE_DEFAULT;
}

/** 书级入口「预生成后续 N 章」的默认 N（真实上限在服务端磁盘，见 IMPL §2.6）。 */
export const KEY_TTS_PREGEN_AHEAD: string = 'tts_pregen_ahead';
export const TTS_PREGEN_AHEAD_DEFAULT: number = 10;
export const TTS_PREGEN_AHEAD_OPTIONS: number[] = [5, 10, 20, 30];

/** 仅 Wi-Fi 时提交预生成（音色与实时链路共用服务器地址/Key）。 */
export const KEY_TTS_PREGEN_WIFI_ONLY: string = 'tts_pregen_wifi_only';
export const TTS_PREGEN_WIFI_ONLY_DEFAULT: boolean = true;

/** 缓存优先播放：关掉则总是走实时 VITS（排查用）。 */
export const KEY_TTS_PREGEN_PREFER: string = 'tts_pregen_prefer';
export const TTS_PREGEN_PREFER_DEFAULT: boolean = true;

/** 服务端 worker 的引擎名（`tts-job.service --engine`）；不匹配的条目在服务端被判失败。 */
export const TTS_PREGEN_ENGINE: string = 'gsv_v2proplus';

/**
 * 缓存路径的听感标定（**不是**语速换算）：GPT-SoVITS `speed=1.0` 实测 4.86 字/秒，
 * 约等于现在「0.75 档」的听感（VITS 5.2 字/秒 × 0.75）。
 * **不要**把服务端给 VITS 标定的 `SPEED_SCALE=0.75` 套到缓存路径上（那会慢一档）。
 */
export const TTS_PREGEN_SPEED_SCALE: number = 1.0;

// ── 缓存上限策略（T-DATA-4 / plan §7）────────────────────────────────
// 口径：已读=软保护（未读先删，仍超配额才按「最久未访问」删已读），另加未读 TTL。

/** 章节正文缓存预算；超出后整理到 TARGET_RATIO。 */
export const CACHE_CHAPTER_QUOTA: number = 200 * 1024 * 1024;
/** 目录缓存兜底预算（真机实测约 74KB/本，通常不会触发）。 */
export const CACHE_TOC_QUOTA: number = 16 * 1024 * 1024;
/**
 * 封面缓存预算。文件名是 Rust 侧对 coverUrl 的哈希（`runtime.rs::download_cover`），
 * ArkTS 无法把书名映射到文件，因此只能按 mtime 最旧先删（代价：可能重下在架封面）。
 */
export const CACHE_COVER_QUOTA: number = 64 * 1024 * 1024;
/** 整理目标水位：删到配额的该比例即停（滞回，避免每次写入都触发整理）。 */
export const CACHE_TARGET_RATIO: number = 0.8;
/** 未读章节的保留天数，超期即清（与配额无关）。 */
export const CACHE_MAX_AGE_DAYS: number = 30;
/** 章节文件平均大小估计，仅用于把配额折算成廉价的「文件数闸门」（免去每次写盘都全扫）。 */
export const CACHE_AVG_CHAPTER_BYTES: number = 16 * 1024;
/** 刚写入/刚访问的文件在此窗口内永不删除（正在读的那几章不会被抽掉）。 */
export const CACHE_FRESH_WINDOW_MS: number = 5 * 60 * 1000;
/** 会话内两次整理的最小间隔（启动后的首次整理用 force，不受此限）。 */
export const CACHE_TRIM_MIN_INTERVAL_MS: number = 30 * 60 * 1000;

/**
 * 目录缓存的「新鲜期」：打开书时若缓存目录的抓取时间（`TocCache.fetchedAt`）早于此值，
 * 就在**后台**重爬一次目录。
 *
 * 为什么必须有：缓存命中时 `Reader.loadToc` 只认 `tocUrl`、没有别的过期条件，于是连载书
 * 首次打开之后**新章再也不会出现**（书架也因此永远显示「已读到最新章」，见
 * [`docs/bugfix/TASKS.md`] T-SHELF-6）。6 小时是「一天内读过就能看到新章」与
 * 「每本书最多每 6 小时多爬一次目录」之间的折中；只影响网络开销，不影响首屏（异步）。
 */
export const TOC_REFRESH_AFTER_MS: number = 6 * 60 * 60 * 1000;

/** Keyword used by the book-source availability detector. */
export const DEFAULT_DETECT_KEYWORD: string = '重生';
/** Maximum in-flight requests for one detect batch. */
export const DETECT_CONCURRENCY: number = 16;
/** Number of sources dispatched by one detect-job batch. */
export const DETECT_BATCH_SIZE: number = 32;
/** Incremental detection skips enabled sources checked within this window. */
export const DETECT_INCREMENTAL_WINDOW_MS: number = 7 * 24 * 60 * 60 * 1000;

/**
 * Aggregate budgets for one engine operation. Rust clamps callers to
 * [3s, 120s]; these values are the product-level defaults shared by every UI
 * entry that fetches a source page.
 */
export const ENGINE_INFO_TIMEOUT_MS: number = 15_000;
export const ENGINE_FETCH_TIMEOUT_MS: number = 15_000;
export const ENGINE_COVER_TIMEOUT_MS: number = 15_000;
export const ENGINE_TOC_TIMEOUT_MS: number = 45_000;
export const ENGINE_CONTENT_TIMEOUT_MS: number = 45_000;

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
