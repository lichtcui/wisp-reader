#!/bin/zsh
# P4 60min 长稳现场保全：连续 hilog 流 + 每 SNAP 秒快照 + 每 SNAP 秒 dumpLayout 兜底。
export PATH="/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains:$PATH"
P4=/Users/lichtcui/Documents/playground/tts/p4
LOGD=$P4/logs
SNAP=${SNAP:-900}
STAMP=$(date +%H%M)
mkdir -p $LOGD
# 连续流（USB 掉线时文件里保留掉线前全部内容）
hdc shell hilog -x -T TTSP4 > $LOGD/stab-stream-$STAMP.log 2>&1 &
echo "stream pid $!" > $LOGD/capture-$STAMP.meta
for i in $(seq 1 8); do
  sleep $SNAP
  hdc shell "hilog -x -T TTSP4" > $LOGD/stab-snap-$(date +%H%M).log 2>/dev/null
  hdc shell "uitest dumpLayout -p /data/local/tmp/l.json -a" >/dev/null 2>&1
  hdc file recv /data/local/tmp/l.json $LOGD/layout-$(date +%H%M).json >/dev/null 2>&1
  echo "$(date +%H:%M:%S) snapshot done (iter $i)" >> $LOGD/capture-$STAMP.meta
done
echo "capture loop finished $(date +%H:%M:%S)" >> $LOGD/capture-$STAMP.meta
