#!/usr/bin/env bash
set -euo pipefail

CACHE_ROOT="${TTS_PROBE_CACHE:-$HOME/.cache/source-reader/tts-probe}"
MODELS_DIR="${MODELS_DIR:-$CACHE_ROOT/models}"
DOWNLOADS_DIR="$CACHE_ROOT/downloads"
GITHUB_RELEASES="${TTS_PROBE_GITHUB_RELEASES:-https://github.com}"

usage() {
  cat <<'EOF'
Usage: download-models.sh [all|melo|fanchen|matcha|piper-xiao-ya|piper-chaowen|matcha-zh-en|kokoro]...

Downloads popular sherpa-onnx Chinese TTS candidates for the on-device RTF
sweep. Files are cached outside the repository by default:
  ~/.cache/source-reader/tts-probe/

Environment:
  TTS_PROBE_CACHE  Cache root (downloads/ and models/)
  MODELS_DIR       Override the final model directory
  TTS_PROBE_GITHUB_RELEASES
                   GitHub prefix (e.g. https://gh-proxy.com/https://github.com)
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ $# -eq 0 || "${1:-}" == "all" ]]; then
  selections=(melo fanchen matcha piper-xiao-ya piper-chaowen matcha-zh-en kokoro)
else
  selections=("$@")
fi

for name in "${selections[@]}"; do
  case "$name" in
    melo|fanchen|matcha|piper-xiao-ya|piper-chaowen|matcha-zh-en|kokoro) ;;
    *)
      echo "Unknown model: $name" >&2
      usage >&2
      exit 2
      ;;
  esac
done

has_model() {
  local wanted="$1"
  local name
  for name in "${selections[@]}"; do
    [[ "$name" == "$wanted" ]] && return 0
  done
  return 1
}

file_size() {
  local path="$1"
  stat -f '%z' "$path" 2>/dev/null || stat -c '%s' "$path"
}

download_file() {
  local url="$1"
  local dest="$2"
  local expected_size="$3"
  local part="$dest.part"

  mkdir -p "$(dirname "$dest")"
  if [[ -f "$dest" && "$(file_size "$dest")" == "$expected_size" ]]; then
    echo "cached: $dest"
    return 0
  fi

  if [[ -f "$part" && "$(file_size "$part")" -gt "$expected_size" ]]; then
    rm -f "$part"
  fi
  if [[ -f "$part" && "$(file_size "$part")" == "$expected_size" ]]; then
    mv "$part" "$dest"
  else
    echo "download: $url" >&2
    curl -fL --retry 5 --retry-delay 3 --retry-all-errors \
      --connect-timeout 20 --continue-at - \
      "$url" -o "$part"
    if [[ "$(file_size "$part")" != "$expected_size" ]]; then
      echo "size mismatch: $part (expected $expected_size, got $(file_size "$part"))" >&2
      exit 1
    fi
    mv "$part" "$dest"
  fi
}

extract_model() {
  local archive="$1"
  local marker="$2"
  local dest="$3"
  local stage
  local src

  stage="$(mktemp -d "$CACHE_ROOT/extract.XXXXXX")"
  trap 'rm -rf "$stage"' RETURN
  tar -xjf "$archive" -C "$stage"
  src="$(find "$stage" -type f -name "$marker" -print -quit)"
  if [[ -n "$src" ]]; then
    src="$(dirname "$src")"
  fi
  if [[ -z "$src" || ! -d "$src" ]]; then
    echo "Archive does not contain $marker: $archive" >&2
    exit 1
  fi

  rm -rf "$dest"
  mkdir -p "$dest"
  cp -R "$src"/. "$dest"/
  rm -rf "$stage"
  trap - RETURN
  echo "ready: $dest"
}

require_file() {
  local path="$1"
  if [[ ! -s "$path" ]]; then
    echo "Missing model file: $path" >&2
    exit 1
  fi
}

mkdir -p "$MODELS_DIR" "$DOWNLOADS_DIR"

if has_model melo; then
  archive="$DOWNLOADS_DIR/vits-melo-tts-zh_en.tar.bz2"
  download_file \
    "$GITHUB_RELEASES/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-melo-tts-zh_en.tar.bz2" \
    "$archive" 167006755
  extract_model "$archive" model.int8.onnx "$MODELS_DIR/melo"
fi

if has_model fanchen; then
  archive="$DOWNLOADS_DIR/vits-zh-hf-fanchen-C.tar.bz2"
  download_file \
    "$GITHUB_RELEASES/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-zh-hf-fanchen-C.tar.bz2" \
    "$archive" 119326431
  extract_model "$archive" vits-zh-hf-fanchen-C.onnx "$MODELS_DIR/fanchen"

  # The C API still accepts dict_dir, but current sherpa-onnx documents it as a
  # legacy no-op. Reuse the jieba dictionary when melo is also present so older
  # sherpa runtimes remain usable.
  if [[ ! -d "$MODELS_DIR/fanchen/dict" && -d "$MODELS_DIR/melo/dict" ]]; then
    cp -R "$MODELS_DIR/melo/dict" "$MODELS_DIR/fanchen/dict"
  fi
fi

if has_model matcha; then
  archive="$DOWNLOADS_DIR/matcha-icefall-zh-baker.tar.bz2"
  download_file \
    "$GITHUB_RELEASES/k2-fsa/sherpa-onnx/releases/download/tts-models/matcha-icefall-zh-baker.tar.bz2" \
    "$archive" 75479739
  extract_model "$archive" model-steps-3.onnx "$MODELS_DIR/matcha"
  download_file \
    "$GITHUB_RELEASES/k2-fsa/sherpa-onnx/releases/download/vocoder-models/vocos-22khz-univ.onnx" \
    "$MODELS_DIR/matcha/vocos-22khz-univ.onnx" 53884024
  if [[ ! -d "$MODELS_DIR/matcha/dict" && -d "$MODELS_DIR/melo/dict" ]]; then
    cp -R "$MODELS_DIR/melo/dict" "$MODELS_DIR/matcha/dict"
  fi
fi

if has_model piper-xiao-ya; then
  archive="$DOWNLOADS_DIR/vits-piper-zh_CN-xiao_ya-medium-int8.tar.bz2"
  download_file \
    "$GITHUB_RELEASES/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-zh_CN-xiao_ya-medium-int8.tar.bz2" \
    "$archive" 14016124
  extract_model "$archive" zh_CN-xiao_ya-medium.onnx "$MODELS_DIR/piper-xiao-ya"
fi

if has_model piper-chaowen; then
  archive="$DOWNLOADS_DIR/vits-piper-zh_CN-chaowen-medium-int8.tar.bz2"
  download_file \
    "$GITHUB_RELEASES/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-zh_CN-chaowen-medium-int8.tar.bz2" \
    "$archive" 14011298
  extract_model "$archive" zh_CN-chaowen-medium.onnx "$MODELS_DIR/piper-chaowen"
fi

if has_model matcha-zh-en; then
  archive="$DOWNLOADS_DIR/matcha-icefall-zh-en.tar.bz2"
  download_file \
    "$GITHUB_RELEASES/k2-fsa/sherpa-onnx/releases/download/tts-models/matcha-icefall-zh-en.tar.bz2" \
    "$archive" 79033838
  extract_model "$archive" model-steps-3.onnx "$MODELS_DIR/matcha-zh-en"
  download_file \
    "$GITHUB_RELEASES/k2-fsa/sherpa-onnx/releases/download/vocoder-models/vocos-16khz-univ.onnx" \
    "$MODELS_DIR/matcha-zh-en/vocos-16khz-univ.onnx" 53882848
  download_file \
    "$GITHUB_RELEASES/k2-fsa/sherpa-onnx/releases/download/tts-models/lexicon-en-us.txt" \
    "$MODELS_DIR/matcha-zh-en/lexicon-en-us.txt" 6305773
fi

if has_model kokoro; then
  archive="$DOWNLOADS_DIR/kokoro-int8-multi-lang-v1_1.tar.bz2"
  download_file \
    "$GITHUB_RELEASES/k2-fsa/sherpa-onnx/releases/download/tts-models/kokoro-int8-multi-lang-v1_1.tar.bz2" \
    "$archive" 147052523
  extract_model "$archive" model.int8.onnx "$MODELS_DIR/kokoro"
fi

if has_model melo; then
  for file in model.int8.onnx tokens.txt lexicon.txt; do
    require_file "$MODELS_DIR/melo/$file"
  done
fi
if has_model fanchen; then
  for file in vits-zh-hf-fanchen-C.onnx tokens.txt lexicon.txt; do
    require_file "$MODELS_DIR/fanchen/$file"
  done
fi
if has_model matcha; then
  for file in model-steps-3.onnx vocos-22khz-univ.onnx tokens.txt lexicon.txt; do
    require_file "$MODELS_DIR/matcha/$file"
  done
fi
if has_model piper-xiao-ya; then
  for file in zh_CN-xiao_ya-medium.onnx tokens.txt lexicon.txt date.fst number.fst phone.fst; do
    require_file "$MODELS_DIR/piper-xiao-ya/$file"
  done
fi
if has_model piper-chaowen; then
  for file in zh_CN-chaowen-medium.onnx tokens.txt lexicon.txt date.fst number.fst phone.fst; do
    require_file "$MODELS_DIR/piper-chaowen/$file"
  done
fi
if has_model matcha-zh-en; then
  for file in model-steps-3.onnx vocos-16khz-univ.onnx tokens.txt lexicon.txt \
              lexicon-en-us.txt phone-zh.fst date-zh.fst number-zh.fst; do
    require_file "$MODELS_DIR/matcha-zh-en/$file"
  done
fi
if has_model kokoro; then
  for file in model.int8.onnx voices.bin tokens.txt lexicon-us-en.txt lexicon-zh.txt \
              phone-zh.fst date-zh.fst number-zh.fst; do
    require_file "$MODELS_DIR/kokoro/$file"
  done
fi

echo "Models ready in: $MODELS_DIR"
