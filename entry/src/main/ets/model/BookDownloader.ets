import { common, wantAgent, WantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit';
import { notificationManager } from '@kit.NotificationKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { bookEngine } from '../engine/BookEngineNapi';
import { Book, BookSource, Chapter } from '../engine/types';
import { ENGINE_CONTENT_TIMEOUT_MS } from '../common/Const';
import { isLocalBook } from './LocalBook';
import { isBookInShelf } from './ShelfRepository';
import {
  BookDownloadState,
  clearDownloadManifest,
  deleteBookDownload,
  ensureBookDownloadDir,
  getDownloadedChapter,
  inspectDownload,
  writeDownloadedChapter,
  writeDownloadManifest
} from './DownloadStore';

const DOMAIN: number = 0x0000;
const TAG: string = 'WispReaderDownload';
const DATA_TRANSFER_MODE: string = 'dataTransfer';
const AUDIO_PLAYBACK_MODE: string = 'audioPlayback';
const PROGRESS_NOTIFY_INTERVAL_MS: number = 1000;
const TERMINAL_NOTIFICATION_ID: number = 4106;

class DownloadBackgroundLease {
  owned: boolean;
  taskId: number;
  notificationId: number;
  originalModes: string[];

  constructor(owned: boolean, taskId: number, notificationId: number, originalModes: string[]) {
    this.owned = owned;
    this.taskId = taskId;
    this.notificationId = notificationId;
    this.originalModes = originalModes;
  }
}

/**
 * Process-level full-book downloader.
 *
 * There is intentionally no persisted job state and no startup resume call. A
 * killed process leaves an incomplete directory, and the next manual action
 * clears it before fetching chapter one again.
 */
@ObservedV2
export class BookDownloader {
  private static shared: BookDownloader | undefined = undefined;

  static instance(): BookDownloader {
    if (BookDownloader.shared === undefined) {
      BookDownloader.shared = new BookDownloader();
    }
    return BookDownloader.shared;
  }

  @Trace running: boolean = false;
  @Trace bookId: string = '';
  @Trace bookName: string = '';
  @Trace done: number = 0;
  @Trace total: number = 0;
  @Trace failed: number = 0;
  @Trace message: string = '';
  /** Incremented whenever a terminal state changes the on-disk download status. */
  @Trace revision: number = 0;

  /** Identifies the accepted job; only `start()` advances it. */
  private jobSerial: number = 0;
  /** Invalidates the current request without hiding the job before it unwinds. */
  private cancelGeneration: number = 0;
  private cancelled: boolean = false;
  private runningTask: Promise<void> | undefined = undefined;
  private ctx: common.UIAbilityContext | undefined = undefined;
  private src: BookSource | undefined = undefined;
  private book: Book | undefined = undefined;
  private chapters: Chapter[] = [];
  private incremental: boolean = false;

  private backgroundOwned: boolean = false;
  private backgroundTaskId: number = -1;
  private notificationId: number = -1;
  private backgroundOriginalModes: string[] = [];
  private backgroundActive: boolean = false;
  private lastNotifyAt: number = 0;

  isActiveFor(bookId: string): boolean {
    return this.running && this.bookId === bookId;
  }

  /** Starts asynchronously and returns whether a new job was accepted. */
  start(
    ctx: common.UIAbilityContext,
    src: BookSource,
    book: Book,
    chapters: Chapter[]
  ): boolean {
    if (this.running || isLocalBook(book)) {
      return false;
    }
    let total: number = 0;
    for (let i = 0; i < chapters.length; i++) {
      if (chapters[i].isVolume !== true) {
        total += 1;
      }
    }
    if (total === 0) {
      return false;
    }
    this.jobSerial += 1;
    this.cancelGeneration += 1;
    this.cancelled = false;
    this.running = true;
    this.bookId = book.bookId;
    this.bookName = book.name;
    this.done = 0;
    this.total = total;
    this.failed = 0;
    this.message = '准备下载';
    this.revision += 1;
    this.ctx = ctx;
    this.src = src;
    this.book = book;
    this.chapters = chapters.slice();
    const job: number = this.jobSerial;
    const cancelGeneration: number = this.cancelGeneration;
    this.runningTask = this.run(job, cancelGeneration).finally((): void => {
      if (job === this.jobSerial) {
        this.running = false;
        this.runningTask = undefined;
        this.message = this.message.length > 0 ? this.message : '下载结束';
        this.revision += 1;
      }
    });
    return true;
  }

  /** Stop after the current chapter request returns; completed files are discarded on restart. */
  cancel(): void {
    if (!this.running) {
      return;
    }
    this.cancelled = true;
    this.cancelGeneration += 1;
    this.message = '正在取消';
    this.revision += 1;
  }

  cancelForBook(bookId: string): boolean {
    if (!this.isActiveFor(bookId)) {
      return false;
    }
    this.cancel();
    return true;
  }

  private async run(job: number, cancelGeneration: number): Promise<void> {
    const ctx: common.UIAbilityContext | undefined = this.ctx;
    const src: BookSource | undefined = this.src;
    const book: Book | undefined = this.book;
    if (ctx === undefined || src === undefined || book === undefined) {
      this.message = '下载失败：缺少运行环境';
      return;
    }
    try {
      if (!await isBookInShelf(book.bookId)) {
        this.message = '请先将书籍加入书架';
        return;
      }
      const state: BookDownloadState = inspectDownload(ctx, book, this.chapters);
      // Only a completed manifest can authorize reuse. A TOC with new or
      // changed chapters is updated in place; a cancelled/killed run has no
      // manifest and is restarted from scratch on the next manual download.
      this.incremental = state.canUpdate;
      if (state.canUpdate) {
        // The new manifest proves completion. Removing the old proof first makes
        // an interrupted update visibly incomplete instead of resumable.
        clearDownloadManifest(ctx, book.bookId);
      } else {
        deleteBookDownload(ctx, book.bookId);
      }
      ensureBookDownloadDir(ctx, book.bookId);
      this.message = '下载中';
      this.revision += 1;
      await this.ensureBackground(ctx);

      for (let i = 0; i < this.chapters.length; i++) {
        if (this.isCancelled(cancelGeneration)) {
          break;
        }
        const chapter: Chapter = this.chapters[i];
        if (chapter.isVolume === true) {
          continue;
        }
        try {
          const existing: string | undefined =
            this.incremental ? getDownloadedChapter(ctx, book.bookId, i, chapter.url) : undefined;
          if (existing === undefined) {
            const result = await bookEngine.content(src, chapter.url, ENGINE_CONTENT_TIMEOUT_MS);
            if (this.isCancelled(cancelGeneration)) {
              break;
            }
            if (result.content.trim().length === 0) {
              throw new Error('empty chapter');
            }
            writeDownloadedChapter(ctx, book.bookId, i, chapter.url, result.content);
          }
        } catch (err) {
          this.failed += 1;
          hilog.warn(DOMAIN, TAG, 'chapter failed book=%{public}s index=%{public}d msg=%{public}s',
            book.name, i, this.errorText(err as Error));
        }
        this.done += 1;
        await this.publishProgress(false, false);
      }

      if (this.isCancelled(cancelGeneration)) {
        this.message = '已取消下载';
      } else if (this.failed > 0) {
        this.message = '下载结束，' + this.failed.toString() + ' 章失败';
      } else {
        writeDownloadManifest(ctx, book, this.chapters);
        this.message = '下载完成';
      }
      hilog.info(DOMAIN, TAG,
        'download terminal book=%{public}s done=%{public}d total=%{public}d failed=%{public}d msg=%{public}s',
        book.name, this.done, this.total, this.failed, this.message);
      await this.publishProgress(true, true);
      await this.releaseBackground();
      await this.publishTerminalNotification();
    } catch (err) {
      const cancelled: boolean = job !== this.jobSerial || this.isCancelled(cancelGeneration);
      this.message = cancelled ? '已取消下载' : '下载失败：' + this.errorText(err as Error);
      hilog.warn(DOMAIN, TAG, 'download terminal book=%{public}s msg=%{public}s',
        book.name, this.message);
      await this.releaseBackground();
      await this.publishTerminalNotification();
    }
  }

  private isCancelled(generation: number): boolean {
    return this.cancelled || generation !== this.cancelGeneration;
  }

  private async ensureBackground(ctx: common.UIAbilityContext): Promise<void> {
    if (this.backgroundActive) {
      return;
    }
    try {
      const lease: DownloadBackgroundLease = await this.acquireBackground(ctx);
      this.backgroundOwned = lease.owned;
      this.backgroundTaskId = lease.taskId;
      this.notificationId = lease.notificationId;
      this.backgroundOriginalModes = lease.originalModes.slice();
      this.backgroundActive = this.notificationId >= 0;
      this.lastNotifyAt = 0;
      if (this.backgroundActive) {
        await this.publishProgress(true, false);
      }
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'download background unavailable msg=%{public}s',
        this.errorText(err as Error));
    }
  }

  private async acquireBackground(ctx: common.UIAbilityContext): Promise<DownloadBackgroundLease> {
    const existing: backgroundTaskManager.ContinuousTaskInfo | undefined = await this.findBackgroundTask(ctx);
    if (existing !== undefined) {
      const modes: string[] = existing.backgroundModes.slice();
      const hasData: boolean = modes.indexOf(DATA_TRANSFER_MODE) >= 0;
      const hasOther: boolean = modes.some((mode: string): boolean => mode !== DATA_TRANSFER_MODE);
      if (hasData && !hasOther) {
        return new DownloadBackgroundLease(true, this.continuousTaskId(existing), existing.notificationId, []);
      }
      if (hasData) {
        const original: string[] = modes.filter((mode: string): boolean => mode !== DATA_TRANSFER_MODE);
        return new DownloadBackgroundLease(
          false, this.continuousTaskId(existing), existing.notificationId, original
        );
      }
      const union: string[] = modes.slice();
      union.push(DATA_TRANSFER_MODE);
      const updated: backgroundTaskManager.ContinuousTaskNotification =
        await backgroundTaskManager.updateBackgroundRunning(ctx, union);
      return new DownloadBackgroundLease(
        false, this.continuousTaskId(updated), updated.notificationId, modes
      );
    }

    const agent: WantAgent = await this.downloadWantAgent();
    try {
      const started: backgroundTaskManager.ContinuousTaskNotification =
        await backgroundTaskManager.startBackgroundRunning(ctx, [DATA_TRANSFER_MODE], agent);
      return new DownloadBackgroundLease(
        true, this.continuousTaskId(started), started.notificationId, []
      );
    } catch (err) {
      const e = err as BusinessError;
      if (e.code !== 9800005) {
        throw new Error('continuous task start failed code=' + e.code.toString() + ' msg=' + e.message);
      }
      const updated: backgroundTaskManager.ContinuousTaskNotification =
        await backgroundTaskManager.updateBackgroundRunning(
          ctx, [AUDIO_PLAYBACK_MODE, DATA_TRANSFER_MODE]
        );
      return new DownloadBackgroundLease(
        false, this.continuousTaskId(updated), updated.notificationId, [AUDIO_PLAYBACK_MODE]
      );
    }
  }

  private async findBackgroundTask(
    ctx: common.UIAbilityContext
  ): Promise<backgroundTaskManager.ContinuousTaskInfo | undefined> {
    try {
      const tasks: backgroundTaskManager.ContinuousTaskInfo[] =
        await backgroundTaskManager.getAllContinuousTasks(ctx, true);
      for (let i = 0; i < tasks.length; i++) {
        if (tasks[i].backgroundModes.indexOf(AUDIO_PLAYBACK_MODE) >= 0) {
          return tasks[i];
        }
      }
      return tasks.length > 0 ? tasks[0] : undefined;
    } catch (err) {
      return undefined;
    }
  }

  private async downloadWantAgent(): Promise<WantAgent> {
    const info: wantAgent.WantAgentInfo = {
      wants: [{
        bundleName: 'com.lichtcui.wispreader',
        abilityName: 'EntryAbility'
      }],
      actionType: wantAgent.OperationType.START_ABILITY,
      requestCode: 4105,
      wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    };
    return wantAgent.getWantAgent(info);
  }

  private notificationTitle(): string {
    const name: string = typeof this.bookName === 'string' ? this.bookName.trim() : '';
    return name.length > 0 ? name : '未命名书籍';
  }

  private async publishProgress(force: boolean, terminal: boolean): Promise<boolean> {
    if (!this.backgroundActive || this.notificationId < 0) {
      return false;
    }
    if (!terminal && !this.running) {
      return false;
    }
    const now: number = Date.now();
    if (!force && this.lastNotifyAt > 0 && now - this.lastNotifyAt < PROGRESS_NOTIFY_INTERVAL_MS) {
      return true;
    }
    const total: number = this.total > 0 ? this.total : 1;
    const percent: number = Math.max(0, Math.min(100, Math.floor(this.done * 100 / total)));
    const progress: string = this.done.toString() + '/' + this.total.toString();
    const detail: string = terminal
      ? (this.failed > 0 ? '失败 ' + this.failed.toString() + ' 章' : this.message)
      : (this.failed > 0 ? progress + ' · 失败 ' + this.failed.toString() : progress);
    const template: notificationManager.NotificationTemplate = {
      name: 'downloadTemplate',
      data: {
        'title': this.notificationTitle(),
        'fileName': detail,
        'progressValue': terminal ? 100 : percent
      }
    };
    const request: notificationManager.NotificationRequest = {
      content: {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_SYSTEM_LIVE_VIEW,
        systemLiveView: {
          typeCode: 8,
          title: this.notificationTitle(),
          text: detail
        }
      },
      id: this.notificationId,
      notificationSlotType: notificationManager.SlotType.LIVE_VIEW,
      template: template
    };
    try {
      await notificationManager.publish(request);
      this.lastNotifyAt = now;
      return true;
    } catch (err) {
      const e = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'download notification failed code=%{public}d msg=%{public}s',
        e.code, e.message);
      await this.releaseBackground();
      return false;
    }
  }

  private async releaseBackground(): Promise<void> {
    const ctx: common.UIAbilityContext | undefined = this.ctx;
    const owned: boolean = this.backgroundOwned;
    const taskId: number = this.backgroundTaskId;
    const notificationId: number = this.notificationId;
    const originalModes: string[] = this.backgroundOriginalModes.slice();
    this.backgroundActive = false;
    this.backgroundOwned = false;
    this.backgroundTaskId = -1;
    this.notificationId = -1;
    this.backgroundOriginalModes = [];
    this.lastNotifyAt = 0;
    if (ctx === undefined) {
      return;
    }
    if (owned) {
      try {
        if (taskId >= 0 && deviceInfo.sdkApiVersion >= 21) {
          await backgroundTaskManager.stopBackgroundRunning(ctx, taskId);
        } else {
          await backgroundTaskManager.stopBackgroundRunning(ctx);
        }
      } catch (err) {
        hilog.warn(DOMAIN, TAG, 'download background stop failed');
      }
      if (notificationId >= 0) {
        try {
          await notificationManager.cancel(notificationId);
        } catch (err) {
          hilog.warn(DOMAIN, TAG, 'download notification cleanup failed');
        }
      }
      return;
    }
    if (originalModes.length > 0) {
      try {
        await backgroundTaskManager.updateBackgroundRunning(ctx, originalModes);
      } catch (err) {
        hilog.warn(DOMAIN, TAG, 'download background restore failed');
      }
    }
  }

  private async publishTerminalNotification(): Promise<void> {
    const detail: string = this.done.toString() + '/' + this.total.toString() +
      (this.failed > 0 ? ' · 失败 ' + this.failed.toString() + ' 章' : '') +
      ' · ' + this.message;
    const request: notificationManager.NotificationRequest = {
      content: {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
        normal: {
          title: this.notificationTitle(),
          text: detail
        }
      },
      id: TERMINAL_NOTIFICATION_ID,
      notificationSlotType: notificationManager.SlotType.CONTENT_INFORMATION
    };
    try {
      await notificationManager.publish(request);
    } catch (err) {
      const e = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'download terminal notification failed code=%{public}d msg=%{public}s',
        e.code, e.message);
    }
  }

  private continuousTaskId(value: backgroundTaskManager.ContinuousTaskInfo |
    backgroundTaskManager.ContinuousTaskNotification): number {
    const id: number | undefined = value.continuousTaskId;
    return id === undefined ? -1 : id;
  }

  private errorText(err: Error): string {
    return err !== undefined && err.message !== undefined && err.message.length > 0
      ? err.message
      : 'unknown error';
  }
}
