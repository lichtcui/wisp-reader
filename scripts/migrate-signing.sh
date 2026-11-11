#!/usr/bin/env bash
# Move the local signing identity out of build-profile.json5.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILE="$ROOT/build-profile.json5"
TARGET="${WISP_READER_SIGNING_FILE:-$HOME/.ohos/wisp-reader/signing.json}"
FORCE=0

case "${1:-}" in
  "")
    ;;
  --force)
    FORCE=1
    ;;
  *)
    echo "Usage: scripts/migrate-signing.sh [--force]" >&2
    exit 2
    ;;
esac

case "$TARGET" in
  "$ROOT"/*)
    echo "ERROR: signing config must stay outside the repository" >&2
    exit 1
    ;;
esac

if [ ! -f "$PROFILE" ]; then
  echo "ERROR: missing build-profile.json5" >&2
  exit 1
fi

TARGET_DIR="$(dirname "$TARGET")"
umask 077
mkdir -p "$TARGET_DIR"
chmod 700 "$TARGET_DIR"

if [ -e "$TARGET" ] && [ "$FORCE" -ne 1 ]; then
  echo "ERROR: external signing config already exists; pass --force to replace it" >&2
  exit 1
fi

node - "$PROFILE" "$TARGET" "$FORCE" <<'NODE'
const fs = require('node:fs');
const path = require('node:path');

const [profilePath, targetPath, forceArg] = process.argv.slice(2);
const force = forceArg === '1';

let profile;
try {
  profile = JSON.parse(fs.readFileSync(profilePath, 'utf8'));
} catch {
  process.stderr.write('ERROR: build-profile.json5 is not valid JSON\n');
  process.exit(1);
}

const configs = profile?.app?.signingConfigs;
if (!Array.isArray(configs) || configs.length !== 1) {
  process.stderr.write('ERROR: expected exactly one current signing config\n');
  process.exit(1);
}

const current = configs[0];
const required = ['storeFile', 'storePassword', 'keyAlias', 'keyPassword', 'signAlg', 'profile', 'certpath'];
if (!current || typeof current !== 'object' || !current.material || typeof current.material !== 'object') {
  process.stderr.write('ERROR: current signing config has no material\n');
  process.exit(1);
}
for (const key of required) {
  if (typeof current.material[key] !== 'string' || current.material[key].length === 0) {
    process.stderr.write(`ERROR: current signing material is missing ${key}\n`);
    process.exit(1);
  }
}
if (typeof current.type !== 'string' || current.type.length === 0) {
  process.stderr.write('ERROR: current signing config has no type\n');
  process.exit(1);
}

if (force && fs.existsSync(targetPath)) {
  const stamp = new Date().toISOString().replace(/[-:.TZ]/g, '');
  const backupPath = `${targetPath}.bak.${stamp}`;
  fs.copyFileSync(targetPath, backupPath, fs.constants.COPYFILE_EXCL);
  fs.chmodSync(backupPath, 0o600);
}

const external = {
  debug: {
    name: 'debug',
    type: current.type,
    material: current.material
  },
  release: null
};

const tempPath = path.join(path.dirname(targetPath), `.signing.${process.pid}.tmp`);
try {
  fs.writeFileSync(tempPath, JSON.stringify(external, null, 2) + '\n', { mode: 0o600, flag: 'wx' });
  fs.chmodSync(tempPath, 0o600);
  fs.renameSync(tempPath, targetPath);
} finally {
  try {
    fs.unlinkSync(tempPath);
  } catch {
    // The rename consumes the temporary file on success.
  }
}

profile.app.signingConfigs = [];
for (const product of profile.app.products ?? []) {
  delete product.signingConfig;
}
fs.writeFileSync(profilePath, JSON.stringify(profile, null, 2) + '\n');
NODE

chmod 600 "$TARGET"
echo "Signing config migrated outside the repository."
