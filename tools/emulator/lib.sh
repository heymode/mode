# Shared helpers for the emulator scripts (smoke.sh; later tasks.sh). Sourced, never run:
#   . "$(dirname "$0")/lib.sh"
# Source it once, before the first step. The traps stay in each script.
#
# Contract. The caller sets these before it calls any helper:
#   OUT         the output folder (it exists)            ADB         adb, or "adb -s <serial>"
#   PKG         Mode's package                           PROBE       the probe receiver, "$PKG/…DevProbe"
#   SERVICE     Mode's accessibility service, for control_on
#   REC_PREFIX  the recording's file names on the device and in $OUT: <prefix>-<n>.mp4
#   STEP_RAW    where probe appends its raw lines (lib.sh starts it at /dev/null; a step points it at a file)
# lib.sh sets TO (timeout, gtimeout or nothing), PROBE_LINE (the last op's line) and REC_PID (empty; the
# caller runs `record &` and keeps its pid there).
#
# POSIX sh has no local variables, so the helpers' own variables start with an underscore. Those names are
# reserved for lib.sh: the scripts that source it never use them.

# $ADB is unquoted on purpose everywhere: ADB="adb -s <serial>" must split into words.
# shellcheck disable=SC2086
if command -v timeout > /dev/null 2>&1; then TO=timeout
elif command -v gtimeout > /dev/null 2>&1; then TO=gtimeout
else TO=; echo "$(basename "$0" .sh): no timeout command; adb calls run without a deadline" >&2
fi

# ---- Helpers -------------------------------------------------------------------------------------------

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

# Android is still delivering boot broadcasts when an emulator reports it has booted (up to 36 s on #9),
# and settings and screenshots flake while it does. Wait until the broadcast queues are idle.
settle() {
    _s0=$(now)
    if dsh 120 am wait-for-broadcast-idle > /dev/null 2>&1; then log "broadcasts idle ($1) after $(( $(now) - _s0 )) s"
    else log "broadcasts not idle ($1) after $(( $(now) - _s0 )) s; going on"; fi
}

# Adds Mode to the enabled accessibility services and keeps the ones already there: on a real phone
# those can be TalkBack or a password manager, which a plain `settings put` of Mode alone would turn off.
control_on() {
    _cur=$(dsh 10 settings get secure enabled_accessibility_services 2> /dev/null | tr -d '\r')
    case "$_cur" in
        *"$SERVICE"*) _new=$_cur ;;
        "" | null) _new=$SERVICE ;;
        *) _new="$_cur:$SERVICE" ;;
    esac
    dsh 10 settings put secure enabled_accessibility_services "$_new" > /dev/null 2>&1
    dsh 10 settings put secure accessibility_enabled 1 > /dev/null 2>&1
}

# ---- Evidence ------------------------------------------------------------------------------------------
# The screen is recorded for the whole run in 170 s segments (screenrecord stops at 180 s). This is best
# effort: it can fail on a software-rendered emulator. That is written down and never fails a step.

REC_PID=
record() {
    _n=0
    while [ ! -f "$OUT/.rec-stop" ]; do
        _n=$((_n + 1))
        _r0=$(now)
        dsh 200 screenrecord --time-limit 170 "/sdcard/$REC_PREFIX-$_n.mp4" >> "$OUT/screenrecord.txt" 2>&1
        _rrc=$?
        if [ ! -f "$OUT/.rec-stop" ] && [ $(( $(now) - _r0 )) -lt 5 ]; then
            echo "segment $_n ended after $(( $(now) - _r0 )) s with exit $_rrc; recording stopped" >> "$OUT/screenrecord.txt"
            break
        fi
    done
}

# Stops the recording and pulls it, then the logs: logcat.txt, modeprobe.txt, crash.txt, accessibility.txt.
evidence() {
    if [ -n "$REC_PID" ]; then
        touch "$OUT/.rec-stop"
        # SIGINT lets screenrecord finish the file. Killed any other way, the mp4 does not play.
        dsh 10 pkill -INT screenrecord > /dev/null 2>&1
        _w0=$(now)
        while kill -0 "$REC_PID" 2> /dev/null && [ $(( $(now) - _w0 )) -lt 20 ]; do sleep 1; done
        kill "$REC_PID" 2> /dev/null
        for _f in $(dsh 10 ls /sdcard/ 2> /dev/null | tr -d '\r' | grep "^$REC_PREFIX-[0-9]*\.mp4\$"); do
            to 120 $ADB pull "/sdcard/$_f" "$OUT/$_f" > /dev/null 2>&1
            dsh 10 rm -f "/sdcard/$_f" > /dev/null 2>&1
        done
        rm -f "$OUT/.rec-stop"
    fi
    dsh 60 logcat -d -v threadtime > "$OUT/logcat.txt" 2>&1
    probe_lines > "$OUT/modeprobe.txt" 2>&1
    dsh 30 logcat -d -b crash > "$OUT/crash.txt" 2>&1
    dsh 15 dumpsys accessibility > "$OUT/accessibility.txt" 2>&1
}
