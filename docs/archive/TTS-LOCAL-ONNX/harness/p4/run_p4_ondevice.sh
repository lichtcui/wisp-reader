#!/bin/zsh
# P4 on-device driver: launch the test HAP, drive gates A/B/C, collect logs.
# Requires the device unlocked and /data/local/tmp/tts-p4 bundle already pushed.
HDC=/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc
BUNDLE=com.lichtcui.sourcereader

$HDC shell "aa force-stop $BUNDLE" >/dev/null 2>&1
$HDC shell "hilog -r" >/dev/null 2>&1
$HDC shell "aa start -a EntryAbility -b $BUNDLE" 2>&1 | head -2
sleep 4

click_text () {  # $1 = substring; find its center in the layout dump and click
  $HDC shell "uitest dumpLayout -p /data/local/tmp/l.json -a" >/dev/null 2>&1
  $HDC file recv /data/local/tmp/l.json /tmp/l.json >/dev/null 2>&1
  python3 - "$1" <<'PY'
import json,sys
sub=sys.argv[1]
d=json.load(open('/tmp/l.json'))
found=None
def walk(n):
    global found
    a=n.get('attributes',{})
    if sub in (a.get('text') or '') and a.get('bounds'):
        found=a['bounds']; return True
    for c in n.get('children',[]) or []:
        if walk(c): return True
    return False
walk(d)
if found:
    import re
    m=re.match(r'\[(\d+),(\d+)\]\[(\d+),(\d+)\]', found)
    x=(int(m.group(1))+int(m.group(3)))//2; y=(int(m.group(2))+int(m.group(4)))//2
    print(f"{x} {y}")
PY
}

for label in 'A. ORT' 'B. 复制' 'C. 合成'; do
  xy=$(click_text "$label")
  echo ">> click '$label' at $xy"; [ -n "$xy" ] && $HDC shell "uitest uiInput click $xy" >/dev/null 2>&1
  sleep 25
  $HDC shell "hilog -x -T TTSP4" 2>&1 | tail -6
done
echo "=== final TTSP4 ==="; $HDC shell "hilog -x -T TTSP4" 2>&1 | tail -40
