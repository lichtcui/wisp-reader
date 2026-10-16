import { fileIo } from '@kit.CoreFileKit';

/**
 * 预生成音频的本地索引（T-TTS-7 阶段二，设计见 `docs/research/TTS-PREGEN-IMPL.md` §3.4）。
 *
 * 一章 WAV 是 25–90 MB（24 kHz mono S16LE，3000 字 ≈ 31 MB / 9.8 min），**不能整块进 ArkTS 堆**，
 * 也不能一个 `ArrayBuffer` 走 HTTP（见 IMPL §3.4「为什么不整块读」）。这里的做法：
 * 音频先由 `TtsPregen` 流式落到 `cacheDir/pregen/<key>.wav`，播放时**按窗口滑读**——
 * 每 `PCM_WINDOW_BYTES` 从盘上一次 `readSync`，然后由 `writeData` 回调分次取走。
 *
 * 为什么不用 AVPlayer：AVPlayer 拿不到「当前源时间 ↔ 段落」的锚点（`framePos` 是渲染器时钟，
 * 段落高亮/进度条/progress claim 全都挂在 `TtsController.playedMs()` 上），而且 `setSpeed`
 * 的听感标定与实时链路要保持同一套口径。
 */

/** RIFF/WAVE 里的 PCM 布局。 */
export interface WavInfo {
  dataOffset: number;
  dataBytes: number;
  sampleRate: number;
  channels: number;
  bitsPerSample: number;
}

/** 每次从盘上读多少 PCM（262144 B = 5.5 s @24 kHz mono S16LE）。 */
const PCM_WINDOW_BYTES: number = 262144;
/** 探测 WAV 头的字节数（`wave` 写的标准文件头 44 B；留出 LIST/INFO 的余量）。 */
const HEADER_PROBE_BYTES: number = 64 * 1024;

function chunkId(bytes: Uint8Array, off: number): string {
  return String.fromCharCode(bytes[off], bytes[off + 1], bytes[off + 2], bytes[off + 3]);
}

/**
 * 源时间（ms）→ **整帧对齐**的 PCM 字节偏移。
 *
 * 拖动进度、从段中续播都靠它定位（`PregAudioSource.seekMs`）。**必须按帧取整**：16 bit mono
 * 时若按字节四舍五入，会落到奇数字节上，之后每个采样的高/低字节全部错位 ⇒ 听感直接变成
 * 刺耳白噪（真机 2026-10-14 拖进度条复现；`preg play … base=711.779449` → 34165 B 奇数）。
 */
export function pregSeekBytes(ms: number, sampleRate: number, frameBytes: number): number {
  return Math.round(ms / 1000 * sampleRate) * frameBytes;
}

/**
 * 从一个（至少覆盖文件头的）字节缓冲里解出 PCM 布局；不是合法 WAV 时返回 `undefined`。
 *
 * `dataBytes` 取文件头里声明的长度（0 视为「到文件尾」），由 `PregAudioSource` 再按真实
 * 文件大小夹一次——只读头时拿不到整文件长度。
 */
export function parseWavHeader(bytes: Uint8Array): WavInfo | undefined {
  if (bytes.length < 44 || chunkId(bytes, 0) !== 'RIFF' || chunkId(bytes, 8) !== 'WAVE') {
    return undefined;
  }
  const view: DataView = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const info: WavInfo = {
    dataOffset: 0,
    dataBytes: 0,
    sampleRate: 0,
    channels: 0,
    bitsPerSample: 0
  };
  let sawFmt: boolean = false;
  let sawData: boolean = false;
  let off: number = 12;
  while (off + 8 <= bytes.length) {
    const id: string = chunkId(bytes, off);
    const size: number = view.getUint32(off + 4, true);
    const body: number = off + 8;
    if (id === 'fmt ' && size >= 16 && body + 16 <= bytes.length) {
      info.channels = view.getUint16(body + 2, true);
      info.sampleRate = view.getUint32(body + 4, true);
      info.bitsPerSample = view.getUint16(body + 14, true);
      sawFmt = true;
    } else if (id === 'data') {
      info.dataOffset = body;
      info.dataBytes = size;
      sawData = true;
      break;
    }
    off = body + size + (size % 2);
  }
  if (!sawFmt || !sawData || info.sampleRate <= 0 || info.channels <= 0 || info.bitsPerSample <= 0) {
    return undefined;
  }
  return info;
}

/**
 * 滑窗读盘的文件 PCM 源。`read()` 在 `writeData` 回调里同步调用，一次调用最多一次系统调用。
 *
 * 校验口径与服务端一致：**24 kHz / mono / 16 bit**。对不上就直接抛错，让调用方回退实时链路
 * （宁可整章换路线，也不要把格式不对的字节喂给渲染器）。
 */
export class PregAudioSource {
  private fd: number = -1;
  private info: WavInfo;
  private dataEnd: number = 0;
  private pos: number = 0;
  private staging: ArrayBuffer = new ArrayBuffer(PCM_WINDOW_BYTES);
  private stagingView: Uint8Array = new Uint8Array(new ArrayBuffer(0));
  private stagedAt: number = 0;
  private staged: number = 0;

  /** @throws Error 文件缺失 / 不是 WAV / 不是 24 kHz mono S16LE */
  constructor(path: string) {
    const fd: number = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY).fd;
    let info: WavInfo | undefined = undefined;
    let fileBytes: number = 0;
    try {
      fileBytes = fileIo.statSync(path).size;
      const probeLen: number = Math.min(HEADER_PROBE_BYTES, fileBytes);
      const probe: ArrayBuffer = new ArrayBuffer(probeLen);
      const got: number = fileIo.readSync(fd, probe, { offset: 0, length: probeLen });
      info = parseWavHeader(new Uint8Array(probe, 0, got));
    } catch (err) {
      fileIo.closeSync(fd);
      throw new Error('preg audio unreadable');
    }
    if (info === undefined) {
      fileIo.closeSync(fd);
      throw new Error('preg audio not a wav');
    }
    if (info.sampleRate !== 24000 || info.channels !== 1 || info.bitsPerSample !== 16) {
      fileIo.closeSync(fd);
      throw new Error('preg audio format ' + info.sampleRate.toString() + '/' + info.channels.toString()
        + '/' + info.bitsPerSample.toString());
    }
    const declared: number = info.dataBytes > 0 ? info.dataBytes : fileBytes - info.dataOffset;
    this.dataEnd = info.dataOffset + Math.max(Math.min(declared, fileBytes - info.dataOffset), 0);
    this.fd = fd;
    this.info = info;
    this.pos = info.dataOffset;
    this.stagingView = new Uint8Array(this.staging);
  }

  /** 一帧（所有声道各一个采样）占多少字节。 */
  private frameBytes(): number {
    return (this.info.bitsPerSample >> 3) * this.info.channels;
  }

  /** PCM 总时长（ms），进度条/AVSession duration 用它，比字数估算准。 */
  durationMs(): number {
    return (this.dataEnd - this.info.dataOffset) / (this.info.sampleRate * this.frameBytes()) * 1000;
  }

  /** 当前读盘位置（源时间 ms）。 */
  positionMs(): number {
    return (this.pos - this.info.dataOffset) / (this.info.sampleRate * this.frameBytes()) * 1000;
  }

  /** 已经读完整段 PCM（`read()` 之后用）。 */
  atEnd(): boolean {
    return this.pos >= this.dataEnd;
  }

  /** 跳到某个源时间（拖动进度 / 从段落中间续播）；越界自动夹取。 */
  seekMs(ms: number): void {
    // 整帧对齐（见 `pregSeekBytes`）：对不齐就是整章白噪
    const target: number = this.info.dataOffset + pregSeekBytes(ms, this.info.sampleRate, this.frameBytes());
    this.pos = Math.min(Math.max(target, this.info.dataOffset), this.dataEnd);
    this.staged = 0;
    this.stagedAt = this.pos;
  }

  /**
   * 把接下来的 PCM 填进 `dest`；返回写入字节数（0 = 已到 PCM 末尾）。
   * 不足部分不补齐——调用方（`fill`）自己保持静音，避免制造假的段落边界。
   */
  read(dest: Uint8Array): number {
    let out: number = 0;
    while (out < dest.length) {
      if (this.pos < this.stagedAt || this.pos >= this.stagedAt + this.staged) {
        if (!this.refill()) {
          break;
        }
      }
      const at: number = this.pos - this.stagedAt;
      const n: number = Math.min(this.staged - at, dest.length - out);
      dest.set(this.stagingView.subarray(at, at + n), out);
      out += n;
      this.pos += n;
    }
    return out;
  }

  /** 一次系统调用填满 staging；返回是否还有数据。 */
  private refill(): boolean {
    if (this.pos >= this.dataEnd) {
      return false;
    }
    const want: number = Math.min(PCM_WINDOW_BYTES, this.dataEnd - this.pos);
    let got: number = 0;
    try {
      got = fileIo.readSync(this.fd, this.staging, { offset: this.pos, length: want });
    } catch (err) {
      got = 0;
    }
    if (got <= 0) {
      // 读盘失败当作读完：整章播放就此结束，而不是继续喂静音。
      this.pos = this.dataEnd;
      this.staged = 0;
      this.stagedAt = this.dataEnd;
      return false;
    }
    this.stagedAt = this.pos;
    this.staged = got;
    return true;
  }

  close(): void {
    if (this.fd < 0) {
      return;
    }
    try {
      fileIo.closeSync(this.fd);
    } catch (err) {
    }
    this.fd = -1;
    this.staged = 0;
  }
}
