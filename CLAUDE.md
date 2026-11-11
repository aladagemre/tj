# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`tj` is a tmux session picker: it lists tmux sessions — on this machine and, if you've
configured any, on remote hosts over `ssh` — ordered by when you last attached, filters
them through `fzf`, and previews each session's live pane. The whole tool is one bash
script (`tj`, 471 lines). `tj.tmux` is a separate 23-line entry point that only exists
so the repo can be installed as a TPM (tmux plugin manager) plugin — it reads
`@tj-key` / `@tj-width` / `@tj-height` and creates the key binding.

There is no build step, and no dependencies beyond `tmux` and `fzf` — plus `ssh`, but
only if you configure remote hosts. There is an 81-assertion test suite
(`tests/run.sh`); see Testing changes below.

## Commands

```sh
shellcheck --shell=bash tj tj.tmux     # style/lint check; CI runs this
tests/run.sh                           # the 81-assertion suite; CI runs this too
./tj --list                            # print the formatted session list (no UI)
./tj --preview <session>               # render the preview pane, local
./tj --preview <host> <name>           # ...for a session on a configured remote host
./tj --kill [<host>] <name>            # kill a session (used by ctrl-x); host optional, local by default
./tj --hosts                           # print the configured remote hosts, one per line
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

**CI runners supply `TERM=dumb` (or unset), and tmux refuses to attach a
client under it** (`open terminal failed: terminal does not support clear`) —
every assertion downstream of that attach then fails. `tests/run.sh` pins
`TERM=xterm-256color` for exactly this reason. `TERM=dumb tests/run.sh`
reproduces the CI-only failure locally if this ever regresses.

**The suite is Linux-only, even though `tj` is not.** It uses GNU spellings that
BSD/macOS does not share — `mktemp -d <template>` and `script -qc <cmd> <file>`
— and CI runs it on Linux. The portability rules in Architecture below govern
`tj` itself; do not read a green suite as evidence that a change works on macOS,
and do not be surprised when `tests/run.sh` will not start there.

## Architecture

**The script re-invokes itself.** `fzf` cannot call shell functions, so `--list`
(used by the `ctrl-x` reload) and `--preview` are dispatched back into the same file
via `$self`, resolved at the top with a `readlink -f` fallback for BSD.

**The list line is a contract, not just formatting.** `list_sessions` prints
`<mark> <name> <age> <windows> <path>`, and `list_remote` prints
`<mark> <host> <name> <age> <windows> <path>` — the host column exists only when
hosts are configured. The session name therefore sits in field 2 or field 3 and
the host, when there is one, in field 2; both indices are computed once into
`NAMEF`/`HOSTF` at startup, and the fzf `--preview` string, the `ctrl-x` binding
and the final `awk` all read them — nothing may hard-code `{2}` or `$2`.
The status mark in field 1 must never be an empty string — if it were,
awk's whitespace splitting would shift every field by one and the wrong session
would be switched to or killed. It is always exactly one mark: local rows use
`◆` (flagged, see Ordering), `●` (current), `○` (attached elsewhere) or `·`, in
that order of precedence, so a flagged current session shows `◆` alone, never
two marks. fzf strips ANSI codes both when expanding `{n}`
and when printing the selected line, so colours anywhere in the row are safe —
but those field numbers count fields in the *stripped* row. The raw row splits
differently: `%6s` left-pads the age, so its colour escape stands alone as a
field. Anything parsing `tj --list` directly (the test suite does) must strip
ANSI first; `tests/run.sh` has a `plain()` helper for exactly that.

**A row that cannot honour the contract is emitted inert, not dropped.** An
unreachable host, and a remote session whose name contains whitespace, both come
out with a `!` mark and `-` where the name goes; `render_preview`, `kill_target`
and the final selection all treat `-` as "not a session". `list_sessions` is
deliberately *not* given the same treatment: a local session with a space in its
name has always broken field 2, and hiding a user's own session is worse than
mis-targeting one they can see. For the same reason a config line with
whitespace left in it (`prod dev`) is a fatal error rather than being glued into
one host — a host string must never be able to widen the row.

**Every field of a remote row is untrusted input.** A remote row is whatever
that host's `tmux list-sessions` printed, so a host that is compromised,
spoofed, or simply running a `tmux` wrapper chooses those bytes — and they
arrive on every `--list`, which is every time the picker opens and every
`ctrl-x` reload. No field may reach an arithmetic or a shell context
unvalidated. Two sinks exist today:

- `ts` → **bash arithmetic** (`[[ $ts -eq 0 ]]` and `$(( now - ts ))` in
  `human_age`). Bash evaluates the *value* of a variable in an arithmetic
  context, and an array subscript inside that value is expanded in full — so a
  timestamp of `HOME[$(cmd)]` runs cmd locally. `set -u` is not a mitigation: it
  trips only on an *unset* variable name, and `HOME`/`PATH`/`PWD` all sail
  through. Guarded by a `^[0-9]+$` check that runs before any arithmetic — and
  then by `ts=$((10#$ts))`, because digits alone only make the value inert:
  bash reads a leading zero as octal, and `08` aborts the arithmetic entirely,
  leaving the age column empty and the row one field short.
- `name` → the **remote command string** in `render_preview`, `kill_target` and
  `enter_remote`. Guarded by `qq`, and additionally by the whitespace rule that
  makes such a row inert.

`wins`, `att` and `path` reach nothing but `printf %s` today, which is why they
carry no guard. Check any new column against this rule before adding it, and
add a `TJ_FAKE_SSH_OUTPUT` assertion for it — that env var makes the ssh double
print a canned row, which is the only way the suite can play a hostile host.

**Ordering** comes from tmux itself: `session_last_attached`, falling back to
`session_created` for sessions never attached, sorted descending. Nothing is cached.
One thing outranks recency: a session with at least one pane whose user option
`@tj-attention` is non-empty is "flagged" — marked `◆` and listed ahead of every
unflagged session, each group keeping MRU order. Any program can set it
(`tmux set -p -t "$TMUX_PANE" @tj-attention <reason>`; the README shows Claude
Code hooks that do). `list_sessions` reads it with ONE extra call,
`list-panes -a -F '#{session_name}|#{@tj-attention}'`, because the flag is per
pane and a list-sessions format would only see each session's active pane. The
order comes from decorate-sort-undecorate: a `1|`/`0|` prefix is the first key
of `sort -t'|' -rn -k1,1 -k2,2`. Keep the global `-rn`: with nothing flagged
every line gets the same `0|`, so the timestamp key and sort's last-resort
whole-line tie-break see exactly what the old `sort -rn -k1,1` saw, and the
output is byte-identical to the pre-flag list — the suite pins that with an MRU
oracle. The flag is **local only**: a remote row's flag would be one more field
the remote host chooses (see the untrusted-input rule above), so remote rows
never read it, and a test asserts a flagged remote pane leaves its row alone.

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
containing a space and execute one containing `;`. `local` as the host, and
either half of `host:name` coming up empty, are settled *before* anything
detaches: a detach that hands the terminal to a doomed `ssh` costs the user
their client for as long as the return ticket takes.

**Portability.** GNU and BSD/macOS disagree on `date -d @<ts>` vs `date -r <ts>` and on
`readlink -f`; both have explicit fallbacks (`fmt_date`, the `$self` block). Keep any
new coreutils usage inside that pattern — macOS is a primary target.

## Releasing

`VERSION` in `tj` and the git tag must match. After tagging, the Homebrew formula lives
in a **separate repo**, `aladagemre/homebrew-tap` (`Formula/tj.rb`) — bump its `url` and
`sha256` there. `packaging/PKGBUILD` carries its own `sha256sums` for the same tarball
and is not yet published to the AUR.

## The demo GIF

`assets/demo.gif` (re-recorded for v0.2.0) shows seven invented projects, each with
a coding agent in its session. Two of them are Claude Code sessions flagged `◆`, and
there are rows from a remote host. The recording scripts live outside the repo, so
this section is the spec any re-record must reproduce.

- **Two throwaway servers, reached only through the test shims.**
  - Every tmux call went through `tests/fakebin/tmux` with
    `TJ_TEST_SOCKET=tjtest-demo-local`.
  - The remote host `gpu-box` (`TJ_HOSTS=gpu-box`) is `tests/fakebin/ssh`
    pointed at a second server, `tjtest-demo-remote`.
  - The rules under "Testing changes" apply in full.
- **The agent screens are scripted. Never record real agents.**
  - Each pane runs a short bash script that prints a screen in Claude Code,
    Codex or OpenCode style.
  - A real `claude` would run the recorder's own hooks, show account details,
    spend quota, and never repeat itself.
  - Agent sessions are split. The agent sits in a 60-column pane on the left;
    that is about tj's preview width, so the preview shows it unwrapped. The
    project's dev server or monitor sits on the right.
  - The scripts size their boxes with `tput cols`. A fixed-width screen parked
    on the left of a wide pane reads as fake.
- **`◆` only where the README backs it.**
  - The flag was set with `tmux set -p -t <session> @tj-attention claude`, on
    Claude Code panes only. The README documents a hook for Claude Code alone.
  - The pane the viewer approves clears its own flag with the same command the
    README's hook runs.
- **Realistic ages.**
  - Each session's creation time is pushed into the past by a tiny
    `LD_PRELOAD` that offsets only the wall clock, re-read from a file before
    each `new-session`.
  - `libfaketime` did this for the first recording, but it deadlocks tmux 3.6
    at startup.
- **No identity.**
  - `HOME` is a scratch directory whose `.bashrc` sets `PS1='$ '`.
  - The status bar shows no hostname and no clock.
  - Every project and host name is invented.
  - The `.cast` is plain text. Before rendering it is grepped for the username,
    the hostname, the email and real project names, and the only acceptable
    result is zero hits.
- **Real keystrokes, captioned.**
  - A driver types into a pty running `asciinema rec`, so `prefix + j` opens
    the real popup.
  - It writes each step's caption into a tmux user option shown in
    `status-right`. Viewers cannot see keys, so the GIF has to say which key
    was pressed and why.
- **Rendering.**
  - `agg` 1.9.0 with `--theme github-dark --font-size 16 --idle-time-limit 2`,
    on a 140×36 terminal.
  - agg falls back to DejaVu Sans Mono here, which lacks `⏺`, `⎿` and the
    braille spinners. The screens use `●`, `└` and `◐` instead.
