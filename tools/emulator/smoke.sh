#!/bin/sh
# Spike (KNO-41, plan T1): does Mode's engine answer on an emulator, with only adb?
#   tools/emulator/smoke.sh <debug apk> <output folder>
#
# Installs the debug APK, starts Mode once, turns phone control on with the three adb commands from
# docs/android.md, waits for the probe's status to say Engine=Passed, takes one probe look, records ten
# seconds of screen and takes one screenshot. Whatever happens, an EXIT trap pulls the evidence into the
# output folder: results.txt (one line per finding), the recording, the screenshot, the full logcat, the
# ModeProbe lines and events.log. Exits non-zero when the engine did not come up or look had no screenshot;
# a failed recording is written down but does not fail the run.
#
# Uses adb from PATH; set ADB="adb -s <serial>" to pick a device. This bare version is for emulators only:
# it does not check what is already on the phone. The real script (plan T2) replaces it.
set -eu

[ $# -eq 2 ] || { echo "usage: tools/emulator/smoke.sh <debug apk> <output folder>" >&2; exit 2; }
APK=$1
OUT=$2
[ -f "$APK" ] || { echo "smoke: no APK at $APK" >&2; exit 2; }
mkdir -p "$OUT"
ADB=${ADB:-adb}
PKG=app.heymode.mode
PROBE="$PKG/com.piyush.mode.app.DevProbe"
SERVICE="$PKG/com.piyush.mode.android.ModeAccessibilityService"
RESULTS="$OUT/results.txt"
: > "$RESULTS"
FAILED=0
REC_PID=

note() { echo "$*" | tee -a "$RESULTS"; }
fail() { note "FAIL $*"; FAILED=1; }
# adb under a deadline: a hung emulator must not hang the job (the job's own timeout is the last resort).
a() { secs=$1; shift; timeout "$secs" $ADB "$@"; }
sh_() { secs=$1; shift; a "$secs" shell "$@"; }

# Runs one probe op and prints the ModeProbe line it logged. am broadcast returns once the op has logged
# (the probe finishes its pending result after Log), so the newest line since the op started is this op's.
probe() {
    since=$(sh_ 10 date +%s | tr -d '\r')
    sh_ 60 am broadcast -n "$PROBE" --es op "$@" > /dev/null || true
    sh_ 10 logcat -d -v epoch -T "$since.000" -s ModeProbe:I | grep -E ' (ok|failed) [0-9]+ms' | tail -1 | sed 's/^.*ModeProbe *: *//'
}

collect() {
    status=$?
    set +e
    if [ -n "$REC_PID" ]; then
        sh_ 10 pkill -INT screenrecord > /dev/null 2>&1
        wait "$REC_PID" 2> /dev/null
    fi
    a 60 pull /sdcard/smoke.mp4 "$OUT/smoke.mp4" > /dev/null 2>&1
    a 30 pull /sdcard/smoke.png "$OUT/smoke.png" > /dev/null 2>&1
    sh_ 60 logcat -d -v threadtime > "$OUT/logcat.txt" 2>&1
    sh_ 30 logcat -d -v threadtime -s ModeProbe:I > "$OUT/modeprobe.txt" 2>&1
    sh_ 30 logcat -d -b crash > "$OUT/crash.txt" 2>&1
    # events.log can hold task text on a real phone; it goes to the folder only, never to the job log.
    sh_ 30 run-as "$PKG" cat files/logs/events.log > "$OUT/events.log" 2>&1
    sh_ 10 dumpsys window 2>/dev/null | grep mCurrentFocus > "$OUT/focus.txt"
    [ "$status" -eq 0 ] && [ "$FAILED" -eq 1 ] && status=1
    note "exit $status"
    exit "$status"
}
trap collect EXIT

# The device.
note "sdk $(sh_ 10 getprop ro.build.version.sdk | tr -d '\r') release $(sh_ 10 getprop ro.build.version.release | tr -d '\r')"
note "image $(sh_ 10 getprop ro.build.fingerprint | tr -d '\r')"
note "uptime_s $(sh_ 10 cat /proc/uptime | cut -d' ' -f1) (about the boot time on a cold boot)"
sh_ 10 logcat -G 16M > /dev/null 2>&1 || note "note: logcat -G not accepted"

# Install and start once (Android delivers no broadcast to an app that was never started).
if a 180 install -r "$APK" > "$OUT/install.txt" 2>&1; then note "PASS install"; else fail "install: $(tail -1 "$OUT/install.txt")"; exit 1; fi
sh_ 30 monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 > /dev/null 2>&1 || true
pid=
for _ in 1 2 3 4 5 6 7 8 9 10; do
    pid=$(sh_ 10 pidof "$PKG" | tr -d '\r' || true)
    [ -n "$pid" ] && break
    sleep 1
done
if [ -n "$pid" ]; then note "PASS started pid $pid"; else fail "started: no process after 10 s"; fi

# Phone control on, the docs/android.md way. On a freshly booted emulator Android can still be taking in
# the new install when the setting is written, and then writes the setting back without Mode's service
# (seen on #9 at API 35 and 36, about one run in four). So first wait until the accessibility system lists
# the service, and if the setting loses it afterwards, write it again (at most three writes).
sh_ 10 appops set "$PKG" ACCESS_RESTRICTED_SETTINGS allow || note "note: appops failed"
t0=$(date +%s)
known=no
while [ $(( $(date +%s) - t0 )) -lt 30 ]; do
    if sh_ 15 dumpsys accessibility 2>/dev/null | grep -q "ModeAccessibilityService"; then known=yes; break; fi
    sleep 1
done
note "accessibility system lists the service: $known after $(( $(date +%s) - t0 )) s"
enable() {
    sh_ 10 settings put secure enabled_accessibility_services "$SERVICE"
    sh_ 10 settings put secure accessibility_enabled 1
}
enable
writes=1
t0=$(date +%s)
line=
engine=no
while [ $(( $(date +%s) - t0 )) -lt 30 ]; do
    line=$(probe status)
    case "$line" in *Engine=Passed*) engine=yes; break ;; esac
    setting=$(sh_ 10 settings get secure enabled_accessibility_services | tr -d '\r' || true)
    case "$setting" in
        *ModeAccessibilityService*) ;;
        *) if [ "$writes" -lt 3 ]; then
               note "setting lost Mode's service after $(( $(date +%s) - t0 )) s (now: ${setting:-empty}); writing it again"
               enable
               writes=$((writes + 1))
           fi ;;
    esac
    sleep 1
done
if [ "$engine" = yes ]; then note "PASS engine after $(( $(date +%s) - t0 )) s, $writes write(s): $line"
else fail "engine not up in 30 s after $writes write(s): $line"; fi

# The recording runs while the probe moves the phone, so a playable file also shows something happening.
sh_ 30 screenrecord --time-limit 10 /sdcard/smoke.mp4 > "$OUT/screenrecord.txt" 2>&1 &
REC_PID=$!
sleep 1

# One look on the launcher, then Settings, so the screenshot and the video are not a blank home screen.
line=$(probe home); note "home: $line"
line=$(probe look)
case "$line" in
    ok*jpeg=[0-9]*) note "PASS look: $(echo "$line" | cut -c1-300)" ;;
    *) fail "look: $(echo "$line" | cut -c1-300)" ;;
esac
line=$(probe launch --es name Settings); note "launch Settings: $line"
sleep 2
line=$(probe look); note "look in Settings: $(echo "$line" | cut -c1-300)"
sh_ 30 screencap -p /sdcard/smoke.png || note "note: screencap failed"

# The recording: done when screenrecord ends by itself after ten seconds.
wait "$REC_PID" && rec=0 || rec=$?
REC_PID=
size=$(sh_ 10 stat -c %s /sdcard/smoke.mp4 2>/dev/null | tr -d '\r' || true)
if [ "$rec" -eq 0 ] && [ -n "$size" ] && [ "$size" -gt 0 ]; then note "PASS recording $size bytes"
else note "WARN recording: exit $rec, size ${size:-none}: $(tail -1 "$OUT/screenrecord.txt" 2>/dev/null)"; fi
