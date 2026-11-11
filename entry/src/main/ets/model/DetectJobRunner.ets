import { common, wantAgent, WantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit';
import { fileIo } from '@kit.CoreFileKit';
import { notificationManager } from '@kit.NotificationKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { DEFAULT_DETECT_KEYWORD, DETECT_BATCH_SIZE } from '../common/Const';
import { bookEngine } from '../engine/BookEngineNapi';
import { BookSource, DetectMode, DetectResult } from '../engine/types';
import { ensureSourceStore } from './SourceStoreMigration';
import {
  DetectPatch,
  EngineSource,
  listRows,
  patchDetects,
  SourceRow,
  sourcesForEngine
} from './SourceStore';
import {
  canonicalDetectSourceIds,
  cancelDetectJob,
  completeDetectBatch,
  decodeDetectJobState,
  DetectBatchLine,
  DetectBatchMap,
  DetectEngineVerdict,
  DetectJobSpec,
  DetectJobState,
  DetectJobTransition,
  DetectJsonlRecovery,
  DetectSourceIdentity,
  DetectStoredResult,
  detectJsonlCanContinue,
  detectJsonlSeparator,
  detectResultFileName,
  detectResultFilesToDelete,
  detectSourceState,
  encodeDetectBatchLine,
  encodeDetectJobState,
  failDetectJob,
  mapDetectBatchResults,
  matchesDetectFingerprint,
  nextDetectBatch,
  newDetectJobState,
  normalizeDetectMode,
  reconcileDetectCursor,
  recoverDetectJsonl,
  replayDetectBatchLinesForJob,
  startDetectJob,
  DETECT_MODE_FULL,
  DETECT_STATUS_IDLE,
  DETECT_STATUS_RUNNING
} from './DetectJob';

const DOMAIN: number = 0x0000;
const TAG: string = 'WispReaderDetect';
const DETECT_DIR: string = 'detect';
const JOB_FILE: string = 'job.json';
const DATA_TRANSFER_MODE: string = 'dataTransfer';
const AUDIO_PLAYBACK_MODE: string = 'audioPlayback';
const PROGRESS_NOTIFY_INTERVAL_MS: number = 30000;
const CANCEL_FEEDBACK_MIN_MS: number = 400;

export const DETECT_BACKGROUND_INACTIVE: string = 'inactive';
export const DETECT_BACKGROUND_REQUESTING: string = 'requesting';
export const DETECT_BACKGROUND_ACTIVE: string = 'active';
export const DETECT_BACKGROUND_DEGRADED: string = 'degraded';

class DetectBackgroundLease {
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

function detectPatches(results: DetectStoredResult[], at: number): DetectPatch[] {
  const patches: DetectPatch[] = [];
  for (let i = 0; i < results.length; i++) {
    const result: DetectStoredResult = results[i];
    patches.push({
      id: result.sourceId,
      state: detectSourceState(result.ok, result.stage),
      elapsedMs: result.elapsedMs,
      at: at
    });
  }
  return patches;
}

/**
 * Process-level detect job runner (T4.3).
 *
 * The frozen trace fields mirror DetectJob.TraceField exactly. The runner keeps
 * only the files directory, never an Ability context: each batch takes a fresh
 * getContext(), then drops it before the next await-heavy engine call.
 */
@ObservedV2
export class DetectJobRunner {
  private static shared: DetectJobRunner | undefined = undefined;

  static instance(): DetectJobRunner {
    if (DetectJobRunner.shared === undefined) {
      DetectJobRunner.shared = new DetectJobRunner();
    }
    return DetectJobRunner.shared;
  }

  @Trace status: string = DETECT_STATUS_IDLE;
  @Trace mode: string = DETECT_MODE_FULL;
  @Trace keyword: string = '';
  @Trace total: number = 0;
  @Trace done: number = 0;
  @Trace cursor: number = 0;
  @Trace batchSize: number = DETECT_BATCH_SIZE;
  @Trace startedAt: number = 0;
  @Trace updatedAt: number = 0;
  @Trace fingerprint: string = '';
  @Trace message: string = '';

  private job: DetectJobState = newDetectJobState();
  private filesDir: string = '';
  private resultNeedsSeparator: boolean = false;
  private starting: boolean = false;
  private runningTask: Promise<void> | undefined = undefined;
  private backgroundStateValue: string = DETECT_BACKGROUND_INACTIVE;
  private backgroundOwned: boolean = false;
  private backgroundTaskId: number = -1;
  private notificationId: number = -1;
  private backgroundOriginalModes: string[] = [];
  private backgroundGeneration: number = 0;
  private lastProgressNotifyAt: number = 0;

  /**
   * Start a round. With no `sourceIds`, the frozen set is all enabled sources.
   * Repeated calls while starting/running are ignored and return false.
   */
  async start(
    mode: string = DETECT_MODE_FULL,
    keyword: string = DEFAULT_DETECT_KEYWORD,
    sourceIds?: string[]
  ): Promise<boolean> {
    if (this.starting || this.runningTask !== undefined || this.job.status === DETECT_STATUS_RUNNING) {
      return false;
    }
    this.starting = true;
    try {
      const ctx: common.UIAbilityContext | undefined = this.currentContext();
      if (ctx === undefined) {
        hilog.warn(DOMAIN, TAG, 'detect start skipped: no ability context');
        return false;
      }
      this.filesDir = ctx.filesDir;
      await ensureSourceStore(ctx);
      const frozenIds: string[] = sourceIds === undefined
        ? await this.enabledSourceIds()
        : canonicalDetectSourceIds(sourceIds);
      const normalizedMode: string = normalizeDetectMode(mode);

      let base: DetectJobState = newDetectJobState();
      if (this.job.status === DETECT_STATUS_IDLE) {
        const persisted: DetectJobState | undefined = this.readPersistedJob(ctx.filesDir);
        if (persisted !== undefined && persisted.status === DETECT_STATUS_RUNNING) {
          persisted.sourceIds = frozenIds.slice();
          if (persisted.total === frozenIds.length &&
            matchesDetectFingerprint(persisted.fingerprint, frozenIds, normalizedMode, keyword)) {
            this.job = persisted;
            this.resultNeedsSeparator = false;
            if (!(await this.recoverRunning(ctx.filesDir))) {
              return true;
            }
            this.trimResultFiles(ctx.filesDir, this.job.startedAt);
            this.refreshTrace();
            await this.ensureBackground();
            if (this.job.status === DETECT_STATUS_RUNNING) {
              this.launch();
            }
            return true;
          }
          this.invalidateRunningJob(ctx.filesDir, persisted.startedAt, persisted.total !== frozenIds.length
            ? 'frozen source count mismatch'
            : 'fingerprint mismatch');
        } else if (persisted !== undefined) {
          base = persisted;
        }
      } else {
        base = this.job;
      }
      base.sourceIds = [];

      const now: number = this.nextRoundStamp(ctx.filesDir, base.startedAt);
      const started: DetectJobTransition = startDetectJob(
        base,
        new DetectJobSpec(frozenIds, normalizedMode, keyword, DETECT_BATCH_SIZE),
        now
      );
      if (!started.accepted) {
        hilog.warn(DOMAIN, TAG, 'detect start rejected: %{public}s', started.reason);
        return false;
      }
      this.job = started.state;
      const resumedExisting: boolean = base.status !== DETECT_STATUS_IDLE && base.startedAt === this.job.startedAt &&
        base.fingerprint === this.job.fingerprint;
      if (resumedExisting) {
        if (!(await this.recoverRunning(ctx.filesDir))) {
          return true;
        }
        this.trimResultFiles(ctx.filesDir, this.job.startedAt);
      } else {
        this.resultNeedsSeparator = false;
        this.createResultFile(ctx.filesDir, this.job.startedAt);
        this.trimResultFiles(ctx.filesDir, this.job.startedAt);
      }
      this.writeJob(ctx.filesDir);
      this.refreshTrace();
      hilog.info(DOMAIN, TAG,
        'detect job start status=%{public}s mode=%{public}s total=%{public}d cursor=%{public}d fingerprint=%{public}s',
        this.job.status, this.job.mode, this.job.total, this.job.cursor, this.job.fingerprint);
      if (this.job.status === DETECT_STATUS_RUNNING) {
        await this.ensureBackground();
      }
      if (this.job.status === DETECT_STATUS_RUNNING) {
        this.launch();
      }
      return true;
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'detect start failed: %{public}s', errorText(err as Error));
      await this.failWithoutContext(errorText(err as Error));
      return false;
    } finally {
      this.starting = false;
    }
  }

  /**
   * Load job.json once at process startup. A running job is resumed only when
   * its frozen fingerprint still matches the current enabled source set.
   */
  async restore(ctx?: common.UIAbilityContext): Promise<boolean> {
    if (this.starting || this.runningTask !== undefined || this.job.status === DETECT_STATUS_RUNNING) {
      return false;
    }
    this.starting = true;
    try {
      const active: common.UIAbilityContext | undefined = ctx === undefined ? this.currentContext() : ctx;
      if (active === undefined) {
        return false;
      }
      this.filesDir = active.filesDir;
      await ensureSourceStore(active);
      const persisted: DetectJobState | undefined = this.readPersistedJob(active.filesDir);
      if (persisted === undefined) {
        return false;
      }
      if (persisted.status !== DETECT_STATUS_RUNNING) {
        this.job = persisted;
        if (persisted.startedAt > 0) {
          this.trimResultFiles(active.filesDir, persisted.startedAt);
        }
        this.refreshTrace();
        return false;
      }
      const ids: string[] = await this.enabledSourceIds();
      if (persisted.total !== ids.length ||
        !matchesDetectFingerprint(persisted.fingerprint, ids, persisted.mode, persisted.keyword)) {
        this.invalidateRunningJob(active.filesDir, persisted.startedAt, persisted.total !== ids.length
          ? 'frozen source count mismatch'
          : 'fingerprint mismatch');
        return false;
      }
      persisted.sourceIds = ids;
      this.job = persisted;
      this.resultNeedsSeparator = false;
      if (!(await this.recoverRunning(active.filesDir))) {
        return true;
      }
      this.trimResultFiles(active.filesDir, this.job.startedAt);
      this.refreshTrace();
      hilog.info(DOMAIN, TAG,
        'detect job restored total=%{public}d cursor=%{public}d status=%{public}s',
        this.job.total, this.job.cursor, this.job.status);
      if (this.job.status === DETECT_STATUS_RUNNING) {
        await this.ensureBackground();
      }
      if (this.job.status === DETECT_STATUS_RUNNING) {
        this.launch();
      }
      return true;
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'detect restore failed: %{public}s', errorText(err as Error));
      return false;
    } finally {
      this.starting = false;
    }
  }

  /**
   * Cancel immediately stops dispatching the next batch. An in-flight engine
   * call may finish, and a complete JSONL batch line already persisted may be
   * recovered on resume; no further batch is requested after cancellation.
   */
  async cancel(): Promise<boolean> {
    const cancelled: DetectJobTransition = cancelDetectJob(this.job, Date.now());
    if (!cancelled.accepted) {
      return false;
    }
    this.job = cancelled.state;
    const filesDir: string = this.currentFilesDir();
    if (filesDir.length > 0) {
      try {
        this.writeJob(filesDir);
      } catch (err) {
        hilog.warn(DOMAIN, TAG, 'detect cancelled-state persistence error: %{public}s', errorText(err as Error));
      }
    }
    const releaseStartedAt: number = Date.now();
    try {
      // Keep the running trace visible while teardown finishes so the UI can
      // render its disabled "stopping" state instead of removing the control.
      await this.releaseBackground();
    } finally {
      const remainingFeedbackMs: number = CANCEL_FEEDBACK_MIN_MS - (Date.now() - releaseStartedAt);
      if (remainingFeedbackMs > 0) {
        await new Promise<void>((resolve: (value: void) => void): void => {
          setTimeout((): void => {
            resolve();
          }, remainingFeedbackMs);
        });
      }
      this.refreshTrace();
    }
    hilog.info(DOMAIN, TAG, 'detect job cancelled cursor=%{public}d', this.job.cursor);
    return true;
  }

  /** Resume a cancelled/failed round only while this process still holds its frozen ids. */
  canResume(): boolean {
    return (this.job.status === 'cancelled' || this.job.status === 'failed') &&
      this.job.sourceIds.length > 0 && this.runningTask === undefined && !this.starting;
  }

  /** Resume from the exact runtime source subset; persisted terminal jobs cannot fake this. */
  async resume(): Promise<boolean> {
    if (!this.canResume()) {
      return false;
    }
    return this.start(this.job.mode, this.job.keyword, this.job.sourceIds.slice());
  }

  /** Runtime-only background status for the later detect UI; not part of the trace contract. */
  runtimeBackgroundState(): string {
    return this.backgroundStateValue;
  }

  private currentContext(): common.UIAbilityContext | undefined {
    return getContext() as common.UIAbilityContext | undefined;
  }

  private currentFilesDir(): string {
    const ctx: common.UIAbilityContext | undefined = this.currentContext();
    return ctx === undefined ? this.filesDir : ctx.filesDir;
  }

  private async enabledSourceIds(): Promise<string[]> {
    const rows: SourceRow[] = await listRows({ enabled: true });
    const ids: string[] = [];
    for (let i = 0; i < rows.length; i++) {
      ids.push(rows[i].id.toString());
    }
    return canonicalDetectSourceIds(ids);
  }

  private launch(): void {
    if (this.runningTask !== undefined) {
      return;
    }
    this.runningTask = this.drain().finally((): void => {
      this.runningTask = undefined;
    });
  }

  private async drain(): Promise<void> {
    try {
      while (this.job.status === DETECT_STATUS_RUNNING) {
        await this.runBatch();
      }
    } catch (err) {
      const message: string = errorText(err as Error);
      hilog.warn(DOMAIN, TAG, 'detect batch failed: %{public}s', message);
      await this.failJob(message);
    } finally {
      await this.releaseBackground();
    }
  }

  private async runBatch(): Promise<void> {
    if (this.job.status !== DETECT_STATUS_RUNNING) {
      return;
    }
    // Keep only the path here so no Ability context survives the engine await.
    const filesDir: string = this.currentFilesDir();
    if (filesDir.length === 0) {
      throw new Error('detect runner has no files directory');
    }
    const cursor: number = this.job.cursor;
    const batchIds: string[] = nextDetectBatch(this.job);
    if (batchIds.length === 0) {
      throw new Error('running detect job produced an empty batch');
    }
    const numericIds: number[] = [];
    for (let i = 0; i < batchIds.length; i++) {
      const id: number = Number.parseInt(batchIds[i], 10);
      if (!Number.isInteger(id) || id <= 0) {
        throw new Error('invalid canonical source id: ' + batchIds[i]);
      }
      numericIds.push(id);
    }

    const engineRows: EngineSource[] = await sourcesForEngine(numericIds);
    if (this.job.status !== DETECT_STATUS_RUNNING) {
      return;
    }
    if (engineRows.length !== numericIds.length) {
      throw new Error('source batch changed while detect job was running: expected ' +
        numericIds.length.toString() + ', got ' + engineRows.length.toString());
    }
    const sources: BookSource[] = [];
    const identities: DetectSourceIdentity[] = [];
    for (let i = 0; i < engineRows.length; i++) {
      const row: EngineSource = engineRows[i];
      if (row.id !== numericIds[i]) {
        throw new Error('source batch order changed while detect job was running');
      }
      sources.push(row.source);
      identities.push(new DetectSourceIdentity(row.id, row.source.bookSourceUrl, row.source.bookSourceName));
    }

    // mode and keyword come from the frozen job state, never live settings.
    const detected: DetectResult[] = await bookEngine.detect(sources, this.job.keyword, this.job.mode as DetectMode);
    if (this.job.status !== DETECT_STATUS_RUNNING) {
      return;
    }
    const verdicts: DetectEngineVerdict[] = [];
    for (let i = 0; i < detected.length; i++) {
      const one: DetectResult = detected[i];
      verdicts.push(new DetectEngineVerdict(
        one.sourceUrl, one.sourceName, one.ok, one.stage, one.detail, one.contentLen, one.elapsedMs
      ));
    }
    const mapped: DetectBatchMap = mapDetectBatchResults(identities, verdicts);
    if (mapped.error.length > 0) {
      throw new Error(mapped.error);
    }
    if (mapped.results.length !== batchIds.length) {
      throw new Error('mapped detect result count mismatch');
    }

    const at: number = Date.now();
    const nextCursor: number = cursor + mapped.results.length;
    const line: DetectBatchLine = new DetectBatchLine(cursor, nextCursor, at, mapped.results);
    if (this.job.status !== DETECT_STATUS_RUNNING) {
      return;
    }
    this.appendBatchLine(filesDir, line);
    await patchDetects(detectPatches(mapped.results, at));

    if (this.job.status !== DETECT_STATUS_RUNNING) {
      return;
    }
    const completed: DetectJobTransition = completeDetectBatch(this.job, mapped.results.length, at);
    if (!completed.accepted) {
      throw new Error('detect cursor transition rejected: ' + completed.reason);
    }
    this.writeJobState(filesDir, completed.state);
    this.job = completed.state;
    this.resultNeedsSeparator = false;
    this.refreshTrace();
    hilog.info(DOMAIN, TAG,
      'detect batch cursor=%{public}d next=%{public}d status=%{public}s results=%{public}d',
      cursor, nextCursor, this.job.status, mapped.results.length);
    await this.publishProgress(false);
  }

  private async recoverRunning(filesDir: string): Promise<boolean> {
    if (this.job.status !== DETECT_STATUS_RUNNING) {
      return true;
    }
    const raw: string = this.readResultFile(filesDir, this.job.startedAt);
    const recovery: DetectJsonlRecovery = recoverDetectJsonl(raw);
    this.resultNeedsSeparator = detectJsonlSeparator(raw).length > 0;
    if (!detectJsonlCanContinue(recovery)) {
      await this.failJob('detect result JSONL is damaged and cannot be continued safely');
      return false;
    }
    if (recovery.contiguousCursor > this.job.cursor) {
      const replayed: DetectBatchLine[] | undefined =
        replayDetectBatchLinesForJob(recovery.lines, this.job.cursor, recovery.contiguousCursor, this.job.sourceIds);
      if (replayed === undefined) {
        await this.failJob('detect result JSONL cursor/source ids do not match the frozen job');
        return false;
      }
      for (let i = 0; i < replayed.length; i++) {
        if (this.job.status !== DETECT_STATUS_RUNNING) {
          return false;
        }
        const line: DetectBatchLine = replayed[i];
        await patchDetects(detectPatches(line.results, line.at));
      }
    }
    if (this.job.status !== DETECT_STATUS_RUNNING) {
      return false;
    }
    const reconciled: DetectJobTransition =
      reconcileDetectCursor(this.job, recovery.contiguousCursor, Date.now());
    if (!reconciled.accepted) {
      await this.failJob('detect cursor reconciliation rejected: ' + reconciled.reason);
      return false;
    }
    this.job = reconciled.state;
    this.writeJob(filesDir);
    this.refreshTrace();
    hilog.info(DOMAIN, TAG,
      'detect cursor reconciled jsonl=%{public}d cursor=%{public}d status=%{public}s',
      recovery.contiguousCursor, this.job.cursor, this.job.status);
    return true;
  }

  private async failJob(message: string): Promise<void> {
    const failed: DetectJobTransition = failDetectJob(this.job, message, Date.now());
    if (failed.accepted) {
      this.job = failed.state;
      if (this.filesDir.length > 0) {
        try {
          this.writeJob(this.filesDir);
        } catch (err) {
          hilog.warn(DOMAIN, TAG, 'detect failed-state persistence error: %{public}s', errorText(err as Error));
        }
      }
      this.refreshTrace();
      await this.releaseBackground();
    }
  }

  private async failWithoutContext(message: string): Promise<void> {
    if (this.job.status === DETECT_STATUS_RUNNING) {
      await this.failJob(message);
    }
  }

  private invalidateRunningJob(filesDir: string, previousStartedAt: number, reason: string): void {
    if (previousStartedAt > 0) {
      this.trimResultFiles(filesDir, previousStartedAt);
    }
    this.job = newDetectJobState();
    this.resultNeedsSeparator = false;
    try {
      this.writeJob(filesDir);
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'detect idle-state persistence error: %{public}s', errorText(err as Error));
    }
    this.refreshTrace();
    hilog.info(DOMAIN, TAG, 'persisted running job invalidated: %{public}s', reason);
  }

  private refreshTrace(): void {
    this.status = this.job.status;
    this.mode = this.job.mode;
    this.keyword = this.job.keyword;
    this.total = this.job.total;
    this.done = this.job.done;
    this.cursor = this.job.cursor;
    this.batchSize = this.job.batchSize;
    this.startedAt = this.job.startedAt;
    this.updatedAt = this.job.updatedAt;
    this.fingerprint = this.job.fingerprint;
    this.message = this.job.message;
  }

  private async ensureBackground(): Promise<void> {
    if (this.job.status !== DETECT_STATUS_RUNNING ||
      this.backgroundStateValue === DETECT_BACKGROUND_ACTIVE ||
      this.backgroundStateValue === DETECT_BACKGROUND_REQUESTING) {
      return;
    }
    const ctx: common.UIAbilityContext | undefined = this.currentContext();
    if (ctx === undefined) {
      this.markBackgroundDegraded('no ability context');
      return;
    }
    const generation: number = this.backgroundGeneration;
    this.backgroundStateValue = DETECT_BACKGROUND_REQUESTING;
    try {
      const lease: DetectBackgroundLease = await this.acquireBackground(ctx);
      if (generation !== this.backgroundGeneration || this.job.status !== DETECT_STATUS_RUNNING) {
        await this.releaseLease(ctx, lease);
        return;
      }
      if (lease.notificationId < 0) {
        await this.releaseLease(ctx, lease);
        this.markBackgroundDegraded('continuous task has no progress notification');
        return;
      }
      this.backgroundOwned = lease.owned;
      this.backgroundTaskId = lease.taskId;
      this.notificationId = lease.notificationId;
      this.backgroundOriginalModes = lease.originalModes.slice();
      this.backgroundStateValue = DETECT_BACKGROUND_ACTIVE;
      this.lastProgressNotifyAt = 0;
      const published: boolean = await this.publishProgress(true);
      if (published && this.job.status === DETECT_STATUS_RUNNING) {
        hilog.info(DOMAIN, TAG,
          'detect background active task=%{public}d notification=%{public}d owned=%{public}s',
          this.backgroundTaskId, this.notificationId, this.backgroundOwned.toString());
      }
    } catch (err) {
      const e = err as BusinessError;
      if (generation === this.backgroundGeneration && this.job.status === DETECT_STATUS_RUNNING) {
        this.markBackgroundDegraded(errorText(err as Error));
        hilog.warn(DOMAIN, TAG,
          'detect background unavailable code=%{public}d msg=%{public}s',
          e.code, e.message);
      }
    }
  }

  private async acquireBackground(ctx: common.UIAbilityContext): Promise<DetectBackgroundLease> {
    const existing: backgroundTaskManager.ContinuousTaskInfo | undefined = await this.findBackgroundTask(ctx);
    if (existing !== undefined) {
      const modes: string[] = existing.backgroundModes.slice();
      const hasData: boolean = modes.indexOf(DATA_TRANSFER_MODE) >= 0;
      const hasOther: boolean = modes.some((mode: string): boolean => mode !== DATA_TRANSFER_MODE);
      if (hasData && !hasOther) {
        return new DetectBackgroundLease(true, continuousTaskId(existing), existing.notificationId, []);
      }
      if (hasData) {
        const original: string[] = modes.filter((mode: string): boolean => mode !== DATA_TRANSFER_MODE);
        return new DetectBackgroundLease(false, continuousTaskId(existing), existing.notificationId, original);
      }
      const union: string[] = modes.slice();
      union.push(DATA_TRANSFER_MODE);
      const updated: backgroundTaskManager.ContinuousTaskNotification =
        await backgroundTaskManager.updateBackgroundRunning(ctx, union);
      return new DetectBackgroundLease(false, continuousTaskId(updated), updated.notificationId, modes);
    }

    const agent: WantAgent = await this.detectWantAgent();
    try {
      const started: backgroundTaskManager.ContinuousTaskNotification =
        await backgroundTaskManager.startBackgroundRunning(ctx, [DATA_TRANSFER_MODE], agent);
      return new DetectBackgroundLease(true, continuousTaskId(started), started.notificationId, []);
    } catch (err) {
      const e = err as BusinessError;
      if (e.code !== 9800005) {
        throw new Error('continuous task start failed code=' + e.code.toString() + ' msg=' + e.message);
      }
      // API 12-19 cannot enumerate tasks. Adopt the pre-existing audio task instead of starting a second one.
      const updated: backgroundTaskManager.ContinuousTaskNotification =
        await backgroundTaskManager.updateBackgroundRunning(
          ctx, [AUDIO_PLAYBACK_MODE, DATA_TRANSFER_MODE]
        );
      return new DetectBackgroundLease(false, continuousTaskId(updated), updated.notificationId,
        [AUDIO_PLAYBACK_MODE]);
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
      // getAllContinuousTasks is API 20+; older devices fall through to start/update probing.
      return undefined;
    }
  }

  private async detectWantAgent(): Promise<WantAgent> {
    const info: wantAgent.WantAgentInfo = {
      wants: [{
        bundleName: 'com.lichtcui.wispreader',
        abilityName: 'EntryAbility'
      }],
      actionType: wantAgent.OperationType.START_ABILITY,
      requestCode: 4104,
      wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    };
    return wantAgent.getWantAgent(info);
  }

  private async publishProgress(force: boolean): Promise<boolean> {
    if (this.job.status !== DETECT_STATUS_RUNNING ||
      this.backgroundStateValue !== DETECT_BACKGROUND_ACTIVE ||
      this.notificationId < 0) {
      return false;
    }
    const now: number = Date.now();
    if (!force && this.lastProgressNotifyAt > 0 &&
      now - this.lastProgressNotifyAt < PROGRESS_NOTIFY_INTERVAL_MS) {
      return true;
    }
    const total: number = this.job.total > 0 ? this.job.total : 1;
    const percent: number = Math.max(0, Math.min(100, Math.floor(this.job.done * 100 / total)));
    const generation: number = this.backgroundGeneration;
    const notificationId: number = this.notificationId;
    const template: notificationManager.NotificationTemplate = {
      name: 'downloadTemplate',
      data: {
        'title': '书源检测',
        'fileName': '已检测 ' + this.job.done.toString() + '/' + this.job.total.toString(),
        'progressValue': percent
      }
    };
    const request: notificationManager.NotificationRequest = {
      content: {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_SYSTEM_LIVE_VIEW,
        systemLiveView: {
          typeCode: 8,
          title: '书源检测',
          text: '已检测 ' + this.job.done.toString() + '/' + this.job.total.toString()
        }
      },
      id: notificationId,
      notificationSlotType: notificationManager.SlotType.LIVE_VIEW,
      template: template
    };
    try {
      await notificationManager.publish(request);
      if (generation !== this.backgroundGeneration ||
        this.notificationId !== notificationId ||
        this.job.status !== DETECT_STATUS_RUNNING) {
        try {
          await notificationManager.cancel(notificationId);
        } catch (err) {
          const e = err as BusinessError;
          hilog.warn(DOMAIN, TAG,
            'detect stale notification cleanup failed code=%{public}d msg=%{public}s', e.code, e.message);
        }
        return false;
      }
      this.lastProgressNotifyAt = now;
      return true;
    } catch (err) {
      const e = err as BusinessError;
      hilog.warn(DOMAIN, TAG,
        'detect progress notification failed code=%{public}d msg=%{public}s', e.code, e.message);
      if (this.job.status === DETECT_STATUS_RUNNING) {
        await this.releaseBackground();
        this.markBackgroundDegraded('progress notification failed');
      }
      return false;
    }
  }

  private async releaseBackground(): Promise<void> {
    const ctx: common.UIAbilityContext | undefined = this.currentContext();
    const owned: boolean = this.backgroundOwned;
    const taskId: number = this.backgroundTaskId;
    const notificationId: number = this.notificationId;
    const originalModes: string[] = this.backgroundOriginalModes.slice();
    this.backgroundGeneration += 1;
    this.backgroundStateValue = DETECT_BACKGROUND_INACTIVE;
    this.backgroundOwned = false;
    this.backgroundTaskId = -1;
    this.notificationId = -1;
    this.backgroundOriginalModes = [];
    this.lastProgressNotifyAt = 0;
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
        const e = err as BusinessError;
        hilog.warn(DOMAIN, TAG, 'detect background stop failed code=%{public}d msg=%{public}s', e.code, e.message);
      }
      if (notificationId >= 0) {
        try {
          await notificationManager.cancel(notificationId);
        } catch (err) {
          const e = err as BusinessError;
          hilog.warn(DOMAIN, TAG,
            'detect notification cleanup failed code=%{public}d msg=%{public}s', e.code, e.message);
        }
      }
      return;
    }
    if (originalModes.length > 0) {
      try {
        await backgroundTaskManager.updateBackgroundRunning(ctx, originalModes);
      } catch (err) {
        const e = err as BusinessError;
        hilog.warn(DOMAIN, TAG,
          'detect background restore failed code=%{public}d msg=%{public}s', e.code, e.message);
      }
    }
  }

  private async releaseLease(ctx: common.UIAbilityContext, lease: DetectBackgroundLease): Promise<void> {
    if (lease.owned) {
      try {
        if (lease.taskId >= 0 && deviceInfo.sdkApiVersion >= 21) {
          await backgroundTaskManager.stopBackgroundRunning(ctx, lease.taskId);
        } else {
          await backgroundTaskManager.stopBackgroundRunning(ctx);
        }
      } catch (err) {
        const e = err as BusinessError;
        hilog.warn(DOMAIN, TAG, 'detect stale background stop failed code=%{public}d', e.code);
      }
      return;
    }
    if (lease.originalModes.length > 0) {
      try {
        await backgroundTaskManager.updateBackgroundRunning(ctx, lease.originalModes);
      } catch (err) {
        const e = err as BusinessError;
        hilog.warn(DOMAIN, TAG, 'detect stale background restore failed code=%{public}d', e.code);
      }
    }
  }

  private markBackgroundDegraded(reason: string): void {
    this.backgroundStateValue = DETECT_BACKGROUND_DEGRADED;
    hilog.warn(DOMAIN, TAG, 'detect background degraded: %{public}s', reason);
  }

  private nextRoundStamp(filesDir: string, previousStartedAt: number): number {
    let stamp: number = Math.max(Date.now(), previousStartedAt + 1);
    while (this.resultFileExists(filesDir, stamp)) {
      stamp += 1;
    }
    return stamp;
  }

  private readPersistedJob(filesDir: string): DetectJobState | undefined {
    const path: string = detectDir(filesDir) + '/' + JOB_FILE;
    try {
      if (!fileIo.accessSync(path)) {
        return undefined;
      }
      return decodeDetectJobState(fileIo.readTextSync(path));
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'job.json read failed: %{public}s', errorText(err as Error));
      return undefined;
    }
  }

  private readResultFile(filesDir: string, roundStamp: number): string {
    const path: string = resultPath(filesDir, roundStamp);
    try {
      return fileIo.accessSync(path) ? fileIo.readTextSync(path) : '';
    } catch (err) {
      throw new Error('detect result file read failed: ' + errorText(err as Error));
    }
  }

  private resultFileExists(filesDir: string, roundStamp: number): boolean {
    try {
      return fileIo.accessSync(resultPath(filesDir, roundStamp));
    } catch (err) {
      return false;
    }
  }

  private createResultFile(filesDir: string, roundStamp: number): void {
    const dir: string = detectDir(filesDir);
    ensureDir(dir);
    const file: fileIo.File = fileIo.openSync(
      resultPath(filesDir, roundStamp),
      fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.APPEND
    );
    fileIo.closeSync(file);
  }

  private appendBatchLine(filesDir: string, line: DetectBatchLine): void {
    const file: fileIo.File = fileIo.openSync(
      resultPath(filesDir, this.job.startedAt),
      fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.APPEND
    );
    try {
      const prefix: string = this.resultNeedsSeparator ? '\n' : '';
      fileIo.writeSync(file.fd, prefix + encodeDetectBatchLine(line));
      fileIo.fsyncSync(file.fd);
    } finally {
      fileIo.closeSync(file);
    }
  }

  private trimResultFiles(filesDir: string, currentRound: number): void {
    const dir: string = detectDir(filesDir);
    let names: string[] = [];
    try {
      names = fileIo.listFileSync(dir);
    } catch (err) {
      return;
    }
    const stale: string[] = detectResultFilesToDelete(names, currentRound, 2);
    for (let i = 0; i < stale.length; i++) {
      try {
        fileIo.unlinkSync(dir + '/' + stale[i]);
      } catch (err) {
        hilog.warn(DOMAIN, TAG, 'stale detect result cleanup failed: %{public}s', stale[i]);
      }
    }
  }

  private writeJob(filesDir: string): void {
    this.writeJobState(filesDir, this.job);
  }

  private writeJobState(filesDir: string, state: DetectJobState): void {
    const dir: string = detectDir(filesDir);
    ensureDir(dir);
    const finalPath: string = dir + '/' + JOB_FILE;
    const tempPath: string = finalPath + '.tmp';
    const file: fileIo.File = fileIo.openSync(
      tempPath,
      fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC
    );
    try {
      fileIo.writeSync(file.fd, encodeDetectJobState(state));
      fileIo.fsyncSync(file.fd);
    } finally {
      fileIo.closeSync(file);
    }
    fileIo.moveFileSync(tempPath, finalPath, 0);
  }
}

function detectDir(filesDir: string): string {
  return filesDir + '/' + DETECT_DIR;
}

function resultPath(filesDir: string, roundStamp: number): string {
  return detectDir(filesDir) + '/' + detectResultFileName(roundStamp);
}

function ensureDir(dir: string): void {
  if (!fileIo.accessSync(dir)) {
    fileIo.mkdirSync(dir, true);
  }
}

function errorText(err: Error): string {
  return err !== undefined && err.message !== undefined && err.message.length > 0 ? err.message : 'unknown error';
}

function continuousTaskId(value: backgroundTaskManager.ContinuousTaskInfo |
  backgroundTaskManager.ContinuousTaskNotification): number {
  const id: number | undefined = value.continuousTaskId;
  return id === undefined ? -1 : id;
}
