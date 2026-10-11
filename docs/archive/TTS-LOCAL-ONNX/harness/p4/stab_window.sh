#!/bin/zsh
# 长稳采样窗口（前台跑，避免被收回）：N 次内存采样（间隔 INT 秒）+ 收尾 hilog/layout 快照。
export PATH="/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains:$PATH"
HDC=hdc
P4=/Users/lichtcui/Documents/playground/tts/p4
OUT=${OUT:-$P4/stability-mem.tsv}
N=${N:-4}; INT=${INT:-240}
[ -f $OUT ] || echo -e "wall\tpss_kb\trss_kb\thwm_kb\trss_anon_kb" > $OUT
for i in $(seq 1 $N); do
  PID=$($HDC shell "ps -ef | grep com.lichtcui.sourcereader | grep -v grep" 2>/dev/null | head -1 | awk '{print $2}')
  if [ -z "$PID" ]; then echo -e "$(date +%H:%M:%S)\tDEAD" >> $OUT; echo "DEAD"; break; fi
  PSS=$($HDC shell "hidumper --mem $PID" 2>/dev/null | awk '/^ *Total +[0-9]/{print $2; exit}')
  ST=$($HDC shell "cat /proc/$PID/status" 2>/dev/null)
  RSS=$(echo "$ST" | awk '/^VmRSS/{print $2}'); HWM=$(echo "$ST" | awk '/^VmHWM/{print $2}'); ANON=$(echo "$ST" | awk '/^RssAnon/{print $2}')
  echo -e "$(date +%H:%M:%S)\t${PSS:-?}\t${RSS:-?}\t${HWM:-?}\t${ANON:-?}" >> $OUT
  echo "$(date +%H:%M:%S) pss=${PSS} rss=${RSS} hwm=${HWM} anon=${ANON}"
  [ $i -lt $N ] && sleep $INT
done
$HDC shell "hilog -x -T TTSP4" > $P4/logs/stab-snap-$(date +%H%M).log 2>/dev/null
$HDC shell "uitest dumpLayout -p /data/local/tmp/l.json -a" >/dev/null 2>&1
$HDC file recv /data/local/tmp/l.json $P4/logs/layout-$(date +%H%M).json >/dev/null 2>&1
echo "--- snap $(date +%H:%M:%S) ---"; grep -E "STAB" $P4/logs/stab-snap-$(date +%H%M).log | tail -5
