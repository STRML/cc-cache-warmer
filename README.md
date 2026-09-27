# cc-cache-warmer

A Claude Code plugin that keeps an idle session's prompt cache warm for a few
cache lifetimes, then runs `/compact` on it.

When you leave a session idle past its cache TTL (1 hour on a Claude
subscription, 5 minutes on an API key), your next message rewrites the whole
context into the cache. On a long session that rewrite is the most expensive
turn you send. This plugin sends a short keep-alive prompt just before the
cache expires, so the next turn reads the cache instead of rewriting it. After
a few pings it compacts the session and stops, so a session you never come
back to leaves a small summary to rewrite instead of the full context.

> **Requires [cmux](https://github.com/manaflow-ai/cmux).** A hook can't submit
> a prompt to Claude Code, so the plugin types into the session's own cmux pane.
> tmux, iTerm2, and other terminals aren't supported yet. PRs welcome.

## How it works

```
you stop typing
      │
Stop hook ──▶ timer: wait 2 s, read the cache TTL from the transcript
      │
      ▼  sleep TTL - 5 min (55 min for 1h, 4 min for 5m)
guards: session idle? input box empty? screen readable?
      │
      ├─ pings < N ─▶ type the keep-alive prompt ─▶ reply ends a turn ─▶ Stop again
      ├─ pings = N ─▶ type /compact
      └─ pings > N ─▶ nothing, until you send a message
```

Any message you type cancels the pending timer and resets the count. The
plugin compares each prompt with the text it last sent, so its own pings
don't reset the count.

Measured on a 70k-token session: the keep-alive turn read 70,471 tokens from
the cache, wrote 133, and produced 4 output tokens.

## Install

```sh
claude plugin marketplace add STRML/cc-cache-warmer
claude plugin install cc-cache-warmer@cc-cache-warmer
```

Run Claude Code inside a cmux pane. Outside cmux, the plugin logs a skip and
does nothing.

## Settings

Set these as environment variables before you start `claude`.

| Variable | Default | Meaning |
|---|---|---|
| `CC_CACHE_WARMER_PINGS` | `3` | Keep-alive pings before `/compact`. |
| `CC_CACHE_WARMER_MIN_TOKENS` | `50000` | Smaller contexts aren't worth warming. |
| `CC_CACHE_WARMER_DELAY` | TTL - 5 min | Seconds to wait before each ping. For testing. |

## When it does nothing

Each skip is logged to `warmer.log` in the plugin's data directory
(`~/.claude/plugins/data/<plugin-id>/`).

| Log line | Cause |
|---|---|
| `skip: not in cmux` | `CMUX_SURFACE_ID` is unset. |
| `skip: no cache info` | The transcript has no cache write. Non-Anthropic backends often report none. |
| `skip: small context` | The context is below `CC_CACHE_WARMER_MIN_TOKENS`. |
| `skip: session active` | The transcript changed after the timer armed. |
| `skip: draft in input` | You left text in the input box. The plugin won't type over it. |
| `skip: cannot read screen` | `cmux read-screen` failed, or no input box is visible (for example, a permission prompt is open). |
| `skip: done` | The session is compacted. The next message you send restarts the cycle. |

## Tests

```sh
./tests/e2e.sh
```

Each scenario matches one row of the failure matrix in
[docs/PLAN.md](docs/PLAN.md). A fake `cmux` on `PATH` records every call. The
results land in `tests/out/results.txt`.

## License

MIT
