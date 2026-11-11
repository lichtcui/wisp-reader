#!/usr/bin/env bash
set -euo pipefail

SIGNING_FILE="${WISP_READER_SIGNING_FILE:-$HOME/.ohos/wisp-reader/signing.json}"

node - "$SIGNING_FILE" <<'NODE'
const fs = require('node:fs');
const path = process.argv[2];

function blocked(message) {
  process.stderr.write(`PUBLICATION_BLOCKED: ${message}\n`);
  process.exit(1);
}

if (!fs.existsSync(path)) {
  blocked('external signing config is missing');
}

let configs;
try {
  configs = JSON.parse(fs.readFileSync(path, 'utf8'));
} catch {
  blocked('external signing config is not valid JSON');
}

const release = configs?.release;
const required = ['storeFile', 'storePassword', 'keyAlias', 'keyPassword', 'signAlg', 'profile', 'certpath'];
if (!release || typeof release !== 'object' || !release.material || typeof release.material !== 'object') {
  blocked('release signing identity is not configured');
}
for (const key of required) {
  if (typeof release.material[key] !== 'string' || release.material[key].length === 0) {
    blocked(`release signing material is missing ${key}`);
  }
}
if (release.type !== 'HarmonyOS') {
  blocked('release signing type must be HarmonyOS');
}

const debug = configs?.debug;
if (debug && debug.material &&
    debug.material.keyAlias === release.material.keyAlias &&
    debug.material.certpath === release.material.certpath &&
    debug.material.profile === release.material.profile) {
  blocked('release signing identity matches debug');
}
NODE

echo "Release signing identity is configured."
