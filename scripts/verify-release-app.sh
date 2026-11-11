#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

MODE="${1:-app}"
case "$MODE" in
  app|profile)
    ;;
  *)
    echo "Usage: scripts/verify-release-app.sh [app|profile]" >&2
    exit 2
    ;;
esac

BUNDLE="${BUNDLE:-com.lichtcui.wispreader}"
APP="${APP_PATH:-build/outputs/default/wisp-reader-default-signed.app}"
JAVA="${JAVA:-$DEVECO/Contents/jbr/Contents/Home/bin/java}"
SIGN_TOOL="${SIGN_TOOL:-$DEVECO_SDK_HOME/default/openharmony/toolchains/lib/hap-sign-tool.jar}"

"$ROOT/scripts/release-preflight.sh"

if [ ! -f "$APP" ]; then
  echo "ERROR: signed APP is missing; run make app-release" >&2
  exit 1
fi
if [ ! -x "$JAVA" ] || [ ! -f "$SIGN_TOOL" ]; then
  echo "ERROR: Java or hap-sign-tool is unavailable" >&2
  exit 1
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/wisp-reader-release.XXXXXX")"
CERT="$TMP/cert-chain.cer"
PROFILE="$TMP/profile.p7b"
PROFILE_JSON="$TMP/profile.json"

if ! "$JAVA" -jar "$SIGN_TOOL" verify-app \
    -inFile "$APP" -inForm zip -outCertChain "$CERT" -outProfile "$PROFILE" \
    > "$TMP/verify-app.log" 2>&1; then
  echo "ERROR: verify-app failed" >&2
  exit 1
fi
if ! grep -q 'Digest verify result: true' "$TMP/verify-app.log"; then
  echo "ERROR: APP digest verification did not pass" >&2
  exit 1
fi

if ! "$JAVA" -jar "$SIGN_TOOL" verify-profile \
    -inFile "$PROFILE" -outFile "$PROFILE_JSON" \
    > "$TMP/verify-profile.log" 2>&1; then
  echo "ERROR: verify-profile failed" >&2
  exit 1
fi

node - "$PROFILE_JSON" "$BUNDLE" <<'NODE'
const fs = require('node:fs');
const [profilePath, expectedBundle] = process.argv.slice(2);
let result;
try {
  result = JSON.parse(fs.readFileSync(profilePath, 'utf8'));
} catch {
  process.stderr.write('ERROR: profile verification result is not valid JSON\n');
  process.exit(1);
}

const content = result?.content;
if (result.verifiedPassed !== true || !content) {
  process.stderr.write('ERROR: profile verification did not pass\n');
  process.exit(1);
}
if (content.type !== 'release') {
  process.stderr.write('ERROR: profile is not a release profile\n');
  process.exit(1);
}
if (content['bundle-info']?.['bundle-name'] !== expectedBundle) {
  process.stderr.write('ERROR: profile bundle does not match the expected bundle\n');
  process.exit(1);
}
const debugInfo = content['debug-info'];
if (debugInfo && typeof debugInfo === 'object' && Object.keys(debugInfo).length > 0) {
  process.stderr.write('ERROR: release profile contains debug identity data\n');
  process.exit(1);
}
const now = Date.now();
const notAfter = Number(content.validity?.['not-after']);
if (Number.isFinite(notAfter) && notAfter > 0) {
  const expiryMs = notAfter < 10_000_000_000 ? notAfter * 1000 : notAfter;
  if (expiryMs <= now) {
    process.stderr.write('ERROR: release profile is expired\n');
    process.exit(1);
  }
}
NODE

if grep -qi 'debug' "$CERT"; then
  echo "ERROR: certificate chain contains a debug identity" >&2
  exit 1
fi

if [ "$MODE" = "app" ]; then
  echo "APP_VERIFY_OK"
fi
echo "PROFILE_VERIFY_OK"
echo "APP_SHA256: $(shasum -a 256 "$APP" | awk '{print $1}')"
