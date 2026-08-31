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
isolated server.

`tj` calls plain `tmux`, so the suite shadows `tmux` on `PATH` with
`tests/fakebin/tmux`, which pins every call to a throwaway `-L` socket and
refuses any socket not named `tjtest-*`. `tests/fakebin/ssh` redirects to a
second throwaway server, so remote paths are exercised with no network.

**`TMUX_TMPDIR` is not isolation.** With a server already running, a client set
to a different `TMUX_TMPDIR` still resolves to the default socket — a
`kill-server` after such a "check" destroys the user's real sessions. `-L` on
every invocation is the only isolation this repo trusts.

Run the suite with `tests/run.sh`. To exercise `enter`/`ctrl-n`/`ctrl-x` end to
end you need a real client attached (`switch-client` and `detach-client` fail
with none), so background one with
`nohup script -qc "tmux -L <sock> attach -t demo" /dev/null &`.

## Architecture

**The script re-invokes itself.** `fzf` cannot call shell functions, so `--list`
(used by the `ctrl-x` reload) and `--preview` are dispatched back into the same file
via `$self`, resolved at the top with a `readlink -f` fallback for BSD.

**The list line is a contract, not just formatting.** `list_sessions` prints
`<mark> <name> <age> <windows> <path>`, and `list_remote` prints
`<mark> <host> <name> <age> <windows> <path>` — the host column exists only when
hosts are configured. The session name therefore sits in field 2 or field 3, and
that index is computed once into `NAMEF` at startup; nothing may hard-code `{2}`
or `$2`. The status mark in field 1 must never be an empty string — if it were,
awk's whitespace splitting would shift every field by one and the wrong session
would be switched to or killed. fzf strips ANSI codes both when expanding `{n}`
and when printing the selected line, so colours anywhere in the row are safe —
but those field numbers count fields in the *stripped* row. The raw row splits
differently: `%6s` right-pads the age, so its colour escape stands alone as a
field. Anything parsing `tj --list` directly (the test suite does) must strip
ANSI first; `tests/run.sh` has a `plain()` helper for exactly that.

**Ordering** comes from tmux itself: `session_last_attached`, falling back to
`session_created` for sessions never attached, sorted descending. Nothing is cached.

**Inside vs outside tmux** is the one behavioural fork: `enter_session` uses
`switch-client` when `$TMUX` is set and `attach-session` otherwise, which is what lets
the same command work from a popup and from a bare terminal.

**Remote hosts are opt-in and the local path never pays for them.** With no
`~/.config/tj/hosts` and no `TJ_HOSTS`, `HOSTS` is empty, `list_remote` returns
immediately and no `ssh` runs. Remote rows are appended after local ones rather
than merged into one MRU ordering, so a slow or dead host cannot delay the
picker.

**Entering a remote session replaces the client.** `enter_remote` uses
`tmux detach-client -E` to hand the terminal to the remote tmux, chaining a
return to the session it left, so exactly one tmux is ever attached. Nesting was
rejected: it forces a doubled prefix on every remote keystroke. The remote
command is built as ONE `qq`-quoted string, like `ssh_q`'s, because ssh re-joins
its arguments with plain spaces — bare words would split a session name
containing a space and execute one containing `;`.

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
