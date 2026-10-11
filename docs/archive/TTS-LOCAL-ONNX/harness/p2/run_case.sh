#!/usr/bin/env bash
# Usage: run_case.sh <bundle_dir> <ref_text> <text> <run_count> <seed> <out_wav> <log_file>
set -euo pipefail
BUNDLE="$1"; REF_TEXT="$2"; TEXT="$3"; RUNS="$4"; SEED="$5"; OUT="$6"; LOG="$7"
REPO=/Users/lichtcui/Documents/playground/tts/gpt-sovits-onnx-rs
# rpath baked into binary via install_name_tool; no DYLD needed
export RUST_LOG=debug
/usr/bin/time -l "$REPO/target/release/examples/gpt_sovits_demo" \
  --model-path "$BUNDLE" \
  --ref-text "$REF_TEXT" \
  --text "$TEXT" \
  --run-count "$RUNS" \
  --seed "$SEED" \
  --output "$OUT" > "$LOG" 2>&1
