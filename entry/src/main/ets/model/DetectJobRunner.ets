import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { DEFAULT_DETECT_KEYWORD, DETECT_BATCH_SIZE } from '../common/Const';
import { bookEngine } from '../engine/BookEngineNapi';
import { BookSource, DetectMode, DetectResult } from '../engine/types';
import { ensureSourceStore } from './SourceStoreMigration';
import {
  EngineSource,
  listRows,
  patchDetect,
  SourceRow,
  sourcesForEngine
} from './SourceStore';
import {
  canonicalDetectSourceIds,
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
const TAG: string = 'SourceReaderDetect';
const DETECT_DIR: string = 'detect';
const JOB_FILE: string = 'job.json';

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
            this.launch();
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
        this.launch();
      }
      return true;
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'detect start failed: %{public}s', errorText(err as Error));
      this.failWithoutContext(errorText(err as Error));
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
    while (this.job.status === DETECT_STATUS_RUNNING) {
      try {
        await this.runBatch();
      } catch (err) {
        const message: string = errorText(err as Error);
        hilog.warn(DOMAIN, TAG, 'detect batch failed: %{public}s', message);
        this.failJob(message);
        return;
      }
    }
  }

  private async runBatch(): Promise<void> {
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
    this.appendBatchLine(filesDir, line);
    for (let i = 0; i < mapped.results.length; i++) {
      const result: DetectStoredResult = mapped.results[i];
      await patchDetect(result.sourceId, detectSourceState(result.ok, result.stage), result.elapsedMs, at);
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
  }

  private async recoverRunning(filesDir: string): Promise<boolean> {
    if (this.job.status !== DETECT_STATUS_RUNNING) {
      return true;
    }
    const raw: string = this.readResultFile(filesDir, this.job.startedAt);
    const recovery: DetectJsonlRecovery = recoverDetectJsonl(raw);
    this.resultNeedsSeparator = detectJsonlSeparator(raw).length > 0;
    if (!detectJsonlCanContinue(recovery)) {
      this.failJob('detect result JSONL is damaged and cannot be continued safely');
      return false;
    }
    if (recovery.contiguousCursor > this.job.cursor) {
      const replayed: DetectBatchLine[] | undefined =
        replayDetectBatchLinesForJob(recovery.lines, this.job.cursor, recovery.contiguousCursor, this.job.sourceIds);
      if (replayed === undefined) {
        this.failJob('detect result JSONL cursor/source ids do not match the frozen job');
        return false;
      }
      for (let i = 0; i < replayed.length; i++) {
        const line: DetectBatchLine = replayed[i];
        for (let j = 0; j < line.results.length; j++) {
          const result: DetectStoredResult = line.results[j];
          await patchDetect(
            result.sourceId,
            detectSourceState(result.ok, result.stage),
            result.elapsedMs,
            line.at
          );
        }
      }
    }
    const reconciled: DetectJobTransition =
      reconcileDetectCursor(this.job, recovery.contiguousCursor, Date.now());
    if (!reconciled.accepted) {
      this.failJob('detect cursor reconciliation rejected: ' + reconciled.reason);
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

  private failJob(message: string): void {
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
    }
    this.refreshTrace();
  }

  private failWithoutContext(message: string): void {
    if (this.job.status === DETECT_STATUS_RUNNING) {
      this.failJob(message);
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
