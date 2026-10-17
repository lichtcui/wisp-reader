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

if ! rg -q "import BuildProfile from 'BuildProfile'" "$ability" ||
   ! rg -q "t16MarkerPhase\(this\.context\) === 'seeded'" "$ability" ||
   ! rg -q 'T1\.6 cold source-store init deferred' "$ability"; then
  echo "ERROR: T1.6 cold readiness must defer the debug startup store init" >&2
  fail=1
fi

if ! rg -q "t16MarkerPhase\(ctx\) === 'seeded'" "$shelf"; then
  echo "ERROR: T1.6 cold readiness must defer the debug shelf consumer init" >&2
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
echo "T1.6 benchmark guard: ok (debug gate, first-frame path, single-row writes, one transaction)"
