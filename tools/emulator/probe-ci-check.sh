#!/bin/sh
# TEMPORARY (real-task PR F only, removed before merge): the plan's validation of DevProbe's signin and
# answer ops (emulator-tasks-plan.md, slice 2), on an emulator, with a fake token and no secret.
#   sh tools/emulator/probe-ci-check.sh <debug apk> <output folder>
# Writes <output folder>/checks.md (one PASS or FAIL line per check) and exits non-zero on any FAIL.
set -u
APK=$1
OUT=$2
mkdir -p "$OUT"
PKG=app.heymode.mode
PROBE="$PKG/com.piyush.mode.app.DevProbe"
SERVICE="$PKG/com.piyush.mode.android.ModeAccessibilityService"
FAILED=0
# A fresh fake token per run, shaped like a real one, so a leak of it is easy to search for.
FAKE="sk-ant-oat01-FAKE$(date +%s)$$x$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
: > "$OUT/checks.md"

say() { echo "$*"; echo "$*" >> "$OUT/checks.md"; }
ok() { say "- PASS $*"; }
bad() { say "- FAIL $*"; FAILED=1; }
now() { date +%s; }
sh_() { timeout 60 adb shell "$@" < /dev/null 2> /dev/null | tr -d '\r'; }
runas() { sh_ run-as "$PKG" "$@"; }
lines() { sh_ logcat -d -s ModeProbe:I | grep -E 'ModeProbe *: (ok|failed) [0-9]+ms'; }
LINE=
probe() {
    before=$(lines | wc -l)
    timeout 60 adb shell am broadcast -n "$PROBE" --es op "$@" > /dev/null 2>&1 < /dev/null
    t0=$(now)
    LINE=
    while [ -z "$LINE" ] && [ $(( $(now) - t0 )) -lt 10 ]; do
        LINE=$(lines | sed -n "$((before + 1))p" | sed 's/^.*ModeProbe *: *//')
        [ -n "$LINE" ] || sleep 1
    done
    echo "op $*: ${LINE:-no line}" >> "$OUT/probe.txt"
}
# The sign-in file, written into Mode's private folder over stdin (never as a command-line argument).
put_signin() {
    printf '%s' "$1" > "$OUT/.signin.json"
    # exec-in joins its arguments into one device command: the redirect stays inside the quotes.
    if ! timeout 30 adb exec-in "run-as $PKG sh -c 'cat > files/probe-signin.json'" < "$OUT/.signin.json" 2> /dev/null || ! has_file; then
        timeout 30 adb push "$OUT/.signin.json" /data/local/tmp/probe-signin.json > /dev/null 2>&1
        sh_ run-as "$PKG" cp /data/local/tmp/probe-signin.json files/probe-signin.json
        sh_ rm -f /data/local/tmp/probe-signin.json
    fi
    rm -f "$OUT/.signin.json"
}
has_file() { runas ls files | grep -qx probe-signin.json; }
pref() { runas cat shared_prefs/mode.xml | sed -n "s/.*name=\"$1\">\([^<]*\)<.*/\1/p"; }
far=$(( ($(now) + 300 * 24 * 3600) * 1000 ))

timeout 600 adb wait-for-device
timeout 120 adb shell am wait-for-broadcast-idle > /dev/null 2>&1
timeout 180 adb install -r "$APK" > "$OUT/install.txt" 2>&1 || { bad "install: $(tail -1 "$OUT/install.txt")"; exit 1; }
sh_ pm grant "$PKG" android.permission.POST_NOTIFICATIONS
sh_ monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 > /dev/null
sleep 5
sh_ input keyevent KEYCODE_HOME
timeout 60 adb shell am wait-for-broadcast-idle > /dev/null 2>&1
say "emulator: API $(sh_ getprop ro.build.version.sdk), ro.kernel.qemu=$(sh_ getprop ro.kernel.qemu), ro.boot.qemu=$(sh_ getprop ro.boot.qemu)"

say "## signin"
# 1 and 2: a fake token with a far expiry is saved, and the file is gone.
put_signin "{\"provider\":\"claude\",\"token\":\"$FAKE\",\"expires_at_ms\":$far,\"max_steps\":15,\"full_access\":false}"
has_file && ok "1. the file is in Mode's folder before the op" || bad "1. the file did not reach Mode's folder"
probe signin
case "$LINE" in "ok "*"ms signin provider=claude expires="*" maxSteps=15 fullAccess=false") ok "2. signin: $LINE" ;; *) bad "2. signin: ${LINE:-no line}" ;; esac
has_file && bad "2. the file is still there" || ok "2. the file is gone"
[ "$(pref model_provider)" = claude_oauth ] && ok "2. provider is claude_oauth" || bad "2. provider is '$(pref model_provider)'"
[ "$(pref learn_from_tasks)" = false ] && ok "2. learn_from_tasks is false" || bad "2. learn_from_tasks is '$(pref learn_from_tasks)'"
[ "$(pref agent_max_steps)" = 15 ] && ok "2. agent_max_steps is 15" || bad "2. agent_max_steps is '$(pref agent_max_steps)'"
# 3: status still answers; a task with the fake token ends on a refused sign-in.
probe status
case "$LINE" in "ok "*) ok "3. status answers: $LINE" ;; *) bad "3. status: ${LINE:-no line}" ;; esac
sh_ appops set "$PKG" ACCESS_RESTRICTED_SETTINGS allow
sh_ settings put secure enabled_accessibility_services "$SERVICE"
sh_ settings put secure accessibility_enabled 1
t0=$(now)
while [ $(( $(now) - t0 )) -lt 30 ]; do probe status; case "$LINE" in ok*Engine=Passed*) break ;; esac; sleep 1; done
case "$LINE" in ok*Engine=Passed*) ok "3. phone control on" ;; *) bad "3. phone control not on: $LINE" ;; esac
runs_before=$(runas ls files/logs/runs | wc -l)
probe overlay --es task "Turn on dark theme"
case "$LINE" in *summoned=true*) ok "3. overlay: $LINE" ;; *) bad "3. overlay: ${LINE:-no line}" ;; esac
t0=$(now)
run=
while [ $(( $(now) - t0 )) -lt 90 ]; do
    run=$(runas ls -t files/logs/runs | head -1)
    if [ "$(runas ls files/logs/runs | wc -l)" -gt "$runs_before" ] && runas cat "files/logs/runs/$run/steps.jsonl" | grep -q '"error"'; then break; fi
    sleep 3
done
runas cat "files/logs/runs/$run/steps.jsonl" > "$OUT/steps.jsonl"
runas cat "files/logs/runs/$run/run.json" > "$OUT/run.json"
err=$(grep '"answer"' "$OUT/steps.jsonl" | grep -o '"error":"[^"]*' | tail -1 | sed 's/^"error":"//')
case "$err" in "Claude sign-in failed (HTTP"*) ok "3. the task's model call ended on: $err" ;; *) bad "3. the task's last answer error: '${err:-none}' (run ${run:-none})" ;; esac
outcome=$(grep -o '"outcome":"[^"]*' "$OUT/run.json" | sed 's/^"outcome":"//')
say "- note: run.json outcome is '${outcome:-none}' (the plan expects running: a failed model call never writes the end)"
probe overlaystate --ez close true
# 4: the fake token is in no log.
timeout 60 adb logcat -d -v threadtime > "$OUT/logcat.txt" 2>&1
runas cat files/logs/events.log > "$OUT/events.log"
for f in logcat.txt events.log steps.jsonl run.json probe.txt; do
    if grep -qF "$FAKE" "$OUT/$f"; then bad "4. the fake token is in $f"; else ok "4. the fake token is not in $f"; fi
done
# 5: the same op on "a real phone" (as_phone) refuses, deletes the file and changes nothing.
put_signin "{\"provider\":\"openrouter\",\"token\":\"sk-or-should-not-be-saved\",\"max_steps\":7,\"full_access\":true}"
probe signin --ez as_phone true
case "$LINE" in "failed "*"ms ProbeRefused: not an emulator") ok "5. as a phone: $LINE" ;; *) bad "5. as a phone: ${LINE:-no line}" ;; esac
has_file && bad "5. the file is still there" || ok "5. the file is gone"
[ "$(pref model_provider)" = claude_oauth ] && [ "$(pref agent_max_steps)" = 15 ] && [ "$(pref full_access)" = false ] \
    && ok "5. nothing changed (provider, max steps, full access)" || bad "5. a setting changed: $(pref model_provider) $(pref agent_max_steps) $(pref full_access)"
# Bad input: refused with a fixed reason that never quotes the file.
put_signin "{\"provider\":\"claude\",\"token\":\"$FAKE\",\"expires_at_ms\":$(( $(now) * 1000 + 60000 )),\"max_steps\":15}"
probe signin
case "$LINE" in "failed "*"ms ProbeRefused: expires_at_ms less than a day ahead") ok "5. a near expiry: $LINE" ;; *) bad "5. a near expiry: ${LINE:-no line}" ;; esac
put_signin "{not json $FAKE"
probe signin
case "$LINE" in "failed "*"ms ProbeRefused: not a JSON object") ok "5. not JSON: $LINE" ;; *) bad "5. not JSON: ${LINE:-no line}" ;; esac
probe signin
case "$LINE" in "failed "*"ms ProbeRefused: no probe-signin.json") ok "5. no file: $LINE" ;; *) bad "5. no file: ${LINE:-no line}" ;; esac

say "## answer"
probe answer --es text yes
case "$LINE" in "failed "*"ms ProbeRefused: nothing pending") ok "6. yes, nothing pending: $LINE" ;; *) bad "6. yes, nothing pending: ${LINE:-no line}" ;; esac
for t in always Yes maybe; do
    probe answer --es text "$t"
    case "$LINE" in "failed "*"ms ProbeRefused: text must be yes or no") ok "7. '$t': $LINE" ;; *) bad "7. '$t': ${LINE:-no line}" ;; esac
done
probe answer --es text yes --ez as_phone true
case "$LINE" in "failed "*"ms ProbeRefused: not an emulator") ok "7. as a phone: $LINE" ;; *) bad "7. as a phone: ${LINE:-no line}" ;; esac
[ "$(pref full_access)" = false ] && ok "8. full_access still false" || bad "8. full_access is '$(pref full_access)'"

timeout 60 adb logcat -d -v threadtime > "$OUT/logcat.txt" 2>&1
grep -qF "$FAKE" "$OUT/logcat.txt" && bad "4. the fake token is in logcat at the end" || ok "4. the fake token is not in logcat at the end"
say ""
[ "$FAILED" -eq 0 ] && say "**All checks passed.**" || say "**Some checks failed.**"
exit "$FAILED"
