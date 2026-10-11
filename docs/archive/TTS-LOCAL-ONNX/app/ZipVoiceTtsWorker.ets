import worker, { ThreadWorkerGlobalScope, MessageEvents, ErrorEvent } from '@ohos.worker';
import { fileIo as fs } from '@kit.CoreFileKit';
import { buffer } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  OfflineTtsConfig,
  OfflineTts,
  listRawfileDir,
  TtsInputWithConfig,
  TtsGenerationConfig,
  TtsOutput
} from 'sherpa_onnx';

const workerPort: ThreadWorkerGlobalScope = worker.workerPort;

const MODEL_DIR: string = 'zipvoice';
const REF_RATE: number = 24000;
const NUM_STEPS: number = 2;
const NUM_THREADS: number = 4;
const DEFAULT_REF_ID: string = 'liuying';

/** Reference-voice registry: refId -> { rawfile path, spoken text }. */
class RefSpec {
  path: string;
  text: string;

  constructor(path: string, text: string) {
    this.path = path;
    this.text = text;
  }
}

const REFS: Map<string, RefSpec> = new Map([
  ['liuying', new RefSpec(MODEL_DIR + '/refs/liuying.f32', '…我应该会选择请求猎犬家系停止追捕。')],
  ['huahuo', new RefSpec(MODEL_DIR + '/refs/huahuo.f32',
    '最近想根据性格给自己打造一个全新面具，换一副样子玩玩。有没有什么推荐？')],
  ['kafuka', new RefSpec(MODEL_DIR + '/refs/kafuka.f32', '不知道呢，我猜不透哪个答案才是你的真心话。')]
]);

let tts: OfflineTts | undefined = undefined;
let refAudios: Map<string, Float32Array> = new Map();

function mkdir(context: Context, parts: string[]): void {
  const sandboxPath: string = context.getApplicationContext().filesDir;
  let d: string = sandboxPath;
  for (const p of parts) {
    d = d + '/' + p;
    if (fs.accessSync(d)) {
      continue;
    }
    fs.mkdirSync(d);
  }
}

function copyRawFileToSandbox(context: Context, src: string, dst: string): void {
  const uint8Array: Uint8Array = context.resourceManager.getRawFileContentSync(src);
  const sandboxPath: string = context.getApplicationContext().filesDir;
  const filepath: string = sandboxPath + '/' + dst;
  if (fs.accessSync(filepath)) {
    const stat = fs.statSync(filepath);
    if (stat.size === uint8Array.length) {
      return;
    }
  }
  const fp = fs.openSync(filepath, fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
  fs.writeSync(fp.fd, buffer.from(uint8Array).buffer);
  fs.closeSync(fp.fd);
}

function copyRawFileDirToSandbox(context: Context, srcDir: string): void {
  const mgr = context.resourceManager;
  const allFiles: string[] = listRawfileDir(mgr, srcDir);
  for (const src of allFiles) {
    const parts: string[] = src.split('/');
    if (parts.length !== 1) {
      mkdir(context, parts.slice(0, -1));
    }
    copyRawFileToSandbox(context, src, src);
  }
}

/** A ref .f32 is raw little-endian float32; reinterpret the bytes directly. */
function readRefAudio(context: Context, path: string): Float32Array {
  const bytes: Uint8Array = context.resourceManager.getRawFileContentSync(path);
  const aligned: ArrayBuffer = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
  return new Float32Array(aligned);
}

function initTts(context: Context): OfflineTts {
  const dataDirName: string = 'espeak-ng-data';
  copyRawFileDirToSandbox(context, MODEL_DIR + '/' + dataDirName);
  const sandboxPath: string = context.getApplicationContext().filesDir;
  const dataDir: string = sandboxPath + '/' + MODEL_DIR + '/' + dataDirName;

  const config: OfflineTtsConfig = new OfflineTtsConfig();
  config.model.zipvoice.tokens = MODEL_DIR + '/tokens.txt';
  config.model.zipvoice.encoder = MODEL_DIR + '/encoder.int8.onnx';
  config.model.zipvoice.decoder = MODEL_DIR + '/decoder.int8.onnx';
  config.model.zipvoice.vocoder = MODEL_DIR + '/vocoder/vocos_24khz.onnx';
  config.model.zipvoice.lexicon = MODEL_DIR + '/lexicon.txt';
  config.model.zipvoice.dataDir = dataDir;
  config.model.numThreads = NUM_THREADS;
  config.model.debug = true;

  return new OfflineTts(config, context.resourceManager);
}

workerPort.onmessage = (e: MessageEvents) => {
  const msgType: string = e.data['msgType'] as string;

  if (msgType === 'init-tts') {
    const context: Context = e.data['context'] as Context;
    try {
      refAudios = new Map();
      for (const entry of REFS) {
        refAudios.set(entry[0], readRefAudio(context, entry[1].path));
      }
      tts = initTts(context);
      const doneMsg: Record<string, Object> = {
        'msgType': 'init-tts-done',
        'sampleRate': tts.sampleRate,
        'refCount': REFS.size
      };
      workerPort.postMessage(doneMsg);
    } catch (err) {
      const error = err as Error;
      const errMsg: Record<string, Object> = {
        'msgType': 'init-tts-error',
        'message': error.message
      };
      workerPort.postMessage(errMsg);
    }
    return;
  }

  if (msgType === 'tts-generate') {
    if (tts === undefined) {
      const errMsg: Record<string, Object> = {
        'msgType': 'tts-generate-error',
        'requestId': e.data['requestId'] as string,
        'message': 'tts not initialized'
      };
      workerPort.postMessage(errMsg);
      return;
    }
    const requestId: string = e.data['requestId'] as string;
    const text: string = e.data['text'] as string;
    const refIdRaw: string | undefined = e.data['refId'] as string | undefined;
    const refId: string = refIdRaw !== undefined && REFS.has(refIdRaw) ? refIdRaw : DEFAULT_REF_ID;
    const refSpec: RefSpec | undefined = REFS.get(refId);
    const refAudio: Float32Array | undefined = refAudios.get(refId);
    if (refSpec === undefined || refAudio === undefined) {
      const errMsg: Record<string, Object> = {
        'msgType': 'tts-generate-error',
        'requestId': requestId,
        'message': 'unknown refId ' + refId
      };
      workerPort.postMessage(errMsg);
      return;
    }

    const input: TtsInputWithConfig = new TtsInputWithConfig();
    input.text = text;
    input.enableExternalBuffer = false;
    const gen: TtsGenerationConfig = new TtsGenerationConfig();
    gen.referenceAudio = refAudio;
    gen.referenceSampleRate = REF_RATE;
    gen.referenceText = refSpec.text;
    gen.numSteps = NUM_STEPS;
    input.generationConfig = gen;

    const start: number = Date.now();
    try {
      const out: TtsOutput = tts.generateWithConfig(input);
      const elapsedMs: number = Date.now() - start;
      const audioDurationSec: number = out.samples.length / out.sampleRate;
      const rtf: number = (elapsedMs / 1000) / audioDurationSec;
      let mn: number = 1e30;
      let mx: number = -1e30;
      for (let i = 0; i < out.samples.length; i++) {
        const v: number = out.samples[i];
        if (v < mn) {
          mn = v;
        }
        if (v > mx) {
          mx = v;
        }
      }
      const h0: string = out.samples.length > 0 ? out.samples[0].toString() : 'n/a';
      const h1: string = out.samples.length > 1 ? out.samples[1].toString() : 'n/a';
      const h2: string = out.samples.length > 2 ? out.samples[2].toString() : 'n/a';
      const h3: string = out.samples.length > 3 ? out.samples[3].toString() : 'n/a';
      const h4: string = out.samples.length > 100 ? out.samples[100].toString() : 'n/a';
      const h5: string = out.samples.length > 1000 ? out.samples[1000].toString() : 'n/a';
      hilog.info(0x0000, 'ZvDiag',
        'len=%{public}d rate=%{public}d min=%{public}s max=%{public}s h0=%{public}s h1=%{public}s h2=%{public}s h3=%{public}s h100=%{public}s h1000=%{public}s',
        out.samples.length, out.sampleRate, mn.toString(), mx.toString(), h0, h1, h2, h3, h4, h5);
      const genDoneMsg: Record<string, Object> = {
        'msgType': 'tts-generate-done',
        'requestId': requestId,
        'samples': Float32Array.from(out.samples),
        'sampleRate': out.sampleRate,
        'elapsedMs': elapsedMs,
        'rtf': rtf,
        'sampleCount': out.samples.length
      };
      workerPort.postMessage(genDoneMsg);
    } catch (err) {
      const error = err as Error;
      const genErrMsg: Record<string, Object> = {
        'msgType': 'tts-generate-error',
        'requestId': requestId,
        'message': error.message
      };
      workerPort.postMessage(genErrMsg);
    }
  }
};

workerPort.onmessageerror = (e: MessageEvents) => {
};

workerPort.onerror = (e: ErrorEvent) => {
};