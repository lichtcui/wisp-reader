#!/usr/bin/env bash
# Guard the debug-only T1.6 benchmark entry and its performance-critical paths.
set -euo pipefail
cd "$(dirname "$0")/.."

fail=0

if ! rg -q 'T16_BENCH_ROW_COUNT: number = 3000' entry/src/main/ets/common/Const.ets; then
  echo "ERROR: T1.6 benchmark row count must stay at 3000" >&2
  fail=1
fi

page=entry/src/main/ets/pages/BookSourceManage.ets
bench=entry/src/main/ets/model/SourceStoreBench.ets
store=entry/src/main/ets/model/SourceStore.ets
ability=entry/src/main/ets/entryability/EntryAbility.ets
shelf=entry/src/main/ets/pages/Shelf.ets
shelf_store=entry/src/main/ets/model/ShelfRepository.ets
runner=entry/src/main/ets/model/DetectJobRunner.ets

if ! rg -q 'import BuildProfile from '\''BuildProfile'\''' "$page" ||
   ! rg -q 'if \(BuildProfile\.DEBUG\)' "$page" ||
   ! rg -q 'seedT16Sources\(ctx\)' "$page"; then
  echo "ERROR: T1.6 seed entry must be gated by BuildProfile.DEBUG" >&2
  fail=1
fi

ready_body="$(sed -n '/private async runT16Ready/,/^  }/p' "$page")"
if ! printf '%s\n' "$ready_body" | rg -q 'measureT16Ready\(ctx\)' ||
   ! printf '%s\n' "$ready_body" | rg -q 'restoreT16Backup\(ctx\)'; then
  echo "ERROR: T1.6 readiness must measure then restore after the page appears" >&2
  fail=1
fi
if ! rg -q '\.onAppear\(\(\) => \{' "$page"; then
  echo "ERROR: T1.6 readiness is missing the first-frame onAppear trigger" >&2
  fail=1
fi

if rg -q 't16MarkerPhase|BuildProfile' "$ability"; then
  echo "ERROR: production startup must always initialize the source store" >&2
  fail=1
fi

if rg -q 't16MarkerPhase|BuildProfile' "$shelf"; then
  echo "ERROR: the shelf must not depend on T1.6 benchmark markers" >&2
  fail=1
fi

remove_body="$(sed -n '/private async removeSource/,/^  }/p' "$page")"
toggle_body="$(sed -n '/private async toggleSource/,/^  }/p' "$page")"
for body in "$remove_body" "$toggle_body"; do
  if printf '%s\n' "$body" | rg -q 'this\.reload\('; then
    echo "ERROR: T1.6 single-row UI actions must not reload the full projection" >&2
    fail=1
  fi
done

upsert_body="$(sed -n '/export async function upsertMany/,/^}/p' "$store")"
if ! printf '%s\n' "$upsert_body" | rg -q 'createTransaction\(\)' ||
   ! printf '%s\n' "$upsert_body" | rg -q 'tx\.commit\(\)' ||
   ! printf '%s\n' "$upsert_body" | rg -q 'tx\.rollback\(\)'; then
  echo "ERROR: upsertMany must remain a single committed transaction" >&2
  fail=1
fi

require_transaction() {
  local file="$1"
  local fn="$2"
  local body
  body="$(sed -n "/export async function ${fn}/,/^}/p" "$file")"
  if ! printf '%s\n' "$body" | rg -q 'createTransaction\(\)' ||
     ! printf '%s\n' "$body" | rg -q 'tx\.commit\(\)' ||
     ! printf '%s\n' "$body" | rg -q 'tx\.rollback\(\)'; then
    echo "ERROR: ${fn} must remain a single committed transaction" >&2
    fail=1
  fi
}

for fn in removeBooks replaceShelf; do
  require_transaction "$shelf_store" "$fn"
done
for fn in setEnabledMany removeMany patchDetects; do
  require_transaction "$store" "$fn"
done

for file in "$shelf_store" "$store"; do
  if ! rg -q 'const ID_CHUNK_SIZE: number = 400;' "$file"; then
    echo "ERROR: bulk id writes must keep the 400-id chunk below SQLite's bind limit" >&2
    fail=1
  fi
done
remove_books_body="$(sed -n '/export async function removeBooks/,/^}/p' "$shelf_store")"
enable_many_body="$(sed -n '/export async function setEnabledMany/,/^}/p' "$store")"
remove_many_body="$(sed -n '/export async function removeMany/,/^}/p' "$store")"
for body in "$remove_books_body" "$enable_many_body" "$remove_many_body"; do
  if ! printf '%s\n' "$body" | rg -q 'IN \(' ||
     ! printf '%s\n' "$body" | rg -q 'ID_CHUNK_SIZE'; then
    echo "ERROR: bulk id writes must chunk IN (...) queries by ID_CHUNK_SIZE" >&2
    fail=1
  fi
done

sources_for_engine_body="$(sed -n '/export async function sourcesForEngine/,/^}/p' "$store")"
if ! printf '%s\n' "$sources_for_engine_body" | rg -q 'ID_CHUNK_SIZE' ||
   ! printf '%s\n' "$sources_for_engine_body" | rg -q 'IN \('; then
  echo "ERROR: sourcesForEngine must chunk IN (...) lookups by ID_CHUNK_SIZE" >&2
  fail=1
fi

sources_for_urls_body="$(sed -n '/export async function sourcesForUrls/,/^}/p' "$store")"
if ! printf '%s\n' "$sources_for_urls_body" | rg -q 'ID_CHUNK_SIZE' ||
   ! printf '%s\n' "$sources_for_urls_body" | rg -q 'IN \('; then
  echo "ERROR: sourcesForUrls must chunk IN (...) lookups by ID_CHUNK_SIZE" >&2
  fail=1
fi
if ! rg -q "const FULL_COLS: string = 'enabled, json, confidence';" "$store"; then
  echo "ERROR: full source reads must overlay the authoritative enabled column" >&2
  fail=1
fi

backup=entry/src/main/ets/pages/BackupManage.ets
if rg -q '\b(openSync|statSync|readSync|writeSync|closeSync)\s*\(' "$backup"; then
  echo "ERROR: BackupManage file I/O must stay asynchronous and chunked" >&2
  fail=1
fi
if ! rg -q 'class BackupWriter' "$backup" ||
   ! rg -q 'new BackupWriter\(tempFile\.fd\)' "$backup"; then
  echo "ERROR: BackupManage must reuse one encoder and byte buffer per export" >&2
  fail=1
fi
if ! rg -q 'fileIo\.copyFile\(tempPath, target\.fd\)' "$backup" ||
   ! rg -q 'BACKUP_TEMP_SUFFIX' "$backup"; then
  echo "ERROR: BackupManage must finish in a temp file before replacing the target" >&2
  fail=1
fi

disable_body="$(sed -n '/private async disableUnavailable/,/^  }/p' "$page")"
delete_unavailable_body="$(sed -n '/private async deleteUnavailable/,/^  }/p' "$page")"
if ! printf '%s\n' "$disable_body" | rg -q 'setEnabledMany\(' ||
   printf '%s\n' "$disable_body" | rg -q 'await setEnabled\('; then
  echo "ERROR: closing all unavailable sources must use one setEnabledMany() batch" >&2
  fail=1
fi
if ! printf '%s\n' "$delete_unavailable_body" | rg -q 'removeMany\(' ||
   printf '%s\n' "$delete_unavailable_body" | rg -q 'await remove\('; then
  echo "ERROR: deleting all unavailable sources must use one removeMany() batch" >&2
  fail=1
fi

run_batch_body="$(sed -n '/private async runBatch/,/^  }/p' "$runner")"
recover_body="$(sed -n '/private async recoverRunning/,/^  }/p' "$runner")"
for body in "$run_batch_body" "$recover_body"; do
  if ! printf '%s\n' "$body" | rg -q 'await patchDetects\(' ||
     printf '%s\n' "$body" | rg -q 'await patchDetect\('; then
    echo "ERROR: detect result persistence must patch each batch in one transaction" >&2
    fail=1
  fi
done

set_body="$(sed -n '/export async function setEnabled/,/^}/p' "$store")"
remove_store_body="$(sed -n '/export async function remove/,/^}/p' "$store")"
for body in "$set_body" "$remove_store_body"; do
  if printf '%s\n' "$body" | rg -q 'JSON\.stringify|exportAll|replaceAll'; then
    echo "ERROR: single-row store writes must not serialize the source table" >&2
    fail=1
  fi
done

if rg -q 'interface ParsedDataset' "$bench"; then
  echo "ERROR: SourceStoreBench JSON helpers must not add keep-list interfaces" >&2
  fail=1
fi

if rg -q 'hilog -r' Makefile; then
  echo "ERROR: make log must not clear the buffer it is about to dump" >&2
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  exit 1
fi
echo "T1.6 benchmark guard: ok (debug gate, first-frame path, single-row UI writes, batched reads/writes)"
