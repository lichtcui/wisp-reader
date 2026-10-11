#!/bin/zsh
# P4 长稳监视器（前台跑）：每 INT 秒取内存样本 + 读最新 STAB 行；停滞则告警。
export PATH="/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains:$PATH"
P4=/Users/lichtcui/Documents/playground/tts/p4
OUT=${OUT:-$P4/stability-mem.tsv}
N=${N:-4}; INT=${INT:-240}
[ -f $OUT ] || echo -e "wall\tpss_kb\trss_kb\thwm_kb\trss_anon_kb" > $OUT
last=""
for i in $(seq 1 $N); do
  PID=$(hdc shell "ps -ef | grep com.lichtcui.sourcereader | grep -v grep" 2>/dev/null | head -1 | awk '{print $2}')
  if [ -z "$PID" ]; then echo -e "$(date +%H:%M:%S)\tDEAD" >> $OUT; echo "!! APP DEAD"; break; fi
  PSS=$(hdc shell "hidumper --mem $PID" 2>/dev/null | awk '/^ *Total +[0-9]/{print $2; exit}')
  ST=$(hdc shell "cat /proc/$PID/status" 2>/dev/null)
  RSS=$(echo "$ST" | awk '/^VmRSS/{print $2}'); HWM=$(echo "$ST" | awk '/^VmHWM/{print $2}'); ANON=$(echo "$ST" | awk '/^RssAnon/{print $2}')
  echo -e "$(date +%H:%M:%S)\t${PSS:-?}\t${RSS:-?}\t${HWM:-?}\t${ANON:-?}" >> $OUT
  LINE=$(hdc shell "hilog -x -T TTSP4" 2>/dev/null | tail -1 | sed -e 's/^[0-9-]* //' -e 's/^[0-9:.]* *[0-9]* *[0-9]* *[A-Z] *[^ ]* *//')
  FLAG=""
  [ "$LINE" = "$last" ] && FLAG=" <<< SAME AS BEFORE"
  echo "$(date +%H:%M:%S) pss=${PSS} | $LINE$FLAG"
  last="$LINE"
  [ $i -lt $N ] && sleep $INT
done
hdc shell "hilog -x -T TTSP4" > $P4/logs/stab-snap-$(date +%H%M).log 2>/dev/null
hdc shell "uitest dumpLayout -p /data/local/tmp/l.json -a" >/dev/null 2>&1
hdc file recv /data/local/tmp/l.json $P4/logs/layout-$(date +%H%M).json >/dev/null 2>&1
echo "--- end-of-window snapshot $(date +%H:%M:%S) ---"
