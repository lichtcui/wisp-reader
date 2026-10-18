import { DETECT_BATCH_SIZE } from '../common/Const';

/**
 * Pure detect-job contract and state machine.
 *
 * Frozen @Trace fields for DetectJobRunner (T4.3) and detect-ui (T5.2):
 * - status: idle | running | done | cancelled | failed
 * - mode: probe | full
 * - keyword: keyword used for this round
 * - total: number of sources in the round
 * - done: number of sources already processed
 * - cursor: next source index in the canonical source-id order
 * - batchSize: sources dispatched per batch
 * - startedAt: round start time in epoch milliseconds
 * - updatedAt: latest transition time in epoch milliseconds
 * - fingerprint: deterministic digest of ids + mode + keyword
 * - message: failure detail; empty outside a failed transition
 *
 * Runtime-only state (not @Trace):
 * - sourceIds: canonical, de-duplicated, sorted ids used for exact batches
 *
 * JSONL recovery:
 * - one complete batch per line; a crash may leave the final line unterminated
 * - valid complete lines are retained even if the final line is partial
 * - callers append a separator before the next batch instead of rewriting the file
 */

export const DETECT_STATUS_IDLE: string = 'idle';
export const DETECT_STATUS_RUNNING: string = 'running';
export const DETECT_STATUS_DONE: string = 'done';
export const DETECT_STATUS_CANCELLED: string = 'cancelled';
export const DETECT_STATUS_FAILED: string = 'failed';

export const DETECT_MODE_PROBE: string = 'probe';
export const DETECT_MODE_FULL: string = 'full';

export const DETECT_SOURCE_OK: string = 'ok';
export const DETECT_SOURCE_NO_RESULT: string = 'noResult';
export const DETECT_SOURCE_TIMEOUT: string = 'timeout';
export const DETECT_SOURCE_UNAVAILABLE: string = 'unavailable';

export const DETECT_TRANSITION_OK: string = 'ok';
export const DETECT_TRANSITION_ALREADY_RUNNING: string = 'already-running';
export const DETECT_TRANSITION_EMPTY: string = 'empty';
export const DETECT_TRANSITION_NOT_RUNNING: string = 'not-running';
export const DETECT_TRANSITION_BAD_COUNT: string = 'bad-count';
export const DETECT_TRANSITION_NOT_RESUMABLE: string = 'not-resumable';

export interface DetectJobTraceField {
  name: string;
  semantics: string;
}

/** Stable names consumed by DetectJobRunner. Do not rename after T4.1. */
export const DETECT_JOB_TRACE_FIELDS: DetectJobTraceField[] = [
  { name: 'status', semantics: 'job state' },
  { name: 'mode', semantics: 'probe or full' },
  { name: 'keyword', semantics: 'detect keyword' },
  { name: 'total', semantics: 'source count' },
  { name: 'done', semantics: 'processed source count' },
  { name: 'cursor', semantics: 'next canonical source index' },
  { name: 'batchSize', semantics: 'sources per batch' },
  { name: 'startedAt', semantics: 'round start time (ms)' },
  { name: 'updatedAt', semantics: 'latest transition time (ms)' },
  { name: 'fingerprint', semantics: 'ids + mode + keyword digest' },
  { name: 'message', semantics: 'failure detail' }
];

export class DetectJobSpec {
  sourceIds: string[];
  mode: string;
  keyword: string;
  batchSize: number;

  constructor(sourceIds: string[], mode: string, keyword: string, batchSize: number = DETECT_BATCH_SIZE) {
    this.sourceIds = sourceIds;
    this.mode = mode;
    this.keyword = keyword;
    this.batchSize = batchSize;
  }
}

export class DetectJobState {
  status: string;
  mode: string;
  keyword: string;
  total: number;
  done: number;
  cursor: number;
  batchSize: number;
  startedAt: number;
  updatedAt: number;
  fingerprint: string;
  message: string;
  sourceIds: string[];

  constructor(
    status: string = DETECT_STATUS_IDLE,
    mode: string = DETECT_MODE_FULL,
    keyword: string = '',
    total: number = 0,
    done: number = 0,
    cursor: number = 0,
    batchSize: number = DETECT_BATCH_SIZE,
    startedAt: number = 0,
    updatedAt: number = 0,
    fingerprint: string = '',
    message: string = '',
    sourceIds: string[] = []
  ) {
    this.status = status;
    this.mode = mode;
    this.keyword = keyword;
    this.total = total;
    this.done = done;
    this.cursor = cursor;
    this.batchSize = batchSize;
    this.startedAt = startedAt;
    this.updatedAt = updatedAt;
    this.fingerprint = fingerprint;
    this.message = message;
    this.sourceIds = sourceIds;
  }
}

export class DetectJobTransition {
  accepted: boolean;
  state: DetectJobState;
  reason: string;

  constructor(accepted: boolean, state: DetectJobState, reason: string) {
    this.accepted = accepted;
    this.state = state;
    this.reason = reason;
  }
}

export class DetectStoredResult {
  sourceId: number;
  sourceUrl: string;
  sourceName: string;
  ok: boolean;
  stage: string;
  detail: string;
  contentLen: number;
  elapsedMs: number;

  constructor(
    sourceId: number = 0,
    sourceUrl: string = '',
    sourceName: string = '',
    ok: boolean = false,
    stage: string = '',
    detail: string = '',
    contentLen: number = 0,
    elapsedMs: number = 0
  ) {
    this.sourceId = sourceId;
    this.sourceUrl = sourceUrl;
    this.sourceName = sourceName;
    this.ok = ok;
    this.stage = stage;
    this.detail = detail;
    this.contentLen = contentLen;
    this.elapsedMs = elapsedMs;
  }
}

/** One append-only line in `results-<round>.jsonl`. */
export class DetectBatchLine {
  cursor: number;
  nextCursor: number;
  at: number;
  results: DetectStoredResult[];

  constructor(cursor: number = 0, nextCursor: number = 0, at: number = 0, results: DetectStoredResult[] = []) {
    this.cursor = cursor;
    this.nextCursor = nextCursor;
    this.at = at;
    this.results = results;
  }
}

export class DetectJsonlRecovery {
  lines: DetectBatchLine[];
  invalidLines: number;
  unterminated: boolean;
  contiguousCursor: number;
  discontinuity: boolean;

  constructor(
    lines: DetectBatchLine[] = [],
    invalidLines: number = 0,
    unterminated: boolean = false,
    contiguousCursor: number = 0,
    discontinuity: boolean = false
  ) {
    this.lines = lines;
    this.invalidLines = invalidLines;
    this.unterminated = unterminated;
    this.contiguousCursor = contiguousCursor;
    this.discontinuity = discontinuity;
  }
}

/** Exact `job.json` shape. Runtime-only `sourceIds` is deliberately absent. */
export class DetectJobDiskState {
  status: string;
  mode: string;
  keyword: string;
  total: number;
  done: number;
  cursor: number;
  batchSize: number;
  startedAt: number;
  updatedAt: number;
  fingerprint: string;
  message: string;

  constructor(
    status: string,
    mode: string,
    keyword: string,
    total: number,
    done: number,
    cursor: number,
    batchSize: number,
    startedAt: number,
    updatedAt: number,
    fingerprint: string,
    message: string
  ) {
    this.status = status;
    this.mode = mode;
    this.keyword = keyword;
    this.total = total;
    this.done = done;
    this.cursor = cursor;
    this.batchSize = batchSize;
    this.startedAt = startedAt;
    this.updatedAt = updatedAt;
    this.fingerprint = fingerprint;
    this.message = message;
  }
}

export function newDetectJobState(): DetectJobState {
  return new DetectJobState();
}

/**
 * Fingerprints are order-independent sets, but batching uses this canonical order.
 * Keeping both operation and cursor on the same sorted ids makes restarts exact.
 */
export function canonicalDetectSourceIds(sourceIds: string[]): string[] {
  const seen: string[] = [];
  for (let i = 0; i < sourceIds.length; i++) {
    const id: string = sourceIds[i].trim();
    if (id.length > 0 && seen.indexOf(id) < 0) {
      seen.push(id);
    }
  }
  seen.sort(compareText);
  return seen;
}

export function normalizeDetectMode(mode: string): string {
  return mode === DETECT_MODE_PROBE ? DETECT_MODE_PROBE : DETECT_MODE_FULL;
}

/**
 * Stable 64-bit digest made from two FNV-1a 32-bit lanes. The canonical
 * encoding length-prefixes every component, so id/mode/keyword boundaries
 * cannot collide through separators.
 */
export function computeDetectFingerprint(sourceIds: string[], mode: string, keyword: string): string {
  const ids: string[] = canonicalDetectSourceIds(sourceIds);
  const normalizedMode: string = normalizeDetectMode(mode);
  let canonical: string = 'detect-job-v1|ids=' + ids.length.toString();
  for (let i = 0; i < ids.length; i++) {
    canonical += '|id=' + ids[i].length.toString() + ':' + ids[i];
  }
  canonical += '|mode=' + normalizedMode.length.toString() + ':' + normalizedMode;
  canonical += '|keyword=' + keyword.length.toString() + ':' + keyword;
  return 'v1-' + hashHex(0x811c9dc5, canonical) + hashHex(0x9e3779b9, canonical);
}

export function matchesDetectFingerprint(stored: string, sourceIds: string[], mode: string, keyword: string): boolean {
  return stored.length > 0 && stored === computeDetectFingerprint(sourceIds, mode, keyword);
}

/** Shared mapping from engine verdict to source-store `last_detect_state`. */
export function detectSourceState(ok: boolean, stage: string): string {
  if (ok) {
    return DETECT_SOURCE_OK;
  }
  if (stage === 'no_results') {
    return DETECT_SOURCE_NO_RESULT;
  }
  if (stage === 'timeout') {
    return DETECT_SOURCE_TIMEOUT;
  }
  return DETECT_SOURCE_UNAVAILABLE;
}

export function startDetectJob(state: DetectJobState, spec: DetectJobSpec, now: number): DetectJobTransition {
  if (state.status === DETECT_STATUS_RUNNING) {
    return reject(state, DETECT_TRANSITION_ALREADY_RUNNING);
  }
  const ids: string[] = canonicalDetectSourceIds(spec.sourceIds);
  if (ids.length === 0) {
    return reject(state, DETECT_TRANSITION_EMPTY);
  }
  const mode: string = normalizeDetectMode(spec.mode);
  const fingerprint: string = computeDetectFingerprint(ids, mode, spec.keyword);
  const canResume: boolean = (state.status === DETECT_STATUS_CANCELLED || state.status === DETECT_STATUS_FAILED) &&
    state.fingerprint === fingerprint && state.cursor < state.total;
  if (canResume) {
    const resumed: DetectJobState = cloneDetectJobState(state);
    resumed.status = DETECT_STATUS_RUNNING;
    resumed.updatedAt = now;
    resumed.message = '';
    resumed.sourceIds = ids;
    return accept(resumed);
  }
  const batchSize: number = spec.batchSize > 0 ? Math.floor(spec.batchSize) : DETECT_BATCH_SIZE;
  const started: DetectJobState = new DetectJobState(
    DETECT_STATUS_RUNNING,
    mode,
    spec.keyword,
    ids.length,
    0,
    0,
    batchSize,
    now,
    now,
    fingerprint,
    '',
    ids
  );
  return accept(started);
}

export function resumeDetectJob(state: DetectJobState, now: number): DetectJobTransition {
  if (state.status !== DETECT_STATUS_CANCELLED && state.status !== DETECT_STATUS_FAILED) {
    return reject(state, DETECT_TRANSITION_NOT_RESUMABLE);
  }
  if (state.total <= 0 || state.cursor >= state.total) {
    return reject(state, DETECT_TRANSITION_NOT_RESUMABLE);
  }
  const resumed: DetectJobState = cloneDetectJobState(state);
  resumed.status = DETECT_STATUS_RUNNING;
  resumed.updatedAt = now;
  resumed.message = '';
  return accept(resumed);
}

export function cancelDetectJob(state: DetectJobState, now: number): DetectJobTransition {
  if (state.status !== DETECT_STATUS_RUNNING) {
    return reject(state, DETECT_TRANSITION_NOT_RUNNING);
  }
  const cancelled: DetectJobState = cloneDetectJobState(state);
  cancelled.status = DETECT_STATUS_CANCELLED;
  cancelled.updatedAt = now;
  cancelled.message = '';
  return accept(cancelled);
}

export function completeDetectBatch(state: DetectJobState, processed: number, now: number): DetectJobTransition {
  if (state.status !== DETECT_STATUS_RUNNING) {
    return reject(state, DETECT_TRANSITION_NOT_RUNNING);
  }
  const remaining: number = state.total - state.cursor;
  if (!Number.isInteger(processed) || processed <= 0 || processed > remaining || processed > state.batchSize) {
    return reject(state, DETECT_TRANSITION_BAD_COUNT);
  }
  const advanced: DetectJobState = cloneDetectJobState(state);
  advanced.done += processed;
  advanced.cursor += processed;
  advanced.updatedAt = now;
  advanced.message = '';
  if (advanced.cursor === advanced.total) {
    advanced.status = DETECT_STATUS_DONE;
  }
  return accept(advanced);
}

export function failDetectJob(state: DetectJobState, message: string, now: number): DetectJobTransition {
  if (state.status !== DETECT_STATUS_RUNNING) {
    return reject(state, DETECT_TRANSITION_NOT_RUNNING);
  }
  const failed: DetectJobState = cloneDetectJobState(state);
  failed.status = DETECT_STATUS_FAILED;
  failed.updatedAt = now;
  failed.message = message;
  return accept(failed);
}

/** Runtime-only: returns the exact next ids. Not persisted and not a @Trace field. */
export function nextDetectBatch(state: DetectJobState): string[] {
  if (state.status !== DETECT_STATUS_RUNNING) {
    return [];
  }
  const end: number = Math.min(state.cursor + state.batchSize, state.total);
  return state.sourceIds.slice(state.cursor, end);
}

/** Encode the frozen trace contract without the runtime-only source-id list. */
export function encodeDetectJobState(state: DetectJobState): string {
  return JSON.stringify(new DetectJobDiskState(
    state.status,
    state.mode,
    state.keyword,
    state.total,
    state.done,
    state.cursor,
    state.batchSize,
    state.startedAt,
    state.updatedAt,
    state.fingerprint,
    state.message
  ));
}

export function decodeDetectJobState(raw: string): DetectJobState | undefined {
  let disk: DetectJobDiskState | undefined = undefined;
  try {
    disk = JSON.parse(raw) as DetectJobDiskState;
  } catch (err) {
    return undefined;
  }
  if (disk === undefined || disk === null ||
    !validDetectStatus(disk.status) ||
    (disk.mode !== DETECT_MODE_PROBE && disk.mode !== DETECT_MODE_FULL) ||
    typeof disk.keyword !== 'string' || typeof disk.message !== 'string' || typeof disk.fingerprint !== 'string' ||
    !Number.isInteger(disk.total) || disk.total < 0 ||
    !Number.isInteger(disk.done) || disk.done < 0 || disk.done > disk.total ||
    !Number.isInteger(disk.cursor) || disk.cursor < 0 || disk.cursor > disk.total || disk.done !== disk.cursor ||
    !Number.isInteger(disk.batchSize) || disk.batchSize <= 0 ||
    !Number.isInteger(disk.startedAt) || disk.startedAt < 0 ||
    !Number.isInteger(disk.updatedAt) || disk.updatedAt < 0) {
    return undefined;
  }
  return new DetectJobState(
    disk.status,
    disk.mode,
    disk.keyword,
    disk.total,
    disk.done,
    disk.cursor,
    disk.batchSize,
    disk.startedAt,
    disk.updatedAt,
    disk.fingerprint,
    disk.message,
    []
  );
}

/**
 * Reconcile an in-flight job with complete JSONL records after a process kill.
 * A complete append wins over a stale `job.json` cursor; any missing/corrupt
 * tail moves the cursor back so that batch is detected again.
 */
export function reconcileDetectCursor(state: DetectJobState, cursor: number, now: number): DetectJobTransition {
  if (state.status !== DETECT_STATUS_RUNNING) {
    return reject(state, DETECT_TRANSITION_NOT_RUNNING);
  }
  if (!Number.isInteger(cursor) || cursor < 0 || cursor > state.total) {
    return reject(state, DETECT_TRANSITION_BAD_COUNT);
  }
  if (cursor === state.cursor) {
    return accept(cloneDetectJobState(state));
  }
  const reconciled: DetectJobState = cloneDetectJobState(state);
  reconciled.done = cursor;
  reconciled.cursor = cursor;
  reconciled.updatedAt = now;
  reconciled.message = '';
  if (cursor === reconciled.total) {
    reconciled.status = DETECT_STATUS_DONE;
  }
  return accept(reconciled);
}

/**
 * Recover complete batch records from an append-only JSONL file.
 *
 * A partial final line is counted as invalid and omitted. The file itself is
 * not rewritten; `detectJsonlSeparator()` lets the caller append a newline
 * before writing the next record.
 */
export function recoverDetectJsonl(raw: string): DetectJsonlRecovery {
  const lines: DetectBatchLine[] = [];
  const parts: string[] = raw.split('\n');
  let invalidLines: number = 0;
  for (let i = 0; i < parts.length; i++) {
    const text: string = parts[i].trim();
    if (text.length === 0) {
      continue;
    }
    const parsed: DetectBatchLine | undefined = parseDetectBatchLine(text);
    if (parsed === undefined) {
      invalidLines += 1;
      continue;
    }
    lines.push(parsed);
  }

  let cursor: number = 0;
  let discontinuity: boolean = false;
  for (let i = 0; i < lines.length; i++) {
    const line: DetectBatchLine = lines[i];
    if (line.nextCursor <= cursor) {
      continue;
    }
    if (line.cursor !== cursor) {
      discontinuity = true;
      break;
    }
    cursor = line.nextCursor;
  }
  return new DetectJsonlRecovery(lines, invalidLines, raw.length > 0 && !raw.endsWith('\n'), cursor, discontinuity);
}

export function encodeDetectBatchLine(line: DetectBatchLine): string {
  return JSON.stringify(line) + '\n';
}

/** Returns the delimiter needed before appending after a crash-truncated tail. */
export function detectJsonlSeparator(raw: string): string {
  return raw.length > 0 && !raw.endsWith('\n') ? '\n' : '';
}

function compareText(left: string, right: string): number {
  if (left < right) {
    return -1;
  }
  if (left > right) {
    return 1;
  }
  return 0;
}

function parseDetectBatchLine(text: string): DetectBatchLine | undefined {
  let parsed: DetectBatchLine | undefined = undefined;
  try {
    parsed = JSON.parse(text) as DetectBatchLine;
  } catch (err) {
    return undefined;
  }
  if (parsed === undefined || parsed === null ||
    !Number.isInteger(parsed.cursor) || parsed.cursor < 0 ||
    !Number.isInteger(parsed.nextCursor) || parsed.nextCursor <= parsed.cursor ||
    !Number.isInteger(parsed.at) || parsed.at < 0 ||
    parsed.results === undefined || parsed.results === null || !Array.isArray(parsed.results) ||
    parsed.results.length !== parsed.nextCursor - parsed.cursor) {
    return undefined;
  }
  const results: DetectStoredResult[] = [];
  for (let i = 0; i < parsed.results.length; i++) {
    const result: DetectStoredResult = parsed.results[i];
    if (!validDetectStoredResult(result)) {
      return undefined;
    }
    results.push(new DetectStoredResult(
      result.sourceId,
      result.sourceUrl,
      result.sourceName,
      result.ok,
      result.stage,
      result.detail,
      result.contentLen,
      result.elapsedMs
    ));
  }
  return new DetectBatchLine(parsed.cursor, parsed.nextCursor, parsed.at, results);
}

function validDetectStoredResult(result: DetectStoredResult): boolean {
  return result !== undefined && result !== null &&
    Number.isInteger(result.sourceId) && result.sourceId > 0 &&
    typeof result.sourceUrl === 'string' &&
    typeof result.sourceName === 'string' &&
    typeof result.ok === 'boolean' &&
    typeof result.stage === 'string' &&
    typeof result.detail === 'string' &&
    Number.isInteger(result.contentLen) && result.contentLen >= 0 &&
    Number.isInteger(result.elapsedMs) && result.elapsedMs >= 0;
}

function validDetectStatus(status: string): boolean {
  return status === DETECT_STATUS_IDLE || status === DETECT_STATUS_RUNNING ||
    status === DETECT_STATUS_DONE || status === DETECT_STATUS_CANCELLED ||
    status === DETECT_STATUS_FAILED;
}

function hashHex(seed: number, input: string): string {
  let hash: number = seed >>> 0;
  for (let i = 0; i < input.length; i++) {
    hash = hash ^ input.charCodeAt(i);
    hash = Math.imul(hash, 0x01000193);
  }
  let hex: string = (hash >>> 0).toString(16);
  while (hex.length < 8) {
    hex = '0' + hex;
  }
  return hex;
}

function cloneDetectJobState(state: DetectJobState): DetectJobState {
  return new DetectJobState(
    state.status,
    state.mode,
    state.keyword,
    state.total,
    state.done,
    state.cursor,
    state.batchSize,
    state.startedAt,
    state.updatedAt,
    state.fingerprint,
    state.message,
    state.sourceIds.slice()
  );
}

function accept(state: DetectJobState): DetectJobTransition {
  return new DetectJobTransition(true, state, DETECT_TRANSITION_OK);
}

function reject(state: DetectJobState, reason: string): DetectJobTransition {
  return new DetectJobTransition(false, state, reason);
}
