import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Book, BookSource, Chapter } from '../engine/types';
import { getBoolean, getNumber, getString } from '../common/Prefs';
import {
  KEY_TTS_PREGEN_AHEAD, KEY_TTS_PREGEN_VOICE, KEY_TTS_PREGEN_WIFI_ONLY,
  TTS_PREGEN_AHEAD_DEFAULT, TTS_PREGEN_VOICE_DEFAULT, TTS_PREGEN_WIFI_ONLY_DEFAULT,
  normalizePregenVoice
} from '../common/Const';
import { TtsController } from './TtsController';
import { getChapterPregKey, setChapterPregKey } from './ChapterCache';
import {
  PregenCollection, PregenCollectItem, PregenError, PregenFailure, PregenStatus, PregenSummary, PregKeyFix,
  collectPregenItems, fetchPregenStatus, healPregKeys, markPregKeyPending, onWifi, pregSummary, pregenErrorMessage, pregenProgressText,
  storePregKeys, submitPregen, toJobItems
} from './TtsPregen';

const DOMAIN: number = 0x0000;
const TAG: string = 'WispReaderTts';
/** 轮询间隔（IMPL §3.3）。一次查询是 ms 级，别做成忙轮询。 */
const POLL_MS: number = 5000;

/**
 * 预生成作业的**跟踪器**（T-TTS-7 阶段二）。只做三件事：提交 / 每 5 s 看进度 / 重试失败章节。
 *
 * 它是进程级单例：听书页被收起再打开时作业还在服务端跑，`@Trace` 的状态和轮询位置都还在
 * （`stopPolling` 只停定时器，不取消服务端作业——服务端没有取消接口，也不该有：合成到一半
 * 的章节停掉就是白烧 CPU）。
 */
@ObservedV2
export class TtsPregenRunner {
  private static shared: TtsPregenRunner | undefined = undefined;

  static instance(): TtsPregenRunner {
    if (TtsPregenRunner.shared === undefined) {
      TtsPregenRunner.shared = new TtsPregenRunner();
    }
    return TtsPregenRunner.shared;
  }

  /** 跟踪着一个作业（含已完成：界面继续显示结果/失败清单）。 */
  @Trace active: boolean = false;
  /** 正在读正文 / 提交（提交前的那几秒）。 */
  @Trace busy: boolean = false;
  /** 定时器在跑。 */
  @Trace polling: boolean = false;
  @Trace total: number = 0;
  @Trace done: number = 0;
  @Trace running: number = 0;
  @Trace queued: number = 0;
  @Trace failed: number = 0;
  @Trace expired: number = 0;
  @Trace currentTitle: string = '';
  @Trace message: string = '';
  @Trace failures: PregenFailure[] = [];

  private jobId: string = '';
  private timerId: number = -1;
  /** 本次作业的缓存键：job 到终态时用它撤销「还没算完」标记（见 `markPregKeyPending`）。 */
  private jobKeys: string[] = [];
  /** 本次提交的章条目（留 url 给状态纠偏；重启后为空 ⇒ 不纠不猜）。 */
  private collected: PregenCollectItem[] = [];
  private ctx: common.UIAbilityContext | undefined = undefined;
  private bookId: string = '';
  private baseUrl: string = '';
  private apiKey: string = '';

  /** 还有没跑完的条目（上次查询的 queued+running）。 */
  pending(): number {
    return this.queued + this.running;
  }

  /** 服务端那一行进度文案（`pregenProgressText` 的薄封装）。 */
  progressLine(): string {
    const summary: PregenSummary = {
      total: this.total, done: this.done, running: this.running, queued: this.queued,
      failed: this.failed, expired: this.expired, currentTitle: this.currentTitle, failures: this.failures
    };
    return pregenProgressText(summary);
  }

  /**
   * 提交「后续 N 章」。正文读取复用章节缓存（读不到就跳过，不报错整单），
   * 服务端返回的 key 立刻记回章节缓存——**下一章起就能走缓存播放**。
   */
  async startPregen(ctx: common.UIAbilityContext, tts: TtsController): Promise<void> {
    if (this.busy) {
      return;
    }
    const book: Book | undefined = tts.currentBook();
    const chapters: Chapter[] = tts.currentChapters();
    if (book === undefined || chapters.length === 0) {
      this.message = '还没有在听的书';
      return;
    }
    if (getBoolean(ctx, KEY_TTS_PREGEN_WIFI_ONLY, TTS_PREGEN_WIFI_ONLY_DEFAULT) && !onWifi()) {
      this.message = '「仅 Wi-Fi 时预生成」已开启：连上 Wi-Fi 或到听书设置里关掉';
      return;
    }
    const base: string = tts.serverBase().trim();
    if (base.length === 0) {
      this.message = '还没配置 TTS 服务器地址（听书设置里填）';
      return;
    }
    const from: number = tts.chapterIndex + 1;
    if (from >= chapters.length) {
      this.message = '已经是最后一章，没有可预生成的了';
      return;
    }
    const voice: string = normalizePregenVoice(getString(ctx, KEY_TTS_PREGEN_VOICE, TTS_PREGEN_VOICE_DEFAULT));
    const ahead: number = Math.max(getNumber(ctx, KEY_TTS_PREGEN_AHEAD, TTS_PREGEN_AHEAD_DEFAULT), 1);
    const src: BookSource | undefined = tts.currentSource();

    this.ctx = ctx;
    this.bookId = book.bookId;
    this.baseUrl = base;
    this.apiKey = tts.apiKeyValue();
    this.busy = true;
    this.failures = [];
    this.message = '正在读取正文…';
    try {
      const collection: PregenCollection = await collectPregenItems(ctx, src, book, chapters, from, ahead, voice);
      if (collection.items.length === 0) {
        this.message = '这几章读不到正文，先在线打开一次再试';
        return;
      }
      this.message = '正在提交 ' + collection.items.length.toString() + ' 章…';
      const result = await submitPregen(this.baseUrl, this.apiKey, toJobItems(book.bookId, collection.items, voice));
      const stored: number = storePregKeys(ctx, book.bookId, collection.items, result);
      this.collected = collection.items;
      hilog.info(DOMAIN, TAG,
        'preg submit jobId=%{public}s items=%{public}d stored=%{public}d evicted=%{public}d',
        result.jobId, collection.items.length, stored, result.evicted.length);
      this.jobId = result.jobId;
      this.jobKeys = [];
      for (const one of result.items) {
        this.jobKeys.push(one.key);
      }
      this.active = true;
      this.total = result.items.length;
      this.done = 0;
      this.running = 0;
      this.queued = result.items.length;
      this.failed = 0;
      this.expired = 0;
      this.currentTitle = '';
      this.message = stored === collection.items.length
        ? '已提交 ' + stored.toString() + ' 章'
        : '已提交 ' + collection.items.length.toString() + ' 章（' +
          (collection.items.length - stored).toString() + ' 章没记下缓存键，下次仍走实时）';
      this.refresh();
    } catch (err) {
      this.message = errorText(err as Error);
      hilog.warn(DOMAIN, TAG, 'preg submit failed: %{public}s', this.message);
    } finally {
      this.busy = false;
    }
  }

  /** 查一次状态并安排下一次（幂等：重复调用只保留一个定时器）。 */
  async refresh(): Promise<void> {
    if (this.jobId.length === 0 || this.ctx === undefined) {
      return;
    }
    try {
      const status: PregenStatus = await fetchPregenStatus(this.baseUrl, this.apiKey, this.jobId);
      this.apply(status);
    } catch (err) {
      const e: PregenError = err as PregenError;
      if (e.kind === 'notfound') {
        // 服务端作业记录被 prune（重启/太久）：别再 5 s 一次打 404。
        this.stopPolling();
        this.message = '服务端已丢掉这个作业记录（重启或过期），可重新点一次预生成';
        return;
      }
      this.message = errorText(err as Error);
      hilog.warn(DOMAIN, TAG, 'preg status failed: %{public}s', this.message);
      if (this.active) {
        this.schedule();
      }
    }
  }

  /** 页面上还有作业没跑完时重新挂上轮询（听书页收起再打开走这里）。 */
  resumePolling(): void {
    if (this.jobId.length === 0 || this.ctx === undefined) {
      return;
    }
    this.refresh();
  }

  /** 只停定时器：服务端的合成继续跑（没有取消接口，也不该打断已开工的块）。 */
  stopPolling(): void {
    this.clearTimer();
    this.polling = false;
    if (this.active) {
      this.message = '已停止查看进度（服务端仍在生成）';
    }
  }

  /** 重试失败/过期章节：重新读正文（走章节缓存）+ 重新提交。 */
  async retryFailed(ctx: common.UIAbilityContext, tts: TtsController): Promise<void> {
    if (this.busy) {
      return;
    }
    const book: Book | undefined = tts.currentBook();
    const chapters: Chapter[] = tts.currentChapters();
    if (book === undefined || this.failures.length === 0) {
      return;
    }
    if (book.bookId !== this.bookId) {
      this.message = '换书了，重试请在新书里点预生成';
      return;
    }
    this.ctx = ctx;
    this.busy = true;
    this.message = '正在重试 ' + this.failures.length.toString() + ' 章…';
    try {
      const voice: string = normalizePregenVoice(getString(ctx, KEY_TTS_PREGEN_VOICE, TTS_PREGEN_VOICE_DEFAULT));
      const collected: PregenCollectItem[] = [];
      for (const failure of this.failures) {
        const one: PregenCollection = await collectPregenItems(
          ctx, tts.currentSource(), book, chapters, failure.chapterIndex, 1, voice);
        for (const item of one.items) {
          collected.push(item);
        }
      }
      if (collected.length === 0) {
        this.message = '重试失败：这几章读不到正文';
        return;
      }
      const result = await submitPregen(this.baseUrl, this.apiKey, toJobItems(book.bookId, collected, voice));
      storePregKeys(ctx, book.bookId, collected, result);
      hilog.info(DOMAIN, TAG, 'preg retry jobId=%{public}s items=%{public}d', result.jobId, collected.length);
      this.jobId = result.jobId;
      this.failures = [];
      this.failed = 0;
      this.collected = collected;
      this.message = '已重新排队 ' + collected.length.toString() + ' 章';
      this.refresh();
    } catch (err) {
      this.message = errorText(err as Error);
    } finally {
      this.busy = false;
    }
  }

  /** 清空跟踪状态（换书/停止听书后界面回到「开始」）。 */
  reset(): void {
    this.clearTimer();
    this.clearPendingKeys();
    this.jobId = '';
    this.active = false;
    this.busy = false;
    this.polling = false;
    this.total = 0;
    this.done = 0;
    this.running = 0;
    this.queued = 0;
    this.failed = 0;
    this.expired = 0;
    this.currentTitle = '';
    this.message = '';
    this.failures = [];
    this.collected = [];
  }

  private apply(status: PregenStatus): void {
    const summary: PregenSummary = pregSummary(status);
    this.healKeys(status);
    this.total = status.total;
    this.done = status.done;
    this.running = status.running;
    this.queued = status.queued;
    this.failed = status.failed;
    this.expired = status.expired;
    this.currentTitle = summary.currentTitle;
    this.failures = summary.failures;
    this.active = true;
    this.message = pregenProgressText(summary);
    if (summary.queued + summary.running > 0) {
      this.polling = true;
      this.schedule();
    } else {
      this.polling = false;
      this.clearTimer();
      this.clearPendingKeys();
      hilog.info(DOMAIN, TAG, 'preg job done total=%{public}d done=%{public}d failed=%{public}d expired=%{public}d',
        summary.total, summary.done, summary.failed, summary.expired);
    }
  }

  /**
   * 用状态端点（带 bookId/chapterIndex）把键按章号写回去：提交响应里同名/无标题章
   * 配不上时在这里补，历史上配错的也在这里纠正。幂等（与已存键相同就不动盘）。
   */
  private healKeys(status: PregenStatus): void {
    const ctx: common.UIAbilityContext | undefined = this.ctx;
    if (ctx === undefined || this.collected.length === 0) {
      return;
    }
    const fixes: PregKeyFix[] = healPregKeys(this.collected, status, this.bookId);
    let healed: number = 0;
    for (const fix of fixes) {
      if (getChapterPregKey(ctx, this.bookId, fix.chapterIndex, fix.url) === fix.key) {
        continue;
      }
      if (setChapterPregKey(ctx, this.bookId, fix.chapterIndex, fix.url, fix.key)) {
        markPregKeyPending(fix.key, true);
        healed++;
      }
    }
    if (healed > 0) {
      hilog.info(DOMAIN, TAG, 'preg key healed n=%{public}d（按状态端点的章号纠偏）', healed);
    }
  }

  /** job 到终态：此后 `notfound` 就是「真没了」，可以作废键了。 */
  private clearPendingKeys(): void {
    for (let i = 0; i < this.jobKeys.length; i++) {
      markPregKeyPending(this.jobKeys[i], false);
    }
    this.jobKeys = [];
  }

  private schedule(): void {
    this.clearTimer();
    this.timerId = setTimeout((): void => {
      this.refresh();
    }, POLL_MS);
  }

  private clearTimer(): void {
    if (this.timerId >= 0) {
      clearTimeout(this.timerId);
      this.timerId = -1;
    }
  }
}

function errorText(err: Error): string {
  const e: PregenError = err as PregenError;
  if (e.kind !== undefined) {
    return pregenErrorMessage(e.kind, e.message);
  }
  return e.message;
}
