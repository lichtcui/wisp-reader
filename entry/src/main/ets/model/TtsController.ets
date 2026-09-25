import { common, wantAgent, WantAgent } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { audio } from '@kit.AudioKit';
import { textToSpeech } from '@kit.CoreSpeechKit';
import { avSession } from '@kit.AVSessionKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { Book, BookSource, Chapter } from '../engine/types';
import { isReadable, nextReadable, prevReadable } from '../common/ChapterUtil';
import { loadChapterParagraphs } from './BookContent';
import { saveProgress } from './ShelfRepository';
import { getNumber, putNumber } from '../common/Prefs';
import {
  KEY_TTS_SPEED,
  KEY_TTS_VOICE,
  TTS_SPEED_DEFAULT,
  TTS_VOICE_DEFAULT
} from '../common/Const';

const ENGINE_NAME: string = 'source-reader-tts';
const SESSION_TAG: string = 'source-reader-listen';
const DOMAIN: number = 0x0000;
const TAG: string = 'SourceReaderTts';
/** Rough offline-TTS reading rate used for the progress/time estimate. */
const CHARS_PER_SECOND: number = 5.0;
/** Paragraphs synthesized ahead of the playback head. */
const AHEAD: number = 2;
/** TTS `onComplete` may fire before the last `onData`; wait a moment before flushing. */
const FLUSH_GRACE_MS: number = 80;
const FLUSH_TICK_MS: number = 40;
/** PCM format: 16 kHz mono S16LE → 16000 frames (32000 bytes) per second. */
const FRAMES_PER_SECOND: number = 16000;
const BYTES_PER_SECOND: number = 32000;
/** UI progress refresh cadence, and how often the AVSession/DB state is pushed. */
const PROGRESS_TICK_MS: number = 200;
const STATE_PUSH_MS: number = 1000;

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

  private creating: boolean = false;
  private voiceSwitching: boolean = false;
  private bgRunning: boolean = false;
  private formatLogged: boolean = false;
  private timerId: number = -1;
  private tickId: number = -1;

  // ── Preferences / getters ─────────────────────────────────────

  private loadPrefs(): void {
    const ctx: common.UIAbilityContext | undefined = this.ctx;
    if (ctx === undefined) {
      return;
    }
    this.speed = getNumber(ctx, KEY_TTS_SPEED, TTS_SPEED_DEFAULT);
    this.voice = getNumber(ctx, KEY_TTS_VOICE, TTS_VOICE_DEFAULT);
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
    this.chapters = chapters;
    this.bookName = book.name;
    this.author = book.author;
    this.active = true;
    this.error = '';
    hilog.info(DOMAIN, TAG, 'start book=%{public}s chapter=%{public}d para=%{public}d',
      book.name, chapterIndex, paragraphIndex);
    try {
      await this.ensureEngine();
      await this.ensureSession();
      await this.ensureRenderer();
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'init failed');
      this.error = '听书初始化失败';
      this.active = false;
      this.playing = false;
      return;
    }
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
    this.playing = false;
    this.active = false;
    if (this.engine !== undefined) {
      try {
        this.engine.stop();
      } catch (err) {
      }
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
    const streamInfo: audio.AudioStreamInfo = {
      samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_16000,
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
      hilog.info(DOMAIN, TAG, 'renderer ready');
    } catch (err) {
      const e = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'renderer create failed code=%{public}d msg=%{public}s', e.code, e.message);
      throw new Error(e.message);
    }
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
    await session.activate();
    try {
      const wantAgentInfo: wantAgent.WantAgentInfo = {
        wants: [{
          bundleName: 'com.lichtcui.sourcereader',
          abilityName: 'EntryAbility'
        }],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      };
      const launch: WantAgent = await wantAgent.getWantAgent(wantAgentInfo);
      await session.setLaunchAbility(launch);
    } catch (err) {
    }
    this.session = session;
    hilog.info(DOMAIN, TAG, 'avsession ready');
  }

  private async startBackground(): Promise<void> {
    const ctx: common.UIAbilityContext | undefined = this.ctx;
    if (this.bgRunning || ctx === undefined) {
      return;
    }
    try {
      const wantAgentInfo: wantAgent.WantAgentInfo = {
        wants: [{
          bundleName: 'com.lichtcui.sourcereader',
          abilityName: 'EntryAbility'
        }],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      };
      const agent: WantAgent = await wantAgent.getWantAgent(wantAgentInfo);
      await backgroundTaskManager.startBackgroundRunning(
        ctx,
        backgroundTaskManager.BackgroundMode.AUDIO_PLAYBACK,
        agent
      );
      this.bgRunning = true;
      hilog.info(DOMAIN, TAG, 'background task started');
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
    backgroundTaskManager.stopBackgroundRunning(ctx).catch((err: BusinessError) => {
    });
    this.bgRunning = false;
  }

  // ── Content / synthesis queue ─────────────────────────────────

  private setChapter(index: number, title: string, paragraphs: string[]): void {
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
  }

  private async loadChapter(index: number, startAtEnd: boolean, autoplay: boolean): Promise<void> {
    if (!isReadable(this.chapters, index)) {
      this.playing = false;
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
      this.playing = false;
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
      this.playing = false;
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
    this.currentIndex = target;
    this.paragraphIndex = target;
    this.issuedIndex = target;
    this.flushIndex = target;
    this.playing = true;
    this.startBackground();
    this.persistProgress();
    hilog.info(DOMAIN, TAG, 'begin para=%{public}d', target);
    this.updatePlaybackState(avSession.PlaybackState.PLAYBACK_STATE_PLAY);
    this.ensureSynthesized();
    this.startFlushTimer();
    this.startProgressTimer();
    this.startRenderer();
  }

  /** Issue `speak()` for upcoming paragraphs so playback has a small buffer. */
  private ensureSynthesized(): void {
    const engine: textToSpeech.TextToSpeechEngine | undefined = this.engine;
    if (engine === undefined || !this.playing) {
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
        this.playing = false;
        break;
      }
      this.issuedIndex++;
    }
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
    this.playing = false;
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
    const renderer: audio.AudioRenderer | undefined = this.renderer;
    if (renderer !== undefined) {
      try {
        const info: audio.AudioTimestampInfo = renderer.getAudioTimestampInfoSync();
        return info.framePos / FRAMES_PER_SECOND * 1000;
      } catch (err) {
      }
    }
    return Math.max(Date.now() - this.playStartWallMs, 0);
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
    const durationMs: number = total / BYTES_PER_SECOND * 1000;
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

  private scheduleParagraphEnd(index: number): void {
    setTimeout(() => {
      this.onParagraphEnd(index);
    }, 0);
  }

  private onParagraphEnd(index: number): void {
    if (!this.playing || index !== this.paragraphs.length - 1) {
      return;
    }
    const next: number = nextReadable(this.chapters, this.chapterIndex);
    if (next < 0) {
      this.playing = false;
      this.stopFlushTimer();
      this.stopProgressTimer();
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
    this.playing = false;
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
    this.updatePlaybackState(avSession.PlaybackState.PLAYBACK_STATE_PAUSE);
  }

  resume(): void {
    if (!this.active || this.playing) {
      return;
    }
    hilog.info(DOMAIN, TAG, 'resume');
    this.error = '';
    this.playing = true;
    this.playStartWallMs = Date.now() - this.elapsedMs;
    this.startBackground();
    this.ensureSynthesized();
    this.startFlushTimer();
    this.startProgressTimer();
    this.updatePlaybackState(avSession.PlaybackState.PLAYBACK_STATE_PLAY);
    const renderer: audio.AudioRenderer | undefined = this.renderer;
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
    if (this.active && this.playing && this.engine !== undefined) {
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
    session.setAVMetadata(meta).catch((err: BusinessError) => {
    });
  }

  private updatePlaybackState(state: avSession.PlaybackState): void {
    const session: avSession.AVSession | undefined = this.session;
    if (session === undefined) {
      return;
    }
    const playback: avSession.AVPlaybackState = {
      state: state,
      speed: this.speed,
      position: {
        elapsedTime: this.elapsedMs,
        updateTime: Date.now()
      },
      duration: this.estimateDurationMs()
    };
    session.setAVPlaybackState(playback).catch((err: BusinessError) => {
    });
  }

  private updatePlaybackStateFromPlaying(): void {
    this.updatePlaybackState(this.playing
      ? avSession.PlaybackState.PLAYBACK_STATE_PLAY
      : avSession.PlaybackState.PLAYBACK_STATE_PAUSE);
  }

  estimateDurationMs(): number {
    if (this.paragraphCount <= 0 || this.totalChars === 0) {
      return 0;
    }
    return (this.totalChars / (CHARS_PER_SECOND * this.speed)) * 1000;
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
    });
  }
}