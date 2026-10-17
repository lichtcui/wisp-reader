#!/usr/bin/env bash
# Guard the T1.5 read path: UI consumers use SourceRow projections, and the legacy
# full JSON blob reader stays confined to the storage layer.
set -euo pipefail
cd "$(dirname "$0")/.."

fail=0

legacy="$(rg -n '\bloadSources\b' entry/src/main/ets || true)"
stray="$(printf '%s\n' "$legacy" | grep -v '^entry/src/main/ets/model/SourceRepository.ets:' || true)"
if [ -n "$stray" ]; then
  echo "ERROR: loadSources is only allowed in model/SourceRepository.ets:" >&2
  printf '%s\n' "$stray" >&2
  fail=1
fi

consumers=(
  entry/src/main/ets/pages/Index.ets
  entry/src/main/ets/pages/Shelf.ets
  entry/src/main/ets/pages/SearchResult.ets
  entry/src/main/ets/components/SourceSwitchPanel.ets
  entry/src/main/ets/pages/BookSourceManage.ets
)
for f in "${consumers[@]}"; do
  if rg -q '\bloadSources\s*\(' "$f"; then
    echo "ERROR: $f calls the legacy full source loader" >&2
    fail=1
  fi
  if rg -q '\b(saveSources|resetToBundled|enabledSources|dedupeByUrl)\s*\(' "$f"; then
    echo "ERROR: $f uses the legacy preferences-backed source API" >&2
    fail=1
  fi
  if ! rg -q '\blistRows\s*\(' "$f"; then
    echo "ERROR: $f must read the SourceRow projection via listRows()" >&2
    fail=1
  fi
  if ! rg -q '\bensureSourceStore\s*\(' "$f"; then
    echo "ERROR: $f must initialize the shared SourceStore before reading it" >&2
    fail=1
  fi
done

# Reading every rule blob is only valid at the engine boundary. BookSourceManage may
# do it for an explicit detect run; the read path must not.
for f in "${consumers[@]:0:4}"; do
  if rg -q '\ballForEngine\s*\(' "$f"; then
    echo "ERROR: $f must not materialize every BookSource on the read path" >&2
    fail=1
  fi
done

# Search and source switching must query the same enabled rows as the management page.
for f in \
  entry/src/main/ets/pages/SearchResult.ets \
  entry/src/main/ets/components/SourceSwitchPanel.ets; do
  if ! rg -q 'listRows\(\{ enabled: true \}\)' "$f"; then
    echo "ERROR: $f must filter enabled sources in SQL" >&2
    fail=1
  fi
done

# SearchResult stays mounted across keyword submissions. Re-read the projection on every new
# token so a source toggled in management cannot leave a stale enabled set in the search page.
search_monitor="$(sed -n '/onSearchTokenChange(): void/,/^  }/p' entry/src/main/ets/pages/SearchResult.ets || true)"
if ! printf '%s\n' "$search_monitor" | rg -q '\bthis\.prepareSearch\s*\('; then
  echo "ERROR: SearchResult must reload the source projection for each search token" >&2
  fail=1
fi

if rg -q '\bloadSources\b' entry/src/main/ets/entryability/EntryAbility.ets; then
  echo "ERROR: EntryAbility must initialize through ensureSourceStore()" >&2
  fail=1
fi
if ! rg -q '\bensureSourceStore\s*\(' entry/src/main/ets/entryability/EntryAbility.ets; then
  echo "ERROR: EntryAbility is missing ensureSourceStore()" >&2
  fail=1
fi

# A completed migration still needs to open the SQLite store in each app process.
# The marker only skips parsing the legacy blob; it is not an open-store guard.
ensure_body="$(sed -n '/^async function ensureRun/,/^}/p' entry/src/main/ets/model/SourceStoreMigration.ets)"
if ! printf '%s\n' "$ensure_body" | rg -q '\bawait initSourceStore\s*\(ctx\)'; then
  echo "ERROR: SourceStoreMigration.ensureRun must initialize the store before checking the migration marker" >&2
  fail=1
fi

# The startup and read-path files must not parse source JSON themselves. Full-source
# parsing is confined to SourceStore.getSource() and the one-time migration.
for f in \
  entry/src/main/ets/entryability/EntryAbility.ets \
  entry/src/main/ets/pages/Index.ets \
  entry/src/main/ets/pages/Shelf.ets \
  entry/src/main/ets/pages/SearchResult.ets; do
  if rg -q '\bJSON\.parse\s*\(' "$f"; then
    echo "ERROR: $f parses JSON on the startup/read path" >&2
    fail=1
  fi
done

if [ "$fail" -ne 0 ]; then
  exit 1
fi
echo "source consumers: ok (projection reads, lazy full-source loads)"
