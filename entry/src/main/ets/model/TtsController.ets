// ─── 文件索引（改本文件先看这里；本文件约 1280 行）──────────────────────────
// 下面只列**成员名**，不列行号（行号会漂）；定位用 `grep -n "<名字>" entry/src/main/ets/model/TtsController.ets`。
//   @ObservedV2 单例（供 Reader / Listening / Shelf FAB 共用）：
//   单例与查询： instance（static）/ isActiveFor / currentSource / currentBook / currentChapters / loadPrefs
//   进度归属：   setPlaying（playing 的唯一写入口，绑定 ProgressOwner 仲裁，见 model/ProgressOwner.ets）
//   对外控制：   start / stop / pause / resume / toggle / next / prev / seekParagraph / jumpChapter /
//                setSpeed / setVoice / setRemoteVoice / setTimer / setVoice 相关的参数持久化走 common/Prefs
//   引擎：       ensureEngine / ensureRenderer / startRenderer / releaseRenderer / remoteSynth / fallbackToSystem
//   后台与锁屏： ensureSession / startBackground / stopBackground / updateMetadata / updatePlaybackState /
//                updatePlaybackStateFromPlaying / listener（onStart/onComplete/onStop/onData/onError）
//   合成与队列： setChapter / loadChapter / beginFrom / ensureSynthesized / ensureRemoteSynthesized / queueExhausted /
//                onData / onComplete / onStop / onError / enqueueParagraph / insertLateData / fill /
//                resetQueues / clearInflight（PCM 预合成 AHEAD 段 + 乱序到达重排在这里）
//   刷新与进度： startFlushTimer / stopFlushTimer / tickProgress / tryFlush / startProgressTimer / stopProgressTimer /
//                scheduleParagraphEnd / onParagraphEnd / playedMs / paragraphAt / estimateDurationMs / persistProgress
//   预生成缓存： pregMode / beginFrom（路由选择）/ startPregChapter / playPregFrom / startPregRenderer / fillFromPreg /
//                onPregEnded / completePregChapter / abandonCachePath / releasePregAudio / prefetchNextPreg
//   调试：       traceFormat（hilog 格式化）
// ──────────────────────────────────────────────────────────────────────

import { common, wantAgent, WantAgent } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { audio } from '@kit.AudioKit';
import { textToSpeech } from '@kit.CoreSpeechKit';
import { avSession } from '@kit.AVSessionKit';
import { notificationManager } from '@kit.NotificationKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { Book, BookSource, Chapter } from '../engine/types';
import { isReadable, nextReadable, prevReadable } from '../common/ChapterUtil';
import { loadChapterParagraphs } from './BookContent';
import { clearChapterPregKey, getChapterPregKey } from './ChapterCache';
import { protectBook } from './CacheTrim';
import { saveProgress } from './ShelfRepository';
import { claimProgress, releaseProgress, ProgressWriter } from './ProgressOwner';
import { getNumber, putNumber, getString, putString, getBoolean, putBoolean } from '../common/Prefs';
import {
  KEY_TTS_SPEED,
  KEY_TTS_VOICE,
  KEY_TTS_ENGINE,
  KEY_TTS_SERVER,
  KEY_TTS_API_KEY,
  KEY_TTS_REMOTE_VOICE,
  KEY_TTS_PREGEN_PREFER,
  KEY_TTS_PREGEN_WIFI_ONLY,
  TTS_SPEED_DEFAULT,
  TTS_VOICE_DEFAULT,
  TTS_ENGINE_SYSTEM,
  TTS_ENGINE_REMOTE,
  TTS_SERVER_DEFAULT,
  TTS_API_KEY_DEFAULT,
  TTS_REMOTE_VOICE_DEFAULT,
  TTS_PREGEN_PREFER_DEFAULT,
  TTS_PREGEN_WIFI_ONLY_DEFAULT,
  normalizeRemoteVoice,
  effectiveSpeed,
  AHEAD_REMOTE
} from '../common/Const';
import { remoteSynthesize } from './RemoteTtsClient';
import { PregAudioSource } from './PregAudioSource';
import {
  AUDIO_CACHE, PregAudio, PregenError, PregenTiming,
  chapterAudioRoute, deletePregCache, deletePregFile, isPregKeyPending, loadPregAudio, onWifi, pregPlaybackRate, pregTimeline,
  pregenErrorMessage, sweepPregFiles
} from './TtsPregen';

const ENGINE_NAME: string = 'wisp-reader-tts';
const SESSION_TAG: string = 'wisp-reader-listen';
const DOMAIN: number = 0x0000;
const TAG: string = 'WispReaderTts';
/** Rough offline-TTS reading rate used for the progress/time estimate. */
const CHARS_PER_SECOND: number = 5.0;
/** Paragraphs synthesized ahead of the playback head. */
const AHEAD: number = 2;
/** TTS `onComplete` may fire before the last `onData`; wait a moment before flushing. */
const FLUSH_GRACE_MS: number = 80;
const FLUSH_TICK_MS: number = 40;
/** S16LE mono PCM → 2 bytes per frame. */
const BYTES_PER_FRAME: number = 2;
/** System TTS renders 16 kHz; the remote VPS WAV comes back at 24 kHz. */
const SAMPLE_RATE_SYSTEM: number = 16000;
const SAMPLE_RATE_REMOTE: number = 24000;
/** UI progress refresh cadence, and how often the AVSession/DB state is pushed. */
const PROGRESS_TICK_MS: number = 200;
const STATE_PUSH_MS: number = 1000;
/** AVSession 调用超过这个耗时就在日志里点名（历史症状：服务端 `syncExecutor timeout`）。 */
const AV_SLOW_MS: number = 300;

/** One piece of audio handed to the renderer; `end` marks a paragraph boundary. */
class RenderItem {
  index: number;
  data: ArrayBuffer;
  end: boolean;

  constructor(index: number, data: ArrayBuffer, end: boolean) {
    this.index = index;
    this.data = data;
    this.end = end;
  }
}

/** PCM chunks collected for one in-flight `speak()` request. */
class ReqBuffer {
  index: number;
  chunks: Map<number, ArrayBuffer> = new Map();
  bytes: number = 0;
  doneAt: number = 0;

  constructor(index: number) {
    this.index = index;
  }
}

/**
 * One paragraph's slot on the playback timeline. Durations come from the
 * synthesized PCM length (`bytes / 32000`), so the audio clock maps back to a
 * real paragraph instead of a character-count guess.
 */
class ParagraphTiming {
  index: number;
  startMs: number;
  endMs: number;

  constructor(index: number, startMs: number, endMs: number) {
    this.index = index;
    this.startMs = startMs;
    this.endMs = endMs;
  }
}

/**
 * M5 listening controller.
 *
 * The system TTS engine synthesizes PCM (`playType: 0`) paragraph by paragraph;
 * the app plays that PCM through its own `AudioRenderer` so the app — not the TTS
 * service — owns audio focus. That makes our `AVSession` the system top session,
 * which is what shows lock-screen media controls. Paragraph boundaries double as
 * highlight/progress checkpoints.
 */
@ObservedV2
export class TtsController {
  private static shared: TtsController | undefined = undefined;

  static instance(): TtsController {
    if (TtsController.shared === undefined) {
      TtsController.shared = new TtsController();
    }
    return TtsController.shared;
  }

  @Trace active: boolean = false;
  @Trace playing: boolean = false;
  @Trace loading: boolean = false;
  @Trace error: string = '';
  @Trace chapterIndex: number = 0;
  @Trace paragraphIndex: number = 0;
  @Trace paragraphCount: number = 0;
  @Trace chapterTitle: string = '';
  @Trace bookName: string = '';
  @Trace author: string = '';
  @Trace speed: number = TTS_SPEED_DEFAULT;
  @Trace voice: number = TTS_VOICE_DEFAULT;
  @Trace timerRemain: number = 0;
  /** Elapsed playback time of the current chapter, from the audio clock. */
  @Trace elapsedMs: number = 0;

  private engine: textToSpeech.TextToSpeechEngine | undefined = undefined;
  private session: avSession.AVSession | undefined = undefined;
  private renderer: audio.AudioRenderer | undefined = undefined;
  /**
   * 当前渲染器建立时的采样率。缓存章是 24 kHz（GSV），实时（系统 TTS）是 16 kHz，
   * 两者不能混：进章时按 `chapterAudioRoute` 的结果重建（见 `ensureRenderRate`）。
   */
  private renderRate: number = SAMPLE_RATE_SYSTEM;
  private ctx: common.UIAbilityContext | undefined = undefined;
  private source: BookSource | undefined = undefined;
  private book: Book | undefined = undefined;
  private chapters: Chapter[] = [];
  private paragraphs: string[] = [];
  private prefixChars: number[] = [];
  private totalChars: number = 0;

  private currentIndex: number = 0;
  private issuedIndex: number = 0;
  private flushIndex: number = 0;
  private seq: number = 0;
  private reqIdIndex: Map<string, number> = new Map();
  private reqByIndex: Map<number, ReqBuffer> = new Map();
  private queue: RenderItem[] = [];
  private queueOffset: number = 0;
  private flushTimerId: number = -1;
  private timeline: ParagraphTiming[] = [];
  private progressTimerId: number = -1;
  private lastStatePushAt: number = 0;
  private playStartWallMs: number = 0;

  // ── 预生成缓存播放（T-TTS-7 阶段二；设计与契约见 research/TTS-PREGEN-IMPL.md）──
  /** 本章正在放预生成音频（UI 用它显示「预生成缓存」）。 */
  @Trace pregMode: boolean = false;
  /** 缓存路径正在下载 / 等首字节。 */
  @Trace pregBuffering: boolean = false;
  /** 已下载字节（「缓冲中 · 已下载 12 MB」）。 */
  @Trace pregBytes: number = 0;
  private pregPlayKey: string = '';
  private pregSource: PregAudioSource | undefined = undefined;
  /** seek 基准：源时间 ms + 那一刻的渲染帧位置 / 墙上时间。 */
  private pregSeekBaseMs: number = 0;
  private pregSeekFramePos: number = -1;
  private pregSeekWallMs: number = 0;
  /** 真的出过声了：之后本章不再换路线（IMPL §3.4 的章级原子切换）。 */
  private pregPlaying: boolean = false;
  /** 整章已经放完（`resume()` 据此决定要不要从头重来）。 */
  private pregEnded: boolean = false;
  /** 音频句柄 + 断点已就绪（下载完但当时暂停着，等 resume 再拉渲染器）。 */
  private pregReady: boolean = false;
  /** 渲染器已为当前断点拉起来，可以从文件读；否则 `fillFromPreg` 只给静音。 */
  private pregPump: boolean = false;
  /** 请求代次：换章/重开会自增，晚到的下载/seek 回调按代次丢弃。 */
  private pregSeq: number = 0;
  private prefPregenPrefer: boolean = TTS_PREGEN_PREFER_DEFAULT;
  /** 「仅 Wi-Fi 时预生成」：只阻预取（正常播放要下就下，否则当场退回实时也照样费流量）。 */
  private prefPregenWifiOnly: boolean = TTS_PREGEN_WIFI_ONLY_DEFAULT;

  private creating: boolean = false;
  private voiceSwitching: boolean = false;
  private bgRunning: boolean = false;
  private bgListenerRegistered: boolean = false;
  private bgProbeTimerIds: number[] = [];
  private formatLogged: boolean = false;
  private timerId: number = -1;
  private tickId: number = -1;

  // ── Engine selection: system TTS (default / offline fallback) or remote VPS ──
  @Trace engineKind: number = TTS_ENGINE_SYSTEM;
  @Trace remoteVoice: string = TTS_REMOTE_VOICE_DEFAULT;
  private serverUrl: string = TTS_SERVER_DEFAULT;
  private apiKey: string = TTS_API_KEY_DEFAULT;
  private fallingBack: boolean = false;

  // ── Preferences / getters ─────────────────────────────────────

  private loadPrefs(): void {
    const ctx: common.UIAbilityContext | undefined = this.ctx;
    if (ctx === undefined) {
      return;
    }
    this.speed = getNumber(ctx, KEY_TTS_SPEED, TTS_SPEED_DEFAULT);
    this.voice = getNumber(ctx, KEY_TTS_VOICE, TTS_VOICE_DEFAULT);
    // D17：远端 VITS 实时链路已停用（音质太差），实时恒为系统 TTS；VPS 只服务
    // 预生成缓存（走 `serverUrl` / `apiKey`）。存量偏好里的 REMOTE 一次性迁掉。
    const storedEngine: number = getNumber(ctx, KEY_TTS_ENGINE, TTS_ENGINE_SYSTEM);
    if (storedEngine === TTS_ENGINE_REMOTE) {
      putNumber(ctx, KEY_TTS_ENGINE, TTS_ENGINE_SYSTEM);
      hilog.info(DOMAIN, TAG, 'tts engine migrated remote->system (D17)');
    }
    this.engineKind = TTS_ENGINE_SYSTEM;
    this.serverUrl = getString(ctx, KEY_TTS_SERVER, TTS_SERVER_DEFAULT);
    this.apiKey = getString(ctx, KEY_TTS_API_KEY, TTS_API_KEY_DEFAULT);
    this.remoteVoice = normalizeRemoteVoice(getString(ctx, KEY_TTS_REMOTE_VOICE, TTS_REMOTE_VOICE_DEFAULT));
    this.prefPregenPrefer = getBoolean(ctx, KEY_TTS_PREGEN_PREFER, TTS_PREGEN_PREFER_DEFAULT);
    this.prefPregenWifiOnly = getBoolean(ctx, KEY_TTS_PREGEN_WIFI_ONLY, TTS_PREGEN_WIFI_ONLY_DEFAULT);
  }

  /** 预生成链路与实时链路共用同一台服务器 / 同一个 Key（单一来源）。 */
  serverBase(): string {
    return this.serverUrl;
  }

  apiKeyValue(): string {
    return this.apiKey;
  }

  /** 当前这一章的 PCM 采样率：缓存章 24 kHz（GSV），实时（系统 TTS）16 kHz。 */
  private get sampleRate(): number {
    return this.pregMode ? SAMPLE_RATE_REMOTE : SAMPLE_RATE_SYSTEM;
  }

  isActiveFor(bookId: string): boolean {
    return this.active && this.book !== undefined && this.book.bookId === bookId;
  }

  currentSource(): BookSource | undefined {
    return this.source;
  }

  currentBook(): Book | undefined {
    return this.book;
  }

  currentChapters(): Chapter[] {
    return this.chapters;
  }

  // ── Start / stop ──────────────────────────────────────────────

  async start(
    ctx: common.UIAbilityContext,
    source: BookSource,
    book: Book,
    chapters: Chapter[],
    chapterIndex: number,
    paragraphs: string[],
    paragraphIndex: number
  ): Promise<void> {
    this.ctx = ctx;
    this.loadPrefs();
    if (this.active && this.book !== undefined && this.book.bookId !== book.bookId) {
      this.stop();
    }
    this.source = source;
    this.book = book;
    // 听书期间整理缓存时不删这本书的章节文件（会话级保护）。
    protectBook(book.bookId);
    this.chapters = chapters;
    this.bookName = book.name;
    this.author = book.author;
    this.active = true;
    this.error = '';
    hilog.info(DOMAIN, TAG, 'start book=%{public}s chapter=%{public}d para=%{public}d',
      book.name, chapterIndex, paragraphIndex);
    this.loading = true;
    try {
      await this.ensureEngine();
      // P0 修复（2026-10-17）：**先申请长时任务，再建/激活 AVSession**。
      // AVSession 一旦 `activate()` 就会把自己标成 front，并向后台任务模块发起
      // `AVSessionNotifyUpdateNotification(uid, pid, true)`，把「长时任务通知」的职责移交过去；
      // 若那一刻应用还没有 AUDIO_PLAYBACK 长时任务，该调用直接失败
      // （`ERR_BGTASK_OBJECT_NOT_EXIST = 980000502`，见 docs/bugfix/TASKS.md P0 条目），
      // 而后台任务模块此后认为「通知由 AVSession 负责」也不再发自己的通知 → 两边都不发
      // → 任务被判无效 → 退后台/息屏后被冻结。
      await this.startBackground();
      await this.ensureSession();
      // 这里还不知道本章走哪条路（`beginFrom` 才定），先按实时采样率建；
      // 缓存章会在 `ensureRenderRate` 里重建为 24 kHz。
      await this.ensureRenderer();
    } catch (err) {
      const e = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'init failed code=%{public}d msg=%{public}s', e.code, e.message);
      this.error = '听书初始化失败';
      this.loading = false;
      this.active = false;
      this.setPlaying(false);
      return;
    }
    this.loading = false;
    if (chapterIndex >= 0 && chapterIndex < chapters.length && paragraphs.length > 0) {
      this.setChapter(chapterIndex, chapters[chapterIndex].title, paragraphs);
      this.beginFrom(paragraphIndex);
      this.updateMetadata();
    } else {
      await this.loadChapter(chapterIndex, false, true);
    }
  }

  stop(): void {
    this.clearTimer();
    this.stopFlushTimer();
    this.stopProgressTimer();
    this.setPlaying(false);
    this.active = false;
    this.pregSeq++;
    // 保留缓存文件（cacheDir 由系统回收，重开同一章不必重下）；只放句柄
    this.releasePregAudio();
    if (this.engine !== undefined) {
      try {
        this.engine.stop();
      } catch (err) {
      }
      try {
        this.engine.shutdown();
      } catch (err) {
      }
      this.engine = undefined;
      this.formatLogged = false;
    }
    this.resetQueues();
    this.releaseRenderer();
    this.stopBackground();
    if (this.session !== undefined) {
      try {
        this.session.deactivate();
        this.session.destroy();
      } catch (err) {
      }
      this.session = undefined;
    }
  }

  /**
   * The single write path for `playing` — every state flip goes through here so the
   * position claim cannot drift out of sync with playback.
   *
   * Starting to play takes the claim for this book: from then on the audio clock is
   * the only writer, and the Reader's writes are dropped in `saveProgress`
   * (`model/ProgressOwner.ets`). Stopping play (pause / natural end / error / stop)
   * writes the final position **before** releasing, because the 1 s progress tick may
   * be up to a second behind and `stop()` also runs on app exit.
   */
  private setPlaying(value: boolean): void {
    if (this.playing === value) {
      return;
    }
    this.playing = value;
    const book: Book | undefined = this.book;
    if (book === undefined) {
      return;
    }
    if (value) {
      claimProgress(book.bookId, ProgressWriter.TTS);
      return;
    }
    this.persistProgress();
    releaseProgress(book.bookId, ProgressWriter.TTS);
  }

  // ── Engine / renderer / session ───────────────────────────────

  private async ensureEngine(): Promise<void> {
    if (this.engine !== undefined || this.creating) {
      return;
    }
    this.creating = true;
    const extra: Record<string, Object> = {
      'style': 'interaction-broadcast',
      'locate': 'CN',
      'name': ENGINE_NAME,
      'isBackStage': true
    };
    const params: textToSpeech.CreateEngineParams = {
      language: 'zh-CN',
      person: this.voice,
      online: 1,
      extraParams: extra
    };
    try {
      const engine: textToSpeech.TextToSpeechEngine = await textToSpeech.createEngine(params);
      engine.setListener(this.listener());
      this.engine = engine;
      hilog.info(DOMAIN, TAG, 'engine ready voice=%{public}d', this.voice);
    } catch (err) {
      const e = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'engine create failed code=%{public}d msg=%{public}s', e.code, e.message);
      throw new Error(e.message);
    } finally {
      this.creating = false;
    }
  }

  private async ensureRenderer(): Promise<void> {
    if (this.renderer !== undefined) {
      return;
    }
    // 本次创建所属的代次。创建是异步的：期间可能换了章或停了播（`pregSeq` 变），
    // 那时这个实例不该挂上去（否则 24 kHz 的实例可能接到 16 kHz 的章上，或
    // 停播后一直被占着不放）。
    const gen: number = this.pregSeq;
    const streamInfo: audio.AudioStreamInfo = {
      samplingRate: this.renderRate === SAMPLE_RATE_REMOTE
        ? audio.AudioSamplingRate.SAMPLE_RATE_24000
        : audio.AudioSamplingRate.SAMPLE_RATE_16000,
      channels: audio.AudioChannel.CHANNEL_1,
      sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
      encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW
    };
    const rendererInfo: audio.AudioRendererInfo = {
      usage: audio.StreamUsage.STREAM_USAGE_AUDIOBOOK,
      rendererFlags: 0
    };
    const options: audio.AudioRendererOptions = {
      streamInfo: streamInfo,
      rendererInfo: rendererInfo
    };
    try {
      const renderer: audio.AudioRenderer = await audio.createAudioRenderer(options);
      if (gen !== this.pregSeq || !this.active) {
        try {
          renderer.release();
        } catch (err) {
        }
        hilog.info(DOMAIN, TAG, 'renderer discarded gen=%{public}d', gen);
        return;
      }
      renderer.on('writeData', (buffer: ArrayBuffer) => {
        return this.fill(buffer);
      });
      renderer.on('audioInterrupt', (event: audio.InterruptEvent) => {
        if (event.hintType === audio.InterruptHint.INTERRUPT_HINT_PAUSE
          || event.hintType === audio.InterruptHint.INTERRUPT_HINT_STOP) {
          this.pause();
        }
      });
      this.renderer = renderer;
      hilog.info(DOMAIN, TAG, 'renderer ready rate=%{public}d', this.renderRate);
    } catch (err) {
      const e = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'renderer create failed code=%{public}d msg=%{public}s', e.code, e.message);
      throw new Error(e.message);
    }
  }

  /**
   * 按本章路线准备渲染器：采样率变了就重建（D17：缓存 24 kHz / 系统 TTS 16 kHz）。
   * 只在**进章时**调用——一旦出声，这一章内不再换采样率。
   */
  private async ensureRenderRate(rate: number): Promise<void> {
    if (rate !== this.renderRate) {
      hilog.info(DOMAIN, TAG, 'render rate %{public}d -> %{public}d', this.renderRate, rate);
      this.releaseRenderer();
      this.renderRate = rate;
    }
    await this.ensureRenderer();
  }

  private async startRenderer(): Promise<void> {
    const renderer: audio.AudioRenderer | undefined = this.renderer;
    if (renderer === undefined) {
      return;
    }
    // Reset to a clean state regardless of the current one: drop anything still
    // buffered and (re)start pulling.
    try {
      await renderer.pause();
    } catch (err) {
    }
    try {
      await renderer.flush();
    } catch (err) {
    }
    try {
      await renderer.start();
    } catch (err) {
      const e = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'renderer start failed code=%{public}d msg=%{public}s', e.code, e.message);
    }
  }

  private releaseRenderer(): void {
    const renderer: audio.AudioRenderer | undefined = this.renderer;
    if (renderer === undefined) {
      return;
    }
    this.renderer = undefined;
    try {
      renderer.off('writeData');
      renderer.stop();
      renderer.release();
    } catch (err) {
    }
  }

  private listener(): textToSpeech.SpeakListener {
    const self: TtsController = this;
    const listener: textToSpeech.SpeakListener = {
      onStart(requestId: string, response: textToSpeech.StartResponse): void {
        self.traceFormat(response);
      },
      onComplete(requestId: string, response: textToSpeech.CompleteResponse): void {
        self.onComplete(requestId);
      },
      onStop(requestId: string, response: textToSpeech.StopResponse): void {
        self.onStop();
      },
      onData(requestId: string, audioData: ArrayBuffer, response: textToSpeech.SynthesisResponse): void {
        self.onData(requestId, audioData, response);
      },
      onError(requestId: string, errorCode: number, errorMessage: string): void {
        self.onError(errorCode, errorMessage);
      }
    };
    return listener;
  }

  private traceFormat(response: textToSpeech.StartResponse): void {
    if (this.formatLogged) {
      return;
    }
    this.formatLogged = true;
    hilog.info(DOMAIN, TAG, 'tts format rate=%{public}d bit=%{public}d ch=%{public}d',
      response.sampleRate, response.sampleBit, response.audioChannel);
  }

  private async ensureSession(): Promise<void> {
    if (this.session !== undefined) {
      return;
    }
    const ctx: common.UIAbilityContext | undefined = this.ctx;
    if (ctx === undefined) {
      return;
    }
    const session: avSession.AVSession = await avSession.createAVSession(ctx, SESSION_TAG, 'audio');
    const self: TtsController = this;
    session.on('play', () => {
      self.resume();
    });
    session.on('pause', () => {
      self.pause();
    });
    session.on('stop', () => {
      self.stop();
    });
    session.on('playNext', () => {
      self.next();
    });
    session.on('playPrevious', () => {
      self.prev();
    });
    session.on('seek', (time: number) => {
      self.seekByTime(time);
    });
    try {
      await session.activate();
    } catch (err) {
      const e = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'activate failed code=%{public}d msg=%{public}s', e.code, e.message);
      throw e as Error;
    }
    try {
      await session.setBackgroundPlayMode(avSession.BackgroundPlayMode.ENABLE_BACKGROUND_PLAY);
      hilog.info(DOMAIN, TAG, 'background play mode enabled');
    } catch (err) {
      const e = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'setBackgroundPlayMode failed code=%{public}d msg=%{public}s', e.code, e.message);
    }
    try {
      const wantAgentInfo: wantAgent.WantAgentInfo = {
        wants: [{
          bundleName: 'com.lichtcui.wispreader',
          abilityName: 'EntryAbility'
        }],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      };
      const launch: WantAgent = await wantAgent.getWantAgent(wantAgentInfo);
      await session.setLaunchAbility(launch);
    } catch (err) {
      const e = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'setLaunchAbility failed code=%{public}d msg=%{public}s', e.code, e.message);
    }
    this.session = session;
    hilog.info(DOMAIN, TAG, 'avsession ready id=%{public}s', session.sessionId);
    this.logNotifyState('session-ready');
  }

  private async startBackground(): Promise<void> {
    const ctx: common.UIAbilityContext | undefined = this.ctx;
    if (this.bgRunning || ctx === undefined) {
      return;
    }
    this.registerContinuousTaskListeners();
    try {
      const wantAgentInfo: wantAgent.WantAgentInfo = {
        wants: [{
          bundleName: 'com.lichtcui.wispreader',
          abilityName: 'EntryAbility'
        }],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      };
      const agent: WantAgent = await wantAgent.getWantAgent(wantAgentInfo);
      const t0: number = Date.now();
      await backgroundTaskManager.startBackgroundRunning(
        ctx,
        backgroundTaskManager.BackgroundMode.AUDIO_PLAYBACK,
        agent
      );
      this.bgRunning = true;
      hilog.info(DOMAIN, TAG, 'background task started dt=%{public}d ms', Date.now() - t0);
      this.logNotifyState('bg-started');
      this.scheduleContinuousTaskProbe('bg+1s', 1000);
      this.scheduleContinuousTaskProbe('bg+10s', 10000);
      this.scheduleContinuousTaskProbe('bg+25s', 25000);
      this.scheduleContinuousTaskProbe('bg+45s', 45000);
      this.scheduleContinuousTaskProbe('bg+60s', 60000);
    } catch (err) {
      const e = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'background task failed code=%{public}d msg=%{public}s', e.code, e.message);
    }
  }

  private stopBackground(): void {
    const ctx: common.UIAbilityContext | undefined = this.ctx;
    if (!this.bgRunning || ctx === undefined) {
      return;
    }
    this.clearContinuousTaskProbes();
    backgroundTaskManager.stopBackgroundRunning(ctx).catch((err: BusinessError) => {
      hilog.warn(DOMAIN, TAG, 'stopBackground failed code=%{public}d', err.code);
    });
    this.bgRunning = false;
  }

  private registerContinuousTaskListeners(): void {
    if (this.bgListenerRegistered) {
      return;
    }
    try {
      backgroundTaskManager.on('continuousTaskCancel', (info: backgroundTaskManager.ContinuousTaskCancelInfo): void => {
        hilog.warn(DOMAIN, TAG, 'continuous task cancel id=%{public}d reason=%{public}d',
          info.id, info.reason);
      });
      backgroundTaskManager.on('continuousTaskSuspend',
        (info: backgroundTaskManager.ContinuousTaskSuspendInfo): void => {
          hilog.warn(DOMAIN, TAG, 'continuous task suspend id=%{public}d state=%{public}s reason=%{public}d',
            info.continuousTaskId, info.suspendState.toString(), info.suspendReason);
        });
      this.bgListenerRegistered = true;
      hilog.info(DOMAIN, TAG, 'continuous task listeners registered');
    } catch (err) {
      const e = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'continuous task listeners failed code=%{public}d msg=%{public}s',
        e.code, e.message);
    }
  }

  private scheduleContinuousTaskProbe(label: string, delayMs: number): void {
    const id: number = setTimeout((): void => {
      this.bgProbeTimerIds = this.bgProbeTimerIds.filter((timerId: number): boolean => timerId !== id);
      this.logContinuousTaskState(label);
    }, delayMs);
    this.bgProbeTimerIds.push(id);
  }

  private clearContinuousTaskProbes(): void {
    for (const id of this.bgProbeTimerIds) {
      clearTimeout(id);
    }
    this.bgProbeTimerIds = [];
  }

  private logContinuousTaskState(label: string): void {
    const ctx: common.UIAbilityContext | undefined = this.ctx;
    if (ctx === undefined) {
      return;
    }
    const renderer: audio.AudioRenderer | undefined = this.renderer;
    const rendererState: string = renderer === undefined
      ? 'none'
      : renderer.state.toString();
    const frame: number = this.framePos();
    backgroundTaskManager.getAllContinuousTasks(ctx, true).then(
      (tasks: backgroundTaskManager.ContinuousTaskInfo[]): void => {
        hilog.info(DOMAIN, TAG,
          'continuous task probe at=%{public}s count=%{public}d renderer=%{public}s frame=%{public}d playing=%{public}s',
          label, tasks.length, rendererState, frame, this.playing.toString());
        for (const task of tasks) {
          hilog.info(DOMAIN, TAG,
            'continuous task info at=%{public}s id=%{public}d modes=%{public}s sub=%{public}s suspend=%{public}s notification=%{public}d ability=%{public}s',
            label, task.continuousTaskId, task.backgroundModes.join(','), task.backgroundSubModes.join(','),
            task.suspendState.toString(), task.notificationId, task.abilityName);
        }
      }).catch((err: BusinessError) => {
      hilog.warn(DOMAIN, TAG, 'continuous task probe failed at=%{public}s code=%{public}d msg=%{public}s',
        label, err.code, err.message);
    });
  }

  /**
   * P0 探针：应用通知是否开启。
   * AUDIO_PLAYBACK 接入 AVSession 时，后台任务模块**故意**不发自己的通知（`id -1`），
   * 通知由 AVSession 侧的媒体通知承担；通知发不出去 ⇒ 长时任务被判无效并被停掉。
   */
  private logNotifyState(where: string): void {
    try {
      const enabled: boolean = notificationManager.isNotificationEnabledSync();
      hilog.info(DOMAIN, TAG, 'notify enabled=%{public}s where=%{public}s', enabled.toString(), where);
    } catch (err) {
      const e = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'notify state query failed code=%{public}d where=%{public}s', e.code, where);
    }
  }

  // ── Content / synthesis queue ─────────────────────────────────

  private setChapter(index: number, title: string, paragraphs: string[]): void {
    this.releasePregAudio();
    this.chapterIndex = index;
    this.chapterTitle = title;
    this.paragraphs = paragraphs;
    this.paragraphCount = paragraphs.length;
    this.prefixChars = [];
    let sum: number = 0;
    for (const p of paragraphs) {
      this.prefixChars.push(sum);
      sum += p.length;
    }
    this.totalChars = sum;
    // 章节文件里已经记过预生成键？没有就说明这一章还没被预生成过 → ''
    this.pregPlayKey = this.lookupPregKey(index);
  }

  /** 该章的预生成音频键（同步读章节缓存；无键/无 ctx 返回 ''）。 */
  private lookupPregKey(index: number): string {
    const ctx: common.UIAbilityContext | undefined = this.ctx;
    const book: Book | undefined = this.book;
    if (ctx === undefined || book === undefined) {
      return '';
    }
    if (index < 0 || index >= this.chapters.length) {
      return '';
    }
    try {
      return getChapterPregKey(ctx, book.bookId, index, this.chapters[index].url);
    } catch (err) {
      return '';
    }
  }

  private async loadChapter(index: number, startAtEnd: boolean, autoplay: boolean): Promise<void> {
    if (!isReadable(this.chapters, index)) {
      this.setPlaying(false);
      return;
    }
    this.loading = true;
    try {
      const chapter: Chapter = this.chapters[index];
      const paragraphs: string[] = await loadChapterParagraphs(
        this.ctx, this.source, this.book, chapter, index
      );
      if (!this.active) {
        this.loading = false;
        return;
      }
      this.setChapter(index, chapter.title, paragraphs);
      this.loading = false;
      const start: number = startAtEnd ? Math.max(paragraphs.length - 1, 0) : 0;
      if (autoplay) {
        this.beginFrom(start);
      } else {
        this.currentIndex = start;
        this.paragraphIndex = start;
      }
      this.updateMetadata();
    } catch (err) {
      this.error = '正文加载失败';
      this.loading = false;
      this.setPlaying(false);
    }
  }

  private resetQueues(): void {
    this.queue = [];
    this.queueOffset = 0;
    this.reqByIndex.clear();
    this.reqIdIndex.clear();
    this.timeline = [];
    this.elapsedMs = 0;
    this.playStartWallMs = Date.now();
  }

  /**
   * Drop only the in-flight synthesis requests, keeping already-flushed PCM and
   * its timeline untouched. Used by pause / speed change so the renderer can
   * keep draining its buffer instead of restarting from a silent queue.
   */
  private clearInflight(): void {
    this.reqByIndex.clear();
    this.reqIdIndex.clear();
    this.issuedIndex = this.flushIndex;
  }

  private beginFrom(index: number): void {
    if (this.paragraphs.length === 0) {
      this.setPlaying(false);
      return;
    }
    const target: number = Math.min(Math.max(index, 0), this.paragraphs.length - 1);
    if (this.engine !== undefined) {
      try {
        this.engine.stop();
      } catch (err) {
      }
    }
    this.resetQueues();
    this.releasePregAudio();
    this.currentIndex = target;
    this.paragraphIndex = target;
    this.issuedIndex = target;
    this.flushIndex = target;
    this.setPlaying(true);
    this.startBackground();
    this.persistProgress();
    this.updatePlaybackState(avSession.PlaybackState.PLAYBACK_STATE_PLAY);
    const seq: number = ++this.pregSeq;
    // 路由照旧（有键就走缓存）：**不做「pending 就跳过」**——同一 job 里有的章可能早就算好了
    // （重新提交 / 别处提交过），跳过反而白走 16 kHz 实时（还会来回重建采样率）。
    // 没算好的那几章多付一次 404 很便宜，退实时前会记 `preg key kept`。
    const route: string = chapterAudioRoute(this.prefPregenPrefer, this.pregPlayKey);
    const cache: boolean = route === AUDIO_CACHE;
    // 采样率随路线走（缓存 24 kHz / 实时 16 kHz），重建渲染器是异步的：
    // 两条分支都等它就位再动；期间换了章或停了播，`seq` 已变，直接放弃。
    this.ensureRenderRate(cache ? SAMPLE_RATE_REMOTE : SAMPLE_RATE_SYSTEM).then((): void => {
      if (seq !== this.pregSeq || !this.active) {
        return;
      }
      if (cache) {
        // 预生成音频是「整章一份」：从章头起放，段落边界靠官方 chunks 时间轴还原
        hilog.info(DOMAIN, TAG, 'begin para=%{public}d route=cache', target);
        this.startPregChapter(this.pregPlayKey, target, seq);
        return;
      }
      hilog.info(DOMAIN, TAG, 'begin para=%{public}d route=realtime', target);
      this.startRealtime();
    }).catch((): void => {
      if (seq !== this.pregSeq || !this.active) {
        return;
      }
      hilog.error(DOMAIN, TAG, 'renderer init failed route=%{public}s', route);
      this.error = '听书初始化失败';
      this.setPlaying(false);
    });
  }

  /** 实时链路（系统 TTS AHEAD 预合成 / 服务端整段 HTTP），两条预生成之外的路径共用。 */
  private startRealtime(): void {
    this.pregMode = false;
    this.pregBuffering = false;
    if (!this.playing) {
      // 下载期间被暂停 / 停下了：等 resume() 再拉数据，别现在就把渲染器跑起来
      return;
    }
    this.ensureSynthesized();
    this.startFlushTimer();
    this.startProgressTimer();
    this.startRenderer();
  }

  /** Issue synth requests for upcoming paragraphs so playback has a small buffer. */
  private ensureSynthesized(): void {
    if (!this.playing) {
      return;
    }
    // 缓存章整章一份音频，不走 /tts；缓存还在下载时也不能先起实时合成，
    // 否则下载完成会把刚合成的 PCM 整段丢掉（白烧服务器）
    if (this.pregMode || this.pregBuffering) {
      return;
    }
    if (this.engineKind === TTS_ENGINE_REMOTE) {
      this.ensureRemoteSynthesized();
      return;
    }
    const engine: textToSpeech.TextToSpeechEngine | undefined = this.engine;
    if (engine === undefined) {
      return;
    }
    while (this.issuedIndex < this.paragraphs.length && this.issuedIndex - this.flushIndex < AHEAD) {
      const idx: number = this.issuedIndex;
      const requestId: string = this.seq.toString() + '-' + idx.toString();
      this.seq++;
      this.reqIdIndex.set(requestId, idx);
      this.reqByIndex.set(idx, new ReqBuffer(idx));
      const extra: Record<string, Object> = {
        'speed': this.speed,
        'volume': 1,
        'pitch': 1,
        'languageContext': 'zh-CN',
        'audioType': 'pcm',
        'playType': 0,
        'queueMode': 0,
        'isBackStage': true
      };
      const params: textToSpeech.SpeakParams = { requestId: requestId, extraParams: extra };
      try {
        engine.speak(this.paragraphs[idx], params);
      } catch (err) {
        this.error = '播报请求失败';
        this.setPlaying(false);
        break;
      }
      this.issuedIndex++;
    }
  }

  /** Issue remote fetch requests ahead of the playback head (whole-paragraph HTTP). */
  private ensureRemoteSynthesized(): void {
    while (this.issuedIndex < this.paragraphs.length && this.issuedIndex - this.flushIndex < AHEAD_REMOTE) {
      const idx: number = this.issuedIndex;
      this.reqByIndex.set(idx, new ReqBuffer(idx));
      this.issuedIndex++;
      this.remoteSynth(idx, this.paragraphs[idx]);
    }
  }

  private async remoteSynth(idx: number, text: string): Promise<void> {
    let pcm: ArrayBuffer;
    try {
      pcm = await remoteSynthesize(this.serverUrl, this.apiKey, text, this.remoteVoice,
        effectiveSpeed(this.speed, TTS_ENGINE_REMOTE));
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'remote synth failed para=%{public}d', idx);
      this.fallbackToSystem();
      return;
    }
    const rb: ReqBuffer | undefined = this.reqByIndex.get(idx);
    if (rb === undefined) {
      return;
    }
    rb.chunks.set(0, pcm);
    rb.bytes = pcm.byteLength;
    rb.doneAt = Date.now();
  }

  /** Remote synthesis failed: drop to the system TTS engine and restart the current paragraph. */
  private async fallbackToSystem(): Promise<void> {
    if (this.engineKind !== TTS_ENGINE_REMOTE || this.fallingBack) {
      return;
    }
    this.fallingBack = true;
    hilog.warn(DOMAIN, TAG, 'remote synth failed, falling back to system TTS');
    const resumeIdx: number = this.currentIndex;
    this.pause();
    this.engineKind = TTS_ENGINE_SYSTEM;
    // Deliberately NOT persisted: a transient failure (timeout / server 500) must not silently
    // overwrite the user's engine choice forever -- otherwise one bad paragraph downgrades
    // them to system TTS until they dig into 听书设置. The preference keeps 远端 so the next
    // 听书 session retries it; this session stays on the system engine.
    this.error = '远端合成失败，本次已切换回系统 TTS';
    this.releaseRenderer();
    try {
      await this.ensureEngine();
      await this.ensureRenderer();
    } catch (err) {
      this.error = '系统 TTS 初始化失败';
    }
    this.fallingBack = false;
    if (this.active) {
      this.beginFrom(resumeIdx);
    }
  }

  /** True when every paragraph was issued and the render queue has drained. */
  private queueExhausted(): boolean {
    return this.paragraphs.length > 0
      && this.issuedIndex >= this.paragraphs.length
      && this.queue.length === 0;
  }

  private onData(requestId: string, data: ArrayBuffer, response: textToSpeech.SynthesisResponse): void {
    const idx: number | undefined = this.reqIdIndex.get(requestId);
    if (idx === undefined) {
      return;
    }
    const rb: ReqBuffer | undefined = this.reqByIndex.get(idx);
    if (rb === undefined) {
      this.insertLateData(idx, data);
      return;
    }
    rb.chunks.set(response.sequence, data);
    rb.bytes += data.byteLength;
  }

  private onComplete(requestId: string): void {
    const idx: number | undefined = this.reqIdIndex.get(requestId);
    if (idx === undefined) {
      return;
    }
    this.reqIdIndex.delete(requestId);
    const rb: ReqBuffer | undefined = this.reqByIndex.get(idx);
    if (rb !== undefined) {
      rb.doneAt = Date.now();
    }
  }

  private onStop(): void {
    // Engine stopped; state is driven by pause()/stop()/beginFrom().
  }

  private onError(errorCode: number, errorMessage: string): void {
    hilog.error(DOMAIN, TAG, 'tts error code=%{public}d msg=%{public}s', errorCode, errorMessage);
    this.error = '播报失败（' + errorCode.toString() + '）';
    this.setPlaying(false);
    // Drop in-flight requests and stop the timers so a later resume() can
    // re-issue the failed paragraph instead of waiting on a stuck buffer.
    this.clearInflight();
    this.stopFlushTimer();
    this.stopProgressTimer();
    this.stopBackground();
    this.updatePlaybackState(avSession.PlaybackState.PLAYBACK_STATE_ERROR);
  }

  private startFlushTimer(): void {
    if (this.flushTimerId >= 0) {
      return;
    }
    this.flushTimerId = setInterval(() => {
      this.tryFlush();
    }, FLUSH_TICK_MS);
  }

  private stopFlushTimer(): void {
    if (this.flushTimerId >= 0) {
      clearInterval(this.flushTimerId);
      this.flushTimerId = -1;
    }
  }

  private startProgressTimer(): void {
    if (this.progressTimerId >= 0) {
      return;
    }
    this.progressTimerId = setInterval(() => {
      this.tickProgress();
    }, PROGRESS_TICK_MS);
  }

  private stopProgressTimer(): void {
    if (this.progressTimerId >= 0) {
      clearInterval(this.progressTimerId);
      this.progressTimerId = -1;
    }
  }

  /**
   * Drive progress from the audio clock, not the write head. Writing ahead of
   * playback (renderer pre-buffer) must never move `paragraphIndex`; only the
   * frame actually being played does.
   */
  private tickProgress(): void {
    if (!this.playing) {
      return;
    }
    const played: number = this.playedMs();
    this.elapsedMs = played;
    const idx: number = this.paragraphAt(played);
    if (idx >= 0 && idx !== this.paragraphIndex) {
      this.paragraphIndex = idx;
      this.currentIndex = idx;
      hilog.info(DOMAIN, TAG, 'play para=%{public}d', idx);
    }
    const now: number = Date.now();
    if (now - this.lastStatePushAt >= STATE_PUSH_MS) {
      this.lastStatePushAt = now;
      this.persistProgress();
      this.updatePlaybackState(avSession.PlaybackState.PLAYBACK_STATE_PLAY);
    }
  }

  /** Frames actually rendered since the last `flush()` → milliseconds. */
  private playedMs(): number {
    const frames: number = this.framePos();
    if (this.pregMode) {
      // 缓存路径：帧数增量 ÷ 采样率 = 已渲染的**源**毫秒（与 estimateDurationMs 同单位），
      // seek 之后就落在 seek 基准上；平台不给帧位置时退化到墙上时钟 × 倍速。
      const rate: number = pregPlaybackRate(this.speed);
      if (frames >= 0 && this.pregSeekFramePos >= 0) {
        return this.pregSeekBaseMs + Math.max(frames - this.pregSeekFramePos, 0) / this.sampleRate * 1000;
      }
      return this.pregSeekBaseMs + Math.max(Date.now() - this.pregSeekWallMs, 0) * rate;
    }
    if (frames >= 0) {
      return frames / this.sampleRate * 1000;
    }
    return Math.max(Date.now() - this.playStartWallMs, 0);
  }

  /** 渲染器已渲染的帧数；平台不支持时 -1（调用方退化到墙上时钟）。 */
  private framePos(): number {
    const renderer: audio.AudioRenderer | undefined = this.renderer;
    if (renderer === undefined) {
      return -1;
    }
    try {
      const info: audio.AudioTimestampInfo = renderer.getAudioTimestampInfoSync();
      return info.framePos;
    } catch (err) {
      return -1;
    }
  }

  /** Latest timeline slot whose start has been reached. */
  private paragraphAt(ms: number): number {
    if (this.timeline.length === 0) {
      return this.paragraphIndex;
    }
    let index: number = this.timeline[0].index;
    for (const seg of this.timeline) {
      if (ms >= seg.startMs) {
        index = seg.index;
      } else {
        break;
      }
    }
    return index;
  }

  /** Move finished synthesis buffers into the render queue, in paragraph order. */
  private tryFlush(): void {
    if (!this.playing) {
      return;
    }
    const now: number = Date.now();
    while (true) {
      const rb: ReqBuffer | undefined = this.reqByIndex.get(this.flushIndex);
      if (rb === undefined || rb.doneAt === 0 || now - rb.doneAt < FLUSH_GRACE_MS) {
        break;
      }
      this.enqueueParagraph(rb);
      this.reqByIndex.delete(this.flushIndex);
      this.flushIndex++;
      this.ensureSynthesized();
    }
  }

  private enqueueParagraph(rb: ReqBuffer): void {
    const seqs: number[] = [];
    rb.chunks.forEach((value: ArrayBuffer, key: number) => {
      seqs.push(key);
    });
    seqs.sort((a: number, b: number) => a - b);
    let total: number = 0;
    for (const s of seqs) {
      const chunk: ArrayBuffer | undefined = rb.chunks.get(s);
      if (chunk !== undefined) {
        total += chunk.byteLength;
      }
    }
    const merged: Uint8Array = new Uint8Array(total);
    let offset: number = 0;
    for (const s of seqs) {
      const chunk: ArrayBuffer | undefined = rb.chunks.get(s);
      if (chunk !== undefined) {
        merged.set(new Uint8Array(chunk), offset);
        offset += chunk.byteLength;
      }
    }
    this.queue.push(new RenderItem(rb.index, merged.buffer as ArrayBuffer, false));
    this.queue.push(new RenderItem(rb.index, new ArrayBuffer(0), true));
    const durationMs: number = total / (this.sampleRate * BYTES_PER_FRAME) * 1000;
    const startMs: number = this.timeline.length > 0
      ? this.timeline[this.timeline.length - 1].endMs
      : 0;
    this.timeline.push(new ParagraphTiming(rb.index, startMs, startMs + durationMs));
  }

  /** A straggler `onData` arrived after its paragraph was already flushed. */
  private insertLateData(index: number, data: ArrayBuffer): void {
    for (let i = this.queue.length - 1; i >= 0; i--) {
      const item: RenderItem = this.queue[i];
      if (item.end && item.index === index) {
        this.queue.splice(i, 0, new RenderItem(index, data, false));
        return;
      }
    }
  }

  // ── Renderer data source ──────────────────────────────────────

  private fill(buffer: ArrayBuffer): audio.AudioDataCallbackResult {
    if (this.pregMode) {
      return this.fillFromPreg(new Uint8Array(buffer));
    }
    const view: Uint8Array = new Uint8Array(buffer);
    const space: number = view.length;
    let pos: number = 0;
    while (pos < space && this.queue.length > 0) {
      const item: RenderItem = this.queue[0];
      if (item.end) {
        this.queue.shift();
        this.queueOffset = 0;
        this.scheduleParagraphEnd(item.index);
        continue;
      }
      // Progress is owned by `tickProgress()` (audio clock); the write callback
      // only moves PCM bytes so a pre-buffered paragraph can't jump the UI.
      const src: Uint8Array = new Uint8Array(item.data);
      const avail: number = src.length - this.queueOffset;
      const n: number = Math.min(avail, space - pos);
      view.set(src.subarray(this.queueOffset, this.queueOffset + n), pos);
      pos += n;
      this.queueOffset += n;
      if (this.queueOffset >= src.length) {
        this.queue.shift();
        this.queueOffset = 0;
      }
    }
    // Remaining bytes stay zero (silence) for a clean underrun.
    return audio.AudioDataCallbackResult.VALID;
  }

  /** 缓存路径的写回调：直接从文件读；读不到就补零（静音），整章读完时收尾。 */
  private fillFromPreg(view: Uint8Array): audio.AudioDataCallbackResult {
    const source: PregAudioSource | undefined = this.pregSource;
    // 断点刚摆好、渲染器还没拉起来：给静音（否则它会把 seek 之后的字节抢在 flush 前读走）
    if (source === undefined || !this.pregPump) {
      return audio.AudioDataCallbackResult.VALID;
    }
    const n: number = source.read(view);
    if (n > 0 && !this.pregPlaying) {
      // 第一个字节真的进了渲染器 = 本章已经出声；此后不再换路线（IMPL §3.4）
      this.pregPlaying = true;
      hilog.info(DOMAIN, TAG, 'preg playing key=%{public}s', this.pregPlayKey);
    }
    if (n < view.length) {
      view.fill(0, n);
      if (source.atEnd() && !this.pregEnded) {
        this.pregEnded = true;
        // 写回调里不能做重活（异步收尾 + 换章）→ 让出这一帧，并带上代次里的 key
        const key: string = this.pregPlayKey;
        setTimeout(() => {
          this.onPregEnded(key);
        }, 0);
      }
    }
    return audio.AudioDataCallbackResult.VALID;
  }

  private scheduleParagraphEnd(index: number): void {
    setTimeout(() => {
      this.onParagraphEnd(index);
    }, 0);
  }

  private onParagraphEnd(index: number): void {
    // 缓存路径没有段落边界回调（整章一份音频），章末走 onPregEnded
    if (this.pregMode || this.pregBuffering) {
      return;
    }
    if (!this.playing || index !== this.paragraphs.length - 1) {
      return;
    }
    const next: number = nextReadable(this.chapters, this.chapterIndex);
    if (next < 0) {
      this.setPlaying(false);
      this.clearTimer();
      this.stopFlushTimer();
      this.stopProgressTimer();
      this.stopBackground();
      if (this.renderer !== undefined) {
        this.renderer.pause().catch((err: BusinessError) => {
        });
      }
      this.updatePlaybackState(avSession.PlaybackState.PLAYBACK_STATE_COMPLETED);
      return;
    }
    this.loadChapter(next, false, true);
  }

  // ── Transport controls ────────────────────────────────────────

  pause(): void {
    if (!this.active || !this.playing) {
      return;
    }
    hilog.info(DOMAIN, TAG, 'pause');
    this.setPlaying(false);
    if (this.engine !== undefined) {
      try {
        this.engine.stop();
      } catch (err) {
      }
    }
    this.stopFlushTimer();
    this.stopProgressTimer();
    // Keep the flushed PCM queue and its timeline: resuming replays it while the
    // dropped in-flight paragraphs are re-synthesized, so there is no silent
    // restart from the top of the paragraph.
    this.clearInflight();
    if (this.renderer !== undefined) {
      this.renderer.pause().catch((err: BusinessError) => {
      });
    }
    this.stopBackground();
    this.updatePlaybackState(avSession.PlaybackState.PLAYBACK_STATE_PAUSE);
  }

  resume(): void {
    if (!this.active || this.playing) {
      return;
    }
    // Natural completion drained every paragraph; restart the chapter so the
    // play button is not a silent no-op after the book ends.
    if (this.pregMode) {
      // 缓存路径：文件位置就是暂停处，直接续（别重开文件 / 重下整章）
      if (this.pregSource === undefined || this.pregEnded) {
        this.beginFrom(0);
        return;
      }
    } else if (this.queueExhausted()) {
      this.beginFrom(0);
      return;
    }
    hilog.info(DOMAIN, TAG, 'resume');
    this.error = '';
    this.setPlaying(true);
    this.playStartWallMs = Date.now() - this.elapsedMs;
    this.startBackground();
    this.ensureSynthesized();
    if (!this.pregMode) {
      this.startFlushTimer();
    }
    this.startProgressTimer();
    this.updatePlaybackState(avSession.PlaybackState.PLAYBACK_STATE_PLAY);
    const renderer: audio.AudioRenderer | undefined = this.renderer;
    if (this.pregMode && this.pregReady) {
      // 缓存音频在下暂停期间就绪：断点已摆好，现在把渲染器拉起来
      this.pregReady = false;
      this.startProgressTimer();
      this.startPregRenderer(this.pregSeq);
      this.updatePlaybackState(avSession.PlaybackState.PLAYBACK_STATE_PLAY);
      return;
    }
    if (renderer === undefined) {
      this.beginFrom(this.currentIndex);
      return;
    }
    // Resume the renderer where it stopped; do NOT pause/flush (that would drop
    // the buffered audio and manufacture an underrun).
    renderer.start().catch((err: BusinessError) => {
      hilog.warn(DOMAIN, TAG, 'renderer resume failed code=%{public}d', err.code);
      setTimeout(() => {
        if (this.playing && this.renderer !== undefined) {
          this.renderer.start().catch((retry: BusinessError) => {
            hilog.warn(DOMAIN, TAG, 'renderer resume retry failed code=%{public}d', retry.code);
          });
        }
      }, 60);
    });
  }

  toggle(): void {
    if (this.playing) {
      this.pause();
    } else {
      this.resume();
    }
  }

  /** Previous/next chapter (not paragraph): the transport buttons and the lock
 *  screen media keys jump a whole chapter, matching the control icons. */
  next(): void {
    if (!this.active) {
      return;
    }
    const chapter: number = nextReadable(this.chapters, this.chapterIndex);
    if (chapter < 0) {
      return;
    }
    this.loadChapter(chapter, false, this.playing);
  }

  prev(): void {
    if (!this.active) {
      return;
    }
    const chapter: number = prevReadable(this.chapters, this.chapterIndex);
    if (chapter < 0) {
      return;
    }
    this.loadChapter(chapter, false, this.playing);
  }

  seekParagraph(index: number): void {
    if (!this.active) {
      return;
    }
    this.beginFrom(index);
  }

  jumpChapter(index: number): void {
    if (!this.active || !isReadable(this.chapters, index)) {
      return;
    }
    this.loadChapter(index, false, this.playing);
  }

  private seekByTime(time: number): void {
    if (!this.active || this.totalChars === 0) {
      return;
    }
    if (this.pregMode) {
      // 缓存路径的时间轴已经是音频源时间（与上报给锁屏的 position 同单位），
      // 直接查表到段落头（章内对齐，见 IMPL §3.3）
      this.beginFrom(this.paragraphAt(time));
      return;
    }
    const targetChars: number = (time / 1000) * CHARS_PER_SECOND * this.speed;
    let index: number = 0;
    for (let i = 0; i < this.prefixChars.length; i++) {
      if (this.prefixChars[i] <= targetChars) {
        index = i;
      } else {
        break;
      }
    }
    this.beginFrom(index);
  }

  // ── Settings ──────────────────────────────────────────────────

  setSpeed(value: number): void {
    this.speed = Math.min(2.0, Math.max(0.5, value));
    const ctx: common.UIAbilityContext | undefined = this.ctx;
    if (ctx !== undefined) {
      putNumber(ctx, KEY_TTS_SPEED, this.speed);
    }
    if (this.pregMode) {
      // 缓存音频已经把语速烘死了（PREGEN_SPEED），只能在渲染器上改倍速
      this.applyPregRate();
      this.updateMetadata();
      this.updatePlaybackStateFromPlaying();
      return;
    }
    if (this.active && this.playing && this.engineKind === TTS_ENGINE_REMOTE) {
      // Remote PCM arrives already spoken at the new rate, so there is nothing to
      // re-pitch locally: drop the not-yet-enqueued buffers and re-request them.
      // Audio already handed to the renderer keeps playing, so no gap.
      this.clearInflight();
      this.ensureSynthesized();
    } else if (this.active && this.playing && this.engine !== undefined) {
      // `speed` is a per-`speak()` parameter, so no re-synthesis of the whole
      // paragraph is needed: drop only the not-yet-flushed requests and re-issue
      // them at the new speed while the buffered audio keeps playing.
      try {
        this.engine.stop();
      } catch (err) {
      }
      this.clearInflight();
      this.ensureSynthesized();
    }
    this.updateMetadata();
    this.updatePlaybackStateFromPlaying();
  }

  async setVoice(person: number): Promise<void> {
    if (person === this.voice || this.voiceSwitching) {
      return;
    }
    const previous: number = this.voice;
    this.voice = person;
    const ctx: common.UIAbilityContext | undefined = this.ctx;
    if (ctx !== undefined) {
      putNumber(ctx, KEY_TTS_VOICE, person);
    }
    const old: textToSpeech.TextToSpeechEngine | undefined = this.engine;
    if (old === undefined) {
      return;
    }
    this.voiceSwitching = true;
    try {
      const wasPlaying: boolean = this.playing;
      try {
        old.stop();
      } catch (err) {
      }
      this.clearInflight();
      // Build the new engine first so the already-buffered audio keeps playing
      // while it boots; only then retire the old engine. `person` is fixed at
      // createEngine time, so a rebuild is unavoidable, but it no longer costs
      // a fixed pause + 120ms wait + restart-from-paragraph-top.
      this.engine = undefined;
      try {
        await this.ensureEngine();
      } catch (err) {
        this.engine = old;
        this.voice = previous;
        if (ctx !== undefined) {
          putNumber(ctx, KEY_TTS_VOICE, previous);
        }
        this.error = '该音色尚未下载';
        return;
      }
      try {
        old.shutdown();
      } catch (err) {
      }
      if (wasPlaying) {
        this.ensureSynthesized();
      }
    } finally {
      this.voiceSwitching = false;
    }
  }

  /** Switch the remote zero-shot voice; no local model re-init needed (server-side). */
  setRemoteVoice(voice: string): void {
    if (voice === this.remoteVoice) {
      return;
    }
    this.remoteVoice = voice;
    const ctx: common.UIAbilityContext | undefined = this.ctx;
    if (ctx !== undefined) {
      putString(ctx, KEY_TTS_REMOTE_VOICE, voice);
    }
    if (this.active && this.playing && this.engineKind === TTS_ENGINE_REMOTE) {
      this.beginFrom(this.currentIndex);
    }
  }

  /** Timer in minutes; <= 0 turns it off. */
  setTimer(minutes: number): void {
    this.clearTimer();
    if (minutes <= 0) {
      return;
    }
    this.timerRemain = minutes * 60;
    this.tickId = setInterval(() => {
      if (this.timerRemain <= 1) {
        hilog.info(DOMAIN, TAG, 'timer fired, pausing');
        this.clearTimer();
        this.pause();
      } else {
        this.timerRemain -= 1;
      }
    }, 1000);
  }

  private clearTimer(): void {
    if (this.tickId >= 0) {
      clearInterval(this.tickId);
      this.tickId = -1;
    }
    if (this.timerId >= 0) {
      clearTimeout(this.timerId);
      this.timerId = -1;
    }
    this.timerRemain = 0;
  }

  // ── AVSession state / metadata ────────────────────────────────

  private updateMetadata(): void {
    const session: avSession.AVSession | undefined = this.session;
    const book: Book | undefined = this.book;
    if (session === undefined || book === undefined) {
      return;
    }
    const artist: string = book.author.length > 0 && book.name.indexOf(book.author) < 0
      ? book.name + ' · ' + book.author
      : book.name;
    const meta: avSession.AVMetadata = {
      assetId: book.bookId + '#' + this.chapterIndex.toString(),
      title: this.chapterTitle,
      artist: artist,
      subtitle: book.name,
      duration: this.estimateDurationMs()
    };
    const t0: number = Date.now();
    session.setAVMetadata(meta).then(() => {
      const dt: number = Date.now() - t0;
      if (dt >= AV_SLOW_MS) {
        hilog.warn(DOMAIN, TAG, 'setAVMetadata slow %{public}d ms', dt);
      }
    }).catch((err: BusinessError) => {
      hilog.warn(DOMAIN, TAG, 'setAVMetadata failed code=%{public}d msg=%{public}s', err.code, err.message);
    });
  }

  private updatePlaybackState(state: avSession.PlaybackState): void {
    const session: avSession.AVSession | undefined = this.session;
    if (session === undefined) {
      return;
    }
    const playback: avSession.AVPlaybackState = {
      state: state,
      speed: this.effectiveRate(),
      position: {
        elapsedTime: this.elapsedMs,
        updateTime: Date.now()
      },
      duration: this.estimateDurationMs()
    };
    const t0: number = Date.now();
    session.setAVPlaybackState(playback).then(() => {
      const dt: number = Date.now() - t0;
      if (dt >= AV_SLOW_MS) {
        hilog.warn(DOMAIN, TAG, 'setAVPlaybackState slow %{public}d ms state=%{public}d', dt, state);
      }
    }).catch((err: BusinessError) => {
      hilog.warn(DOMAIN, TAG, 'setAVPlaybackState failed code=%{public}d msg=%{public}s state=%{public}d',
        err.code, err.message, state);
    });
  }

  private updatePlaybackStateFromPlaying(): void {
    this.updatePlaybackState(this.playing
      ? avSession.PlaybackState.PLAYBACK_STATE_PLAY
      : avSession.PlaybackState.PLAYBACK_STATE_PAUSE);
  }

  /**
   * 「缓存优先播放」开关（听书设置）：改完**下一次进章**生效（本章不换路线，见 IMPL §3.4）。
   * 关掉之后所有章节都走实时 VITS——排查缓存链路用。
   */
  setPregenPrefer(value: boolean): void {
    this.prefPregenPrefer = value;
    const ctx: common.UIAbilityContext | undefined = this.ctx;
    if (ctx !== undefined) {
      putBoolean(ctx, KEY_TTS_PREGEN_PREFER, value);
    }
  }

  /** 「仅 Wi-Fi 时预生成」：进章时的下载不拦（那是用户当下要听），只拦后台预取。 */
  setPregenWifiOnly(value: boolean): void {
    this.prefPregenWifiOnly = value;
    const ctx: common.UIAbilityContext | undefined = this.ctx;
    if (ctx !== undefined) {
      putBoolean(ctx, KEY_TTS_PREGEN_WIFI_ONLY, value);
    }
  }

  /**
   * 当前的实际播放速率。实时链路把语速烘在 PCM 里（`effectiveSpeed`），缓存链路在
   * 渲染器上改倍速（`pregPlaybackRate`）；锁屏与「听感」小字都用这个值。
   */
  effectiveRate(): number {
    if (this.pregMode) {
      return pregPlaybackRate(this.speed);
    }
    return effectiveSpeed(this.speed, this.engineKind);
  }

  estimateDurationMs(): number {
    // 缓存章有真实时长（整章一份），比按字数估的准
    if (this.pregMode && this.pregSource !== undefined) {
      return this.pregSource.durationMs();
    }
    if (this.paragraphCount <= 0 || this.totalChars === 0) {
      return 0;
    }
    return (this.totalChars / (CHARS_PER_SECOND * this.speed)) * 1000;
  }

  // ── 预生成缓存路径（设计 / 契约见 docs/research/TTS-PREGEN-IMPL.md）────────
  //
  // 进章前定路线（`chapterAudioRoute`），出声之后不再改：缓存是 24 kHz GPT-SoVITS，
  // 系统 TTS 是 16 kHz，混着放会变调；**出声之前**失败（404/超时/开文件失败）才退回实时。

  /** 缓存章：整章下载到本地 → 建段落时间轴 → 从段落头开播。 */
  private startPregChapter(key: string, target: number, seq: number): void {
    const ctx: common.UIAbilityContext | undefined = this.ctx;
    if (ctx === undefined) {
      this.abandonCachePath(seq, target, 'no-ctx');
      return;
    }
    this.pregBuffering = true;
    this.pregBytes = 0;
    // 只留本章这一份（下一章会在 prefetchNextPreg 里落到同一目录，最多两份）
    sweepPregFiles(ctx, [key]);
    loadPregAudio(this.serverUrl, this.apiKey, ctx, key, (bytes: number): void => {
      if (seq === this.pregSeq) {
        this.pregBytes = bytes;
      }
    }).then((audio: PregAudio): void => {
      if (seq !== this.pregSeq || !this.active) {
        return;
      }
      this.pregBuffering = false;
      this.pregBytes = 0;
      this.installPregTimeline(audio);
      try {
        this.pregSource = new PregAudioSource(audio.path);
      } catch (err) {
        this.pregSource = undefined;
        this.abandonCachePath(seq, target, 'open');
        return;
      }
      this.playPregFrom(target, seq);
      this.prefetchNextPreg();
    }).catch((err: Error): void => {
      if (seq !== this.pregSeq || !this.active) {
        return;
      }
      this.pregBuffering = false;
      const e: PregenError = err as PregenError;
      const kind: string = e.kind !== undefined ? e.kind : 'unknown';
      hilog.warn(DOMAIN, TAG, 'preg audio failed kind=%{public}s msg=%{public}s',
        kind, pregenErrorMessage(kind, e.message));
      if (kind === 'notfound') {
        // `notfound` 只说明「**现在**拿不到」：① job 还没算完（等几分钟就有）② 音频真没了（听完删过 / 被淘汰）。
        // 键是**内容寻址**的 ⇒ 一律留住：① 算好了（或重新提交同一章）还是同一条 key，下次进章就命中；
        // ② 留着也无害，只多一次注定 404 的请求。作废却会把刚付了算力的缓存永久丢掉（本地书尤其，
        // 那边正文不进缓存、只靠旁路存键）。`pending=` 只用于日志区分两种 notfound（不改变行为）。
        hilog.info(DOMAIN, TAG, 'preg key kept key=%{public}s why=notfound pending=%{public}d',
          key, isPregKeyPending(key) ? 1 : 0);
      }
      this.abandonCachePath(seq, target, kind);
    });
  }

  /** 缓存路径在**出声之前**失败：退回实时，用户感知不到声线变化。 */
  private abandonCachePath(seq: number, target: number, why: string): void {
    if (seq !== this.pregSeq || !this.active) {
      return;
    }
    hilog.warn(DOMAIN, TAG, 'preg fallback=realtime why=%{public}s para=%{public}d', why, target);
    this.releasePregAudio();
    this.currentIndex = target;
    this.paragraphIndex = target;
    this.issuedIndex = target;
    this.flushIndex = target;
    // 退回实时前把渲染器换回 16 kHz（刚才按缓存章建的是 24 kHz）
    this.ensureRenderRate(SAMPLE_RATE_SYSTEM).then((): void => {
      if (seq !== this.pregSeq || !this.active) {
        return;
      }
      this.startRealtime();
    }).catch((): void => {
    });
  }

  /**
   * 从段落 `target` 起放整章音频（seek 靠文件读指针，渲染器只负责重新拉数据）。
   * 下载期间有可能被暂停：那就只把断点摆好，`resume()` 再把渲染器拉起来。
   */
  private playPregFrom(target: number, seq: number): void {
    const source: PregAudioSource | undefined = this.pregSource;
    if (source === undefined) {
      return;
    }
    this.pregMode = true;
    this.pregEnded = false;
    this.pregPlaying = false;
    this.pregReady = true;
    // 先停抽水：从实时章换过来时渲染器还在跑，它可能抢在 pause/flush 前把
    // seek 位置之后的字节读走（那几帧随后被 flush 丢掉 = 丢音频）。
    this.pregPump = false;
    this.pregSeekBaseMs = this.timelineStartMs(target);
    this.pregSeekWallMs = Date.now();
    this.pregSeekFramePos = -1;
    source.seekMs(this.pregSeekBaseMs);
    this.elapsedMs = this.pregSeekBaseMs;
    this.paragraphIndex = target;
    this.currentIndex = target;
    this.applyPregRate();
    this.updateMetadata();
    // 注意：hilog 不支持 `%f`（会原样打出 `}f`），倍速自己格成字符串。
    hilog.info(DOMAIN, TAG, 'preg play para=%{public}d base=%{public}d rate=%{public}s',
      target, this.pregSeekBaseMs, pregPlaybackRate(this.speed).toFixed(2));
    if (!this.playing) {
      hilog.info(DOMAIN, TAG, 'preg ready while paused para=%{public}d', target);
      return;
    }
    this.startProgressTimer();
    this.startPregRenderer(seq);
    this.updatePlaybackState(avSession.PlaybackState.PLAYBACK_STATE_PLAY);
  }

  /**
   * 把渲染器拉回「从头喂」的状态：flush 掉实时链路的残留队列，再 start；
   * 真正的断点位置在文件读指针上（`source.seekMs`），渲染器没有 seek API。
   */
  private async startPregRenderer(seq: number): Promise<void> {
    const renderer: audio.AudioRenderer | undefined = this.renderer;
    if (renderer === undefined) {
      this.abandonCachePath(seq, this.currentIndex, 'no-renderer');
      return;
    }
    try {
      await renderer.pause();
    } catch (err) {
    }
    try {
      await renderer.flush();
    } catch (err) {
    }
    if (seq !== this.pregSeq || !this.pregMode) {
      return;
    }
    try {
      await renderer.start();
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'preg renderer start failed code=%{public}d', e.code);
    }
    if (seq !== this.pregSeq || !this.pregMode) {
      return;
    }
    // 基准在 start 之后取：flush/start 可能把 framePos 清零也可能继续累加，
    // 进度只算「此刻起的增量」，两种平台行为都对。
    this.pregSeekFramePos = this.framePos();
    this.pregSeekWallMs = Date.now();
    this.pregReady = false;
    this.pregPump = true;
  }

  /** 缓存音频的语速烘死在服务端，只能在渲染器上改倍速（见 `pregPlaybackRate`）。 */
  private applyPregRate(): void {
    const renderer: audio.AudioRenderer | undefined = this.renderer;
    if (renderer === undefined) {
      return;
    }
    try {
      renderer.setSpeed(pregPlaybackRate(this.speed));
      // 变速的验收判据（IMPL §4.2 第 4 项）：改语速**不重下**，只改这里的倍速
      hilog.info(DOMAIN, TAG, 'preg rate=%{public}s', pregPlaybackRate(this.speed).toFixed(2));
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'preg setSpeed failed code=%{public}d', e.code);
    }
  }

  /** 块锚点 → 段落时间轴；拿不到锚点就按字数摊平（高亮边界会偏，但不会错乱）。 */
  private installPregTimeline(audio: PregAudio): void {
    const timings: PregenTiming[] = pregTimeline(audio.chunks, this.paragraphs, audio.audioMs);
    this.timeline = [];
    for (const seg of timings) {
      this.timeline.push(new ParagraphTiming(seg.index, seg.startMs, seg.endMs));
    }
    if (timings.length > 0) {
      const last: PregenTiming = timings[timings.length - 1];
      if (last.index !== this.paragraphs.length - 1) {
        // 服务端存的正文与本地解析出的段落数不一致（正文变了）：音频照放，
        // 高亮会停在最后一段——日志里留证据，不静默
        hilog.warn(DOMAIN, TAG, 'preg timeline covers=%{public}d/%{public}d',
          last.index + 1, this.paragraphs.length);
      }
    }
  }

  /** 段落 `index` 在整章音频里的起点（源时间 ms）；找不到就当章头。 */
  private timelineStartMs(index: number): number {
    for (const seg of this.timeline) {
      if (seg.index === index) {
        return seg.startMs;
      }
    }
    return 0;
  }

  /** 整章音频放完（`fill` 读到文件尾）：听完即删，再进下一章。 */
  private onPregEnded(key: string): void {
    if (!this.active || !this.playing || !this.pregMode || key !== this.pregPlayKey) {
      return;
    }
    hilog.info(DOMAIN, TAG, 'preg chapter end key=%{public}s', key);
    this.completePregChapter(key);
    const next: number = nextReadable(this.chapters, this.chapterIndex);
    if (next < 0) {
      this.setPlaying(false);
      this.clearTimer();
      this.stopProgressTimer();
      this.stopBackground();
      if (this.renderer !== undefined) {
        this.renderer.pause().catch((err: BusinessError) => {
        });
      }
      this.updatePlaybackState(avSession.PlaybackState.PLAYBACK_STATE_COMPLETED);
      return;
    }
    this.loadChapter(next, false, true);
  }

  /**
   * 听完即删：本地音频 + 服务端缓存 + 章节缓存里的键。
   *
   * 删服务端是为了让「生成完就一直占着盘」不会积累（用户重听同一章会重新生成或
   * 退回实时，见 IMPL §3.4）；本地那份顺手删是因为键已经没了。
   */
  private completePregChapter(key: string): void {
    const ctx: common.UIAbilityContext | undefined = this.ctx;
    if (ctx !== undefined) {
      deletePregFile(ctx, key);
    }
    deletePregCache(this.serverUrl, this.apiKey, key).catch((err: Error): void => {
    });
    if (key === this.pregPlayKey) {
      this.invalidatePregKey();
    }
  }

  /** 把当前章的预生成键从章节缓存里抹掉（服务端已无对应音频）。 */
  private invalidatePregKey(): void {
    const ctx: common.UIAbilityContext | undefined = this.ctx;
    const book: Book | undefined = this.book;
    this.pregPlayKey = '';
    if (ctx === undefined || book === undefined || this.chapterIndex < 0
      || this.chapterIndex >= this.chapters.length) {
      return;
    }
    try {
      clearChapterPregKey(ctx, book.bookId, this.chapterIndex, this.chapters[this.chapterIndex].url);
    } catch (err) {
    }
  }

  /** 当前章开播之后，后台把下一章备到本地；失败无所谓（正常走下载 / 实时）。 */
  private prefetchNextPreg(): void {
    const ctx: common.UIAbilityContext | undefined = this.ctx;
    if (ctx === undefined || !this.prefPregenPrefer) {
      return;
    }
    if (this.prefPregenWifiOnly && !onWifi()) {
      hilog.info(DOMAIN, TAG, 'preg prefetch skipped (wifi-only)');
      return;
    }
    const next: number = nextReadable(this.chapters, this.chapterIndex);
    if (next < 0) {
      return;
    }
    const key: string = this.lookupPregKey(next);
    if (key.length === 0 || key === this.pregPlayKey) {
      return;
    }
    hilog.info(DOMAIN, TAG, 'preg prefetch next=%{public}d key=%{public}s', next, key);
    loadPregAudio(this.serverUrl, this.apiKey, ctx, key, (bytes: number): void => {
    }).then((audio: PregAudio): void => {
      // 预取只要落盘，时间轴等真正进章时再装
      hilog.info(DOMAIN, TAG, 'preg prefetch ready ms=%{public}d', audio.audioMs);
    }).catch((err: Error): void => {
      const e: PregenError = err as PregenError;
      hilog.warn(DOMAIN, TAG, 'preg prefetch failed msg=%{public}s', e.message);
    });
  }

  /** 放掉当前章的音频句柄（不动磁盘文件）：换章 / 停播 / 退实时都走这里。 */
  private releasePregAudio(): void {
    const source: PregAudioSource | undefined = this.pregSource;
    this.pregSource = undefined;
    this.pregMode = false;
    this.pregPlaying = false;
    this.pregBuffering = false;
    this.pregReady = false;
    this.pregPump = false;
    this.pregBytes = 0;
    if (source !== undefined) {
      source.close();
    }
  }

  // ── Progress persistence ──────────────────────────────────────

  private persistProgress(): void {
    const book: Book | undefined = this.book;
    if (book === undefined || this.chapters.length === 0) {
      return;
    }
    saveProgress({
      bookId: book.bookId,
      chapterIndex: this.chapterIndex,
      chapterTitle: this.chapterTitle,
      paragraphIndex: this.paragraphIndex,
      charOffset: 0,
      percent: (this.chapterIndex + 1) / this.chapters.length,
      updatedAt: Date.now()
    }, ProgressWriter.TTS);
  }
}
