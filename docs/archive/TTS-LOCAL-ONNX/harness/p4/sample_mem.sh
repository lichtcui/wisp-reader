#!/bin/zsh
# P4 长稳内存采样：每 $INTERVAL 秒取一次 hidumper Total Pss + /proc/<pid> 的 VmRSS/VmHWM。
HDC=/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc
OUT=${OUT:-$HOME/Documents/playground/tts/p4/stability-mem.tsv}
INTERVAL=${INTERVAL:-300}
COUNT=${COUNT:-13}
echo -e "wall\tpss_kb\trss_kb\thwm_kb\trss_anon_kb" > $OUT
for i in $(seq 1 $COUNT); do
  PID=$($HDC shell "ps -ef | grep com.lichtcui.sourcereader | grep -v grep" 2>/dev/null | head -1 | awk '{print $2}')
  if [ -z "$PID" ]; then echo -e "$(date +%H:%M:%S)\tDEAD" >> $OUT; break; fi
  PSS=$($HDC shell "hidumper --mem $PID" 2>/dev/null | awk '/^ *Total +[0-9]/{print $2; exit}')
  ST=$($HDC shell "cat /proc/$PID/status" 2>/dev/null)
  RSS=$(echo "$ST" | awk '/^VmRSS/{print $2}')
  HWM=$(echo "$ST" | awk '/^VmHWM/{print $2}')
  ANON=$(echo "$ST" | awk '/^RssAnon/{print $2}')
  echo -e "$(date +%H:%M:%S)\t${PSS:-?}\t${RSS:-?}\t${HWM:-?}\t${ANON:-?}" >> $OUT
  echo "$(date +%H:%M:%S) pss=${PSS} rss=${RSS} hwm=${HWM} anon=${ANON}"
  sleep $INTERVAL
done
