#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

OUT_DIR=build/outputs/default
APP="$OUT_DIR/wisp-reader-default-signed.app"

"$ROOT/scripts/release-preflight.sh"

node - "$OUT_DIR" <<'NODE'
const fs = require('node:fs');
const path = require('node:path');
const dir = process.argv[2];
if (!fs.existsSync(dir)) process.exit(0);
for (const name of fs.readdirSync(dir)) {
  if (name.endsWith('.app')) fs.unlinkSync(path.join(dir, name));
}
NODE

if [ -z "${HVIGORW:-}" ]; then
  echo "ERROR: HVIGORW is not set" >&2
  exit 1
fi

WISP_READER_SIGNING_MODE=release "$HVIGORW" assembleApp \
  --mode project -p product=default -p buildMode=release

node - "$OUT_DIR" "$APP" <<'NODE'
const fs = require('node:fs');
const path = require('node:path');
const dir = process.argv[2];
const expected = process.argv[3];
const apps = [];

function visit(current) {
  if (!fs.existsSync(current)) return;
  for (const entry of fs.readdirSync(current, { withFileTypes: true })) {
    const full = path.join(current, entry.name);
    if (entry.isDirectory()) visit(full);
    else if (entry.isFile() && entry.name.endsWith('.app')) apps.push(full);
  }
}

visit(dir);
const signed = apps.filter((file) => file.endsWith('-signed.app'));
if (signed.length !== 1 || path.resolve(signed[0]) !== path.resolve(expected)) {
  process.stderr.write('ERROR: expected exactly one newly built signed APP\n');
  process.exit(1);
}
console.log(`APP_BUILT: ${expected}`);
NODE
