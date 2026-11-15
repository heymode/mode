#!/bin/sh
# Emulator smoke for Mode for Android: installs the debug build, turns phone control on over adb and drives
# the engine through the debug probe (DevProbe), step by step. Works on an emulator or a plugged-in phone.
#   tools/emulator/smoke.sh [--skip S4] … <debug apk> <output folder>     (or SMOKE_SKIP="S4" in the environment)
#
# Steps (each PASS, FAIL or SKIP, with a screenshot):
#   S1 install, grant the notification permission      S2 start Mode once, then send it to the background
#   S3 stand-in AI key (emulators only)                S4 phone control on (the docs/android.md commands)
#   S5 home, the launcher, the phone checks            S6 open Settings and look
#   S7 tap a Settings row, back, home                  S8 a question notification
#   S9 Mode is still the same process, with no crash or ANR, and phone control is still on
# The output folder gets summary.md (what QA reads), a screenshot per step, the screen recording, the full
# logcat, the ModeProbe lines, the crash buffer and events.log. An EXIT trap fills it, so it is complete
# however the run ends. Exits non-zero if any step failed.
#
# Uses adb from PATH (ADB="adb -s <serial>" picks a device) and `timeout` (or `gtimeout` on a Mac; with
# neither, calls run without a deadline). On a real phone:
#   - S3 is skipped (the probe's key op would replace the saved AI key).
#   - A phone with the release build installed stops at S1 (S2 to S9 skipped). Nothing is uninstalled or cleared.
#   - S4 adds Mode to the accessibility services and keeps the others on.
#   - events.log from a real phone can hold real task text, so keep the output folder to yourself.
#
# No `set -e`: a failed step must not stop the run. Every step reports, and the trap collects the evidence.
set -u

usage() { echo "usage: tools/emulator/smoke.sh [--skip <step>]… <debug apk> <output folder>" >&2; exit 2; }
SKIP=" "
while [ $# -gt 0 ]; do
    case "$1" in
        --skip) [ $# -ge 2 ] || usage; SKIP="$SKIP$2 "; shift 2 ;;
        -*) usage ;;
        *) break ;;
    esac
done
[ $# -eq 2 ] || usage
# The workflow passes its `skip` input as SMOKE_SKIP ("S4", or "S4 S7"). Only step names are accepted.
for s in ${SMOKE_SKIP:-}; do
    case "$s" in S[1-9]) SKIP="$SKIP$s " ;; *) echo "smoke: SMOKE_SKIP takes step names like S4, not '$s'" >&2; exit 2 ;; esac
done
APK=$1
OUT=$2
[ -f "$APK" ] || { echo "smoke: no APK at $APK" >&2; exit 2; }
mkdir -p "$OUT"
ADB=${ADB:-adb}
PKG=app.heymode.mode
PROBE="$PKG/com.piyush.mode.app.DevProbe"
SERVICE="$PKG/com.piyush.mode.android.ModeAccessibilityService"
# On #9 the smallest probe screenshot of a real screen was 14774 (base64 length, launcher, API 35). A
# blank 320x640 frame is a few thousand, so below this S6 calls the screenshot blank.
JPEG_MIN=10000
# The Settings row S7 taps, by its label (present on API 34, 35 and 36; checked on #9).
ROW="Connected devices"

if command -v timeout > /dev/null 2>&1; then TO=timeout
elif command -v gtimeout > /dev/null 2>&1; then TO=gtimeout
else TO=; echo "smoke: no timeout command; adb calls run without a deadline" >&2
fi

# ---- Helpers -------------------------------------------------------------------------------------------

# POSIX sh has no local variables, so the helpers' own variables start with an underscore and the steps
# never use those names.

# A command under a deadline (exit 124 when it ran out).
to() { _secs=$1; shift; if [ -n "$TO" ]; then $TO "$_secs" "$@"; else "$@"; fi; }
# One argument quoted for the device's shell, which splits again whatever adb sends it.
qd() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
# A command on the device under a deadline, each argument kept whole (text with spaces stays one argument).
dsh() {
    _dsecs=$1; shift
    _cmd=
    for _arg in "$@"; do _cmd="$_cmd $(qd "$_arg")"; done
    to "$_dsecs" $ADB shell "$_cmd"
}
prop() { dsh 10 getprop "$1" 2> /dev/null | tr -d '\r'; }
now() { date +%s; }
log() { echo "$*"; echo "$*" >> "$OUT/run.log"; }

# ---- Probe ops -----------------------------------------------------------------------------------------
# The probe logs one line per op under ModeProbe: "ok <ms>ms <result>" or "failed <ms>ms <error>". The
# line does not name the op, so it is found by position: count the ModeProbe result lines before the op,
# and this op's line is the next one. `am broadcast` returns once the op has logged. If the call hits its
# deadline, the op is still running on the phone, so wait for its late line before going on; otherwise
# it would be read as the next op's.

# ModeProbe:I shows info and above (warnings too); a second spec for the same tag would replace the first.
probe_lines() { dsh 20 logcat -d -s ModeProbe:I 2> /dev/null | tr -d '\r' | grep -E 'ModeProbe *: (ok|failed) [0-9]+ms'; }
probe_count() { probe_lines | wc -l | tr -d ' '; }

PROBE_LINE=
STEP_RAW=/dev/null
probe() {
    _op=$1; shift
    _before=$(probe_count)
    dsh 60 am broadcast -n "$PROBE" --es op "$_op" "$@" > /dev/null 2>&1
    _rc=$?
    PROBE_LINE=
    _t0=$(now)
    _limit=5
    [ "$_rc" -eq 124 ] && _limit=90
    while [ $(( $(now) - _t0 )) -lt "$_limit" ]; do
        PROBE_LINE=$(probe_lines | sed -n "$((_before + 1))p" | sed 's/^.*ModeProbe *: *//')
        [ -n "$PROBE_LINE" ] && break
        sleep 1
    done
    if [ "$_rc" -eq 124 ]; then PROBE_LINE="timeout after 60 s (late line: ${PROBE_LINE:-none})"
    # Lines are found by count, so a log that wrapped (a busy phone, or one that refused logcat -G) shows
    # up here: a false FAIL, never a false PASS.
    elif [ -z "$PROBE_LINE" ]; then PROBE_LINE="no ModeProbe line (am broadcast exit $_rc; or the log wrapped)"
    fi
    echo "$_op $*: $PROBE_LINE" >> "$STEP_RAW"
}
# The op succeeded: "ok", and not "unknown op" (the probe logs a mistyped op name as ok).
probe_ok() {
    case "$PROBE_LINE" in
        "ok "*"ms unknown op"*) return 1 ;;
        "ok "*) return 0 ;;
        *) return 1 ;;
    esac
}
probe_result() { printf '%s' "$PROBE_LINE" | sed 's/^ok [0-9]*ms //'; }
# `current` prints a package in quotes.
unquote() { printf '%s' "$1" | sed 's/^"//; s/"$//'; }
# A look result's labels from the app's own windows, one per line and sorted. Positions are left out
# (they move when Settings shows a card), and so is the status bar (its clock changes).
# The texts part of a look result, one `"label"@x,y/"window"` per line (the bounds before it hold colons).
look_texts() {
    printf '%s\n' "$1" | sed 's/^.* texts=[0-9]*: //' | awk '{ n = split($0, t, / [|] /); for (i = 1; i <= n; i++) print t[i] }'
}
app_labels() { look_texts "$1" | sed -n 's/@[-0-9.]*,[-0-9.]*\/"app"$//p' | sort; }
# "x y" of an app label in a look result (its first match).
label_xy() {
    look_texts "$1" | awk -v want="\"$2\"" 'match($0, /@[-0-9.]+,[-0-9.]+\/"app"$/) && substr($0, 1, RSTART - 1) == want {
        xy = substr($0, RSTART + 1, RLENGTH - 7); sub(",", " ", xy); print xy; exit }'
}

# ---- Step bookkeeping ----------------------------------------------------------------------------------

FAILED=0
STEP=
STEP_OK=1
: > "$OUT/run.log"
: > "$OUT/steps.tsv"

pass() { log "  ok   $*"; }
bad() { log "  FAIL $*"; STEP_OK=0; }
note() { log "  note $*"; }

# Runs step $1 (titled $2) with function $3, unless --skip names it. A function that returns 2 skips itself
# (S3 on a real phone). Then a screenshot and one summary row.
run_step() {
    STEP=$1
    STEP_OK=1
    t0_step=$(now)
    STEP_RAW="$OUT/probe-$STEP.txt"
    : > "$STEP_RAW"
    log "$STEP $2"
    case "$SKIP" in
        *" $STEP "*) result=SKIP; log "  skipped (--skip $STEP)" ;;
        *) "$3"
           rc=$?
           if [ "$rc" -eq 2 ]; then result=SKIP
           elif [ "$STEP_OK" -eq 1 ]; then result=PASS
           else result=FAIL; FAILED=1; fi ;;
    esac
    to 30 $ADB exec-out screencap -p > "$OUT/$STEP.png" 2> /dev/null || rm -f "$OUT/$STEP.png"
    # On a slow emulator a system "isn't responding" dialog in front is a usual cause of a failure.
    [ "$result" = FAIL ] && dsh 15 dumpsys window 2> /dev/null | tr -d '\r' | grep mCurrentFocus > "$OUT/$STEP-focus.txt"
    secs=$(( $(now) - t0_step ))
    printf '%s\t%s\t%s\t%s\n' "$STEP" "$2" "$result" "$secs" >> "$OUT/steps.tsv"
    log "  $result in $secs s"
}

# Android is still delivering boot broadcasts when an emulator reports it has booted (up to 36 s on #9),
# and settings and screenshots flake while it does. Wait until the broadcast queues are idle.
settle() {
    s0=$(now)
    if dsh 120 am wait-for-broadcast-idle > /dev/null 2>&1; then log "broadcasts idle ($1) after $(( $(now) - s0 )) s"
    else log "broadcasts not idle ($1) after $(( $(now) - s0 )) s; going on"; fi
}

# ---- Evidence ------------------------------------------------------------------------------------------
# The screen is recorded for the whole run in 170 s segments (screenrecord stops at 180 s). This is best
# effort: it can fail on a software-rendered emulator. That is written down and never fails a step.

REC_PID=
record() {
    n=0
    while [ ! -f "$OUT/.rec-stop" ]; do
        n=$((n + 1))
        r0=$(now)
        dsh 200 screenrecord --time-limit 170 "/sdcard/mode-smoke-$n.mp4" >> "$OUT/screenrecord.txt" 2>&1
        rc=$?
        if [ ! -f "$OUT/.rec-stop" ] && [ $(( $(now) - r0 )) -lt 5 ]; then
            echo "segment $n ended after $(( $(now) - r0 )) s with exit $rc; recording stopped" >> "$OUT/screenrecord.txt"
            break
        fi
    done
}

summary() {
    {
        echo "# Mode emulator smoke: $( [ "$FAILED" -eq 0 ] && echo PASS || echo FAIL )"
        echo
        echo "- Commit: ${SMOKE_COMMIT:-${GITHUB_SHA:-$(git rev-parse HEAD 2> /dev/null || echo unknown)}}"
        [ -n "${GITHUB_RUN_ID:-}" ] && echo "- Run: ${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}/actions/runs/$GITHUB_RUN_ID"
        echo "- Device: $DEVICE, API $SDK (Android $RELEASE)"
        echo "- Image: \`$IMAGE\`"
        echo "- Mode: ${VERSION:-not installed}"
        echo "- Uptime when the script started: ${UPTIME:-?} s (about the boot time on a cold boot)"
        echo
        echo "| Step | What | Result | Time |"
        echo "| --- | --- | --- | --- |"
        tab=$(printf '\t')
        while IFS="$tab" read -r id what result secs; do echo "| $id | $what | $result | $secs s |"; done < "$OUT/steps.tsv"
        echo
        echo "## Notes"
        echo
        echo "- S5's \`Screen=Passed\` does not prove a screenshot works: that check passes even when the screenshot comes back private with no image. S6 checks a real one (\`jpeg\` at least $JPEG_MIN, not private)."
        echo "- S5 reports Battery but does not assert it: a fresh emulator restricts Mode's battery use."
        mp4s=$(ls "$OUT"/mode-smoke-*.mp4 2> /dev/null | wc -l | tr -d ' ')
        if [ "$mp4s" -gt 0 ]; then echo "- Screen recording: $mp4s file(s), \`mode-smoke-*.mp4\`."
        else echo "- Screen recording: none. $(tail -1 "$OUT/screenrecord.txt" 2> /dev/null)"; fi
        echo "- Other files: a screenshot per step (\`S1.png\` …), \`logcat.txt\`, \`modeprobe.txt\`, \`crash.txt\`, \`events.log\`, \`run.log\`."
        echo
        echo "## What each step did"
        echo
        echo '```'
        cat "$OUT/run.log"
        echo '```'
        echo
        echo "## The probe's raw lines (what Mode saw)"
        for f in "$OUT"/probe-S*.txt; do
            [ -s "$f" ] || continue
            echo
            echo "### $(basename "$f" .txt | sed 's/^probe-//')"
            echo
            echo '```'
            cat "$f"
            echo '```'
        done
    } > "$OUT/summary.md"
}

collect() {
    status=$?
    trap - EXIT INT TERM
    log "collecting evidence"
    if [ -n "$REC_PID" ]; then
        touch "$OUT/.rec-stop"
        # SIGINT lets screenrecord finish the file. Killed any other way, the mp4 does not play.
        dsh 10 pkill -INT screenrecord > /dev/null 2>&1
        w0=$(now)
        while kill -0 "$REC_PID" 2> /dev/null && [ $(( $(now) - w0 )) -lt 20 ]; do sleep 1; done
        kill "$REC_PID" 2> /dev/null
        for f in $(dsh 10 ls /sdcard/ 2> /dev/null | tr -d '\r' | grep '^mode-smoke-[0-9]*\.mp4$'); do
            to 120 $ADB pull "/sdcard/$f" "$OUT/$f" > /dev/null 2>&1
            dsh 10 rm -f "/sdcard/$f" > /dev/null 2>&1
        done
        rm -f "$OUT/.rec-stop"
    fi
    dsh 60 logcat -d -v threadtime > "$OUT/logcat.txt" 2>&1
    probe_lines > "$OUT/modeprobe.txt" 2>&1
    dsh 30 logcat -d -b crash > "$OUT/crash.txt" 2>&1
    dsh 15 dumpsys accessibility > "$OUT/accessibility.txt" 2>&1
    # events.log goes to the folder only, never to the job log: on a real phone it can hold task text.
    dsh 30 run-as "$PKG" cat files/logs/events.log > "$OUT/events.log" 2>&1
    summary
    [ "$FAILED" -eq 1 ] && [ "$status" -eq 0 ] && status=1
    log "exit $status"
    exit "$status"
}
interrupted() {
    log "interrupted${STEP:+ during $STEP}"
    [ -n "$STEP" ] && ! grep -q "^$STEP	" "$OUT/steps.tsv" && printf '%s\t%s\t%s\t%s\n' "$STEP" "(interrupted)" FAIL "$(( $(now) - t0_step ))" >> "$OUT/steps.tsv"
    FAILED=1
    exit 130
}

# ---- The steps -----------------------------------------------------------------------------------------

MODE_PID=
LAUNCHER=
TOP=
TOP_JPEG=
LABELS=
VERSION=

s1() {
    if to 180 $ADB install -r "$APK" > "$OUT/install.txt" 2>&1; then pass "installed"
    else bad "install: $(tail -1 "$OUT/install.txt")"; return; fi
    VERSION=$(dsh 20 dumpsys package "$PKG" 2> /dev/null | tr -d '\r' \
        | sed -n 's/^ *versionCode=\([0-9]*\).*/versionCode \1/p; s/^ *versionName=\(.*\)$/versionName \1/p' | head -2 | tr '\n' ' ')
    note "$VERSION"
    dsh 15 pm grant "$PKG" android.permission.POST_NOTIFICATIONS > /dev/null 2>&1
    if dsh 20 dumpsys package "$PKG" 2> /dev/null | grep -q "android.permission.POST_NOTIFICATIONS: granted=true"; then pass "notification permission granted"
    else bad "notification permission not granted"; fi
}

s2() {
    # Android delivers no broadcast to an app that was never started, so Mode is started once.
    dsh 30 monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 > /dev/null 2>&1
    t0=$(now)
    while [ -z "$MODE_PID" ] && [ $(( $(now) - t0 )) -lt 10 ]; do
        MODE_PID=$(dsh 10 pidof "$PKG" 2> /dev/null | tr -d '\r')
        [ -n "$MODE_PID" ] || sleep 1
    done
    [ -n "$MODE_PID" ] || { bad "no process 10 s after the start"; return; }
    # The check itself is "still the same process 5 s later".
    sleep 5
    again=$(dsh 10 pidof "$PKG" 2> /dev/null | tr -d '\r')
    if [ "$again" = "$MODE_PID" ]; then pass "running, pid $MODE_PID"; else bad "pid $MODE_PID, then '${again:-none}'"; fi
    if dsh 20 logcat -d -b crash 2> /dev/null | grep -q "$PKG"; then bad "the crash buffer has $PKG"; else pass "no crash"; fi
    # Mode ends its phone session whenever it goes to the background while idle (IdleDisconnectPolicy).
    # On #9 that cut a look short. So send Mode to the background now, before any op opens a session, and
    # wait until it has noticed. From here on Mode stays in the background. `install -r` keeps Mode's data,
    # so events.log can already have such a line from an earlier run: wait for one more than before.
    left() { dsh 10 run-as "$PKG" cat files/logs/events.log 2> /dev/null | grep -c "left Mode while idle"; }
    before=$(left)
    dsh 10 input keyevent KEYCODE_HOME > /dev/null 2>&1
    t0=$(now)
    while [ $(( $(now) - t0 )) -lt 15 ]; do
        if [ "$(left)" -gt "${before:-0}" ]; then pass "Mode in the background"; return; fi
        sleep 1
    done
    bad "Mode did not log leaving the screen within 15 s"
}

s3() {
    if [ "$(prop ro.kernel.qemu)" != 1 ] && [ "$(prop ro.boot.qemu)" != 1 ]; then
        note "not an emulator: the key op would replace this phone's AI key"
        return 2
    fi
    probe key
    if probe_ok && [ "$(probe_result)" = "key set" ]; then pass "stand-in key set"; else bad "key: $PROBE_LINE"; fi
}

# Adds Mode to the enabled accessibility services and keeps the ones already there: on a real phone
# those can be TalkBack or a password manager, which a plain `settings put` of Mode alone would turn off.
enable() {
    cur=$(dsh 10 settings get secure enabled_accessibility_services 2> /dev/null | tr -d '\r')
    case "$cur" in
        *"$SERVICE"*) new=$cur ;;
        "" | null) new=$SERVICE ;;
        *) new="$cur:$SERVICE" ;;
    esac
    dsh 10 settings put secure enabled_accessibility_services "$new" > /dev/null 2>&1
    dsh 10 settings put secure accessibility_enabled 1 > /dev/null 2>&1
}
s4() {
    dsh 10 appops set "$PKG" ACCESS_RESTRICTED_SETTINGS allow > /dev/null 2>&1 || note "appops failed"
    enable
    writes=1
    # Just after an install, Android can write the setting back without Mode's service (#9: 2 boots in 9).
    # So the script reads it back while waiting and writes it again if the service is gone (at most three writes).
    t0=$(now)
    while [ $(( $(now) - t0 )) -lt 30 ]; do
        probe status
        case "$PROBE_LINE" in ok*Engine=Passed*) pass "Engine=Passed after $(( $(now) - t0 )) s, $writes write(s)"; return ;; esac
        setting=$(dsh 10 settings get secure enabled_accessibility_services 2> /dev/null | tr -d '\r')
        case "$setting" in
            *ModeAccessibilityService*) ;;
            *) if [ "$writes" -lt 3 ]; then
                   note "the setting lost the service (now: ${setting:-empty}); writing it again"
                   enable
                   writes=$((writes + 1))
               fi ;;
        esac
        sleep 1
    done
    bad "Engine not Passed within 30 s ($writes writes): $PROBE_LINE"
}

s5() {
    probe home
    probe_ok || bad "home: $PROBE_LINE"
    probe current
    LAUNCHER=$(unquote "$(probe_result)")
    expected=$(dsh 15 cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME 2> /dev/null \
        | tr -d '\r' | tail -1 | cut -d/ -f1)
    if ! probe_ok; then bad "current: $PROBE_LINE"; LAUNCHER=
    elif [ -z "$LAUNCHER" ] || [ "$LAUNCHER" = null ] || [ "$LAUNCHER" = "$PKG" ]; then bad "in front after home: '$LAUNCHER'"; LAUNCHER=
    elif [ "$LAUNCHER" != "$expected" ]; then bad "in front after home: $LAUNCHER; the home app is $expected"; LAUNCHER=
    else pass "the launcher is in front: $LAUNCHER"
    fi
    probe checks
    probe_ok || { bad "checks: $PROBE_LINE"; return; }
    r=$(probe_result)
    for id in Engine Screen Hands; do
        case "$r" in *"$id=Passed"*) pass "$id=Passed" ;; *) bad "$id not Passed" ;; esac
    done
    note "$(printf '%s' "$r" | grep -o 'Battery=[A-Za-z]*([^)]*)' || echo 'Battery not reported')"
}

s6() {
    probe launch --es name Settings
    probe_ok || bad "launch: $PROBE_LINE"
    probe current
    if probe_ok && [ "$(unquote "$(probe_result)")" = com.android.settings ]; then pass "Settings is in front"
    else bad "in front after launch: $PROBE_LINE"; fi
    probe look
    probe_ok || { bad "look: $PROBE_LINE"; return; }
    r=$(probe_result)
    jpeg=$(printf '%s' "$r" | sed -n 's/.* jpeg=\([0-9]*\) .*/\1/p')
    if [ -z "$jpeg" ]; then bad "look has no screenshot"
    elif [ "$jpeg" -lt "$JPEG_MIN" ]; then bad "the screenshot is too small to be a real screen (jpeg=$jpeg, less than $JPEG_MIN)"
    else pass "screenshot jpeg=$jpeg"; fi
    case "$r" in *" private=true "*) bad "the screenshot is private" ;; *) pass "the screenshot is not private" ;; esac
    TOP=$(app_labels "$r")
    TOP_JPEG=$jpeg
    n=$(printf '%s\n' "$TOP" | grep -c .)
    if [ "$n" -ge 1 ]; then pass "$n texts from Settings"; else bad "no texts from Settings"; fi
    printf '%s\n' "$TOP" > "$OUT/S6-labels.txt"
}

# Repeats look until its app labels "differ" from $TOP or "equal" it ($1), for up to 10 s.
look_until() {
    t0=$(now)
    while :; do
        probe look
        LABELS=
        probe_ok && LABELS=$(app_labels "$(probe_result)")
        if [ -n "$LABELS" ]; then
            [ "$1" = differ ] && [ "$LABELS" != "$TOP" ] && return 0
            [ "$1" = equal ] && [ "$LABELS" = "$TOP" ] && return 0
        fi
        [ $(( $(now) - t0 )) -ge 10 ] && return 1
        sleep 1
    done
}

s7() {
    [ -n "$TOP" ] || { bad "S6 gave no Settings page to start from"; return; }
    probe look
    xy=
    probe_ok && xy=$(label_xy "$(probe_result)" "$ROW")
    [ -n "$xy" ] || { bad "no \"$ROW\" row on the Settings page"; return; }
    x=${xy% *}
    y=${xy#* }
    probe tap --ef x "$x" --ef y "$y"
    probe_ok || bad "tap: $PROBE_LINE"
    if look_until differ; then pass "the page changed after tapping \"$ROW\" at $x,$y"; else bad "the page did not change within 10 s"; fi
    # The new page's texts must come with a new image: a screenshot of exactly the size of the first page's
    # is the earlier frame (KNO-61, seen once on #13). On that failure one more look 2 s later tells QA
    # whether the frame recovers. (The look after `back` is not compared: the same page can match.)
    after=$(printf '%s' "$(probe_result)" | sed -n 's/.* jpeg=\([0-9]*\) .*/\1/p')
    if [ -n "$after" ] && [ "$after" = "$TOP_JPEG" ]; then
        bad "Mode's screenshot did not change after the tap (jpeg=$after, as on the first page)"
        sleep 2
        probe look
        again=$(printf '%s' "$(probe_result)" | sed -n 's/.* jpeg=\([0-9]*\) .*/\1/p')
        if [ "${again:-}" = "$TOP_JPEG" ]; then note "2 s later still the same: jpeg=$again"; else note "2 s later: jpeg=${again:-none} (the frame recovered)"; fi
    elif [ -n "$after" ]; then
        pass "a new screenshot after the tap (jpeg=$after)"
    fi
    printf '%s\n' "$LABELS" > "$OUT/S7-after-tap-labels.txt"
    probe current
    if probe_ok && [ "$(unquote "$(probe_result)")" = com.android.settings ]; then pass "still in Settings"
    else bad "in front after the tap: $PROBE_LINE"; fi
    probe back
    probe_ok || bad "back: $PROBE_LINE"
    if look_until equal; then pass "back on the first Settings page"; else bad "not back on the first Settings page within 10 s"; fi
    probe home
    probe_ok || bad "home: $PROBE_LINE"
    probe current
    if [ -z "$LAUNCHER" ]; then bad "S5 gave no launcher to compare with"
    elif probe_ok && [ "$(unquote "$(probe_result)")" = "$LAUNCHER" ]; then pass "home: $LAUNCHER in front"
    else bad "in front after home: $PROBE_LINE"; fi
}

s8() {
    text="Mode smoke ${GITHUB_RUN_ID:-local} $(now) $$"
    probe ask --es text "$text"
    probe_ok || bad "ask: $PROBE_LINE"
    # The probe logs "asked" even when Android blocked the notification, so the test is the notification.
    t0=$(now)
    while [ $(( $(now) - t0 )) -lt 10 ]; do
        if dsh 20 dumpsys notification --noredact 2> /dev/null | grep -qF "$text"; then pass "a notification shows \"$text\""; return; fi
        sleep 1
    done
    bad "no notification with \"$text\" within 10 s"
}

s9() {
    pid=$(dsh 10 pidof "$PKG" 2> /dev/null | tr -d '\r')
    if [ -n "$MODE_PID" ] && [ "$pid" = "$MODE_PID" ]; then pass "same process as at S2 ($pid)"
    else bad "the process was ${MODE_PID:-none} at S2 and is ${pid:-none} now"; fi
    if dsh 20 logcat -d -b crash 2> /dev/null | grep -q "$PKG"; then bad "the crash buffer has $PKG"; else pass "no crash"; fi
    if dsh 30 logcat -d 2> /dev/null | grep -q "ANR in $PKG"; then bad "ANR in $PKG"; else pass "no ANR"; fi
    probe status
    case "$PROBE_LINE" in ok*Engine=Passed*) pass "Engine=Passed" ;; *) bad "Engine: $PROBE_LINE" ;; esac
}

# ---- The run -------------------------------------------------------------------------------------------

DEVICE="$(prop ro.product.manufacturer) $(prop ro.product.model)"
SDK=$(prop ro.build.version.sdk)
RELEASE=$(prop ro.build.version.release)
IMAGE=$(prop ro.build.fingerprint)
UPTIME=$(dsh 10 cat /proc/uptime 2> /dev/null | cut -d' ' -f1)
trap collect EXIT
trap interrupted INT TERM
log "device $DEVICE, API $SDK (Android $RELEASE), up ${UPTIME:-?} s"
dsh 10 logcat -G 16M > /dev/null 2>&1 || log "logcat -G not accepted"

settle boot
# Recording starts once the boot has settled: before that, /sdcard can refuse the file (seen on #13).
rm -f "$OUT/.rec-stop"
record &
REC_PID=$!
run_step S1 "Install, notification permission" s1
# A failed S1 (for example the release build already installed) stops here: nothing runs against an app
# this script did not install.
[ "$result" = PASS ] || { log "S1 failed: S2 to S9 are skipped"; SKIP=" S2 S3 S4 S5 S6 S7 S8 S9 "; }
settle install
run_step S2 "Start Mode, then to the background" s2
run_step S3 "Stand-in AI key (emulators only)" s3
run_step S4 "Phone control on" s4
run_step S5 "Home, launcher, phone checks" s5
run_step S6 "Open Settings, look" s6
run_step S7 "Tap a row, back, home" s7
run_step S8 "Question notification" s8
run_step S9 "Same process, no crash or ANR, still on" s9
