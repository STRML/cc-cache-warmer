# Plan: cc-cache-warmer

Keep an idle Claude Code session's prompt cache warm for a few TTL cycles, then
compact it. Requires cmux: the plugin types into the session's own pane.

## Flow

```
Stop hook ──▶ kill old timer, spawn timer ──▶ wait 2 s for the transcript
              flush, read TTL, sleep(TTL - margin)
                                      │
UserPromptSubmit ──▶ ours? keep count : reset count, kill timer
                                      │
timer fires ──▶ guards pass? ──▶ pings < N ─▶ send warm prompt, pings++
                                 pings = N ─▶ send /compact, pings++
                                 pings > N ─▶ do nothing
SessionEnd ──▶ kill timer, drop state
```

Each warm prompt ends a turn, so its Stop hook re-arms the next cycle.

## Decisions

- TTL comes from the transcript: the last assistant entry with a nonzero
  `cache_creation` names `ephemeral_1h_input_tokens` or `ephemeral_5m_input_tokens`.
  No such entry means the backend is not reporting a cache. Skip.
- Delay = TTL - min(300, TTL/5). That fires at 55 min for 1h and 4 min for 5m.
- The plugin tells its own prompts from the user's by recording the exact text
  it sent in a `pending` file. UserPromptSubmit compares and consumes it.
- Context below `CC_CACHE_WARMER_MIN_TOKENS` (default 50000) is not worth
  warming. A cold rewrite of a small context is cheap.
- State lives in `${CLAUDE_PLUGIN_DATA}/<session_id>/`: `pid`, `armed_at`,
  `pings`, `pending`, plus a shared `warmer.log`.

## Failure matrix

| # | state or input | what the operation does | how it can fail | what the caller is told |
|---|---|---|---|---|
| 1 | Stop, cmux pane, 1h cache, big context | arms timer at 3300 s | spawn blocks the hook | log `armed delay=3300`; hook exits 0 fast |
| 2 | Stop, 5m cache | arms timer at 240 s | wrong TTL picked | log `armed delay=240` |
| 3 | Stop, no `CMUX_SURFACE_ID` | nothing | | log `skip: not in cmux` |
| 4 | Stop, no cache fields in transcript | nothing | | log `skip: no cache info` |
| 5 | Stop, context < min tokens | nothing | | log `skip: small context` |
| 6 | Stop twice (re-arm) | kills first timer, arms second | two timers both fire | exactly one send |
| 7 | timer fires, idle, empty input box, pings 0..N-1 | sends warm prompt, pings++ | cmux send fails | log `warm n/N` or `error: send failed` |
| 8 | timer fires, pings = N | sends `/compact`, pings++ | | log `compact` |
| 9 | Stop after compact (pings > N) | nothing | loop re-arms forever | log `skip: done` |
| 10 | UserPromptSubmit, user text | resets pings, kills timer | stale timer fires on active session | no send |
| 11 | UserPromptSubmit, text equals `pending` | keeps pings, clears `pending` | counter reset by own ping, warms forever | pings survive |
| 12 | timer fires, a `user` or `assistant` record written after arm | nothing | fires mid-turn | log `skip: session active` |
| 13 | timer fires, draft in input box | nothing | clobbers draft | log `skip: draft in input` |
| 14 | timer fires, `read-screen` fails | nothing | types blind | log `skip: cannot read screen` |
| 15 | SessionEnd | kills timer, removes state dir | orphan timer types into a dead pane | no send |
| 16 | hook stdin is not JSON / missing fields | nothing | hook error shown to user | exits 0, log `error: bad input` |
| 17 | Stop fires before the turn's usage line reaches the transcript (seen live) | timer waits 2 s, then reads TTL | reads the previous turn, or nothing | arms normally |
| 18 | UserPromptSubmit on the first prompt, transcript file not created yet (seen live) | resets count | rejected as bad input | no error |
| 19 | Claude Code appends an `away_summary` recap (about 3 min after the turn) or metadata records while idle (seen live) | fires normally | every timer skips as `session active`, so nothing ever warms | log `warm n/N` |
