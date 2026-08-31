# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`tj` is a tmux session picker: it lists sessions ordered by when you last attached,
filters them through `fzf`, and previews each session's live pane. The whole tool is
one bash script (`tj`, ~155 lines). `tj.tmux` is a separate 23-line entry point that
only exists so the repo can be installed as a TPM (tmux plugin manager) plugin — it
reads `@tj-key` / `@tj-width` / `@tj-height` and creates the key binding.

There is no build step, no test framework, and no dependencies beyond `tmux` and `fzf`.

## Commands

```sh
shellcheck --shell=bash tj tj.tmux   # the only automated check; CI runs exactly this
./tj --list                          # print the formatted session list (no UI)
./tj --preview <session>             # render what the preview pane would show
./tj --version
```

## Testing changes — never against the default tmux server

Whoever runs this has real work in their own tmux sessions, and `tj` creates and
kills sessions. Never exercise it against the default socket — always use an
isolated server:

```sh
tmux -L test -f /dev/null new-session -d -s demo -x 140 -y 32
tmux -L test send-keys -t demo './tj' Enter        # drive the picker
tmux -L test capture-pane -p -t demo               # read what it rendered
tmux -L test kill-server && rm -f "/tmp/tmux-$(id -u)/test"
```

`-f /dev/null` also stops the isolated server from loading the user's own tmux config.

To test `enter`/`ctrl-n`/`ctrl-x` end to end you need a real *client* attached to that
server (`switch-client` fails with none), so background one with
`nohup script -qc "tmux -L test attach -t demo" /dev/null &` and then assert with
`tmux -L test list-clients -F '#{client_tty} => #{client_session}'`.

## Architecture

**The script re-invokes itself.** `fzf` cannot call shell functions, so `--list`
(used by the `ctrl-x` reload) and `--preview` are dispatched back into the same file
via `$self`, resolved at the top with a `readlink -f` fallback for BSD.

**The list line is a contract, not just formatting.** `list_sessions` prints
`<mark> <name> <age> <windows> <path>`, and both the fzf preview (`{2}`) and the final
`awk '{print $2}'` read the session name from field 2. The status mark in field 1 must
therefore never be an empty string — if it were, awk's whitespace splitting would shift
every field by one and the wrong session would be switched to or killed. fzf strips
ANSI codes before expanding `{n}`, so the colours in the line are safe.

**Ordering** comes from tmux itself: `session_last_attached`, falling back to
`session_created` for sessions never attached, sorted descending. Nothing is cached.

**Inside vs outside tmux** is the one behavioural fork: `enter_session` uses
`switch-client` when `$TMUX` is set and `attach-session` otherwise, which is what lets
the same command work from a popup and from a bare terminal.

**Portability.** GNU and BSD/macOS disagree on `date -d @<ts>` vs `date -r <ts>` and on
`readlink -f`; both have explicit fallbacks (`fmt_date`, the `$self` block). Keep any
new coreutils usage inside that pattern — macOS is a primary target.

## Releasing

`VERSION` in `tj` and the git tag must match. After tagging, the Homebrew formula lives
in a **separate repo**, `aladagemre/homebrew-tap` (`Formula/tj.rb`) — bump its `url` and
`sha256` there. `packaging/PKGBUILD` carries its own `sha256sums` for the same tarball
and is not yet published to the AUR.

## The demo GIF

`assets/demo.gif` was recorded against a throwaway tmux server whose sessions were
created under `libfaketime` with a timestamp file, so the age column shows a realistic
spread (`now / 6m / 2h / 1d / 10 Aug`) instead of every session reading "now". Panes ran
with `HOME` pointed at a scratch directory containing a `.profile` that sets `PS1="$ "`,
which is what keeps the real username and hostname out of the recording. Any re-record
must reproduce both of those or it will leak the user's identity and real project names.
