import { appTasks } from '@ohos/hvigor-ohos-plugin';
import { existsSync, readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';

type SigningConfig = {
  type: string;
  material: Record<string, string>;
};

type SigningFile = {
  debug: SigningConfig | null;
};

const signingFile = process.env.SOURCE_READER_SIGNING_FILE ??
  join(homedir(), '.ohos', 'source-reader', 'signing.json');
if (!existsSync(signingFile)) {
  throw new Error(`TTS probe signing config missing: ${signingFile}`);
}
const signing = JSON.parse(readFileSync(signingFile, 'utf8')) as SigningFile;
if (signing.debug === null) {
  throw new Error('TTS probe requires a debug signing identity');
}

export default {
  system: appTasks,
  plugins: [],
  config: {
    ohos: {
      overrides: {
        signingConfig: {
          type: signing.debug.type,
          material: signing.debug.material
        }
      }
    }
  }
};
