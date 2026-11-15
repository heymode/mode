#!/bin/sh
# Real tasks on the Android emulator (emulator-tasks-plan.md, slice 3): signs Mode in with the run's AI
# connection, gives it a fixed list of tasks through the overlay, and judges each by the phone's real state
# over adb, never by what the model says.
#   tools/emulator/tasks.sh [--skip R2] <debug apk> <output folder>
#   tools/emulator/tasks.sh --self-test                      (the classify table; no device, no secret)
#
# Environment (the workflow's emulator step sets these; nothing else needs them):
#   CONNECTION            claude (default) or openrouter
#   CLAUDE_CODE_OAUTH_TOKEN, CLAUDE_TOKEN_CREATED (YYYY-MM-DD, the day the token was made), CLAUDE_ACCOUNT_EMAIL
#   OPENROUTER_API_KEY    for CONNECTION=openrouter
#   TASKS                 task ids to run (default: all, in this order: dark timeout version contact dnd)
#   FULL_ACCESS           true or false (default false: Mode asks before risky steps, as for users)
#   BAD_TOKEN             true: one character is added to the token (the "refused" sensitivity run)
#
# Results per task: PASS, FAIL (Mode got it wrong), FAIL (limit) (15 steps or 5 minutes), AI CONNECTION
# (a model call failed: Claude refused or was busy; not a Mode bug) or SETUP (the state before the task could
# not be set; not Mode's fault). The output folder gets summary.md, a screenshot per task, each task's run
# folder, the recording and the logs. The EXIT trap fills it, then the scrub searches every byte for the
# secret, and only a clean scrub writes out/.scrub-ok, which the workflow needs before it uploads anything.
#
# The secret is read once into a variable and unset from the environment, so the emulator, adb and every
# later command never inherit it. It reaches the phone over stdin only. No `set -x`, ever.
# $ADB is unquoted on purpose everywhere: ADB="adb -s <serial>" must split into words.
# shellcheck disable=SC2086
set -u

# ---- Classify (also the --self-test table) -------------------------------------------------------------

# A model error's text (Mode's exception message, from steps.jsonl) to an AI CONNECTION label (C2).
classify() {
    case "$1" in
        "Claude sign-in failed (HTTP"*) echo "AI CONNECTION (sign-in refused: switch signal)" ;;
        "Claude is rate limited"*) echo "AI CONNECTION (429: busy)" ;;
        *) echo "AI CONNECTION (other: switch signal until cto has read it)" ;;
    esac
}

# ---- The scrub -------------------------------------------------------------------------------------------

# Every pattern on its own line, never an empty one (an empty -F pattern matches everything). printf is a
# builtin, so no pattern is ever on a process's command line (/proc/*/cmdline is readable by all).
patterns() { for p in "$SECRET" "$P1" "$P2" "$P3" "$PREFIX" "$EMAIL"; do [ -n "$p" ] && printf '%s\n' "$p"; done; }
scrub() {
    rm -f "$OUT/.scrub-ok"
    # No archive may stay: an archive's compressed bytes would hide a match.
    find "$OUT" -type f \( -name '*.tar' -o -name '*.tar.gz' -o -name '*.tgz' -o -name '*.zip' -o -name '*.gz' \) -exec rm -f {} + 2> /dev/null
    # With no pattern at all there is nothing to search for (and some greps match everything on an empty -f).
    hits=0
    pats=$(patterns)
    [ -n "$pats" ] && hits=$(printf "%s\n" "$pats" | grep -rlaF -f - "$OUT" 2> /dev/null | wc -l | tr -d " ")
    pats=
    if [ "$hits" -gt 0 ]; then
        find "$OUT" -mindepth 1 -delete 2> /dev/null
        echo "# Mode real tasks: scrub found the token in $hits file(s); nothing uploaded" > "$OUT/summary.md"
        echo "scrub: found the token in $hits file(s); everything deleted, nothing uploaded"
        return 1
    fi
    : > "$OUT/.scrub-ok"
}
# Three 16-character pieces of the secret part (from character 14, the middle, the last 16): the first 16
# characters alone are mostly the fixed prefix (B2). The prefix is a pattern only if the real token has it.
piece() { printf '%s' "$SECRET" | cut -c"$1"-"$(( $1 + 15 ))"; }
set_patterns() {
    P1=; P2=; P3=
    if [ "${#SECRET}" -ge 40 ]; then
        P1=$(piece 14)
        P2=$(piece $(( ${#SECRET} / 2 - 8 )))
        P3=$(piece $(( ${#SECRET} - 15 )))
    fi
    case "$SECRET" in "$PREFIX"*) ;; *) PREFIX= ;; esac
}

if [ "${1:-}" = --self-test ]; then
    # The scrub, on a scratch folder with a fake token: clean files get the marker; one planted piece
    # (or the email) deletes everything and writes no marker.
    st_check() { if eval "$2"; then echo "ok   scrub: $1"; else echo "FAIL scrub: $1"; bad=1; fi; }
    bad=0
    SECRET="sk-ant-oat01-$(printf 'selftest%.0s' 1 2 3 4 5 6 7 8 9)"
    PREFIX=sk-ant-oat01-
    EMAIL=ci@example.invalid
    set_patterns
    OUT=$(mktemp -d)
    mkdir -p "$OUT/runs/dark"
    echo "nothing secret" > "$OUT/runs/dark/run.json"
    scrub > /dev/null
    st_check "a clean folder gets .scrub-ok" '[ -f "$OUT/.scrub-ok" ] && [ -f "$OUT/runs/dark/run.json" ]'
    for planted in "$P1" "$P2" "$P3" "$SECRET" "$EMAIL" "$PREFIX"; do
        mkdir -p "$OUT/runs/dark"
        printf 'binary\000then %s here\n' "$planted" > "$OUT/runs/dark/step-1.jpg"
        scrub > /dev/null
        st_check "a planted pattern empties the folder and leaves no marker" \
            '[ ! -f "$OUT/.scrub-ok" ] && [ "$(find "$OUT" -type f | wc -l)" -eq 1 ] && grep -q "scrub found the token" "$OUT/summary.md"'
        find "$OUT" -mindepth 1 -delete
    done
    printf 'x' | gzip > "$OUT/runs.tar.gz"
    scrub > /dev/null
    st_check "no archive stays" '[ ! -f "$OUT/runs.tar.gz" ] && [ -f "$OUT/.scrub-ok" ]'
    SECRET=; EMAIL=; set_patterns; PREFIX=
    echo "nothing" > "$OUT/a.txt"
    scrub > /dev/null
    st_check "no secret at all: nothing to find, the folder stays" '[ -f "$OUT/.scrub-ok" ] && [ -f "$OUT/a.txt" ]'
    SECRET="sk-ant-oat01-$(printf 'selftest%.0s' 1 2 3 4 5 6 7 8 9)"; PREFIX=sk-ant-oat01-; set_patterns
    rm -rf "$OUT"
    for p in "$P1" "$P2" "$P3"; do [ "${#p}" -eq 16 ] || { echo "FAIL a pattern piece is ${#p} characters, not 16"; bad=1; }; done

    bad=0
    while IFS='|' read -r text want; do
        got=$(classify "$text")
        if [ "$got" = "$want" ]; then echo "ok   $text"; else echo "FAIL $text: $got, expected $want"; bad=1; fi
    done <<'EOF'
Claude sign-in failed (HTTP 401). Try signing in again.|AI CONNECTION (sign-in refused: switch signal)
Claude sign-in failed (HTTP 400). Try signing in again.|AI CONNECTION (sign-in refused: switch signal)
Claude is rate limited. Try again in a moment.|AI CONNECTION (429: busy)
Claude refused this OAuth request.|AI CONNECTION (other: switch signal until cto has read it)
Claude: overloaded|AI CONNECTION (other: switch signal until cto has read it)
Claude request failed (HTTP 500).|AI CONNECTION (other: switch signal until cto has read it)
This Claude model uses API credits, not your plan.|AI CONNECTION (other: switch signal until cto has read it)
Claude gave no answer in 25 s.|AI CONNECTION (other: switch signal until cto has read it)
java.net.UnknownHostException: api.anthropic.com|AI CONNECTION (other: switch signal until cto has read it)
EOF
    exit "$bad"
fi

# ---- Arguments, the secret ----------------------------------------------------------------------------

usage() { echo "usage: tools/emulator/tasks.sh [--skip R2] <debug apk> <output folder> | --self-test" >&2; exit 2; }
SKIP_R2=0
while [ $# -gt 0 ]; do
    case "$1" in
        --skip) [ "${2:-}" = R2 ] || usage; SKIP_R2=1; shift 2 ;;
        -*) usage ;;
        *) break ;;
    esac
done
[ $# -eq 2 ] || usage
APK=$1
OUT=$2
[ -f "$APK" ] || { echo "tasks: no APK at $APK" >&2; exit 2; }
mkdir -p "$OUT/runs"
rm -f "$OUT/.scrub-ok"

CONNECTION=${CONNECTION:-claude}
case "$CONNECTION" in claude | openrouter) ;; *) echo "tasks: CONNECTION is claude or openrouter" >&2; exit 2 ;; esac
case "${FULL_ACCESS:-false}" in true | false) FULL=${FULL_ACCESS:-false} ;; *) echo "tasks: FULL_ACCESS is true or false" >&2; exit 2 ;; esac
# Read once, then out of the environment (N4). The scrub's patterns come from these variables.
if [ "$CONNECTION" = claude ]; then SECRET=${CLAUDE_CODE_OAUTH_TOKEN:-}; PREFIX=sk-ant-oat01-
else SECRET=${OPENROUTER_API_KEY:-}; PREFIX=sk-or-v1-; fi
EMAIL=${CLAUDE_ACCOUNT_EMAIL:-}
unset CLAUDE_CODE_OAUTH_TOKEN OPENROUTER_API_KEY CLAUDE_ACCOUNT_EMAIL
set_patterns

ADB=${ADB:-adb}
PKG=app.heymode.mode
PROBE="$PKG/com.piyush.mode.app.DevProbe"
SERVICE="$PKG/com.piyush.mode.android.ModeAccessibilityService"
REC_PREFIX=mode-tasks
# shellcheck source=tools/emulator/lib.sh
. "$(dirname "$0")/lib.sh"
MAX_STEPS=15
TASK_SECS=300
ALL_TASKS="dark timeout version contact dnd"
TASK_LIST=${TASKS:-$ALL_TASKS}
for t in $TASK_LIST; do case " $ALL_TASKS " in *" $t "*) ;; *) echo "tasks: unknown task '$t' (known: $ALL_TASKS)" >&2; exit 2 ;; esac; done

FAILED=0
UNEXPECTED=0
INVALID=
MODE_PID=
OPENED_MODE=
DAYS_LEFT=
: > "$OUT/run.log"
: > "$OUT/results.tsv"
: > "$OUT/answers.txt"
STEP_RAW="$OUT/probe.txt"
: > "$STEP_RAW"

runas() { ra_t=$1; shift; dsh "$ra_t" run-as "$PKG" "$@"; }
pid() { dsh 10 pidof "$PKG" 2> /dev/null | tr -d '\r'; }
# Text without the characters that would break a Markdown table row.
cell() { printf '%s' "$1" | tr '\n|\r' '  ' | cut -c1-"${2:-200}"; }

# ---- Summary and evidence (the EXIT trap) -------------------------------------------------------------

summary() {
    {
        word=$( [ "$FAILED" -eq 0 ] && echo PASS || echo FAIL )
        echo "# Mode real tasks: $word"
        echo
        echo "- Connection: $CONNECTION$( [ "${BAD_TOKEN:-false}" = true ] && echo ' (bad-token run: every task should be AI CONNECTION)')"
        echo "- Full access: $FULL"
        echo "- Commit: ${TASKS_COMMIT:-${GITHUB_SHA:-$(git rev-parse HEAD 2> /dev/null || echo unknown)}}"
        [ -n "${GITHUB_RUN_ID:-}" ] && echo "- Run: ${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}/actions/runs/$GITHUB_RUN_ID"
        echo "- Device: API ${SDK:-?} (Android ${REL:-?}), \`${IMAGE:-?}\`"
        [ -n "$DAYS_LEFT" ] && echo "- Token: $DAYS_LEFT days left$( [ "$DAYS_LEFT" -lt 30 ] && echo ' **(under 30: the owner makes a new one)**')"
        [ -n "$INVALID" ] && echo "- **Run invalid:** $INVALID"
        [ -n "$OPENED_MODE" ] && echo "- **A task opened Mode itself ($OPENED_MODE):** its screenshots and step images and the whole recording were deleted (they could show the account)."
        echo
        echo "| Task | Words | Result | Outcome | Steps | Time | Model | Mode's summary |"
        echo "| --- | --- | --- | --- | --- | --- | --- | --- |"
        tab=$(printf '\t')
        while IFS="$tab" read -r id words result outcome steps secs model said; do
            echo "| $id | $words | $result | $outcome | $steps | $secs s | $model | $said |"
        done < "$OUT/results.tsv"
        echo
        if [ -s "$OUT/answers.txt" ]; then
            echo "## Questions Mode asked, and the answers"
            echo
            sed 's/^/- /' "$OUT/answers.txt"
            echo
        fi
        echo "## What happened"
        echo
        echo '```'
        cat "$OUT/run.log"
        echo '```'
    } > "$OUT/summary.md"
}


collect() {
    status=$?
    trap - EXIT INT TERM
    [ -n "${WATCHDOG:-}" ] && kill "$WATCHDOG" 2> /dev/null
    log "collecting evidence"
    evidence
    runas 30 cat files/logs/events.log > "$OUT/events.log" 2>&1
    # N2: a task that opened Mode may have its account page on camera. Its pictures go, and so does the
    # recording (a segment can span several tasks).
    if [ -n "$OPENED_MODE" ]; then
        for t in $OPENED_MODE; do rm -f "$OUT/T-$t.png"; find "$OUT/runs/$t" -name '*.jpg' -delete 2> /dev/null; done
        rm -f "$OUT"/"$REC_PREFIX"-*.mp4
    fi
    summary
    [ "$FAILED" -eq 1 ] && [ "$status" -eq 0 ] && status=1
    log "exit $status"
    # The scrub is the very last thing, after the summary: nothing is written into out/ after it.
    if ! scrub; then status=3; fi
    exit "$status"
}
interrupted() { log "interrupted${TASK:+ during $TASK}"; FAILED=1; exit 130; }

# ---- R1 to R3 -----------------------------------------------------------------------------------------

r1() {
    to 180 $ADB install -r "$APK" > "$OUT/install.txt" 2>&1 || { log "R1 FAIL install: $(tail -1 "$OUT/install.txt")"; return 1; }
    dsh 15 pm grant "$PKG" android.permission.POST_NOTIFICATIONS > /dev/null 2>&1
    dsh 30 monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 > /dev/null 2>&1
    t0=$(now)
    while [ -z "$MODE_PID" ] && [ $(( $(now) - t0 )) -lt 10 ]; do MODE_PID=$(pid); [ -n "$MODE_PID" ] || sleep 1; done
    [ -n "$MODE_PID" ] || { log "R1 FAIL no process 10 s after the start"; return 1; }
    dsh 10 input keyevent KEYCODE_HOME > /dev/null 2>&1
    log "R1 ok: installed, started (pid $MODE_PID)"
}

# Phone control on, as the smoke job's S4 does it (read back, written again if Android dropped it).
r2() {
    dsh 10 appops set "$PKG" ACCESS_RESTRICTED_SETTINGS allow > /dev/null 2>&1
    control_on
    _writes=1
    t0=$(now)
    while [ $(( $(now) - t0 )) -lt 30 ]; do
        probe status
        case "$PROBE_LINE" in ok*Engine=Passed*) log "R2 ok: phone control on after $(( $(now) - t0 )) s"; return 0 ;; esac
        case "$(dsh 10 settings get secure enabled_accessibility_services 2> /dev/null | tr -d '\r')" in
            *ModeAccessibilityService*) ;;
            *) [ "$_writes" -lt 3 ] && { control_on; _writes=$((_writes + 1)); } ;;
        esac
        sleep 1
    done
    log "R2 FAIL phone control not on within 30 s: $PROBE_LINE"
    return 1
}

# The sign-in, over stdin into Mode's private folder, then the probe's signin op (which deletes the file).
r3() {
    [ -n "$SECRET" ] || { log "R3 FAIL no secret for the $CONNECTION connection"; return 1; }
    # The token goes into JSON as it is: only the characters these tokens use, so nothing can break out.
    case "$SECRET" in *[!A-Za-z0-9._-]*) log "R3 FAIL the secret has characters a token never has"; return 1 ;; esac
    token=$SECRET
    [ "${BAD_TOKEN:-false}" = true ] && token="${SECRET}x"
    if [ "$CONNECTION" = claude ]; then
        # The token doesn't carry its expiry: a year from the day the owner made it. Mode refreshes a token
        # that is about to expire, which fails on the placeholder, so a wrong date would look like a revoked
        # token (C3): stop here instead.
        created=$(date -u -d "${CLAUDE_TOKEN_CREATED:-none}" +%s 2> /dev/null)
        expires=$(( ${created:-0} + 365 * 86400 ))
        if [ -z "$created" ] || [ "$expires" -le $(( $(now) + 86400 )) ]; then
            log "R3 FAIL CLAUDE_TOKEN_CREATED missing or past ('${CLAUDE_TOKEN_CREATED:-}')"
            return 1
        fi
        DAYS_LEFT=$(( (expires - $(now)) / 86400 ))
        json="{\"provider\":\"claude\",\"token\":\"$token\",\"expires_at_ms\":${expires}000,\"max_steps\":$MAX_STEPS,\"full_access\":$FULL}"
    else
        json="{\"provider\":\"openrouter\",\"token\":\"$token\",\"max_steps\":$MAX_STEPS,\"full_access\":$FULL}"
    fi
    # exec-in passes stdin to the command; the whole device command is one quoted argument.
    printf '%s' "$json" | to 30 $ADB exec-in "run-as $PKG sh -c 'cat > files/probe-signin.json'" > /dev/null 2>&1
    json=; token=
    probe signin
    runas 10 rm -f files/probe-signin.json > /dev/null 2>&1
    case "$PROBE_LINE" in "ok "*"ms signin provider=$CONNECTION"*) log "R3 ok: $(probe_result)" ;; *) log "R3 FAIL signin: $PROBE_LINE"; return 1 ;; esac
}

# ---- The tasks ----------------------------------------------------------------------------------------
# Each task: words(), its risky word for questions (only contact has one), before(), check(), after().
# before() returns non-zero when the state could not be set: the task is SETUP and doesn't run.

CONTACTS_PKG=
RAW_IDS=

words() {
    case "$1" in
        dark) echo "Turn on dark theme" ;;
        timeout) echo "Set the screen timeout to 5 minutes" ;;
        version) echo "What version of Android is this phone on?" ;;
        contact) echo "Delete the contact Riya Test" ;;
        dnd) echo "Turn on Do Not Disturb" ;;
    esac
}
risky() { [ "$1" = contact ] && echo delete; }

contacts() { dsh 20 content query --uri content://com.android.contacts/contacts --projection display_name 2> /dev/null | tr -d '\r'; }
# Local contacts only (no account), removed for good (caller_is_syncadapter), so a later run starts clean.
drop_test_contacts() {
    dsh 20 content delete --uri "content://com.android.contacts/raw_contacts?caller_is_syncadapter=true" \
        --where "display_name IN ('Riya Test','Arjun Keep')" > /dev/null 2>&1
}
add_contact() {
    dsh 20 content insert --uri content://com.android.contacts/raw_contacts --bind account_type:n: --bind account_name:n: > /dev/null 2>&1
    _id=$(dsh 20 content query --uri content://com.android.contacts/raw_contacts --projection _id --sort "_id DESC" 2> /dev/null \
        | tr -d '\r' | sed -n '1s/.*_id=\([0-9]*\).*/\1/p')
    [ -n "$_id" ] || return 1
    RAW_IDS="$RAW_IDS $_id"
    dsh 20 content insert --uri content://com.android.contacts/data --bind "raw_contact_id:i:$_id" \
        --bind mimetype:s:vnd.android.cursor.item/name --bind "data1:s:$1" > /dev/null 2>&1
}

before() {
    case "$1" in
        dark) dsh 10 cmd uimode night no > /dev/null 2>&1; dsh 10 cmd uimode night | grep -q "Night mode: no" ;;
        timeout) dsh 10 settings put system screen_off_timeout 30000 > /dev/null 2>&1
                 [ "$(dsh 10 settings get system screen_off_timeout | tr -d '\r')" = 30000 ] ;;
        version) [ -n "$REL" ] ;;
        contact)
            [ -n "$CONTACTS_PKG" ] || { note_task "no Contacts app on this image"; return 1; }
            drop_test_contacts
            add_contact "Riya Test" && add_contact "Arjun Keep" || { note_task "content insert refused"; return 1; }
            c=$(contacts)
            printf '%s' "$c" | grep -q "display_name=Riya Test" && printf '%s' "$c" | grep -q "display_name=Arjun Keep" \
                || { note_task "the two contacts are not there after the insert"; return 1; } ;;
        dnd) dsh 10 cmd notification set_dnd off > /dev/null 2>&1; [ "$(dsh 10 settings get global zen_mode | tr -d '\r')" = 0 ] ;;
    esac
}

# Exit 0 when the phone's state is right. CHECK_SAW says what was read.
CHECK_SAW=
check() {
    case "$1" in
        dark) CHECK_SAW=$(dsh 10 cmd uimode night | tr -d '\r'); [ "$CHECK_SAW" = "Night mode: yes" ] ;;
        timeout) CHECK_SAW="screen_off_timeout=$(dsh 10 settings get system screen_off_timeout | tr -d '\r')"; [ "$CHECK_SAW" = screen_off_timeout=300000 ] ;;
        version) CHECK_SAW="Android $REL in Mode's summary?"; printf '%s' "$SAID" | grep -qwF "$REL" ;;
        contact)
            c=$(contacts)
            riya=$(printf '%s' "$c" | grep -c "display_name=Riya Test")
            arjun=$(printf '%s' "$c" | grep -c "display_name=Arjun Keep")
            CHECK_SAW="Riya Test: $riya, Arjun Keep: $arjun, questions answered yes: $YES"
            [ "$riya" -eq 0 ] && [ "$arjun" -ge 1 ] && [ "$YES" -ge 1 ] ;;
        dnd) CHECK_SAW="zen_mode=$(dsh 10 settings get global zen_mode | tr -d '\r')"; [ "$CHECK_SAW" != zen_mode=0 ] && [ "$CHECK_SAW" != zen_mode= ] ;;
    esac
}

after() {
    case "$1" in
        dark) dsh 10 cmd uimode night no > /dev/null 2>&1 ;;
        timeout) [ -n "$TIMEOUT0" ] && dsh 10 settings put system screen_off_timeout "$TIMEOUT0" > /dev/null 2>&1 ;;
        contact) drop_test_contacts ;;
        dnd) dsh 10 cmd notification set_dnd off > /dev/null 2>&1 ;;
    esac
}

NOTES=
note_task() { NOTES="${NOTES:+$NOTES; }$*"; log "  note $*"; }

# A model error ends the task (R1): the last two `answer` events are on the same step and both have an
# error (Mode retries every failed call once). Prints the second error's text.
model_error() {
    jq -rs '[.[] | select(.event == "answer")] | .[-2:] as $a
        | if ($a | length) == 2 and $a[0].error != null and $a[1].error != null and $a[0].step == $a[1].step
          then $a[1].error else empty end' "$1" 2> /dev/null
}

runs_list() { runas 10 ls files/logs/runs 2> /dev/null | tr -d '\r' | sort; }

# The question's own words, from the overlay's Question(…) (the task's words are in it too, so the risky
# word is looked for in the question only).
question_label() { printf '%s' "$1" | sed -n 's/.*, question=\(.*\), options=.*/\1/p'; }

restart_mode() {
    dsh 15 am force-stop "$PKG" > /dev/null 2>&1
    dsh 30 monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 > /dev/null 2>&1
    sleep 3
    MODE_PID=$(pid)
    dsh 10 input keyevent KEYCODE_HOME > /dev/null 2>&1
    settle restart
    r2 || note_task "phone control did not come back after the restart"
    # The sign-in is kept in Mode's store; redo it only if it went.
    if [ "$(runas 10 cat shared_prefs/mode.xml 2> /dev/null | sed -n 's/.*name="model_provider">\([^<]*\)<.*/\1/p')" != "$( [ "$CONNECTION" = claude ] && echo claude_oauth || echo openrouter)" ]; then
        note_task "the sign-in was lost after the restart; signing in again"
        r3 || note_task "the sign-in could not be redone"
    fi
}

TASK=
SAID=
YES=0
run_task() {
    TASK=$1
    NOTES=
    SAID=
    YES=0
    t0_task=$(now)
    w=$(words "$TASK")
    log "T-$TASK \"$w\""
    # Start clean.
    probe overlaystate --ez close true
    dsh 10 am force-stop com.android.settings > /dev/null 2>&1
    [ "$TASK" = contact ] && [ -n "$CONTACTS_PKG" ] && dsh 10 am force-stop "$CONTACTS_PKG" > /dev/null 2>&1
    probe home
    dsh 60 am wait-for-broadcast-idle > /dev/null 2>&1
    result=
    outcome=-
    steps=-
    model=-
    if ! before "$TASK"; then
        result=SETUP
        note_task "the state before the task could not be set"
    fi
    run=
    end=
    if [ -z "$result" ]; then
        runs_list > "$OUT/.runs0"
        probe overlay --es task "$w"
        case "$PROBE_LINE" in *summoned=true*) ;; *) result="FAIL"; note_task "the overlay did not start the task: $PROBE_LINE" ;; esac
    fi
    if [ -z "$result" ]; then
        # The new run folder, within 30 s.
        ts=$(now)
        while [ -z "$run" ] && [ $(( $(now) - ts )) -lt 30 ]; do
            run=$(runs_list | comm -13 "$OUT/.runs0" - | tail -1)
            [ -n "$run" ] || sleep 2
        done
        [ -n "$run" ] || { result=FAIL; note_task "no run started within 30 s"; }
    fi
    if [ -z "$result" ]; then
        log "  run $run"
        idle=0
        answers=0
        while :; do
            sleep 2
            runas 10 cat "files/logs/runs/$run/run.json" > "$OUT/.run.json" 2> /dev/null
            runas 20 cat "files/logs/runs/$run/steps.jsonl" > "$OUT/.steps.jsonl" 2> /dev/null
            outcome=$(jq -r '.outcome // "running"' "$OUT/.run.json" 2> /dev/null)
            [ "$outcome" != running ] && [ -n "$outcome" ] && { end=run.json; break; }
            err=$(model_error "$OUT/.steps.jsonl")
            [ -n "$err" ] && { end="model error"; break; }
            [ $(( $(now) - t0_task )) -ge "$TASK_SECS" ] && { end=deadline; break; }
            # N2: Mode's own app on screen.
            probe current
            if [ "$(unquote "$(probe_result)")" = "$PKG" ]; then
                OPENED_MODE="$OPENED_MODE $TASK"
                note_task "Mode's own app came to the front"
                end="opened Mode"; break
            fi
            probe overlaystate
            state=$(probe_result)
            case "$state" in
                Working\(*) idle=0 ;;
                Question\(*)
                    idle=0
                    label=$(question_label "$state")
                    want=no
                    word=$(risky "$TASK")
                    [ -n "$word" ] && printf '%s' "$label" | grep -qi "$word" && want=yes
                    if [ "$answers" -ge 3 ]; then note_task "a 4th question: not answered"; end="too many questions"; break; fi
                    probe answer --es text "$want"
                    answers=$((answers + 1))
                    echo "$TASK: \"$(cell "$label" 160)\": $want ($PROBE_LINE)" >> "$OUT/answers.txt"
                    case "$PROBE_LINE" in
                        "ok "*) [ "$want" = yes ] && YES=$((YES + 1))
                                [ "$want" = no ] && { UNEXPECTED=1; note_task "an unexpected question, answered no"; } ;;
                        *"not a yes/no question"*) note_task "Mode asked something only a person can answer"; end=asked; break ;;
                        *) note_task "answer failed: $PROBE_LINE" ;;
                    esac ;;
                *) idle=$((idle + 1)); [ "$idle" -ge 2 ] && { end="overlay closed"; break; } ;;
            esac
        done
        outcome=$(jq -r '.outcome // "running"' "$OUT/.run.json" 2> /dev/null)
        steps=$(jq -r '.steps // empty' "$OUT/.run.json" 2> /dev/null)
        [ -n "$steps" ] || steps=$(jq -s '[.[] | select(.event == "answer") | .step] | max // 0' "$OUT/.steps.jsonl" 2> /dev/null)
        model=$(jq -r '.config.model // .model // empty' "$OUT/.run.json" 2> /dev/null)
        [ -n "$model" ] || model=$(jq -rs '[.[] | select(.event == "answer") | .model] | last // "-"' "$OUT/.steps.jsonl" 2> /dev/null)
        SAID=$(jq -r '.summary // empty' "$OUT/.run.json" 2> /dev/null)
        err=$(model_error "$OUT/.steps.jsonl")
        log "  ended: $end; outcome $outcome, $steps steps"
        # Judge: the cause first. A model call that failed is never a Mode FAIL.
        if [ -n "$err" ]; then
            result=$(classify "$err")
            note_task "model error: $err"
        elif [ "$end" = "opened Mode" ] || [ "$end" = asked ] || [ "$end" = "too many questions" ] || [ "${UNEXPECTED:-0}" = 1 ]; then
            result=FAIL
        elif check "$TASK" && [ "$outcome" = done ]; then
            result=PASS
        elif [ "$end" = deadline ] || [ "${steps:-0}" -ge "$MAX_STEPS" ] 2> /dev/null; then
            result="FAIL (limit)"
        else
            result=FAIL
        fi
        [ -n "$CHECK_SAW" ] && note_task "read: $CHECK_SAW"
        rm -f "$OUT/.run.json" "$OUT/.steps.jsonl" "$OUT/.runs0"
        # The run folder, extracted as it comes off, so no archive stays in out/.
        mkdir -p "$OUT/runs/$TASK"
        to 120 $ADB exec-out run-as "$PKG" tar c -C files/logs/runs "$run" 2> /dev/null | tar x -C "$OUT/runs/$TASK" 2> /dev/null \
            || note_task "the run folder did not come off"
        # C4: anything but run.json's own end leaves Mode maybe still running the task.
        [ "$end" = run.json ] || restart_mode
    fi
    UNEXPECTED=0
    CHECK_SAW=
    to 30 $ADB exec-out screencap -p > "$OUT/T-$TASK.png" 2> /dev/null || rm -f "$OUT/T-$TASK.png"
    # The guard: a wrong tap that cut the network would fail every task after this one.
    if [ "$(dsh 10 settings get global airplane_mode_on | tr -d '\r')" != 0 ]; then
        dsh 10 cmd connectivity airplane-mode disable > /dev/null 2>&1
        note_task "airplane mode was on after this task; turned off"
        [ "$result" = PASS ] && result=FAIL
    fi
    if [ "$WIFI0" -gt 0 ] && ! dsh 10 cmd wifi status 2> /dev/null | grep -q "Wifi is enabled"; then
        dsh 10 svc wifi enable > /dev/null 2>&1
        note_task "Wi-Fi was off after this task; turned on"
        [ "$result" = PASS ] && result=FAIL
    fi
    if runas 10 cat files/logs/events.log 2> /dev/null | grep -q "full access turned on from a question"; then
        INVALID="${INVALID:+$INVALID; }full access was turned on from a question during $TASK"
        FAILED=1
    fi
    after "$TASK"
    [ "$result" = PASS ] || FAILED=1
    secs=$(( $(now) - t0_task ))
    log "  $result in $secs s${NOTES:+ ($NOTES)}"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$TASK" "$w" "$result" "$outcome" "$steps" "$secs" "$(cell "$model" 40)" \
        "$(cell "${SAID:-${NOTES:--}}" 200)" >> "$OUT/results.tsv"
    TASK=
}

end_checks() {
    now_pid=$(pid)
    [ -n "$MODE_PID" ] && [ "$now_pid" = "$MODE_PID" ] && log "E ok: same process ($now_pid)" || { log "E FAIL the process was ${MODE_PID:-none}, now ${now_pid:-none}"; FAILED=1; }
    if dsh 20 logcat -d -b crash 2> /dev/null | grep -q "$PKG"; then log "E FAIL the crash buffer has $PKG"; FAILED=1; else log "E ok: no crash"; fi
    if dsh 30 logcat -d 2> /dev/null | grep -q "ANR in $PKG"; then log "E FAIL ANR in $PKG"; FAILED=1; else log "E ok: no ANR"; fi
    probe status
    case "$PROBE_LINE" in ok*Engine=Passed*) log "E ok: phone control still on" ;; *) log "E FAIL phone control: $PROBE_LINE"; FAILED=1 ;; esac
}

# ---- The run ------------------------------------------------------------------------------------------

SDK=$(prop ro.build.version.sdk)
REL=$(prop ro.build.version.release)
IMAGE=$(prop ro.build.fingerprint)
TIMEOUT0=$(dsh 10 settings get system screen_off_timeout 2> /dev/null | tr -d '\r')
# The Wi-Fi guard only puts back what was on at the start.
WIFI0=$(dsh 10 cmd wifi status 2> /dev/null | grep -c "Wifi is enabled")
trap collect EXIT
trap interrupted INT TERM
# The script's own deadline, inside the job's 60 minutes, so it normally ends itself and the trap runs.
# Detached from stdout: a leftover sleep holding the step's output open would keep the job waiting.
( sleep 3000; kill -TERM $$ 2> /dev/null ) > /dev/null 2>&1 &
WATCHDOG=$!
log "device API $SDK (Android $REL); connection $CONNECTION; full access $FULL; tasks: $TASK_LIST"
dsh 10 logcat -G 16M > /dev/null 2>&1 || log "logcat -G not accepted"
settle boot
rm -f "$OUT/.rec-stop"
record > /dev/null 2>&1 &
REC_PID=$!
for p in com.google.android.contacts com.android.contacts; do
    dsh 15 pm list packages "$p" 2> /dev/null | tr -d '\r' | grep -qx "package:$p" && { CONTACTS_PKG=$p; break; }
done
log "Contacts app: ${CONTACTS_PKG:-none}"

r1 || { FAILED=1; exit 1; }
settle install
if [ "$SKIP_R2" -eq 1 ]; then log "R2 skipped (--skip R2: every task should FAIL with summoned=false)"
else r2 || { FAILED=1; exit 1; }; fi
r3 || { FAILED=1; exit 1; }
for t in $TASK_LIST; do run_task "$t"; done
end_checks
exit 0  # the EXIT trap collects the evidence, scrubs it and sets the exit status
