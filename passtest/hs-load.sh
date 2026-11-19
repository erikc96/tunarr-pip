#!/bin/bash
# Hammerspoon-load pass test (tv-design.md section 4, lines 1-5). Prints PASS/FAIL per line with the measured number.
# Reads Hammerspoon only through hs-safe (one call), everything else from files and the process list.
HS_DIR=${HS_DIR:-$HOME/.hammerspoon}
STALL=$HOME/.local/state/hs-stalls.log
fail=0
check() { # name measured want
  if [ "$2" = "$3" ]; then echo "PASS $1: $2 (want $3)"; else echo "FAIL $1: $2 (want $3)"; fail=1; fi
}
# files Hammerspoon can load for this player: the module behind the symlink, or the new key file
mod=$(ls "$HS_DIR"/tunarr_pip/*.lua 2>/dev/null)
loaded=$("$HOME/life/bin/hs-safe" 'return type(package.loaded["tunarr_pip"])' 2>/dev/null)
c() { [ -n "$mod" ] && cat $mod "$HS_DIR/tunarr_keys.lua" 2>/dev/null | grep -cE "$1" || echo 0; }
[ -n "$mod" ] || c() { cat "$HS_DIR/tunarr_keys.lua" 2>/dev/null | grep -cE "$1" || echo 0; }
check "1 tunarr module loaded in Hammerspoon" "${loaded:-unreadable}" nil
check "1 hs.timer.doEvery in tunarr files" "$(c 'hs\.timer\.doEvery')" 0
check "2 hs.eventtap.new in tunarr files" "$(c 'hs\.eventtap\.new')" 0
check "3 Accessibility window calls in tunarr files" "$(c 'applicationForPID|allWindows|:setFrame|:mainWindow')" 0
check "4 /bin/sh hs.task spawns in tunarr files" "$(c "hs\.task\.new\('/bin/sh'")" 0
check "5 'hs -c' probes of tunarr_pip running" "$(pgrep -fl 'hs -c.*tunarr_pip' | grep -vc pgrep)" 0
if [ -n "$WATCH_FROM" ]; then # epoch the 30-minute watch started
  n=$(awk -v t="$WATCH_FROM" '$1>=t' "$STALL" 2>/dev/null | awk -F'late=' '{split($2,a,"s"); if (a[1]+0>0.25) k++} END{print k+0}')
  check "5 stalls over 0.25 s since WATCH_FROM (all causes; read front= to attribute)" "$n" 0
fi
exit $fail
