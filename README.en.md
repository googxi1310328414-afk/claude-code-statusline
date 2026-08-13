# claude-code-statusline

An information-dense, colorized status line for Claude Code (Windows / Git Bash): a three-line themed grid for the main session plus a fully custom subagent panel row. Segments with missing data disappear cleanly; empty lines vanish; key metrics change color with state.

> 中文原版（权威）见 [README.md](README.md)。This English page is a condensed translation.

![preview](assets/preview.svg)

```
08:17:08               | Fable 5·max·think | ~\claude-code-statusline  | main*
ctx ████░ 71% 294k/1M  | ▂▃▂▄ 2.9k/m       | cache 99%
$74.94 $79.8/h         | +2005/-585        | 5h 32%→09:10 7d 12%→08-15 | » session-name
```

- **Line 1 — identity & location**: seconds clock · model + effort heat + thinking marker · abbreviated directory · `⎇ worktree` · repo (OSC 8 hyperlink) · branch + dirty `*` · `⚑N` stash count (bright red at ≥5, hidden at zero) · PR (hyperlink + review state)
- **Line 2 — context engine**: `ctx` battery (occupancy = input + latest output tokens, `k`/`M` units) · token sparkline + burn rate (from a cross-refresh history file) · cache hit rate
- **Line 3 — spend & quota**: cost + `$X.X/h` rate · lines changed · 5h/7d rate-limit windows with reset times · `»` session name

The subagent panel row (via `subagentStatusLine`) renders every agent as an aligned table row:

```
▸ 0.2.79 收尾与发布(local_agent) ● | 295k tok | █▄▁ 14.9k/m | Σ78% | 19m44s@08:11:18 | description…
```

with bright-magenta identity (vs. the main line's bright cyan), minority-model marker, status glyphs (● ○ ✓ ✗), cumulative token spend (deliberately **not** a fake "context battery" — `tokenCount` is cumulative), sparkline + rate, Σ fleet-share, seconds-precision elapsed time, and a width-budgeted description. Columns align using true display-width measurement (CJK = 2 cells).

## Install

Requirements: Claude Code (≥ 2.1.205 for some subagent fields), Git Bash (bash ≥ 4, UTF-8), `jq`, `git` (≥ 2.35 for the stash segment).

1. Copy both `.sh` files into `~/.claude/`.
2. Merge the two keys from `settings-snippet.json` into `~/.claude/settings.json`.
3. Done — the status line re-renders on the next refresh.

**Recommended**: feed [`AI-GUIDE.md`](AI-GUIDE.md) (Chinese; the complete build spec with data contracts, thresholds, robustness rules and a verification checklist) to Claude Code and let it rebuild and adapt everything for your machine.

## Testing

```bash
bash test.sh          # render all fixtures (see real colors in your terminal)
bash test.sh --codes  # show ANSI escapes as \e[..m for inspection
```

## Notable engineering notes

- Auto-refresh = event-driven repaints (~300 ms debounce) + a `refreshInterval` timer (defaults here: main 10s / subagent panel 3s) that re-runs the whole script with fresh stdin JSON even when idle. A new trigger CANCELS the in-flight render, so the interval must comfortably exceed worst-case render time (0.4–1.3 s measured) — undershooting it blanks the bar entirely. settings.json changes hot-reload by CONTENT (touching mtime does nothing), which is also the no-restart recovery path if the render loop ever wedges.
- Windows `jq` emits CRLF: every line-wise read must pass through `tr -d '\r'` (MSYS bash strips trailing CRs in `$(...)` substitutions, `mapfile` does not).
- Scripts export `LC_ALL=C.UTF-8` — column alignment depends on character-based (not byte-based) string measurement, plus a `disp_width()` that counts East-Asian wide characters as 2 terminal cells.
- Workflow/ultracode fleets do **not** flow through `subagentStatusLine` (measured empirically); they render in the dedicated `/workflows` UI, which has no customization hook.

MIT licensed.
