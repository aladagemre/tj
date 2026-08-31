# tj — remote tmux sessions

Date: 2026-08-31
Status: approved design, not yet implemented

## Goal

Let `tj` list, preview and enter tmux sessions living on remote machines, alongside
the local ones, without giving up the two properties that make the tool worth using:
it opens instantly, and it is one dependency-free bash script.

## Non-goals

- Creating sessions on a remote host (`ctrl-n` stays local).
- Reading `~/.ssh/config` to discover hosts.
- Any caching layer or background daemon.
- Password / 2FA prompts during *listing*. Listing requires key-based auth.

## Core decisions

### D1 — Entering a remote session replaces the client, never nests

Inside tmux, `switch-client` cannot target another machine. Rather than running the
remote tmux *inside* the local one (which forces a doubled prefix on every remote
keystroke), tj hands the terminal over:

```bash
tmux detach-client -E "ssh -t <host> tmux attach -t <name>; tmux attach -t <back>"
```

`man tmux`, `detach-client`: *"With -E, run shell-command to replace the client."*
The local server keeps running with its sessions intact; only this client leaves.
The second command in the chain is the return ticket — when the user detaches from
the remote tmux or the SSH connection drops, the terminal falls back to the local
session it came from. `<back>` is captured with `tmux display-message -p '#S'`
*before* detaching.

Because exactly one tmux is attached to the terminal at any moment, the prefix is
unambiguous. No nesting, no doubled keys.

Outside tmux there is no client to replace:

```bash
exec ssh -t <host> tmux attach -t <name>
```

Verified on tmux 3.4 against isolated `tmux -L` servers: the client moves from the
local server to the remote one, returns automatically when the remote session ends,
and the same call works when issued from inside a `display-popup -E` (which is how
`tj.tmux` invokes the picker).

### D2 — Remote rows are appended, the picker never waits

Local sessions are printed and rendered first; remote rows are gathered in parallel
and appended below. The list is therefore *not* one merged MRU ordering — locals
keep their existing "most recently attached first" order, remotes follow, grouped by
host in config-file order and MRU-sorted within each host.

This is deliberate. A merged ordering would require collecting every host before
printing a single row, making the common case (jump to a local session) pay for the
slowest or dead host on every invocation.

## Configuration

Hosts come from `${XDG_CONFIG_HOME:-$HOME/.config}/tj/hosts`, one per line, `#`
starts a comment, blank lines ignored. Each entry is passed to `ssh` verbatim, so it
may be an `~/.ssh/config` alias, `user@host`, or a plain hostname.

`TJ_HOSTS="prod dev"` (space separated) overrides the file entirely.

**If neither is present, tj executes no SSH at all and behaves exactly as it does
today.** This is the load-bearing property of the whole feature: remote support must
be invisible until switched on.

## The list line

`CLAUDE.md` fixes the contract: field 1 is the status mark (never empty), field 2 is
the session name, and `awk '{print $2}'` plus fzf's `{2}` both read field 2.

Remote sessions keep that contract by encoding the host into the name as a single
token:

```
· api-gateway        3h  2w  ~/work/api      (local, unchanged)
◦ prod:api           1d  4w  /srv/api        (remote, detached)
● prod:build         2h  1w  /srv/build      (remote, attached elsewhere)
! prod:-                     unreachable     (host down)
```

Marks are one column wide and never empty. Remote marks are drawn in a distinct
colour from the local `●`/`○`/`·` set so the two groups stay tellable apart at a
glance; the exact colour is an implementation detail, the non-emptiness is not.

`:` is a safe separator because tmux rewrites it out of session names — creating a
session named `has:colon` yields `has_colon` (verified on tmux 3.4). Any `:` in field
2 therefore means "remote", and splitting on the *first* `:` is unambiguous.

The unreachable row uses mark `!` and name `<host>:-` so the field count still
holds; pressing enter on it fails with a message rather than attempting a
connection, and `ctrl-x` on it is a no-op.

## SSH transport

Two distinct modes, because their auth requirements differ:

**Listing and preview** (non-interactive, must never block):

```
-o BatchMode=yes
-o ConnectTimeout=2
-o ControlMaster=auto
-o ControlPersist=60
-o ControlPath=~/.ssh/tj-%C
```

`ControlPersist` is what makes preview usable: fzf re-runs the preview command on
every cursor move, and without connection multiplexing each move would open a fresh
SSH connection. `%C` is a fixed-length hash (OpenSSH 6.7+; 9.6 present on the dev
machine), which keeps the control socket path under the unix-socket length limit.

`BatchMode=yes` means a host needing a password simply reports as unreachable rather
than hanging the picker. This is the documented cost of remote listing.

**Entering a session** (interactive): plain `ssh -t`, no `BatchMode`, so password and
2FA prompts still work. An existing control master is reused if one is up.

## Behaviour of each key

| Key | Local row | Remote row |
|---|---|---|
| `enter` | unchanged | D1 |
| `ctrl-x` | unchanged | `ssh <host> tmux kill-session -t <name>`, then reload |
| `ctrl-n` | unchanged | always creates a **local** session |
| `ctrl-/` | unchanged | unchanged |

`tj prod:api` as a direct argument jumps straight to the remote session, mirroring
`tj api`. A bare `tj <text>` that matches no local session keeps today's behaviour of
creating a local session — remote hosts are only consulted when the argument contains
a `:`.

## Structure

`tj` re-invokes itself for anything fzf calls (`CLAUDE.md`: fzf cannot call shell
functions). The existing `--list` / `--preview` entrypoints are extended and one is
added:

- `--list` — locals, then remotes appended.
- `--preview <target>` — splits on the first `:`; renders locally or over SSH.
- `--kill <target>` — new; replaces the inline `tmux kill-session` in the `ctrl-x`
  binding so the local/remote decision lives in one place instead of inside an fzf
  binding string.

New functions: `tj_hosts`, `ssh_opts`, `split_target`, `list_remote`, `enter_remote`,
`kill_target`. Estimated size: ~100 added lines, taking the script from ~155 to ~255.

## Parallelism and cleanup

Each host is queried in a background subshell writing to its own file under a single
`mktemp -d` directory, named by loop *index* rather than by hostname so a hostile or
odd host string cannot influence a path. After `wait`, files are concatenated in
config order. Cleanup runs from a `trap`, guarded (`[[ -n $dir && -d $dir ]]`) per the
project's shell-safety rule against unguarded `rm -rf`.

## Known limitations to document, not fix

- Ages of remote sessions are computed from the remote clock against the local one.
  Machines with NTP disagree by milliseconds; badly skewed machines will show a wrong
  age. Not worth correcting.
- While attached to a remote session the local session list is unreachable, because
  the client is no longer attached to the local server. `prefix + d` returns.
- Remote listing requires key-based auth (see `BatchMode` above).

## Testing

`CLAUDE.md` forbids exercising tj against the default tmux server. All tests use
`tmux -L <name> -f /dev/null` throwaway servers, plus a real client backgrounded with
`nohup script -qc ... /dev/null &` where a client is required.

Remote behaviour is tested without any network by putting a fake `ssh` shim early on
`PATH` that strips its options and redirects the command to a *second* local tmux
socket. That makes "the remote host" a deterministic local server, and exercises the
real code path including quoting.

Cases to cover:

1. No config, no `TJ_HOSTS` → output of `--list` is byte-identical to today's, and no
   `ssh` process is spawned.
2. `--list` with one reachable fake host → local rows first, remote rows appended,
   every row still has 5 whitespace-separated fields.
3. `--list` with an unreachable host → `!` row present, command returns within the
   connect timeout.
4. `--preview prod:api` renders the remote pane; `--preview api` renders the local one.
5. `--kill prod:api` kills on the fake remote only; the local session of the same name
   survives.
6. D1 round trip: client moves to the fake remote server and returns to the original
   local session when the remote session dies.
7. `shellcheck --shell=bash tj tj.tmux` clean.

## Release

Version bumps to `0.2.0` in `tj`. `README.md` gains a "Remote sessions" section
documenting the config file and the key-auth requirement. `CLAUDE.md` gains the
`host:session` field-2 encoding and the fake-ssh test harness alongside the existing
architecture notes. The Homebrew formula in `aladagemre/homebrew-tap` and
`packaging/PKGBUILD` need their `url`/`sha256` bumped after tagging.
