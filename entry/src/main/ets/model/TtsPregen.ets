import { http, connection } from '@kit.NetworkKit';
import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Book, BookSource, Chapter } from '../engine/types';
import { loadChapterParagraphs } from './BookContent';
import { setChapterPregKey } from './ChapterCache';
import { TTS_PREGEN_ENGINE, TTS_PREGEN_SPEED_SCALE } from '../common/Const';

/**
 * 预生成音频的客户端（T-TTS-7 阶段二，设计与契约见 `docs/research/TTS-PREGEN-IMPL.md`）。
 *
 * 这里只有**纯逻辑 + IO**，没有任何 ArkUI 装饰器：进度状态在 `TtsPregenRunner.ets`，
 * 播放集成在 `TtsController.ets`。这样纯净逻辑（时间轴/选区/文案/路由）能在主机上用
 * `make test-pregen`（`scripts/tts-pregen-sim.py`）直接跑，不必上真机。
 *
 * 服务端契约（`server/app.py` / `server/job_worker.py`，字段名一律进 obfuscation-rules.txt）：
 *   POST   /job                    items[] → {jobId, items[{key,state,title}], evicted, protected}
 *   GET    /job/status?jobId=|key= → {queued,running,done,failed,expired,total,items[]}
 *   GET    /audio/<key>            Range 分片（206）/ 404 / 416
 *   DELETE /cache/<key>            → 204（章节听完后清理）
 */

const DOMAIN: number = 0x0000;
const TAG: string = 'SourceReaderTts';

/** 连接/读超时：作业提交要读 40 章正文，给宽一点；轮询要短，别拖住 UI。 */
const PREGEN_CONNECT_TIMEOUT_MS: number = 5000;
const PREGEN_JOB_TIMEOUT_MS: number = 30000;
const PREGEN_STATUS_TIMEOUT_MS: number = 10000;
/** 音频分片下载的窗口大小（≈31 s @24 kHz mono S16LE）。 */
const PREGEN_WINDOW_BYTES: number = 1024 * 1024;
/** 每片一个请求，读超时按片算。 */
const PREGEN_AUDIO_TIMEOUT_MS: number = 60000;
/** 无块锚点时的兜底语速（ms/字，GPT-SoVITS speed=1.0 实测 4.86 字/秒）。 */
const PREGEN_MS_PER_CHAR: number = 206;

// ── JSON 契约（服务端字段名，勿改；新增字段要同步 obfuscation-rules.txt）────────

/** 服务端每个合成块的锚点：`[t0Ms,t1Ms]` 是音频区间，`[p0,p1)` 是它覆盖的段落。 */
export interface PregenChunk {
  t0Ms: number;
  t1Ms: number;
  chars: number;
  p0: number;
  p1: number;
}

/** 客户端把块锚点摊平成的段落时间轴（`index` 段落在 `[startMs,endMs]` 内）。 */
export interface PregenTiming {
  index: number;
  startMs: number;
  endMs: number;
}

export interface PregenJobItem {
  bookId: string;
  chapterIndex: number;
  title: string;
  voice: string;
  engine: string;
  paragraphs: string[];
}

export interface PregenJobRequest {
  items: PregenJobItem[];
}

export interface PregenSubmitItem {
  key: string;
  title: string;
  state: string;
}

export interface PregenSubmitResult {
  jobId: string;
  items: PregenSubmitItem[];
  evicted: string[];
  protected: number;
}

export interface PregenStatusItem {
  key: string;
  state: string;
  title: string;
  bookId: string;
  chapterIndex: number;
  err?: string;
  audioMs?: number;
  chars?: number;
  chunks?: PregenChunk[];
}

export interface PregenStatus {
  jobId?: string;
  total: number;
  queued: number;
  running: number;
  done: number;
  failed: number;
  expired: number;
  items: PregenStatusItem[];
}

export interface PregenFailure {
  key: string;
  title: string;
  chapterIndex: number;
  err: string;
}

export interface PregenSummary {
  total: number;
  done: number;
  running: number;
  queued: number;
  failed: number;
  expired: number;
  currentTitle: string;
  failures: PregenFailure[];
}

export interface PregenErrorDetail {
  reason?: string;
  neededBytes?: number;
  protected?: number;
  evicted?: string[];
}

export interface PregenErrorBody {
  detail?: PregenErrorDetail;
}

/** 一章的本地音频 + 锚点（`path` 一定已在盘上；`chunks` 可能为空 = 拿不到块锚点）。 */
export interface PregAudio {
  path: string;
  audioMs: number;
  chunks: PregenChunk[];
}

/** 收集阶段的一章（提交前）：正文段落 + 定位信息。 */
export interface PregenCollectItem {
  chapterIndex: number;
  title: string;
  url: string;
  paragraphs: string[];
}

export interface PregenCollection {
  items: PregenCollectItem[];
  skipped: number;
}

/** 路由判定结果。 */
export const AUDIO_CACHE: string = 'cache';
export const AUDIO_REALTIME: string = 'realtime';

/** 预生成链路的错误分类，决定 UI 文案与是否回退实时。 */
export class PregenError extends Error {
  kind: string;

  constructor(kind: string, message: string) {
    super(message);
    this.kind = kind;
  }
}

// ── 纯逻辑（sim 覆盖）────────────────────────────────────────────────────────

/**
 * 章级原子切换（IMPL §3.4）：进章**前**就决定这一章走哪条路，出声之后不再改。
 *
 * - 关掉「缓存优先」：直接实时（排查用）；
 * - 没有键：这一章没预生成过 → 实时。
 *
 * 这条路由**与朗读引擎无关**（D17：远端 VITS 实时链路已停用，实时恒为系统 TTS）。
 * 实时链路是 16 kHz，缓存音频是 24 kHz，采样率不能混——渲染器按本函数的返回值
 * 在进章时重建（见 `TtsController.beginFrom` / `ensureRenderRate`）。
 *
 * 缓存路径**在出声之前**失败（404/409/网络）时可以退回实时——此时还没有一个采样
 * 被播出去，不算换声线；一旦开始出声就不再回退（见 `TtsController.onPregAudioEnd`）。
 */
export function chapterAudioRoute(preferCache: boolean, pregKey: string): string {
  if (!preferCache || pregKey.length === 0) {
    return AUDIO_REALTIME;
  }
  return AUDIO_CACHE;
}

/**
 * 缓存路径的播放倍速。`speed` 是听书设置里的档位，实时链路把它直接喂给系统 TTS；
 * 缓存链路的音频已经烘死在服务端，只能用渲染器倍速近似，且要乘听感标定系数
 * （`TTS_PREGEN_SPEED_SCALE`，见 Const.ets 的说明）。
 */
export function pregPlaybackRate(speed: number): number {
  const rate: number = speed * TTS_PREGEN_SPEED_SCALE;
  return Math.min(Math.max(rate, 0.5), 2.0);
}

/**
 * 块锚点 → 段落时间轴：每个块按 `[p0,p1)` 里的字数占比摊到它覆盖的段落上。
 *
 * 一个段落被切成两个块（超长段，`split`）时，同一段落会出现在两个块里；这里用后写的
 * 覆盖先写的（`pregParagraphAt` 取最后一个 `startMs <= ms` 的段），边界最多偏一个块。
 * 拿不到块锚点（老服务端 / meta 被清）就退化成「整章按字数占比均摊」。
 */
export function pregTimeline(chunks: PregenChunk[], paragraphs: string[], audioMs: number): PregenTiming[] {
  const out: PregenTiming[] = [];
  const count: number = paragraphs.length;
  if (count === 0) {
    return out;
  }
  let totalChars: number = 0;
  for (const p of paragraphs) {
    totalChars += p.length > 0 ? p.length : 1;
  }
  let blocks: PregenChunk[] = chunks;
  let missing: boolean = false;
  for (const c of chunks) {
    if (c.p1 <= c.p0 || c.t1Ms <= c.t0Ms) {
      missing = true;
    }
  }
  if (chunks.length === 0 || missing) {
    const span: number = audioMs > 0 ? audioMs : totalChars * PREGEN_MS_PER_CHAR;
    blocks = [{ t0Ms: 0, t1Ms: span, chars: totalChars, p0: 0, p1: count }];
  }
  for (const c of blocks) {
    const p0: number = Math.min(Math.max(c.p0, 0), count - 1);
    const p1: number = Math.min(Math.max(c.p1, p0 + 1), count);
    let sum: number = 0;
    for (let i = p0; i < p1; i++) {
      sum += paragraphs[i].length > 0 ? paragraphs[i].length : 1;
    }
    const span: number = Math.max(c.t1Ms - c.t0Ms, 1);
    let cursor: number = Math.max(c.t0Ms, 0);
    for (let i = p0; i < p1; i++) {
      const weight: number = paragraphs[i].length > 0 ? paragraphs[i].length : 1;
      const end: number = i === p1 - 1 ? cursor + (Math.max(c.t1Ms, 0) - cursor) : cursor + span * weight / sum;
      out.push({ index: i, startMs: cursor, endMs: end });
      cursor = end;
    }
  }
  return out;
}

/** 时间轴里 `ms` 落在哪一段（没有时间轴返回 0；超出末尾返回最后一段）。 */
export function pregParagraphAt(timeline: PregenTiming[], ms: number): number {
  if (timeline.length === 0) {
    return 0;
  }
  let index: number = timeline[0].index;
  for (const seg of timeline) {
    if (ms >= seg.startMs) {
      index = seg.index;
    } else {
      break;
    }
  }
  return index;
}

/** 把服务端状态压成 UI 需要的摘要（进度、正在合成的章节、失败清单）。 */
export function pregSummary(status: PregenStatus): PregenSummary {
  const failures: PregenFailure[] = [];
  let current: string = '';
  let queuedTitle: string = '';
  for (const item of status.items) {
    if (item.state === 'failed' || item.state === 'expired') {
      // expired 也要进失败清单：否则 `failed+expired>0` 时界面显示「重试失败」，
      // 点下去却因为清单为空直接 return（按钮死掉）。
      const said: string = item.err !== undefined && item.err.length > 0
        ? item.err
        : (item.state === 'expired' ? '已过期（服务器已清理）' : '');
      failures.push({
        key: item.key,
        title: item.title,
        chapterIndex: item.chapterIndex,
        err: said
      });
    } else if (item.state === 'running' && current.length === 0) {
      current = item.title;
    } else if (item.state === 'queued' && queuedTitle.length === 0) {
      queuedTitle = item.title;
    }
  }
  return {
    total: status.total,
    done: status.done,
    running: status.running,
    queued: status.queued,
    failed: status.failed,
    expired: status.expired,
    currentTitle: current.length > 0 ? current : queuedTitle,
    failures: failures
  };
}

/** 进度条下方的一行字。 */
export function pregenProgressText(summary: PregenSummary): string {
  if (summary.total <= 0) {
    return '';
  }
  if (summary.running > 0 && summary.currentTitle.length > 0) {
    return '正在合成 ' + summary.done.toString() + '/' + summary.total.toString() + ' · ' + summary.currentTitle;
  }
  if (summary.running > 0 || summary.queued > 0) {
    return '排队中 ' + summary.done.toString() + '/' + summary.total.toString();
  }
  const bad: number = summary.failed + summary.expired;
  if (bad > 0) {
    return '完成 ' + summary.done.toString() + '/' + summary.total.toString()
      + ' · 失败 ' + bad.toString();
  }
  return '已就绪 ' + summary.done.toString() + ' 章';
}

/** 失败原因一行（截断，避免把 worker 的长报错铺满屏）。 */
export function pregenFailureText(failure: PregenFailure): string {
  const reason: string = failure.err.length > 0 ? failure.err : '未知原因';
  const short: string = reason.length > 40 ? reason.substring(0, 40) + '…' : reason;
  return failure.title + '：' + short;
}

/** 用户可读的错误文案。 */
export function pregenErrorMessage(kind: string, detail: string): string {
  if (kind === 'full') {
    return '服务器缓存已满：先听完已缓存的章节再继续（未播放的章节不会被淘汰）';
  }
  if (kind === 'auth') {
    return '服务器拒不鉴权：检查听书设置里的 API Key';
  }
  if (kind === 'net') {
    return '连不上预生成服务器：' + detail;
  }
  if (kind === 'notfound') {
    return '服务器上找不到这一章（可能已被清理）';
  }
  return detail.length > 0 ? detail : '预生成失败';
}

/** 「仅 Wi-Fi」判定：以太网也算；拿不到网络信息按「没 Wi-Fi」处理（宁可拒绝，不偷跑流量）。 */
export function onWifi(): boolean {
  try {
    const handle: connection.NetHandle = connection.getDefaultNetSync();
    const caps: connection.NetCapabilities = connection.getNetCapabilitiesSync(handle);
    const bearers: connection.NetBearType[] = caps.bearerTypes;
    for (const bearer of bearers) {
      if (bearer === connection.NetBearType.BEARER_WIFI || bearer === connection.NetBearType.BEARER_ETHERNET) {
        return true;
      }
    }
    return false;
  } catch (err) {
    return false;
  }
}

// ── HTTP ────────────────────────────────────────────────────────────────────

function requestHeaders(apiKey: string, json: boolean): Record<string, string> {
  const head: Record<string, string> = {};
  if (json) {
    head['Content-Type'] = 'application/json';
  }
  if (apiKey.length > 0) {
    head['X-API-Key'] = apiKey;
  }
  return head;
}

function classify(res: http.HttpResponse, what: string): PregenError {
  const code: number = res.responseCode;
  if (code === 409) {
    let reason: string = '';
    try {
      const body: PregenErrorBody = JSON.parse(res.result as string) as PregenErrorBody;
      const detail: PregenErrorDetail | undefined = body.detail;
      if (detail !== undefined && detail.reason !== undefined) {
        reason = detail.reason;
      }
    } catch (err) {
      reason = '';
    }
    return new PregenError('full', what + '：' + (reason.length > 0 ? reason : 'cache full'));
  }
  if (code === 404) {
    return new PregenError('notfound', what + '：404');
  }
  if (code === 401 || code === 403) {
    return new PregenError('auth', what + '：' + code.toString());
  }
  return new PregenError('http', what + '：http ' + code.toString());
}

async function requestText(
  url: string,
  method: http.RequestMethod,
  body: string,
  apiKey: string,
  readTimeout: number
): Promise<http.HttpResponse> {
  const request: http.HttpRequest = http.createHttp();
  try {
    return await request.request(url, {
      method: method,
      header: requestHeaders(apiKey, body.length > 0),
      extraData: body,
      expectDataType: http.HttpDataType.STRING,
      connectTimeout: PREGEN_CONNECT_TIMEOUT_MS,
      readTimeout: readTimeout
    });
  } catch (err) {
    const e: BusinessError = err as BusinessError;
    throw new PregenError('net', 'net ' + e.code.toString() + ' ' + e.message);
  } finally {
    request.destroy();
  }
}

/** 提交/续跑一批章节。返回服务端算好的 key（**不要**在客户端自己拼）。 */
export async function submitPregen(
  baseUrl: string,
  apiKey: string,
  items: PregenJobItem[]
): Promise<PregenSubmitResult> {
  const req: PregenJobRequest = { items: items };
  const res: http.HttpResponse = await requestText(
    baseUrl + '/job', http.RequestMethod.POST, JSON.stringify(req), apiKey, PREGEN_JOB_TIMEOUT_MS);
  if (res.responseCode === 200) {
    return JSON.parse(res.result as string) as PregenSubmitResult;
  }
  throw classify(res, '提交预生成失败');
}

/** 作业进度（按 jobId）。 */
export async function fetchPregenStatus(
  baseUrl: string,
  apiKey: string,
  jobId: string
): Promise<PregenStatus> {
  const url: string = baseUrl + '/job/status?jobId=' + encodeURIComponent(jobId);
  const res: http.HttpResponse = await requestText(
    url, http.RequestMethod.GET, '', apiKey, PREGEN_STATUS_TIMEOUT_MS);
  if (res.responseCode === 200) {
    return JSON.parse(res.result as string) as PregenStatus;
  }
  throw classify(res, '查询预生成进度失败');
}

/** 单章元数据（块锚点 + 时长）；拿不到就让调用方退化成字数摊平。 */
export async function fetchPregMeta(
  baseUrl: string,
  apiKey: string,
  key: string
): Promise<PregenStatusItem> {
  const url: string = baseUrl + '/job/status?key=' + encodeURIComponent(key);
  const res: http.HttpResponse = await requestText(
    url, http.RequestMethod.GET, '', apiKey, PREGEN_STATUS_TIMEOUT_MS);
  if (res.responseCode !== 200) {
    throw classify(res, '查询章节元数据失败');
  }
  const status: PregenStatus = JSON.parse(res.result as string) as PregenStatus;
  return status.items.length > 0 ? status.items[0] : { key: key, state: 'expired', title: '', bookId: '', chapterIndex: 0 };
}

/** 章节听完后清服务端缓存（幂等，失败只记日志）。 */
export async function deletePregCache(baseUrl: string, apiKey: string, key: string): Promise<boolean> {
  if (key.length === 0) {
    return true;
  }
  const request: http.HttpRequest = http.createHttp();
  try {
    const res: http.HttpResponse = await request.request(baseUrl + '/cache/' + encodeURIComponent(key), {
      method: http.RequestMethod.DELETE,
      header: requestHeaders(apiKey, false),
      connectTimeout: PREGEN_CONNECT_TIMEOUT_MS,
      readTimeout: PREGEN_STATUS_TIMEOUT_MS
    });
    const ok: boolean = res.responseCode === 204 || res.responseCode === 404 || res.responseCode === 200;
    hilog.info(DOMAIN, TAG, 'preg cache delete key=%{public}s code=%{public}d', key, res.responseCode);
    return ok;
  } catch (err) {
    const e: BusinessError = err as BusinessError;
    hilog.warn(DOMAIN, TAG, 'preg cache delete failed key=%{public}s code=%{public}d', key, e.code);
    return false;
  } finally {
    request.destroy();
  }
}

// ── 本地文件 ────────────────────────────────────────────────────────────────

/** 预生成音频的本地目录（在 `cacheDir` 下：系统清缓存/卸载会一并带走）。 */
export function pregenDir(ctx: common.UIAbilityContext): string {
  return ctx.cacheDir + '/pregen';
}

export function pregenFilePath(ctx: common.UIAbilityContext, key: string): string {
  return pregenDir(ctx) + '/' + key + '.wav';
}

/** 章节听完后删掉本地文件（服务端那份也删，见 `deletePregCache`）。 */
export function deletePregFile(ctx: common.UIAbilityContext, key: string): void {
  if (key.length === 0) {
    return;
  }
  const path: string = pregenFilePath(ctx, key);
  const part: string = path + '.part';
  removeQuietly(path);
  removeQuietly(part);
}

function removeQuietly(path: string): void {
  try {
    if (fileIo.accessSync(path)) {
      fileIo.unlinkSync(path);
    }
  } catch (err) {
  }
}

/** 正在下载/读取的 key（清理时要避开）。 */
const inflight: Map<string, Promise<PregAudio>> = new Map();

/**
 * 只留 `keep` 里的本地音频（当前章 + 预取章）。**播放中的文件不会被删**：
 * 调用点（`TtsController.setChapter`）总是把自己算进 `keep`。
 */
export function sweepPregFiles(ctx: common.UIAbilityContext, keep: string[]): void {
  const dir: string = pregenDir(ctx);
  let names: string[] = [];
  try {
    names = fileIo.listFileSync(dir);
  } catch (err) {
    return;
  }
  let removed: number = 0;
  for (const name of names) {
    const base: string = name.endsWith('.part') ? name.substring(0, name.length - 5)
      : (name.endsWith('.wav') ? name.substring(0, name.length - 4) : name);
    if (base === name || keep.indexOf(base) >= 0 || inflight.has(base)) {
      continue;
    }
    try {
      fileIo.unlinkSync(dir + '/' + name);
      removed++;
    } catch (err) {
    }
  }
  if (removed > 0) {
    hilog.info(DOMAIN, TAG, 'preg sweep removed=%{public}d keep=%{public}d', removed, keep.length);
  }
}

/**
 * 确保某章音频在本地：命中直接返回，否则分片下载（Range）。
 * 同一 key 并发调用共享同一个 Promise（预取与播放同时命中时只下一次）。
 */
export function loadPregAudio(
  baseUrl: string,
  apiKey: string,
  ctx: common.UIAbilityContext,
  key: string,
  onBytes: (bytes: number) => void
): Promise<PregAudio> {
  const running: Promise<PregAudio> | undefined = inflight.get(key);
  if (running !== undefined) {
    return running;
  }
  const task: Promise<PregAudio> = ensurePregAudio(baseUrl, apiKey, ctx, key, onBytes);
  inflight.set(key, task);
  return task.then((audio: PregAudio): PregAudio => {
    inflight.delete(key);
    return audio;
  }).catch((err: Error): PregAudio => {
    inflight.delete(key);
    throw err;
  });
}

async function ensurePregAudio(
  baseUrl: string,
  apiKey: string,
  ctx: common.UIAbilityContext,
  key: string,
  onBytes: (bytes: number) => void
): Promise<PregAudio> {
  // 元数据（块锚点）先拿：顺带判断服务端还在不在这一章。
  let meta: PregenStatusItem | undefined = undefined;
  try {
    meta = await fetchPregMeta(baseUrl, apiKey, key);
  } catch (err) {
    meta = undefined;
  }
  const path: string = pregenFilePath(ctx, key);
  let present: boolean = false;
  try {
    present = fileIo.accessSync(path);
  } catch (err) {
    present = false;
  }
  if (!present) {
    await downloadPregFile(baseUrl, apiKey, ctx, key, onBytes);
  }
  const audioMs: number = meta !== undefined && meta.audioMs !== undefined ? meta.audioMs : 0;
  const chunks: PregenChunk[] = meta !== undefined && meta.chunks !== undefined ? meta.chunks : [];
  return { path: path, audioMs: audioMs, chunks: chunks };
}

/** Range 分片下载到 `<key>.wav`（先写 `.part` 再原子改名）。 */
async function downloadPregFile(
  baseUrl: string,
  apiKey: string,
  ctx: common.UIAbilityContext,
  key: string,
  onBytes: (bytes: number) => void
): Promise<void> {
  const dir: string = pregenDir(ctx);
  try {
    if (!fileIo.accessSync(dir)) {
      fileIo.mkdirSync(dir, true);
    }
  } catch (err) {
    throw new PregenError('io', '本地缓存目录不可用');
  }
  const final: string = pregenFilePath(ctx, key);
  const part: string = final + '.part';
  const file = fileIo.openSync(part, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
  let written: number = 0;
  let start: number = 0;
  try {
    while (true) {
      const res: http.HttpResponse = await requestWindow(baseUrl + '/audio/' + encodeURIComponent(key),
        apiKey, start);
      if (res.responseCode === 416) {
        break;
      }
      if (res.responseCode !== 200 && res.responseCode !== 206) {
        throw classify(res, '下载预生成音频失败');
      }
      const buf: ArrayBuffer = res.result as ArrayBuffer;
      if (buf.byteLength === 0) {
        break;
      }
      fileIo.writeSync(file.fd, buf);
      written += buf.byteLength;
      onBytes(written);
      if (res.responseCode === 200) {
        break; // 服务端忽略了 Range：整段已到齐
      }
      if (buf.byteLength < PREGEN_WINDOW_BYTES) {
        break; // 服务端把 end 夹到了文件尾 = 最后一片
      }
      start += buf.byteLength;
    }
  } catch (err) {
    try {
      fileIo.closeSync(file);
    } catch (ioErr) {
    }
    try {
      fileIo.unlinkSync(part);
    } catch (ioErr) {
    }
    throw err as Error;
  }
  try {
    fileIo.closeSync(file);
  } catch (err) {
  }
  if (written <= 0) {
    try {
      fileIo.unlinkSync(part);
    } catch (err) {
    }
    throw new PregenError('notfound', '服务器返回空音频');
  }
  try {
    fileIo.renameSync(part, final);
  } catch (err) {
    throw new PregenError('io', '本地缓存写入失败');
  }
  hilog.info(DOMAIN, TAG, 'preg audio ready key=%{public}s bytes=%{public}d', key, written);
}

async function requestWindow(url: string, apiKey: string, start: number): Promise<http.HttpResponse> {
  const request: http.HttpRequest = http.createHttp();
  const header: Record<string, string> = requestHeaders(apiKey, false);
  header['Range'] = 'bytes=' + start.toString() + '-' + (start + PREGEN_WINDOW_BYTES - 1).toString();
  try {
    return await request.request(url, {
      method: http.RequestMethod.GET,
      header: header,
      expectDataType: http.HttpDataType.ARRAY_BUFFER,
      usingCache: false,
      connectTimeout: PREGEN_CONNECT_TIMEOUT_MS,
      readTimeout: PREGEN_AUDIO_TIMEOUT_MS
    });
  } finally {
    request.destroy();
  }
}

// ── 收集（正文 → 提交项）──────────────────────────────────────────────────────

/**
 * 把 `chapters[startIndex, startIndex+count)` 里的可读章节收成提交项。
 * 正文走 `loadChapterParagraphs`（命中章节缓存就不请求书源），顺带把章节缓存养起来——
 * 服务端返回的 key 只有跟着章节缓存落盘才有意义（见 `ChapterCache.setChapterPregKey`）。
 */
export async function collectPregenItems(
  ctx: common.UIAbilityContext,
  src: BookSource | undefined,
  book: Book | undefined,
  chapters: Chapter[],
  startIndex: number,
  count: number,
  voice: string
): Promise<PregenCollection> {
  const items: PregenCollectItem[] = [];
  let skipped: number = 0;
  const end: number = Math.min(startIndex + count, chapters.length);
  for (let i = Math.max(startIndex, 0); i < end; i++) {
    const chapter: Chapter = chapters[i];
    if (chapter.isVolume === true) {
      skipped++;
      continue;
    }
    const paragraphs: string[] = await loadChapterParagraphs(ctx, src, book, chapter, i);
    if (paragraphs.length === 0) {
      skipped++;
      continue;
    }
    items.push({ chapterIndex: i, title: chapter.title, url: chapter.url, paragraphs: paragraphs });
  }
  return { items: items, skipped: skipped };
}

/** 提交项 → 服务端请求项。 */
export function toJobItems(bookId: string, collected: PregenCollectItem[], voice: string): PregenJobItem[] {
  const out: PregenJobItem[] = [];
  for (const item of collected) {
    out.push({
      bookId: bookId,
      chapterIndex: item.chapterIndex,
      title: item.title,
      voice: voice,
      engine: TTS_PREGEN_ENGINE,
      paragraphs: item.paragraphs
    });
  }
  return out;
}

/**
 * 把服务端返回的 key 记回章节缓存（正文在缓存里）或旁路文件（本地书，见 `ChapterCache`）。
 *
 * **服务端响应顺序 ≠ 提交顺序**：POST /job 里边扫边把已 ready/queued 的条目写进响应，
 * 新条目等循环结束才统一追加（`server/app.py` 的 `create_job`）。真机实测过
 * 「提交 [二、三、四] 响应 [三、四、二]」——按下标对齐会把别人的 key 记到本章上，
 * 表现为“缓存章读出别章的正文”。所以这里**只按 title 匹配**，而且只在标题
 * **两侧都恰好出现一次**时敢用：同名章（或没标题的章）匹配不了就不给键，这一章
 * 退实时——**宁可慢，不许放错章的音频**（按位置猜正是本 bug 的成因）。
 * 返回**真正落盘的**章数（正文不在缓存且旁路也写不了时不计）。
 */
export function storePregKeys(
  ctx: common.UIAbilityContext,
  bookId: string,
  collected: PregenCollectItem[],
  result: PregenSubmitResult
): number {
  const match: PregKeyMatch = matchPregKeys(collected, result);
  let stored: number = 0;
  for (let i = 0; i < collected.length; i++) {
    const item: PregenCollectItem = collected[i];
    const key: string = match.keys[i];
    if (key.length === 0) {
      continue;
    }
    if (setChapterPregKey(ctx, bookId, item.chapterIndex, item.url, key)) {
      stored++;
      markPregKeyPending(key, true);
    }
  }
  if (match.reordered > 0) {
    hilog.info(DOMAIN, TAG,
      'preg keys out-of-order n=%{public}d（按标题对齐，勿改回按下标）', match.reordered);
  }
  if (match.unmapped > 0) {
    hilog.info(DOMAIN, TAG,
      'preg keys unmapped n=%{public}d（同名/无标题章不敢猜 ⇒ 退实时）', match.unmapped);
  }
  return stored;
}

/** `matchPregKeys` 的结果：`keys[i]` 属于 `collected[i]`（空串 = 没配上）。 */
export interface PregKeyMatch {
  keys: string[];
  /** 按 title 找到的位置与提交位置不同的条数（服务端顺序没被打乱时为 0）。 */
  reordered: number;
  /** 没配上键的条数（同名/无标题/服务端没回 ⇒ 这一章退实时，不猜）。 */
  unmapped: number;
}

/** 标题 → 出现次数（空标题不计：它当不了标识）。 */
function countTitles(titles: string[]): Map<string, number> {
  const counts: Map<string, number> = new Map<string, number>();
  for (const title of titles) {
    if (title.length === 0) {
      continue;
    }
    const seen: number | undefined = counts.get(title);
    counts.set(title, seen === undefined ? 1 : seen + 1);
  }
  return counts;
}

/** 该标题能否唯一确定一项：提交侧与返回侧都要恰好出现一次。 */
function uniqueTitle(title: string, sent: Map<string, number>, got: Map<string, number>): boolean {
  return title.length > 0 && sent.get(title) === 1 && got.get(title) === 1;
}

/**
 * 提交项 ↔ 服务端返回项的配对（纯逻辑，主机侧 `make test-pregen` 覆盖）。
 *
 * 输出顺序**同样长的数组**，空串表示这一项没配上（服务端去重掉了同名同文重复项等）。
 */
export function matchPregKeys(collected: PregenCollectItem[], result: PregenSubmitResult): PregKeyMatch {
  const sentTitles: string[] = [];
  for (const item of collected) {
    sentTitles.push(item.title);
  }
  const gotTitles: string[] = [];
  for (const got of result.items) {
    gotTitles.push(got.title);
  }
  const sent: Map<string, number> = countTitles(sentTitles);
  const got: Map<string, number> = countTitles(gotTitles);
  const keys: string[] = [];
  let reordered: number = 0;
  let unmapped: number = 0;
  for (let i = 0; i < collected.length; i++) {
    const title: string = collected[i].title;
    let key: string = '';
    if (uniqueTitle(title, sent, got)) {
      for (let j = 0; j < result.items.length; j++) {
        if (result.items[j].title === title) {
          key = result.items[j].key;
          if (j !== i) {
            reordered++;
          }
          break;
        }
      }
    }
    if (key.length === 0) {
      unmapped++;
    }
    keys.push(key);
  }
  return { keys: keys, reordered: reordered, unmapped: unmapped };
}

/** 状态端点纠偏的结果：把 `chapterIndex` 这一章的键写成 `key`（`url` 给落盘校验用）。 */
export interface PregKeyFix {
  chapterIndex: number;
  url: string;
  key: string;
}

/**
 * 用 `/job/status` 回带的 `bookId` + `chapterIndex` 把键**按章号**写回去（精确标识）。
 *
 * 为什么需要：提交响应只回 `{key,state,title}`，同名章 / 无标题章无法配对（`matchPregKeys`
 * 只能放弃，那几章退实时）；而状态端点回的是服务端当时存下的提交 meta，带着章号 ⇒
 * 只要作业还在，就能把配不上的（甚至历史上配错的）键纠正回来。只认 `state === 'ready'`
 * （算完了才敢落盘），且只认本次提交里的章（`collected` 提供 url；换过书/重启后
 * `collected` 为空 ⇒ 不纠、不猜）。纯逻辑，主机侧 `make test-pregen` 覆盖。
 */
export function healPregKeys(
  collected: PregenCollectItem[],
  status: PregenStatus,
  bookId: string
): PregKeyFix[] {
  const fixes: PregKeyFix[] = [];
  for (const got of status.items) {
    if (got.state !== 'ready' || got.key.length === 0) {
      continue;
    }
    // 作业是按单本书建的 ⇒ 服务端没回 bookId（老版本）时看章号也安全；回了就必须一致。
    if (got.bookId.length > 0 && got.bookId !== bookId) {
      continue;
    }
    for (const item of collected) {
      if (item.chapterIndex === got.chapterIndex) {
        fixes.push({ chapterIndex: item.chapterIndex, url: item.url, key: got.key });
        break;
      }
    }
  }
  return fixes;
}

/**
 * 本次进程内「已提交、还没算完」的缓存键。
 *
 * 为什么要这个：`notfound` 有两种完全不同的含义——① 服务端**还没算好**（job 还在 queued/running，
 * 等几分钟就有）；② 音频**真没了**（被淘汰 / 听完删过）。`TtsController` 原来一律把键作废，
 * 于是「提交完接着听后面的章」这条最自然的路径（章还没算完就进去了）会把刚付了算力的缓存
 * 永久丢掉；反过来一律保留又会让真正失效的键每次进章都白试一次下载。
 * 所以：提交时登记为 pending，job 到终态时由 `TtsPregenRunner` 撤销。
 */
const pendingPregKeys: Set<string> = new Set<string>();

/** 登记 / 撤销一个「还没算完」的键（空键忽略）。 */
export function markPregKeyPending(key: string, pending: boolean): void {
  if (key.length === 0) {
    return;
  }
  if (pending) {
    pendingPregKeys.add(key);
  } else {
    pendingPregKeys.delete(key);
  }
}

/** 这个键是不是「已提交但 job 还没到终态」。 */
export function isPregKeyPending(key: string): boolean {
  return pendingPregKeys.has(key);
}
