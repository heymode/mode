#!/bin/sh
# TEMPORARY (the stay-awake PR only, removed before merge): the plan's Validate (b) for
# tasks.sh on an emulator, with a fake token and no secret, then the kill -9 check.
#   sh tools/emulator/tasks-validate.sh <debug apk>
set -u
APK=$1
FAKE="sk-ant-oat01-$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 70)"
SECRET=$FAKE
piece() { printf '%s' "$SECRET" | cut -c"$1"-"$(( $1 + 15 ))"; }
P1=$(piece 14); P2=$(piece $(( ${#SECRET} / 2 - 8 ))); P3=$(piece $(( ${#SECRET} - 15 )))
bad=0
ok() { echo "- PASS $*"; echo "- PASS $*" >> validate.md; }
no() { echo "- FAIL $*"; echo "- FAIL $*" >> validate.md; bad=1; }
: > validate.md

echo "## (b) a full run with a fake token" >> validate.md
CONNECTION=claude CLAUDE_CODE_OAUTH_TOKEN=$FAKE CLAUDE_ACCOUNT_EMAIL=ci@example.invalid CLAUDE_TOKEN_CREATED=$(date -u +%Y-%m-%d) \
    sh tools/emulator/tasks.sh "$APK" out
echo "tasks.sh exit $?" >> validate.md
for r in R1 R2 R3; do grep -q "^$r ok" out/run.log && ok "$r: $(grep "^$r ok" out/run.log | head -1)" || no "$r: $(grep "^$r" out/run.log | head -1)"; done
cut -f1,3 out/results.tsv | while IFS="$(printf '\t')" read -r id result; do
    case "$result" in "AI CONNECTION (sign-in refused: switch signal)") ok "task $id: $result" ;; *) no "task $id: $result" ;; esac
done
[ "$(wc -l < out/results.tsv)" -eq 5 ] && ok "5 tasks in results.tsv" || no "$(wc -l < out/results.tsv) tasks in results.tsv"
for p in "$FAKE" "$P1" "$P2" "$P3" ci@example.invalid; do
    if grep -rlaF -- "$p" out > /dev/null 2>&1; then no "a piece of the fake token (or the email) is in out/"; else ok "pattern of ${#p} characters: not in out/"; fi
done
[ -f out/.scrub-ok ] && ok "out/.scrub-ok exists" || no "no out/.scrub-ok"
n=$(find out -name '*.tar*' -o -name '*.gz' -o -name '*.zip' | wc -l); [ "$n" -eq 0 ] && ok "no archive in out/" || no "$n archive(s) in out/"
ls out/runs/*/ > /dev/null 2>&1 && ok "run folders: $(ls out/runs | tr '\n' ' ')" || no "no run folders"
grep -q "^screen kept on for the run" out/run.log && ok "$(grep "^screen kept on" out/run.log)" || no "no stay-awake line in run.log"
s=$(adb shell settings get global stay_on_while_plugged_in < /dev/null | tr -d "\r"); ok "note: stay_on_while_plugged_in after the run (put back): $s"
grep -q "^- Screen: kept on" out/summary.md && ok "summary.md has the Screen line" || no "summary.md has no Screen line"
echo "## stay-awake mechanism" >> validate.md
adb shell svc power stayon true < /dev/null; adb shell settings put system screen_off_timeout 15000 < /dev/null; adb shell input keyevent KEYCODE_WAKEUP < /dev/null
sleep 25
w=$(adb shell dumpsys power < /dev/null | tr -d "\r" | grep -o "mWakefulness=[A-Za-z]*" | head -1)
[ "$w" = mWakefulness=Awake ] && ok "with stayon and a 15 s timeout, after 25 s: $w" || no "with stayon and a 15 s timeout, after 25 s: $w"
adb shell svc power stayon false < /dev/null; sleep 25
w=$(adb shell dumpsys power < /dev/null | tr -d "\r" | grep -o "mWakefulness=[A-Za-z]*" | head -1); ok "note: without stayon, after 25 s: $w (expected Asleep or Dozing)"
grep -h "Contacts app:" out/run.log | sed 's/^/- note /' >> validate.md
echo "## kill -9 mid-task" >> validate.md
CONNECTION=claude CLAUDE_CODE_OAUTH_TOKEN=$FAKE CLAUDE_TOKEN_CREATED=$(date -u +%Y-%m-%d) TASKS="dark timeout" \
    sh tools/emulator/tasks.sh "$APK" out-kill > /dev/null 2>&1 &
k=$!
t0=$(date +%s)
until grep -q "^T-dark" out-kill/run.log 2> /dev/null || [ $(( $(date +%s) - t0 )) -gt 300 ]; do sleep 2; done
sleep 5
kill -9 "$k"
sleep 3
grep -q "^T-dark" out-kill/run.log && ok "killed during T-dark" || no "T-dark never started"
[ -f out-kill/.scrub-ok ] && no "out-kill/.scrub-ok exists after kill -9 (the upload would run)" || ok "no out-kill/.scrub-ok after kill -9: the upload would be skipped"
cp out/summary.md summary-full.md 2> /dev/null
echo; cat validate.md
exit "$bad"
