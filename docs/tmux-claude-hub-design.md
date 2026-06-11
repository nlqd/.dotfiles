# tmux-hub: a live aggregated session for running agents

Date: 2026-06-10
Status: design, approved direction, not yet implemented

## Goal

One tmux session, `claude-hub`, that is a live view into every window (across all
other sessions) currently running an agent CLI: Claude Code and friends
(`claude`, `dclaude`, `sdai`, `aider`, configurable). You flip between all running
agents in one place with normal window navigation, and the set maintains itself as
agents start and stop, whether an agent is launched the moment a window is created
or minutes later, and whether it owns the window or is just one pane in it.

The hub windows are the real windows, linked in via `link-window`, not copies. That
gives a persistent, interactive, bidirectional view. The cost of that choice and the
guards that make it livable are the bulk of this document.

### Non-goals

- Not a read-only dashboard. Input is live (see Guards for the peek convention).
- Not a status/token monitor. Per-agent state (working / waiting / done) is Recon's
  niche and is out of scope here.
- Single hub in v1. Mapping different predicates to different hubs is a noted future
  extension, not built now.
- Linux only. Detection reads `/proc`.

## Why this shape

An agent can appear in an existing window long after the window was created, so tmux
window-lifecycle hooks alone cannot catch it (tmux has no "process launched in a
pane" event). The two robust ways to know an agent is running are to ask the agent to
announce itself, or to inspect processes. We inspect processes, because the user runs
agents both natively and sandboxed (`dclaude`), and a sandboxed agent cannot reach the
host tmux server to announce itself. Host-side detection covers both.

`#{pane_current_command}` is insufficient: Claude Code is a Node app, so it reports
`node`, not `claude`. Detection walks the process tree from `#{pane_pid}` and matches
`/proc/PID/cmdline`, which sees `node /…/claude.js` and the `dclaude` wrapper alike.

## Architecture: a stateless reconciler

The whole system is one idempotent operation, `tmux-hub reconcile`, invoked by several
triggers. It computes the desired hub membership from scratch, diffs against what is
currently linked, and applies the difference. No persisted state, so nothing drifts;
running it twice is a no-op; a missed trigger self-heals on the next one.

### `tmux-hub reconcile`

1. Acquire a non-blocking `flock`. If another reconcile holds it, exit 0. Concurrent
   triggers (a `precmd` in every shell, plus tmux hooks) would otherwise race on shared
   tmux state; the in-flight run already converges to the same result.
2. Ensure the hub exists (see Hub lifecycle).
3. Build the desired set. `tmux list-panes -a -F` over every pane, skipping the hub
   session. For each pane, walk the process subtree from `#{pane_pid}` (children via the
   `PPid` field of `/proc/<pid>/status`, command via `/proc/<pid>/cmdline`) and test each
   descendant against the predicates. A pane matches if any descendant matches. Record,
   per matching `window_id`: its home session name and a label (basename of the matching
   pane's `pane_current_path`, plus git branch if the path is a repo).
4. Read the current set: `tmux list-windows -t claude-hub -F '#{window_index} #{window_id}'`,
   excluding the landing window (the one with `@hub_landing` set).
5. Link `desired − current`: for each window, pick the lowest free index at or above
   `base-index`, then `link-window -s <window_id> -t claude-hub:<index> -d`. Set the
   window options `@hub_home` and `@hub_label`.
6. Unlink `current − desired`: for each, resolve its hub index and plain
   `unlink-window -t claude-hub:<index>`. Never `-k`.
7. Refresh `@hub_home` and `@hub_label` on all still-desired windows (cwd or branch may
   have changed).
8. Always exit 0. A vanished window or a `/proc` race during the scan is ignored.

Plain `unlink-window` (no `-k`) is safe by construction: the reconciler only ever manages
the hub's link and never removes a window's home-session link, so a hub window is
virtually always linked to two sessions and plain unlink simply drops the hub one. If a
window is somehow linked only to the hub (its home session was independently killed),
plain unlink refuses rather than destroying a live agent.

### `tmux-hub link-current`

Fast path used by the zsh `preexec` trigger for instant response, no `/proc` scan.
Resolves the calling pane's window from `$TMUX_PANE`, takes the same `flock`, and links
that window into the hub if absent, setting `@hub_home` and `@hub_label`. Correctness
does not depend on it; it is an optimization, and the authoritative `reconcile` (fired
from `precmd` and tmux hooks) is the backstop.

## Triggers (event-driven, no daemon)

zsh, inlined in `.zshrc.linux`:

```zsh
# tmux-hub: surface agent windows in the claude-hub session
if [[ -n $TMUX ]]; then
  autoload -Uz add-zsh-hook
  _tmux_hub_preexec() {
    # $1 is the command line about to run; glob mirrors the predicate list
    if [[ $1 == (#i)*(claude|dclaude|sdai|aider)* ]]; then
      tmux-hub link-current 2>/dev/null
      _tmux_hub_dirty=1
    fi
  }
  _tmux_hub_precmd() {
    if [[ -n $_tmux_hub_dirty ]]; then
      tmux-hub reconcile &>/dev/null &!
      unset _tmux_hub_dirty
    fi
  }
  add-zsh-hook preexec _tmux_hub_preexec
  add-zsh-hook precmd  _tmux_hub_precmd
fi
```

`preexec` links the window the instant a matching command launches. `precmd` runs the
authoritative reconcile once that command returns (catching exit), and only when a match
fired, so unrelated prompts cost nothing. The zsh glob duplicates the predicate list for
speed; it can drift from the config file without affecting correctness, since `reconcile`
uses the real predicates.

tmux, in `.config/tmux/tmux.conf`:

```tmux
set-hook -g after-new-window 'run-shell -b "tmux-hub reconcile"'
set-hook -g pane-exited      'run-shell -b "tmux-hub reconcile"'
set-hook -g window-unlinked  'run-shell -b "tmux-hub reconcile"'
```

`window-linked` is deliberately not hooked: the reconciler fires it itself, so hooking it
would loop. `window-unlinked` fires on our own unlinks too, but a converged reconcile
makes no further change and emits no further event, so it terminates. `pane-exited` has a
historical wrong-target bug, irrelevant here because reconcile ignores the hook's target
and rescans everything.

There is no separate bootstrap step. `prefix G` reconciles before switching, so the first
press builds the hub and picks up any agents already running.

## Hub lifecycle and presentation

A tmux session needs at least one window, so the hub keeps a permanent landing window
marked `@hub_landing 1` that is skipped by the reconcile diff. The landing window prints a
short banner of the hub keybindings, which also answers the discoverability problem (the
machinery is otherwise invisible).

On creation the reconciler sets, on the hub session only:

```tmux
set -t claude-hub @is_hub 1
set -t claude-hub window-status-format         '#I #{@hub_home}/#{@hub_label}#{?pane_in_mode, [peek],}'
set -t claude-hub window-status-current-format '#I #{@hub_home}/#{@hub_label}#{?pane_in_mode, [peek],}'
```

`renumber-windows` is left at its default (off), so an agent keeps its index for its whole
life and a dead agent leaves an honest gap instead of shifting its neighbors. `prefix
<number>` muscle memory holds. New agents link at the lowest free index.

Window names are never changed. The shared window object's name would otherwise leak into
every session and fight `automatic-rename`. Identity lives in two window options the hub
alone renders: `@hub_home` (origin session) and `@hub_label` (`cwd-basename@branch`). They
are set as window options so they travel with the window, but only the hub's status format
references them, so origin sessions are visually untouched.

## Guards and keybindings

All stock tmux, using the same `if-shell` idiom already in the user's `tmux.conf`. Added to
`.config/tmux/tmux.conf`:

```tmux
# enter/leave the hub (G is unbound today); toggles back to where you were
bind G if-shell -F '#{@is_hub}' \
  'switch-client -l' \
  'run "tmux-hub reconcile" ; switch-client -t claude-hub'

# inside the hub, &/x DETACH the link (agent keeps running); everywhere else, normal kill
bind & if-shell -F '#{@is_hub}' \
  'unlink-window ; display "removed from hub, agent still running in its home session"' \
  'confirm-before -p "kill-window #W? (y/n)" kill-window'
bind x if-shell -F '#{@is_hub}' \
  'unlink-window ; display "removed from hub, kill it from its home session"' \
  'confirm-before -p "kill-pane #P? (y/n)" kill-pane'

# inside the hub, jump to a window's real home session ('o' keeps its default elsewhere)
bind o if-shell -F '#{@is_hub}' \
  'run "tmux switch-client -t \"#{@hub_home}\""' \
  'select-pane -t :.+'
```

The single rule to internalize: in the hub, `&`/`x` remove from the view, they never kill.
The status line and the `display` message reinforce it, and plain `unlink-window` makes the
wrong outcome impossible anyway.

Peek before you type. The existing `prefix [` (copy-mode) is the read-only idiom: glance in
copy-mode, press `i` or `q` to go live. The `[peek]` flag in the status format shows when a
window is parked in copy-mode.

## Configuration

Predicates default to a built-in list (`claude`, `dclaude`, `sdai`, `aider`), matched as
extended regexes against full command lines. An optional `~/.config/tmux-hub/predicates`
overrides it, one regex per line, `#` comments ignored. Matching the wrapper names is what
makes sandboxed agents work: the host pane runs `dclaude`, which matches without ever
looking inside the container. The hub session name is the constant `claude-hub` in v1.

## Edge cases and accepted tradeoffs

- Multi-pane window: a window with an agent in one split pane is linked once, alongside its
  other panes. You land on whatever pane was active, possibly a shell, so the peek habit
  matters.
- Agent exits: the window stops matching and the next reconcile unlinks it from the hub. It
  stays alive in its home session.
- Orphaned window (home session killed while the agent runs): it survives only in the hub,
  and plain `unlink-window` refuses to drop the last link. To actually kill it, use
  `:kill-window` explicitly. Rare.
- Killing the hub session is low-stakes: agents survive via their home links, and the hub
  rebuilds on the next `prefix G`.
- Two coordinates for one window (`work:3` and `claude-hub:5`) and `#{session_name}`
  reporting the hub: the `@hub_home` label and `prefix o` are the answer to "where does this
  really live."
- Bidirectional input is real; copy-mode is the mitigation, not a hard lock.
- Label staleness: cwd or branch changes are picked up on the next reconcile, which a
  `cd`-then-command in that shell triggers. Brief staleness between reconciles is accepted.
- Concurrency is handled by the `flock`; the feedback loop is handled by not hooking
  `window-linked` and by skipping the landing window in the diff.

## Files

New:
- `.local/scripts/tmux-hub`: the reconciler with subcommands `reconcile`, `link-current`,
  and the help/banner used by the landing window.
- a test script (throwaway-socket integration test).

Edited:
- `.config/tmux/tmux.conf`: the three `set-hook` lines and the four `bind` lines.
- `.zshrc.linux`: the `preexec`/`precmd` block.

## Testing

Two pure pieces are unit tested in isolation: predicate matching against a given command
line, and the desired-vs-current set diff. Both take input as args or stdin so they need no
tmux.

The whole thing is integration tested on a throwaway socket, `tmux -L hubtest`, so it never
touches the real server. The test starts a server, creates sessions whose windows run a fake
`claude` script (a named sleeper), runs `tmux-hub reconcile` against that socket, and asserts
the hub links exactly the right window ids with the right `@hub_home`/`@hub_label`. It then
exits a fake agent, reconciles, and asserts the window is unlinked while its home window
survives. Finally it kills the server. Deterministic, no reliance on real timing.

## Future, explicitly deferred

- Mapping different predicates to different named hubs.
- A read-only glance dashboard (capture-pane previews, or just use Recon) for the one thing
  the live hub does not safely provide: passive at-a-glance watching.
- Per-agent status in the label, which would mean reading `~/.claude/sessions/{PID}.json`
  for Claude and is really a different tool.
