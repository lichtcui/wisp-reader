import { http } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';

/** Find the PCM payload of a RIFF/WAV buffer by walking its chunks. */
function wavData(wav: ArrayBuffer): ArrayBuffer {
  if (wav.byteLength < 12) {
    return new ArrayBuffer(0);
  }
  const view: DataView = new DataView(wav);
  let off: number = 12;
  while (off + 8 <= wav.byteLength) {
    const id: string = String.fromCharCode(
      view.getUint8(off), view.getUint8(off + 1),
      view.getUint8(off + 2), view.getUint8(off + 3)
    );
    const size: number = view.getUint32(off + 4, true);
    if (id === 'data') {
      const start: number = off + 8;
      const end: number = Math.min(start + size, wav.byteLength);
      return wav.slice(start, end);
    }
    off += 8 + size + (size % 2);
  }
  // Non-chunked fallback: standard 44-byte header.
  return wav.slice(44);
}

/**
 * POST /tts on the remote service and return the payload as S16LE PCM (mono,
 * server's native sample rate). Throws on HTTP error / network failure so the
 * caller can fall back to the system TTS engine.
 */
export async function remoteSynthesize(
  serverUrl: string,
  apiKey: string,
  text: string,
  voice: string
): Promise<ArrayBuffer> {
  const request: http.HttpRequest = http.createHttp();
  try {
    const body: string = JSON.stringify({ text: text, voice: voice, speed: 1.0 });
    const header: Record<string, string> = { 'Content-Type': 'application/json' };
    if (apiKey.length > 0) {
      header['X-API-Key'] = apiKey;
    }
    const response: http.HttpResponse = await request.request(serverUrl + '/tts', {
      method: http.RequestMethod.POST,
      header: header,
      extraData: body,
      expectDataType: http.HttpDataType.ARRAY_BUFFER,
      connectTimeout: 5000,
      readTimeout: 60000
    });
    if (response.responseCode !== 200) {
      throw new Error('http ' + response.responseCode.toString());
    }
    return wavData(response.result as ArrayBuffer);
  } catch (err) {
    const e = err as BusinessError;
    throw new Error(e.message);
  } finally {
    request.destroy();
  }
}