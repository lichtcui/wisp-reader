#!/bin/zsh
# P4: push artifacts + load-smoke + (ready-to-run) bench. Needs the device
# (UDID 33Z0224424136564). Everything else in P4 is done.
set -e
HDC=/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc
P4=$HOME/Documents/playground/tts/p4
BUNDLE=$HOME/Documents/playground/tts/p2/onnx-int8/liuying
G2PEN=$HOME/Documents/playground/tts/gpt-sovits-onnx-rs/gpt-sovits-upstream/onnx-patched/liuying/g2p_en
DEV=/data/local/tmp/tts-p4

$HDC list targets 2>&1 | grep -q '\[Empty\]' && { echo "device offline"; exit 1; }

$HDC shell "mkdir -p $DEV/lib $DEV/bundle"

# host-side libs + binaries
for f in libonnxruntime.so libc++_shared.so libgpt_sovits_tts_ohos.so ort_smoke tts-bench; do
  $HDC file send $P4/out/$f $DEV/$f
done

# 1) load smoke: dlopen + version string + GetApi(24)  -> the P4 gate
$HDC shell "cd $DEV && LD_LIBRARY_PATH=$DEV/lib ./ort_smoke $DEV/lib/libonnxruntime.so 24"

# 2) model bundle (1.2 GB) + tokenizer dir
for f in $BUNDLE/*.onnx $BUNDLE/ref.wav; do
  $HDC file send "$f" "$DEV/bundle/$(basename $f)"
done
$HDC shell "mkdir -p $DEV/bundle/g2p_en"
for f in $G2PEN/*; do $HDC file send "$f" "$DEV/bundle/g2p_en/$(basename $f)"; done

# 3) bench (run manually / for the long-stability loop):
cat <<'RUN'
# RTF（短句/长段/混排；cap=30）:
#   hdc shell "cd /data/local/tmp/tts-p4 && LD_LIBRARY_PATH=lib ./tts-bench bundle ref.wav '抱歉，我不得不这么做……' rtf short_zh 30 3"
#   hdc shell "... rtf page_long 30 3"   hdc shell "... rtf mixed_zh_en 30 3"
# 长稳（≥1h；iters 调到 ≥2h）:
#   hdc shell "cd /data/local/tmp/tts-p4 && LD_LIBRARY_PATH=lib nohup ./tts-bench bundle ref.wav '抱歉，我不得不这么做……' stability 30 400 > stab.log 2>&1 &"
#   内存：同时 `hdc shell hidumper --mem <pid>`（或 libproc）每 5s 采样，以 phys_footprint 为准
RUN
