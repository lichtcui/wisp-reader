import { appTasks } from '@ohos/hvigor-ohos-plugin';
import { existsSync, readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';

type SigningConfig = {
  name: string;
  type: string;
  material: Record<string, string>;
};

type SigningFile = {
  debug: SigningConfig | null;
  release: SigningConfig | null;
};

const signingMode: string = process.env.SOURCE_READER_SIGNING_MODE ?? 'debug';
if (signingMode !== 'debug' && signingMode !== 'release') {
  throw new Error('PUBLICATION_BLOCKED: SOURCE_READER_SIGNING_MODE must be debug or release');
}

const signingFile: string = process.env.SOURCE_READER_SIGNING_FILE ??
  join(homedir(), '.ohos', 'source-reader', 'signing.json');
if (!existsSync(signingFile)) {
  throw new Error('PUBLICATION_BLOCKED: external signing config is missing; run scripts/migrate-signing.sh');
}

let signingConfigs: SigningFile;
try {
  signingConfigs = JSON.parse(readFileSync(signingFile, 'utf8')) as SigningFile;
} catch {
  throw new Error('PUBLICATION_BLOCKED: external signing config is not valid JSON');
}

const signingConfig: SigningConfig | null = signingConfigs[signingMode as keyof SigningFile];
if (signingConfig === null || signingConfig === undefined) {
  throw new Error(`PUBLICATION_BLOCKED: ${signingMode} signing identity is not configured`);
}

const signingOverride = {
  type: signingConfig.type,
  material: signingConfig.material
};

export default {
  system: appTasks,
  plugins: [],
  config: {
    ohos: {
      overrides: {
        signingConfig: signingOverride
      }
    }
  }
}
