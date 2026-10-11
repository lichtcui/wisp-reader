#!/bin/zsh
# P4: deploy ORT libs + ONNX bundle straight into the debug app sandbox via
# `hdc file send -b <bundle> <local> <el2-base-relative-path>`.
#
# Why not /data/local/tmp: the app process cannot see it (SELinux), and the
# sandbox is not writable from the plain `hdc shell` domain (ENOENT/EACCES).
# `-b` is the only channel that lands files where BOTH hdc and the app can read.
set -e
HDC=/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc
BUNDLE=com.lichtcui.sourcereader
P4=$HOME/Documents/playground/tts/p4
MODELS=$HOME/Documents/playground/tts/p2/onnx-int8/liuying
G2PEN=$HOME/Documents/playground/tts/gpt-sovits-onnx-rs/gpt-sovits-upstream/onnx-patched/liuying/g2p_en
BASE=data/storage/el2/base/tts-p4

$HDC list targets 2>&1 | grep -q '\[Empty\]' && { echo "device offline"; exit 1; }

$HDC shell -b $BUNDLE "mkdir -p $BASE/lib $BASE/bundle/g2p_en"

echo "== libs =="
for f in libonnxruntime.so libc++_shared.so libgpt_sovits_tts_ohos.so; do
  echo "-- $f"
  $HDC file send -b $BUNDLE $P4/out/$f $BASE/lib/$f
done

echo "== bundle (1.2 GB, one file at a time) =="
for f in $MODELS/*.onnx $MODELS/ref.wav; do
  echo "-- $(basename $f)"
  $HDC file send -b $BUNDLE "$f" "$BASE/bundle/$(basename $f)"
done
for f in $G2PEN/*; do
  echo "-- g2p_en/$(basename $f)"
  $HDC file send -b $BUNDLE "$f" "$BASE/bundle/g2p_en/$(basename $f)"
done

echo "== verify =="
$HDC shell -b $BUNDLE "du -sh $BASE/*; ls -l $BASE/lib $BASE/bundle"
