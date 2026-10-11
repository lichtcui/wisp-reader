#!/bin/zsh
set -e
ORT=~/Documents/playground/tts/p4/src/onnxruntime-1.24.4
MIRROR=$ORT/mirror
cd $ORT
mkdir -p $MIRROR
grep -v '^#' cmake/deps.txt | while IFS=';' read -r name url sha; do
  [ -z "$url" ] && continue
  case "$url" in
    https://github.com/*) rel="${url#https://github.com/}";;
    *) continue;;
  esac
  dest="$MIRROR/github.com/$rel"
  mkdir -p "$(dirname "$dest")"
  if [ -s "$dest" ]; then echo "SKIP  $name"; continue; fi
  echo "GET   $name"
  curl -sL --max-time 300 -o "$dest.part" "https://gh-proxy.com/$url" || { echo "FAIL  $name"; continue; }
  mv "$dest.part" "$dest"
done
echo DONE
