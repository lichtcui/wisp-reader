#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SO=entry/libs/arm64-v8a/liblegado_core.so
DTS=entry/src/main/cpp/types/liblegado_core/index.d.ts
DIST_DTS=rust/legado-core/dist/index.d.ts
LIB_RS=rust/legado-core/src/lib.rs

FAIL=0
bad() {
  echo "ERROR: $1" >&2
  FAIL=1
}

if [ ! -f "$SO" ]; then
  bad "$SO is missing; run make rust"
else
  stale="$(find rust -name '*.rs' -path '*/src/*' \
    -not -path '*/target/*' -not -path '*/dist/*' -newer "$SO" -print -quit 2>/dev/null)"
  if [ -n "$stale" ]; then
    bad "$SO is older than Rust source; run make rust"
  fi
fi

if [ ! -f "$DTS" ]; then
  bad "$DTS is missing; run make rust"
elif [ -f "$LIB_RS" ] && [ "$LIB_RS" -nt "$DTS" ]; then
  bad "$DTS is older than rust/legado-core/src/lib.rs; run make rust"
elif [ -f "$DIST_DTS" ] && ! cmp -s "$DIST_DTS" "$DTS"; then
  bad "$DTS differs from rust/legado-core/dist/index.d.ts; run make rust"
fi

if [ "$FAIL" -ne 0 ]; then
  exit 1
fi
echo "Native artifacts are fresh."
