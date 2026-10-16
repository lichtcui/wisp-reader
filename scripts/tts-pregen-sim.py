#!/usr/bin/env python3
"""TTS 预生成（T-TTS-7 阶段二）客户端**纯逻辑**的主机侧仿真：不上真机就跑真源码。

为什么需要：预生成播放的这条链路里，**最容易错且最难在真机上盯**的是三件纯事情 ——
  * `chapterAudioRoute`：这一章到底走缓存还是实时（章级原子切换的判据）；
  * `pregTimeline`：块锚点 `chunks[].p0/p1` → 段落时间轴（段落高亮全靠它，错了就是「念 A 高亮 B」）；
  * `pregPlaybackRate`：缓存音频的倍速（服务端烘死 1.0，只能在渲染器上变速）；
外加进度/失败文案的形态。真机上每验一次要等 1 小时合成 + 真机在环，这里秒级跑完。

做法（**不重写被测逻辑**）：机械切片真源码 —— `common/Const.ets` + `model/TtsPregen.ets`
去掉 `import` 行的**全文**（后者约定：无 ArkUI 装饰器、纯逻辑与 IO 分开），补上宿主桩，
用 DevEco 自带的 `tsc` 编到 JS、`node` 跑断言。改这两个文件后直接重跑本脚本即可。

用法：python3 scripts/tts-pregen-sim.py      （退出码 0 = 全部断言通过，= `make test-pregen`）
未覆盖：HTTP/落盘（`loadPregAudio`/`sweepPregFiles`/`storePregKeys` 的**落盘**部分；其中
        提交项↔响应项的配对用 `matchPregKeys` 已覆盖）、`TtsController` 的播放编排、
        Runner 的轮询节奏、真机 UI —— 这些只能上设备（IMPL §4.2）。
"""
import os
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORK = '/tmp/tts-pregen-sim'
TSC_CANDIDATES = [
    '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor-ohos-plugin/node_modules/typescript/bin/tsc',
    '/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript/bin/tsc',
]

# ── 宿主桩：只声明被切片代码「引用到」的外部名（引擎类型 / 三个 Kit 模块 / hilog）──
STUBS = r"""
// ── host stubs（只补类型与模块名，不含任何被测逻辑）──
interface Book { bookId: string; }
interface BookSource { bookSourceUrl?: string; bookSourceName?: string; }
interface Chapter { title: string; url: string; isVolume?: boolean; }
interface BookSearchItem { name: string; author: string; bookUrl: string; }
interface BusinessError { code: number; message?: string; }
declare const hilog: { info(...a: any[]): void; warn(...a: any[]): void; error(...a: any[]): void };
declare namespace common { interface UIAbilityContext { filesDir: string; cacheDir: string; } }
declare namespace http {
  interface HttpResponse { responseCode: number; result: string | ArrayBuffer | object; header: Record<string, string>; }
  interface HttpRequestOptions {
    method?: string; header?: Record<string, string>; extraData?: string | ArrayBuffer;
    readTimeout?: number; connectTimeout?: number; expectDataType?: number; usingCache?: boolean;
  }
  interface HttpRequest {
    request(url: string, options: HttpRequestOptions): Promise<HttpResponse>;
    destroy(): void;
    on(event: string, cb: (value: any) => void): void;
  }
  const HttpDataType: { STRING: number; ARRAY_BUFFER: number };
  enum RequestMethod { OPTIONS = 'OPTIONS', GET = 'GET', HEAD = 'HEAD', POST = 'POST', PUT = 'PUT',
    DELETE = 'DELETE', TRACE = 'TRACE', CONNECT = 'CONNECT' }
  function createHttp(): HttpRequest;
}
declare namespace connection {
  interface NetHandle { netId: number; }
  interface NetCapabilities { bearerTypes: number[]; }
  enum NetBearType { BEARER_CELLULAR = 0, BEARER_WIFI = 1, BEARER_BLUETOOTH = 2, BEARER_ETHERNET = 3 }
  function getDefaultNetSync(): NetHandle;
  function getNetCapabilitiesSync(handle: NetHandle): NetCapabilities;
}
declare namespace fileIo {
  interface Stat { size: number; }
  const OpenMode: { READ_ONLY: number; WRITE_ONLY: number; READ_WRITE: number; CREATE: number; TRUNC: number; APPEND: number };
  function accessSync(path: string): boolean;
  function mkdirSync(path: string, recursion?: boolean): void;
  function listFileSync(path: string): string[];
  function openSync(path: string, mode?: number): any;
  function closeSync(fd: any): void;
  function writeSync(fd: any, buf: ArrayBuffer | string, opt?: any): number;
  function readSync(fd: any, buf: ArrayBuffer, opt?: any): number;
  function statSync(path: string): Stat;
  function renameSync(src: string, dest: string): void;
  function unlinkSync(path: string): void;
}
declare function loadChapterParagraphs(ctx: common.UIAbilityContext | undefined,
  source: BookSource | undefined, book: Book | undefined, chapter: Chapter,
  index: number): Promise<string[]>;
declare function setChapterPregKey(ctx: common.UIAbilityContext, bookId: string, index: number,
  url: string, key: string): boolean;
declare const process: { exitCode?: number };
"""

# ── 断言（只调用切片来的真函数，不复制逻辑）──────────────────────────────────
TEST = r"""
// ── 迷你断言框架 ──────────────────────────────────────────────────────────
let passed: number = 0;
const failed: string[] = [];
function ok(cond: boolean, label: string): void {
  if (cond) { passed++; return; }
  failed.push(label);
}
function eq(actual: unknown, expect: unknown, label: string): void {
  ok(actual === expect, label + '（期望 ' + JSON.stringify(expect) + '，实际 ' + JSON.stringify(actual) + '）');
}
function near(actual: number, expect: number, tol: number, label: string): void {
  ok(Math.abs(actual - expect) <= tol,
    label + '（期望 ' + expect + '±' + tol + '，实际 ' + actual + '）');
}
function monotonic(tl: PregenTiming[], label: string): void {
  let prev: number = -1;
  let sorted: boolean = true;
  for (const seg of tl) {
    if (seg.startMs < prev || seg.endMs < seg.startMs) { sorted = false; }
    prev = seg.startMs;
  }
  ok(sorted, label);
  let finite: boolean = true;
  for (const seg of tl) {
    if (!Number.isFinite(seg.startMs) || !Number.isFinite(seg.endMs)) { finite = false; }
  }
  ok(finite, label + '·无 NaN');
}
function seg(tl: PregenTiming[], index: number): PregenTiming | undefined {
  for (const s of tl) { if (s.index === index) { return s; } }
  return undefined;
}

// ══ 1. 章级原子切换 ════════════════════════════════════════════════════════
eq(AUDIO_CACHE, 'cache', '路线常量 cache');
eq(AUDIO_REALTIME, 'realtime', '路线常量 realtime');
// D17 后路由与朗读引擎无关（实时恒为系统 TTS）
eq(chapterAudioRoute(true, 'abc123'), AUDIO_CACHE, '开缓存优先 + 有键 → 缓存');
eq(chapterAudioRoute(false, 'abc123'), AUDIO_REALTIME, '关掉缓存优先 → 实时');
eq(chapterAudioRoute(true, ''), AUDIO_REALTIME, '没预生成键 → 实时');
eq(chapterAudioRoute(false, ''), AUDIO_REALTIME, '全不满足 → 实时');

// ══ 2. 缓存音频的倍速 ══════════════════════════════════════════════════════
eq(pregPlaybackRate(1.0), TTS_PREGEN_SPEED_SCALE, '1.0 档 = 标定系数');
ok(Math.abs(pregPlaybackRate(1.0) - 0.75) > 1e-9, '缓存路径**不**套 VITS 的 SPEED_SCALE=0.75');
near(pregPlaybackRate(0.5), 0.5, 1e-9, '0.5 档');
near(pregPlaybackRate(0.75), 0.75, 1e-9, '0.75 档');
near(pregPlaybackRate(1.2), 1.2, 1e-9, '1.2 档');
near(pregPlaybackRate(3.0), 2.0, 1e-9, '超上限 → 夹到 2.0');
near(pregPlaybackRate(0.1), 0.5, 1e-9, '低于下限 → 夹到 0.5');

// ══ 3. 时间轴：块锚点摊平 ══════════════════════════════════════════════════
// 9 段 × 100 字，3 个块各 300 字 / 10 s
const paras9: string[] = [];
for (let i = 0; i < 9; i++) { paras9.push('x'.repeat(100)); }
const chunks3: PregenChunk[] = [
  { t0Ms: 0, t1Ms: 10000, chars: 300, p0: 0, p1: 3 },
  { t0Ms: 10000, t1Ms: 20000, chars: 300, p0: 3, p1: 6 },
  { t0Ms: 20000, t1Ms: 30000, chars: 300, p0: 6, p1: 9 }
];
const tl9: PregenTiming[] = pregTimeline(chunks3, paras9, 30000);
eq(tl9.length, 9, '时间轴段数 = 段落数');
eq(tl9[0].index, 0, '第一段 index');
eq(tl9[8].index, 8, '最后段 index');
eq(tl9[0].startMs, 0, '整章从 0 开始');
eq(tl9[8].endMs, 30000, '整章到 audioMs 结束');
monotonic(tl9, '时间轴单调');
near(tl9[2].endMs, 10000, 1e-6, '块边界：第 3 段结束 = 块 1 的 t1Ms');
near(tl9[5].endMs, 20000, 1e-6, '块边界：第 6 段结束 = 块 2 的 t1Ms');
near(tl9[1].endMs - tl9[1].startMs, 10000 / 3, 1e-6, '等长段均分块内时长');
eq(pregParagraphAt(tl9, 0), 0, 'ms=0 → 第 0 段');
eq(pregParagraphAt(tl9, 9999), 2, '块 1 内 → 第 2 段');
eq(pregParagraphAt(tl9, 10000), 3, '块边界（含）→ 第 3 段');
eq(pregParagraphAt(tl9, 29999), 8, '末尾 → 第 8 段');
eq(pregParagraphAt(tl9, 99999), 8, '超出末尾 → 最后一段');
eq(pregParagraphAt([], 5), 0, '空时间轴 → 0');
eq(pregParagraphAt(tl9, -1), 0, '负数 → 第 0 段');

// 字数不均：块内按字数占比摊（100 / 300 字，块 8 s）
const tlUneven: PregenTiming[] = pregTimeline(
  [{ t0Ms: 0, t1Ms: 8000, chars: 400, p0: 0, p1: 2 }],
  ['x'.repeat(100), 'x'.repeat(300)], 8000);
near(tlUneven[0].endMs - tlUneven[0].startMs, 2000, 1e-6, '100/400 字 → 1/4 时长');
near(tlUneven[1].endMs - tlUneven[1].startMs, 6000, 1e-6, '300/400 字 → 3/4 时长');
near(tlUneven[1].endMs, 8000, 1e-6, '块尾对齐 t1Ms');

// ══ 4. 时间轴：退化分支 ════════════════════════════════════════════════════
eq(pregTimeline([], [], 0).length, 0, '无段落 → 空时间轴');
const tlNoAnchor: PregenTiming[] = pregTimeline([], paras9, 30000);
eq(tlNoAnchor.length, 9, '无块锚点 → 仍覆盖全部段落');
eq(tlNoAnchor[8].endMs, 30000, '无块锚点 → 整章到 audioMs');
monotonic(tlNoAnchor, '无块锚点时间轴单调');
const tlByChars: PregenTiming[] = pregTimeline([], paras9, 0);
near(tlByChars[8].endMs, 900 * PREGEN_MS_PER_CHAR, 1e-6, 'audioMs=0 → 按字数兜底（900 字 × ms/字）');
const tlBroken: PregenTiming[] = pregTimeline(
  [{ t0Ms: 0, t1Ms: 5000, chars: 100, p0: 2, p1: 2 }], paras9, 20000);
eq(tlBroken[8].endMs, 20000, '坏锚点（p1<=p0）→ 退化成整章均摊');
const tlZeroLen: PregenTiming[] = pregTimeline(
  [{ t0Ms: 5000, t1Ms: 5000, chars: 100, p0: 0, p1: 1 }], paras9, 20000);
eq(tlZeroLen[8].endMs, 20000, '坏锚点（t1<=t0）→ 退化成整章均摊');
const tlOver: PregenTiming[] = pregTimeline(
  [{ t0Ms: 0, t1Ms: 1000, chars: 100, p0: 0, p1: 99 }], paras9.slice(0, 2), 1000);
eq(tlOver.length, 2, 'p1 越界 → 夹到段落数');
eq(tlOver[1].endMs, 1000, 'p1 越界 → 末段仍对齐 t1Ms');
const tlUnder: PregenTiming[] = pregTimeline(
  [{ t0Ms: 0, t1Ms: 1000, chars: 100, p0: 7, p1: 9 }], paras9.slice(0, 2), 1000);
eq(tlUnder.length, 1, 'p0 越界 → 只覆盖被夹到的那一段');
eq(tlUnder[0].index, 1, 'p0 越界 → 落在最后一段');
const tlEmpty: PregenTiming[] = pregTimeline(
  [{ t0Ms: 0, t1Ms: 1000, chars: 2, p0: 0, p1: 2 }], ['', ''], 1000);
monotonic(tlEmpty, '空段落（weight=1）不产生 NaN');
near(tlEmpty[0].endMs - tlEmpty[0].startMs, 500, 1e-6, '空段落按 1 字摊');
// 超长段被服务端切成两块：同一 index 出现两次，后者（更靠后）为准
const tlSplit: PregenTiming[] = pregTimeline([
  { t0Ms: 0, t1Ms: 1000, chars: 200, p0: 0, p1: 1 },
  { t0Ms: 1000, t1Ms: 2000, chars: 200, p0: 0, p1: 1 }
], ['x'.repeat(400)], 2000);
eq(tlSplit.length, 2, '超长段被切两块 → 两条同 index 记录');
eq(pregParagraphAt(tlSplit, 1500), 0, '第二块里的 ms 仍指向同一段');
monotonic(tlSplit, '切块后的时间轴仍单调');

// ══ 5. 状态摘要与文案 ══════════════════════════════════════════════════════
const status: PregenStatus = {
  jobId: 'j1', total: 4, queued: 1, running: 1, done: 1, failed: 1, expired: 0,
  items: [
    { key: 'k1', state: 'done', title: '第1章', bookId: 'b', chapterIndex: 1 },
    { key: 'k2', state: 'running', title: '第2章', bookId: 'b', chapterIndex: 2 },
    { key: 'k3', state: 'queued', title: '第3章', bookId: 'b', chapterIndex: 3 },
    { key: 'k4', state: 'failed', title: '第4章', bookId: 'b', chapterIndex: 4, err: 'engine mismatch' }
  ]
};
const sum: PregenSummary = pregSummary(status);
eq(sum.currentTitle, '第2章', '当前章取 running');
eq(sum.failures.length, 1, '失败清单长度');
eq(sum.failures[0].err, 'engine mismatch', '失败原因透传');
eq(sum.failures[0].chapterIndex, 4, '失败章号透传');
eq(pregenProgressText(sum), '正在合成 1/4 · 第2章', '进度文案：正在合成');
const sumQueued: PregenSummary = pregSummary({
  total: 4, queued: 4, running: 0, done: 0, failed: 0, expired: 0,
  items: [{ key: 'k', state: 'queued', title: '第1章', bookId: 'b', chapterIndex: 1 }]
});
eq(sumQueued.currentTitle, '第1章', '没有 running 时用 queued 的标题兜底');
eq(pregenProgressText(sumQueued), '排队中 0/4', '进度文案：排队中');
const sumBad: PregenSummary = pregSummary({
  total: 4, queued: 0, running: 0, done: 2, failed: 1, expired: 1,
  items: [
    { key: 'k1', state: 'expired', title: '第5章', bookId: 'b', chapterIndex: 5 },
    { key: 'k2', state: 'failed', title: '第6章', bookId: 'b', chapterIndex: 6, err: 'rv' }
  ]
});
eq(sumBad.failures.length, 2, 'expired 也进失败清单（否则「重试失败」按钮点了没反应）');
eq(sumBad.failures[0].err, '已过期（服务器已清理）', 'expired 给默认原因');
eq(pregenProgressText(sumBad), '完成 2/4 · 失败 2', '进度文案：失败数含 expired');
eq(pregenProgressText(pregSummary({
  total: 3, queued: 0, running: 0, done: 3, failed: 0, expired: 0, items: []
})), '已就绪 3 章', '进度文案：全就绪');
eq(pregenProgressText(pregSummary({
  total: 0, queued: 0, running: 0, done: 0, failed: 0, expired: 0, items: []
})), '', '总数为 0 → 空文案');
eq(pregenFailureText({ key: 'k', title: '第7章', chapterIndex: 7, err: 'x'.repeat(50) }),
  '第7章：' + 'x'.repeat(40) + '…', '失败行截断到 40 字');
eq(pregenFailureText({ key: 'k', title: '第7章', chapterIndex: 7, err: '' }),
  '第7章：未知原因', '空原因 → 未知原因');
eq(pregenErrorMessage('full', ''), '服务器缓存已满：先听完已缓存的章节再继续（未播放的章节不会被淘汰）', '错误文案 full');
eq(pregenErrorMessage('auth', ''), '服务器拒不鉴权：检查听书设置里的 API Key', '错误文案 auth');
eq(pregenErrorMessage('net', 'timeout'), '连不上预生成服务器：timeout', '错误文案 net');
eq(pregenErrorMessage('notfound', ''), '服务器上找不到这一章（可能已被清理）', '错误文案 notfound');
eq(pregenErrorMessage('http', '500'), '500', '未知分类 → 原样给 detail');
eq(pregenErrorMessage('http', ''), '预生成失败', '未知分类且无 detail → 兜底');

// ══ 6. 音色归一与提交体 ════════════════════════════════════════════════════
eq(normalizePregenVoice('流萤'), '流萤', '预生成音色：流萤');
eq(normalizePregenVoice('花火'), '花火', '预生成音色：花火');
eq(normalizePregenVoice('卡芙卡'), '卡芙卡', '预生成音色：卡芙卡');
eq(normalizePregenVoice('甘雨'), TTS_PREGEN_VOICE_DEFAULT, '实时音色名（甘雨）→ 回默认');
eq(normalizePregenVoice(''), TTS_PREGEN_VOICE_DEFAULT, '空串 → 默认');
eq(normalizePregenVoice(' 流萤 '), TTS_PREGEN_VOICE_DEFAULT, '带空格不匹配 → 默认');
eq(TTS_PREGEN_VOICE_OPTIONS.length, TTS_PREGEN_VOICE_OPTIONS.length, '音色档位存在');
ok(TTS_PREGEN_VOICE_OPTIONS.indexOf(TTS_PREGEN_VOICE_DEFAULT) >= 0, '默认音色必须在档位表里');
ok(TTS_PREGEN_AHEAD_OPTIONS.indexOf(TTS_PREGEN_AHEAD_DEFAULT) >= 0, '默认章数必须在档位表里');
const job: PregenJobItem[] = toJobItems('book1', [
  { chapterIndex: 3, title: '第3章', url: 'u3', paragraphs: ['一段', '二段'] }
], '花火');
eq(job.length, 1, '提交体条数');
eq(job[0].bookId, 'book1', '提交体 bookId');
eq(job[0].chapterIndex, 3, '提交体 chapterIndex');
eq(job[0].voice, '花火', '提交体 voice');
eq(job[0].engine, TTS_PREGEN_ENGINE, '提交体 engine = 服务端 worker 引擎名');
eq(job[0].paragraphs.length, 2, '提交体段落数（不重新切分）');

// ── 缓存键的「已提交但 job 还没算完」标记（`notfound` 时保住键的依据）───────
eq(isPregKeyPending('k1'), false, '未登记 → 不算 pending');
markPregKeyPending('k1', true);
eq(isPregKeyPending('k1'), true, '提交后登记 → pending');
markPregKeyPending('k1', false);
eq(isPregKeyPending('k1'), false, 'job 到终态 → 撤销');
markPregKeyPending('', true);
eq(isPregKeyPending(''), false, '空键不进表（storePregKeys 里可能拿到空键）');

// ── 拖动 seek 的字节对齐（真机 2026-10-14：拖进度条后整章白噪）─────────────
// 16 bit mono ⇒ 帧 = 2 B；按字节四舍五入会落到奇数字节 ⇒ 采样高低字节互换 = 刺耳白噪
eq(pregSeekBytes(711.779449, 24000, 2), 34166, '711.779449 ms @24 kHz mono16 折成整帧字节');
let odd = 0;
for (let i = 0; i < 200; i++) {
  const ms = i * 17.371 + 0.0001 * i;
  if (pregSeekBytes(ms, 24000, 2) % 2 !== 0) { odd++; }
}
eq(odd, 0, '200 个零碎 ms 全部帧对齐（不留奇数偏移）');
eq(pregSeekBytes(0, 24000, 2), 0, '0 ms → 0 B');
eq(pregSeekBytes(1000, 24000, 2), 48000, '1 s @24 kHz mono16 = 48000 B');

// ── 提交项 ↔ 服务端响应项的配对（真机 2026-10-14：响应把已 ready 的排前面，按下标对齐 ⇒ 缓存章读出别章正文）
const col3: PregenCollectItem[] = [
  { chapterIndex: 1, title: '第二章', url: 'u1', paragraphs: ['p'] },
  { chapterIndex: 2, title: '第三章', url: 'u2', paragraphs: ['p'] },
  { chapterIndex: 3, title: '第四章', url: 'u3', paragraphs: ['p'] }
];
const shuffled: PregenSubmitResult = {
  jobId: 'j1', evicted: [], protected: 0,
  items: [{ key: 'k3', title: '第三章', state: 'ready' },
          { key: 'k4', title: '第四章', state: 'ready' },
          { key: 'k2', title: '第二章', state: 'queued' }]
};
const m1 = matchPregKeys(col3, shuffled);
eq(m1.keys[0], 'k2', '响应顺序被打乱（旧条目先回）：第二章拿 k2');
eq(m1.keys[1], 'k3', '响应顺序被打乱：第三章拿 k3');
eq(m1.keys[2], 'k4', '响应顺序被打乱：第四章拿 k4');
eq(m1.reordered, 3, '错位条数记下来（顺序没被打乱时为 0，进日志便于现场取证）');
const inOrder: PregenSubmitResult = {
  jobId: 'j2', evicted: [], protected: 0,
  items: [{ key: 'k2', title: '第二章', state: 'queued' },
          { key: 'k3', title: '第三章', state: 'ready' },
          { key: 'k4', title: '第四章', state: 'ready' }]
};
const m2 = matchPregKeys(col3, inOrder);
eq(m2.keys.join(','), 'k2,k3,k4', '顺序一致 → 一一对应');
eq(m2.reordered, 0, '顺序一致 → 无错位');
eq(m1.unmapped, 0, '标题唯一 → 无 unmapped');
const dup: PregenSubmitItem[] = [{ key: 'kA', title: '同名', state: 'ready' },
  { key: 'kB', title: '同名', state: 'queued' }];
const m3 = matchPregKeys(
  [{ chapterIndex: 5, title: '同名', url: 'ua', paragraphs: ['p'] },
   { chapterIndex: 6, title: '同名', url: 'ub', paragraphs: ['p'] }],
  { jobId: 'j3', items: dup, evicted: [], protected: 0 });
eq(m3.keys.join(','), ',', '同名章不猜（响应顺序不可信）⇒ 都留空、退实时');
eq(m3.unmapped, 2, '同名章计入 unmapped（进日志便于现场取证）');
const noTitle: PregenSubmitResult = {
  jobId: 'j4', evicted: [], protected: 0,
  items: [{ key: 'k2', title: '', state: 'ready' },
          { key: 'k3', title: '', state: 'ready' },
          { key: 'k4', title: '', state: 'ready' }]
};
const m4 = matchPregKeys(col3, noTitle);
eq(m4.keys.join(','), ',,', '无标题/老版本不按位置猜 ⇒ 留空退实时（按位置对齐正是本 bug 的成因）');
eq(m4.unmapped, 3, '无标题章全部计入 unmapped');
const shortResp: PregenSubmitResult = {
  jobId: 'j5', evicted: [], protected: 0,
  items: [{ key: 'k4', title: '第四章', state: 'ready' }]
};
const m5 = matchPregKeys(col3, shortResp);
eq(m5.keys.join(','), ',,k4', '响应短于提交（同文本被去重）→ 只有配上的那项拿键，其余留空');
eq(m5.unmapped, 2, '没配上的两项计入 unmapped');

// ── 状态端点纠偏（healPregKeys）：提交响应只回 title，同名章配不上 ⇒ 用带章号的 /job/status 补
const healCol: PregenCollectItem[] = [
  { chapterIndex: 5, title: '同名', url: 'ua', paragraphs: ['p'] },
  { chapterIndex: 6, title: '同名', url: 'ub', paragraphs: ['p'] },
  { chapterIndex: 7, title: '同名', url: 'uc', paragraphs: ['p'] }
];
const healStatus: PregenStatus = {
  total: 3, queued: 1, running: 0, done: 2, failed: 0, expired: 0,
  items: [
    { key: 'kA', state: 'ready', title: '同名', bookId: 'b', chapterIndex: 5 },
    { key: 'kB', state: 'ready', title: '同名', bookId: 'b', chapterIndex: 6 },
    { key: 'kC', state: 'queued', title: '同名', bookId: 'b', chapterIndex: 7 }
  ]
};
const fx: PregKeyFix[] = healPregKeys(healCol, healStatus, 'b');
eq(fx.length, 2, '只纠 ready 的（queued 不算）');
eq(fx[0].chapterIndex + ':' + fx[0].url + '=' + fx[0].key, '5:ua=kA', '同名章按章号（不是标题/下标）对上 kA');
eq(fx[1].chapterIndex + ':' + fx[1].url + '=' + fx[1].key, '6:ub=kB', '同名章按章号对上 kB');
eq(healPregKeys(healCol, healStatus, 'other').length, 0, 'bookId 不符（换书了）⇒ 不纠');
eq(healPregKeys([{ chapterIndex: 9, title: 'x', url: 'ux', paragraphs: ['p'] }], healStatus, 'b').length,
  0, '本次提交里没这一章（重启后 collected 空）⇒ 不纠不猜');
eq(healPregKeys([{ chapterIndex: 5, title: '同名', url: 'ua', paragraphs: ['p'] }],
  { total: 1, queued: 0, running: 0, done: 1, failed: 0, expired: 0,
    items: [{ key: 'kZ', state: 'ready', title: '同名', bookId: '', chapterIndex: 5 }] }, 'b')[0].key,
  'kZ', '服务端没回 bookId（老版本）：作业是单本书的 ⇒ 按章号纠也安全');

// ── 收尾 ─────────────────────────────────────────────────────────────────
if (failed.length > 0) {
  console.log('✗ ' + failed.length + ' 条断言失败 / 共 ' + (passed + failed.length) + ' 条：');
  for (const f of failed) { console.log('    ' + f); }
  process.exitCode = 1;
} else {
  console.log('✓ 全部 ' + passed + ' 条断言通过（`model/TtsPregen.ets` + `model/PregAudioSource.ets` + `common/Const.ets` 纯逻辑）');
}
"""


def read(rel):
    with open(os.path.join(ROOT, rel), encoding='utf-8') as f:
        return f.read()


def strip_imports(text, label):
    lines = [l for l in text.splitlines() if not l.startswith('import ')]
    if len(lines) == len(text.splitlines()):
        print('提示：%s 不再有 import 行，确认切的是真源码' % label)
    return '\n'.join(lines)


def main():
    const = strip_imports(read('entry/src/main/ets/common/Const.ets'), 'Const.ets')
    pregen = strip_imports(read('entry/src/main/ets/model/TtsPregen.ets'), 'TtsPregen.ets')
    audio = strip_imports(read('entry/src/main/ets/model/PregAudioSource.ets'), 'PregAudioSource.ets')
    for needle in ('export function pregTimeline', 'export function chapterAudioRoute',
                   'export function pregSummary'):
        if needle not in pregen:
            sys.exit('切片失败：TtsPregen.ets 里找不到 %r，源码结构可能已改' % needle)
    if 'export function pregSeekBytes' not in audio:
        sys.exit('切片失败：PregAudioSource.ets 里找不到 pregSeekBytes，源码结构可能已改')
    # D17 回归门：路由只看「缓存优先 + 有键」，不再看朗读引擎
    route_body = pregen.split('export function chapterAudioRoute', 1)[1].split('}', 1)[0]
    for bad in ('engine', 'TTS_ENGINE'):
        if bad in route_body:
            sys.exit('D17 回归：chapterAudioRoute 不该再看朗读引擎（命中 %r）' % bad)
    if 'export function normalizePregenVoice' not in const:
        sys.exit('切片失败：Const.ets 里找不到 normalizePregenVoice')

    shutil.rmtree(WORK, ignore_errors=True)
    os.makedirs(WORK, exist_ok=True)
    src = os.path.join(WORK, 'pregen.ts')
    with open(src, 'w', encoding='utf-8') as f:
        f.write(STUBS + '\n' + const + '\n' + audio + '\n' + pregen + '\n' + TEST + '\n')

    tsc = next((p for p in TSC_CANDIDATES if os.path.exists(p)), None)
    if tsc is None:
        sys.exit('找不到 DevEco 的 tsc，改 TSC_CANDIDATES')
    out = os.path.join(WORK, 'out')
    r = subprocess.run([tsc, '--target', 'es2020', '--module', 'commonjs', '--lib', 'es2020,dom',
                        '--outDir', out, src], capture_output=True, text=True)
    if r.returncode != 0:
        print(r.stdout + r.stderr)
        sys.exit('tsc 失败')
    print('编译通过 → ' + out, flush=True)
    return subprocess.call(['node', os.path.join(out, 'pregen.js')])


if __name__ == '__main__':
    sys.exit(main())
