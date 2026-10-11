import worker, { MessageEvents, ErrorEvent } from '@ohos.worker';
import { audio } from '@kit.AudioKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0000;
const TAG: string = 'ZipVoiceTts';
const TEST_TEXT: string = '傍晚的风从河谷里爬上来，带着湿润的青草气味。';

@ComponentV2
export struct ZipVoiceTestPage {
  @Local status: string = '初始化中…';
  @Local initDone: boolean = false;
  @Local generating: boolean = false;
  @Local rtfText: string = '';
  private workerInstance: worker.ThreadWorker | undefined = undefined;
  private renderer: audio.AudioRenderer | undefined = undefined;
  private sampleRate: number = 24000;
  private chunks: Float32Array[] = [];
  private chunkHead: number = 0;
  private seq: number = 0;

  aboutToAppear(): void {
    this.workerInstance = new worker.ThreadWorker('entry/ets/workers/ZipVoiceTtsWorker.ets', {
      name: 'ZipVoiceTtsWorker'
    });
    this.workerInstance.onmessage = (e: MessageEvents) => {
      this.onMessage(e);
    };
    this.workerInstance.onerror = (e: ErrorEvent) => {
      hilog.error(DOMAIN, TAG, 'worker error %{public}s', e.message);
      this.status = 'worker error: ' + e.message;
    };
    const initMsg: Record<string, Object> = {
      'msgType': 'init-tts',
      'context': getContext()
    };
    this.workerInstance.postMessage(initMsg);
  }

  aboutToDisappear(): void {
    this.stopRenderer();
    if (this.workerInstance !== undefined) {
      this.workerInstance.terminate();
      this.workerInstance = undefined;
    }
  }

  private onMessage(e: MessageEvents): void {
    const msgType: string = e.data['msgType'] as string;
    if (msgType === 'init-tts-done') {
      this.sampleRate = e.data['sampleRate'] as number;
      const refCount: number = e.data['refCount'] as number;
      this.initDone = true;
      this.status = '模型初始化完成 · 采样率 ' + this.sampleRate.toString()
        + ' · ' + refCount.toString() + ' 个参考音色';
    } else if (msgType === 'init-tts-error') {
      this.status = '初始化失败: ' + (e.data['message'] as string);
    } else if (msgType === 'tts-generate-done') {
      this.generating = false;
      const samples: Float32Array = e.data['samples'] as Float32Array;
      const sampleRate: number = e.data['sampleRate'] as number;
      const elapsedMs: number = e.data['elapsedMs'] as number;
      const rtf: number = e.data['rtf'] as number;
      const sampleCount: number = e.data['sampleCount'] as number;
      this.rtfText = '音频 ' + (sampleCount / sampleRate).toFixed(2) + 's · 合成 ' + (elapsedMs / 1000).toFixed(2)
        + 's · RTF ' + rtf.toFixed(3) + ' · ' + sampleCount.toString() + ' 采样';
      this.status = '合成完成，播放中';
      this.chunks.push(samples);
      this.play();
    } else if (msgType === 'tts-generate-error') {
      this.generating = false;
      this.status = '合成失败: ' + (e.data['message'] as string);
    }
  }

  private generate(): void {
    if (!this.initDone || this.generating) {
      return;
    }
    this.generating = true;
    this.status = '合成中…';
    this.chunks = [];
    this.chunkHead = 0;
    this.rtfText = '';
    this.stopRenderer();
    const genMsg: Record<string, Object> = {
      'msgType': 'tts-generate',
      'requestId': this.seq.toString(),
      'text': TEST_TEXT,
      'refId': 'liuying'
    };
    this.seq++;
    this.workerInstance?.postMessage(genMsg);
  }

  // ── Streaming playback (24000 Hz S16LE) ──────────────────────

  private async play(): Promise<void> {
    try {
      const renderer: audio.AudioRenderer = await this.ensureRenderer();
      if (renderer.state === audio.AudioState.STATE_RUNNING) {
        return;
      }
      renderer.on('writeData', (buffer: ArrayBuffer) => {
        this.fill(buffer);
      });
      await renderer.start();
    } catch (err) {
      const e = err as Error;
      this.status = '播放失败: ' + e.message;
    }
  }

  private async ensureRenderer(): Promise<audio.AudioRenderer> {
    if (this.renderer !== undefined) {
      return this.renderer;
    }
    const streamInfo: audio.AudioStreamInfo = {
      samplingRate: this.sampleRate === 16000
        ? audio.AudioSamplingRate.SAMPLE_RATE_16000
        : audio.AudioSamplingRate.SAMPLE_RATE_24000,
      channels: audio.AudioChannel.CHANNEL_1,
      sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
      encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW
    };
    const rendererInfo: audio.AudioRendererInfo = {
      usage: audio.StreamUsage.STREAM_USAGE_MUSIC,
      rendererFlags: 0
    };
    const options: audio.AudioRendererOptions = {
      streamInfo: streamInfo,
      rendererInfo: rendererInfo
    };
    this.renderer = await audio.createAudioRenderer(options);
    return this.renderer;
  }

  private fill(buffer: ArrayBuffer): void {
    const out: Int16Array = new Int16Array(buffer);
    const n: number = out.length;
    let pos: number = 0;
    while (pos < n && this.chunks.length > 0) {
      const head: Float32Array = this.chunks[0];
      const avail: number = head.length - this.chunkHead;
      const take: number = Math.min(avail, n - pos);
      for (let i = 0; i < take; i++) {
        let s: number = head[this.chunkHead + i] * 32767;
        s = s > 32767 ? 32767 : s;
        s = s < -32768 ? -32768 : s;
        out[pos + i] = s;
      }
      pos += take;
      this.chunkHead += take;
      if (this.chunkHead >= head.length) {
        this.chunks.shift();
        this.chunkHead = 0;
      }
    }
    // Underrun: fill remainder with silence, stop only once synthesis finished.
    if (pos < n) {
      out.fill(0, pos);
      if (!this.generating) {
        this.renderer?.stop().catch(() => {
        });
      }
    }
  }

  private stopRenderer(): void {
    const renderer: audio.AudioRenderer | undefined = this.renderer;
    if (renderer === undefined) {
      return;
    }
    this.renderer = undefined;
    try {
      renderer.stop();
      renderer.release();
    } catch (err) {
    }
  }

  build() {
    Column({ space: 20 }) {
      Text('ZipVoice 端侧离线听书测试')
        .fontSize(18)
        .fontWeight(FontWeight.Bold)

      Text(this.status)
        .fontSize(14)
        .fontColor($r('app.color.text_2'))

      if (this.rtfText !== '') {
        Text(this.rtfText)
          .fontSize(14)
          .fontColor($r('app.color.text_1'))
      }

      Button('生成并播放')
        .enabled(this.initDone && !this.generating)
        .onClick(() => this.generate())
    }
    .width('100%')
    .height('100%')
    .padding(20)
    .justifyContent(FlexAlign.Center)
    .backgroundColor($r('app.color.bg_page'))
  }
}