# tj

**t**mux **j**ump — because you bind it to `prefix + j`.

[![lint](https://github.com/aladagemre/tj/actions/workflows/lint.yml/badge.svg)](https://github.com/aladagemre/tj/actions/workflows/lint.yml)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![no dependencies beyond tmux + fzf](https://img.shields.io/badge/deps-tmux%20%2B%20fzf-lightgrey)

An interactive tmux session picker, sorted by **most recently used** — not
alphabetically.

`tmux ls` + `tmux attach -t <name>` stops working once you keep more than a
dozen sessions around: the list is long, it is sorted by name, and the session
you actually want is almost always one of the last few you touched. `tj` puts
those on top, lets you fuzzy-filter them, and shows you each session's live
screen so you can recognise it without attaching.

![tj in action](assets/demo.gif)

- `●` current session · `○` attached by another client · `·` detached ·
  `◆` [needs you](#sessions-that-need-you)
- then: how long ago you last attached, window count, session directory
- the right pane is a live capture of that session's active pane

## Install

Requires `tmux` and [`fzf`](https://github.com/junegunn/fzf).

**With TPM** — the tmux plugin manager. This is the shortest path: it installs
the script *and* sets up the key binding.

```tmux
set -g @plugin 'aladagemre/tj'
```

Then `prefix + I` to install, and `prefix + j` opens the picker. To use a
different key or popup size:

```tmux
set -g @tj-key 'j'
set -g @tj-width '80%'
set -g @tj-height '75%'
```

**Just the file** — Linux, macOS, anything with bash. `tj` is a single script,
so downloading it *is* the install:

```sh
mkdir -p ~/.local/bin
curl -fsSL https://raw.githubusercontent.com/aladagemre/tj/main/tj -o ~/.local/bin/tj
chmod +x ~/.local/bin/tj
```

(No `curl … | bash` here on purpose — this way the file lands on disk where you
can read it before you run it.)

**Homebrew** — works on macOS and Linux:

```sh
brew install aladagemre/tap/tj
```

**Arch Linux** — a `PKGBUILD` is in [`packaging/`](packaging), not yet on the AUR.

---

If you installed without TPM, bind the popup yourself in `~/.tmux.conf`:

```tmux
bind j display-popup -E -w 80% -h 75% "$HOME/.local/bin/tj"
```

Reload with `tmux source-file ~/.tmux.conf`.

## Usage

```
tj                open the picker
tj <name>         jump straight to a session (fuzzy; creates it if there's no match)
tj <host>:<name>  jump straight to a session on a remote host
tj --help         key reference
```

Inside tmux, `prefix + j` opens the picker in a popup. Outside tmux it attaches
instead of switching, so the same command works from a fresh terminal.

| key    | action                                      |
|--------|---------------------------------------------|
| type   | fuzzy filter                                |
| enter  | attach (outside tmux) / switch (inside)     |
| ctrl-x | kill the highlighted session                |
| ctrl-n | create a new session named after your query |
| ctrl-/ | toggle the preview pane                     |
| esc    | quit                                        |

## Remote sessions

List and enter tmux sessions on other machines alongside your own. Put one host
per line in `~/.config/tj/hosts`:

```
prod
dev
user@build.example.com
```

Entries are passed straight to `ssh`, so `~/.ssh/config` aliases work. `TJ_HOSTS="prod dev"` overrides the file.

Remote sessions appear below your local ones with the host in its own column.
Picking one hands your terminal to the remote tmux rather than nesting one tmux
inside another, so your prefix key keeps working normally; detaching there
(`prefix + d`) brings you back to the session you left.

A few things worth knowing:

- Listing uses `ssh -o BatchMode=yes`, so it needs key-based auth. A host that
  would prompt for a password shows as unreachable. Entering a session uses a
  normal `ssh -t`, so passwords and 2FA still work there.
- `local` is reserved as the label for this machine and cannot name a host, and
  a host goes on a line of its own — a line with a space in it is an error, not
  two hosts.
- A remote session whose name contains a space is listed but not selectable. The
  list is a whitespace-separated table, so picking such a row would act on the
  wrong session.

With no hosts configured the list and the picker run no `ssh` at all and behave
exactly as they always have. Naming a host yourself is the exception and always
was: `tj prod:api` connects whether or not `prod` is in the config, since asking
for a host by name is instruction enough.

One compatibility note if you are upgrading: `tj foo:bar` used to create a
*local* session called `foo_bar`, because tmux rewrites `:` in a session name.
It now tries to reach session `bar` on host `foo`.

## Sessions that need you

Some of what runs in your sessions stops and waits for you: a coding agent
asking for permission, a long build that has finished. Anything that can run
`tmux` can say so by flagging its own pane with the user option
`@tj-attention`, set to a short reason, and unsetting it once it no longer
needs you:

```sh
tmux set -p -t "$TMUX_PANE" @tj-attention <reason>   # needs you
tmux set -p -u -t "$TMUX_PANE" @tj-attention          # done
```

A session with at least one flagged pane is marked `◆` and moves to the top of
the list. Flagged sessions keep most-recently-used order among themselves, and
so does everything below them. The picker opens with the first row highlighted,
so `prefix + j`, `enter` takes you straight to a session that is waiting. Once
the flag is cleared, the session goes back to its usual place.

The flag sits on the pane rather than the session because one session can hold
several programs that each want you. Only local sessions are flagged; remote
rows look exactly as they always have.

**Claude Code** can do this with hooks and no script at all. Merge this into
`~/.claude/settings.json`:

```json
{
  "hooks": {
    "Notification": [{
      "matcher": "permission_prompt|idle_prompt|elicitation_dialog",
      "hooks": [{ "type": "command", "command": "[ -n \"$TMUX_PANE\" ] && tmux set -p -t \"$TMUX_PANE\" @tj-attention claude 2>/dev/null || true" }]
    }],
    "UserPromptSubmit": [{
      "hooks": [{ "type": "command", "command": "[ -n \"$TMUX_PANE\" ] && tmux set -p -u -t \"$TMUX_PANE\" @tj-attention 2>/dev/null || true" }]
    }],
    "PostToolUse": [{
      "hooks": [{ "type": "command", "command": "[ -n \"$TMUX_PANE\" ] && tmux set -p -u -t \"$TMUX_PANE\" @tj-attention 2>/dev/null || true" }]
    }],
    "SessionEnd": [{
      "hooks": [{ "type": "command", "command": "[ -n \"$TMUX_PANE\" ] && tmux set -p -u -t \"$TMUX_PANE\" @tj-attention 2>/dev/null || true" }]
    }]
  }
}
```

The pane is flagged when Claude shows a permission prompt or an input dialog,
or has finished a turn and you have not answered for a while. Your next prompt,
the next tool call (which is what follows an approved permission prompt), or
quitting the session clears it. `PostToolUse` runs after every tool call, which
is why the clear is one `tmux` call and nothing more. Every command checks
`$TMUX_PANE` first, so a Claude Code running outside tmux is left alone, and
ends in `|| true`, so a hook can never fail a session. One gap: denying a
permission prompt fires no hook, so that flag stays until your next prompt.

## How it works

Sessions are ordered by tmux's own `session_last_attached`, falling back to
`session_created` for sessions that have never been attached, with flagged
sessions moved ahead of the rest ([above](#sessions-that-need-you)). Everything
else is `fzf`: the script re-invokes itself for `--list` (so `ctrl-x` can reload
the list after a kill) and for `--preview`.

It is one self-contained bash script with no dependencies beyond `tmux` and
`fzf`, and it works on both GNU and BSD/macOS userlands.

## How it compares

tmux already ships with a session tree — `prefix + s` — and it is genuinely
good: it previews sessions and it is always there. What `tj` adds is ordering
by when you last attached, plus fuzzy filtering, which is what starts to matter
somewhere north of a dozen sessions.

[`sesh`](https://github.com/joshmedeski/sesh) is the fuller-featured take on
this idea. Its own README leads with zoxide integration and per-project session
configuration, so if you want session *management* — starting sessions from
directories and config files — reach for that instead. `tj` is deliberately
smaller: one file, one job, no config file, nothing to learn beyond three keys.

## License

MIT
