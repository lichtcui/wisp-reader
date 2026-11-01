import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { fileIo } from '@kit.CoreFileKit';
import probe from 'libttsprobe.so';

const DOMAIN = 0x5454;
const TAG = 'TtsProbe';

@Entry
@Component
struct Index {
  @State status: string = 'Waiting for probe manifest';

  aboutToAppear(): void {
    this.runProbe();
  }

  private async runProbe(): Promise<void> {
    const baseDir = getContext(this).filesDir + '/tts-probe';
    const pointer = baseDir + '/current-run.txt';
    let manifest = '';
    this.status = 'Probe running';
    try {
      const runRoot = fileIo.readTextSync(pointer).trim();
      if (runRoot.length === 0) {
        throw new Error(`empty run pointer: ${pointer}`);
      }
      manifest = `${baseDir}/${runRoot}/manifest.tsv`;
      const result = `${baseDir}/${runRoot}/results.jsonl`;
      hilog.info(DOMAIN, TAG, 'Probe starting manifest=%{public}s', manifest);
      const reply: string = await probe.runManifest(manifest, result);
      this.status = reply;
      hilog.info(DOMAIN, TAG, 'Probe complete %{public}s', reply);
    } catch (error) {
      const failure = error as BusinessError;
      const detail = failure.message === undefined ? String(error) : failure.message;
      this.status = `Probe failed: ${detail}`;
      hilog.error(DOMAIN, TAG, 'Probe failed code=%{public}s message=%{public}s',
        String(failure.code), detail);
    }
  }

  build() {
    Column({ space: 16 }) {
      Text('TTS RTF probe')
        .fontSize(24)
        .fontWeight(FontWeight.Bold)
      Text(this.status)
        .fontSize(16)
        .textAlign(TextAlign.Center)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .padding(24)
  }
}
