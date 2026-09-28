#!/usr/bin/env bash
# shellcheck disable=SC2317,SC2329 # helpers run indirectly through check "$@" (older shellcheck calls it SC2317)
# E2E tests for bin/cache-warmer. One scenario per failure-matrix row in docs/PLAN.md.
# A fake `cmux` on PATH records every call. Artifact: tests/out/results.txt.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
WARMER="$ROOT/bin/cache-warmer"
OUT="$ROOT/tests/out"
rm -rf "$OUT" && mkdir -p "$OUT"
RESULTS="$OUT/results.txt"
: >"$RESULTS"
FAILS=0
SLEEP=2 # CC_CACHE_WARMER_DELAY used by every armed timer
FLUSH=2 # the timer waits this long for the transcript before reading it

EMPTY_SCREEN='  ⎿  done

────────────────────────────────
❯
────────────────────────────────
  status line'
DRAFT_SCREEN='────────────────────────────────
❯ half a thought
────────────────────────────────
  status line'

# setup NAME: fresh data dir, fake cmux, empty screen, default env.
setup() {
  T="$OUT/$1"
  mkdir -p "$T/bin" "$T/data"
  export CLAUDE_PLUGIN_DATA="$T/data"
  export FAKE_LOG="$T/cmux.log" FAKE_SCREEN="$T/screen.txt"
  export CMUX_SURFACE_ID="SURF-1"
  export CC_CACHE_WARMER_DELAY=$SLEEP
  unset CC_CACHE_WARMER_PINGS CC_CACHE_WARMER_MIN_TOKENS FAKE_SCREEN_FAIL
  : >"$FAKE_LOG"
  printf '%s\n' "$EMPTY_SCREEN" >"$FAKE_SCREEN"
  cat >"$T/bin/cmux" <<'EOF'
#!/usr/bin/env bash
cmd=$1; shift
if [ "$cmd" = read-screen ]; then
  [ -n "${FAKE_SCREEN_FAIL:-}" ] && exit 1
  cat "$FAKE_SCREEN"; exit 0
fi
printf '%s %s\n' "$cmd" "$*" >>"$FAKE_LOG"
EOF
  chmod +x "$T/bin/cmux"
  export PATH="$T/bin:$BASE_PATH"
  TR="$T/transcript.jsonl"
}
BASE_PATH=$PATH

# transcript TTL TOKENS: one assistant entry with a cache write of that TTL.
transcript() {
  local h=0 m=0
  [ "$1" = 1h ] && h=500
  [ "$1" = 5m ] && m=500
  printf '{"type":"assistant","message":{"usage":{"input_tokens":10,"cache_read_input_tokens":%d,"cache_creation_input_tokens":500,"cache_creation":{"ephemeral_1h_input_tokens":%d,"ephemeral_5m_input_tokens":%d}}}}\n' \
    "$2" "$h" "$m" >"$TR"
}

hook() { # hook EVENT [PROMPT]
  jq -nc --arg t "$TR" --arg p "${2:-}" --arg e "$1" \
    '{session_id:"S1",transcript_path:$t,hook_event_name:$e,prompt:$p,cwd:"/"}' |
    "$WARMER" "$1"
}
log() { cat "$CLAUDE_PLUGIN_DATA/warmer.log" 2>/dev/null; }
sends() { grep -c '^send ' "$FAKE_LOG" || true; }
wait_arm() { sleep $((FLUSH + 1)); }
wait_fire() { sleep $((FLUSH + SLEEP + 2)); }

check() { # check ROW DESC CONDITION...
  local row=$1 desc=$2; shift 2
  if "$@"; then
    echo "PASS row $row: $desc" | tee -a "$RESULTS"
  else
    echo "FAIL row $row: $desc" | tee -a "$RESULTS"
    { echo "--- log"; log; echo "--- cmux"; cat "$FAKE_LOG"; } | sed 's/^/    /' | tee -a "$RESULTS"
    FAILS=$((FAILS + 1))
  fi
}
has_log() { log | grep -q -- "$1"; }
no_sends() { [ "$(sends)" -eq 0 ]; }

# Row 1: 1h cache arms at 3300 s, and the hook returns fast.
setup r1; transcript 1h 200000
start=$(date +%s); hook Stop; took=$(($(date +%s) - start))
wait_arm
check 1 "1h cache arms delay=3300, hook returns fast" \
  bash -c "grep -q 'armed ttl=3600 delay=3300' '$CLAUDE_PLUGIN_DATA/warmer.log' && [ $took -le 1 ]"
wait_fire

# Row 2: 5m cache arms at 240 s.
setup r2; transcript 5m 200000; hook Stop; wait_arm
check 2 "5m cache arms delay=240" has_log 'armed ttl=300 delay=240'
wait_fire

# Row 3: outside cmux, nothing arms.
setup r3; transcript 1h 200000; unset CMUX_SURFACE_ID; hook Stop
check 3 "no cmux surface skips" has_log 'skip: not in cmux'

# Row 4: transcript without cache fields.
setup r4; echo '{"type":"assistant","message":{"usage":{"input_tokens":90000}}}' >"$TR"; hook Stop; wait_arm
check 4 "no cache info skips" has_log 'skip: no cache info'

# Row 5: small context.
setup r5; transcript 1h 1000; hook Stop; wait_arm
check 5 "small context skips" has_log 'skip: small context'

# Row 6: re-arm replaces the first timer.
setup r6; transcript 1h 200000; hook Stop; sleep 1; hook Stop; wait_fire
check 6 "two Stops give exactly one send" bash -c "[ \$(grep -c '^send ' '$FAKE_LOG') -eq 1 ]"

# Row 7: idle fire sends a warm prompt and Enter.
setup r7; transcript 1h 200000; hook Stop; wait_fire
check 7 "fire sends warm prompt + enter" \
  bash -c "grep -q '^send --surface SURF-1 .*cache-warmer' '$FAKE_LOG' && grep -q '^send-key --surface SURF-1 enter' '$FAKE_LOG' && grep -q 'warm 1/3' '$CLAUDE_PLUGIN_DATA/warmer.log'"

# Rows 8, 9, 11: a full cycle. Our own prompts keep the count; ping N+1 compacts; then it stops.
setup r8; export CC_CACHE_WARMER_PINGS=2; transcript 1h 200000
hook Stop
for _ in 1 2 3; do
  wait_fire
  sent=$(cat "$CLAUDE_PLUGIN_DATA/S1/pending" 2>/dev/null) || sent=""
  [ -n "$sent" ] && hook UserPromptSubmit "$sent"
  transcript 1h 200000 # the ping's reply lands before its Stop
  hook Stop
done
wait_fire
check 11 "own prompts do not reset the count" has_log 'warm 2/2'
check 8 "ping N+1 sends /compact" bash -c "grep -q '^send --surface SURF-1 /compact' '$FAKE_LOG' && grep -q 'compact' '$CLAUDE_PLUGIN_DATA/warmer.log'"
check 9 "after compact, Stop does not re-arm" \
  bash -c "[ \$(grep -c '^send ' '$FAKE_LOG') -eq 3 ] && grep -q 'skip: done' '$CLAUDE_PLUGIN_DATA/warmer.log'"

# Row 10: a user prompt kills the timer and resets the count.
setup r10; transcript 1h 200000; hook Stop; hook UserPromptSubmit "real question"; wait_fire
check 10 "user prompt cancels the timer" no_sends

# Row 12: a conversation record lands after arm (a turn with no UserPromptSubmit).
setup r12; transcript 1h 200000; hook Stop; sleep $((FLUSH + 1))
printf '{"type":"assistant","timestamp":"%s","message":{"usage":{}}}\n' "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)" >>"$TR"; wait_fire
check 12 "activity after arm skips" bash -c "[ \$(grep -c '^send ' '$FAKE_LOG') -eq 0 ] && grep -q 'skip: session active' '$CLAUDE_PLUGIN_DATA/warmer.log'"

# Row 19: Claude Code's idle recap (away_summary) and metadata land after arm (seen live).
setup r19; transcript 1h 200000; hook Stop; sleep $((FLUSH + 1))
printf '{"type":"system","subtype":"away_summary","timestamp":"%s"}\n{"type":"ai-title","aiTitle":"x"}\n' "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)" >>"$TR"; wait_fire
check 19 "idle recap after arm still fires" has_log 'warm 1/3'

# Row 13: draft in the input box.
setup r13; transcript 1h 200000; printf '%s\n' "$DRAFT_SCREEN" >"$FAKE_SCREEN"; hook Stop; wait_fire
check 13 "draft in input skips" bash -c "[ \$(grep -c '^send ' '$FAKE_LOG') -eq 0 ] && grep -q 'skip: draft in input' '$CLAUDE_PLUGIN_DATA/warmer.log'"

# Row 14: read-screen fails.
setup r14; transcript 1h 200000; export FAKE_SCREEN_FAIL=1; hook Stop; wait_fire
check 14 "unreadable screen skips" bash -c "[ \$(grep -c '^send ' '$FAKE_LOG') -eq 0 ] && grep -q 'skip: cannot read screen' '$CLAUDE_PLUGIN_DATA/warmer.log'"

# Row 15: SessionEnd kills the timer and drops state.
setup r15; transcript 1h 200000; hook Stop; hook SessionEnd; wait_fire
check 15 "SessionEnd cancels and cleans" bash -c "[ \$(grep -c '^send ' '$FAKE_LOG') -eq 0 ] && [ ! -d '$CLAUDE_PLUGIN_DATA/S1' ]"

# Row 16: garbage stdin.
setup r16; echo 'not json' | "$WARMER" Stop; rc=$?
check 16 "bad input exits 0 and logs" bash -c "[ $rc -eq 0 ] && grep -q 'error: bad input' '$CLAUDE_PLUGIN_DATA/warmer.log'"

# Row 17: the usage line lands after the Stop hook starts (the flush race).
setup r17; transcript 1h 1000; hook Stop; transcript 1h 200000; wait_fire
check 17 "usage written after Stop still arms and fires" has_log 'warm 1/3'

# Row 18: first prompt, before the transcript file exists.
setup r18; hook UserPromptSubmit "first prompt"
check 18 "prompt with no transcript yet is accepted" bash -c "! grep -q error '$CLAUDE_PLUGIN_DATA/warmer.log' 2>/dev/null && [ \$(cat '$CLAUDE_PLUGIN_DATA/S1/pings') -eq 0 ]"

echo "$FAILS failed" | tee -a "$RESULTS"
exit $((FAILS > 0))
