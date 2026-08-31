# tj Remote Sessions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let `tj` list, preview, kill and enter tmux sessions on remote hosts alongside local ones, without slowing down or changing the local-only path.

**Architecture:** `tj` stays one bash script that re-invokes itself for anything fzf calls. Remote hosts come from a config file; when none are configured no `ssh` runs at all. Remote rows are appended below local ones with the host in its own column, so grouping is visual rather than structural. Entering a remote session hands the terminal from the local tmux to the remote one with `detach-client -E` instead of nesting.

**Tech Stack:** bash, tmux 3.x, fzf, OpenSSH. No new runtime dependencies. Tests are plain bash against throwaway tmux servers.

**Spec:** `docs/superpowers/specs/2026-08-31-tj-remote-sessions-design.md`

## Global Constraints

- `shellcheck --shell=bash tj tj.tmux` must stay clean; CI runs exactly that.
- macOS is a primary target. Any new coreutils usage needs a BSD fallback, following the existing `fmt_date` and `$self` patterns.
- With no hosts configured, `./tj --list` output must be **byte-identical** to today's and **no `ssh` process may be spawned**.
- The list line is a contract: field 1 is the status mark and is never an empty string. The session name lives in field 2 (local-only mode) or field 3 (remote mode); that index is a computed variable, never a hard-coded literal.
- **Test isolation is `-L <socket>` on every single tmux invocation.** `TMUX_TMPDIR` does not isolate: with a server already running, a client still finds the default socket. Nothing in this repo may run a destructive tmux command against the default server.
- No new files under `tests/` may be executable-but-unreferenced; `tests/run.sh` is the only entry point.

---

### Task 1: Test harness

**Files:**
- Create: `tests/run.sh`
- Create: `tests/fakebin/tmux`
- Create: `tests/fakebin/ssh`

**Interfaces:**
- Consumes: nothing.
- Produces: `tests/run.sh` runnable with no arguments, exit 0 on success and 1 on any failure. Helper functions available to later tasks: `ok <desc>`, `no <desc> <detail>`, `is <desc> <expected> <actual>`, `srv <socket> <tmux args...>`, and the env contract `TJ_REAL_TMUX`, `TJ_TEST_SOCKET`, `TJ_FAKE_SSH_REMOTE_SOCKET`, `TJ_FAKE_SSH_DEAD`, `TJ_SSH_LOG`.

- [ ] **Step 1: Write the fake tmux**

`tj` calls plain `tmux`. The only way to keep the suite off the user's real server is to shadow `tmux` on `PATH` and pin every call to a throwaway socket.

Create `tests/fakebin/tmux`:

```bash
#!/usr/bin/env bash
# Test double for tmux: pins every call to the throwaway server named by
# TJ_TEST_SOCKET. tj calls plain `tmux`, so this shim is the only thing standing
# between the suite and the user's real sessions. TMUX_TMPDIR is NOT used: with a
# server already running, a client still resolves to the default socket.
set -u
: "${TJ_REAL_TMUX:?fake tmux: TJ_REAL_TMUX is not set}"
: "${TJ_TEST_SOCKET:?fake tmux: TJ_TEST_SOCKET is not set}"
case $TJ_TEST_SOCKET in
  tjtest-*) ;;
  *) printf 'fake tmux: refusing socket %s\n' "$TJ_TEST_SOCKET" >&2; exit 1 ;;
esac
exec "$TJ_REAL_TMUX" -L "$TJ_TEST_SOCKET" "$@"
```

- [ ] **Step 2: Write the fake ssh**

Create `tests/fakebin/ssh`:

```bash
#!/usr/bin/env bash
# Test double for ssh: runs the command against a second throwaway tmux server
# instead of reaching a host, so remote behaviour is exercised with no network.
# A host listed in TJ_FAKE_SSH_DEAD exits 255, which is what real ssh returns
# when it cannot connect at all.
set -u

[[ -n ${TJ_SSH_LOG:-} ]] && printf '%s\n' "$*" >>"$TJ_SSH_LOG"

host=""
cmd=()
while (( $# )); do
  case $1 in
    -o|-l|-p|-i|-F|-b|-c|-E|-D|-L|-R) shift 2 ;;
    -*) shift ;;
    *)  if [[ -z $host ]]; then host=$1; else cmd+=("$1"); fi; shift ;;
  esac
done

case " ${TJ_FAKE_SSH_DEAD:-} " in
  *" $host "*) exit 255 ;;
esac

(( ${#cmd[@]} )) || exit 0
# The command always begins with `tmux`, which resolves back to the fake tmux
# above; pointing TJ_TEST_SOCKET at the remote server is what makes it "remote".
exec env TJ_TEST_SOCKET="${TJ_FAKE_SSH_REMOTE_SOCKET:?}" bash -c "${cmd[*]}"
```

- [ ] **Step 3: Write the runner with one failing test**

Create `tests/run.sh`. The first test asserts something not yet true — that `--list` emits a row whose field 2 is the session name — so the harness proves it can fail before anything else is built.

```bash
#!/usr/bin/env bash
# tj's test suite. Everything runs against throwaway tmux servers reached only
# through `-L`; the default server is never touched. Run: tests/run.sh
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
ROOT=$PWD
TJ=$ROOT/tj

TJ_REAL_TMUX=$(command -v tmux) || { echo "tmux not on PATH"; exit 1; }
export TJ_REAL_TMUX
export PATH="$ROOT/tests/fakebin:$PATH"

LOCAL_SOCK=tjtest-local-$$
REMOTE_SOCK=tjtest-remote-$$
export TJ_FAKE_SSH_REMOTE_SOCKET=$REMOTE_SOCK

pass=0
fail=0
ok() { printf '  \033[32mok\033[0m    %s\n' "$1"; pass=$((pass + 1)); }
no() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; printf '        %s\n' "$2"; fail=$((fail + 1)); }
is() { if [[ $2 == "$3" ]]; then ok "$1"; else no "$1" "expected [$2] got [$3]"; fi; }

# Every raw tmux call in the suite goes through here so the socket name is
# checked before anything destructive runs.
srv() {
  case $1 in
    tjtest-*) ;;
    *) echo "refusing to act on socket '$1'"; exit 1 ;;
  esac
  local sock=$1; shift
  "$TJ_REAL_TMUX" -L "$sock" "$@"
}

cleanup() {
  srv "$LOCAL_SOCK"  kill-server 2>/dev/null
  srv "$REMOTE_SOCK" kill-server 2>/dev/null
}
trap cleanup EXIT

# -f /dev/null keeps the user's tmux.conf out of the test servers.
srv "$LOCAL_SOCK"  -f /dev/null new-session -d -s alpha -c /tmp -x 120 -y 30
srv "$LOCAL_SOCK"  -f /dev/null new-session -d -s beta  -c /tmp -x 120 -y 30
srv "$REMOTE_SOCK" -f /dev/null new-session -d -s api   -c /tmp -x 120 -y 30

export TJ_TEST_SOCKET=$LOCAL_SOCK

echo "local-only mode"
out=$(TJ_HOSTS= "$TJ" --list)
is "field 2 of the first row is a session name" \
   "1" \
   "$(awk 'NR==1 && ($2=="alpha" || $2=="beta"){c++} END{print c+0}' <<<"$out")"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
```

- [ ] **Step 4: Make the files executable and run the suite**

```bash
chmod +x tests/run.sh tests/fakebin/tmux tests/fakebin/ssh
tests/run.sh
```

Expected: the suite runs and the assertion PASSES (today's `tj` already puts the name in field 2). If it fails, the harness is misrouting — fix the harness before continuing.

- [ ] **Step 5: Prove the harness cannot reach the real server**

```bash
tmux ls | wc -l                  # note the number
tests/run.sh >/dev/null
tmux ls | wc -l                  # must be the same number
TJ_TEST_SOCKET=default tests/fakebin/tmux ls; echo "exit=$?"
```

Expected: the two counts match, and the last command prints `fake tmux: refusing socket default` with `exit=1`.

- [ ] **Step 6: Commit**

```bash
git add tests/run.sh tests/fakebin/tmux tests/fakebin/ssh
git commit -m "Add a test harness that cannot touch the real tmux server

tj calls plain tmux, so the suite shadows tmux on PATH with a shim that
pins every call to a throwaway -L socket and refuses any socket not
named tjtest-*. A matching ssh shim redirects to a second throwaway
server, so remote behaviour is testable with no network.

TMUX_TMPDIR is deliberately not used: with a server already running a
client still resolves to the default socket, which makes it useless as
isolation."
```

---

### Task 2: Host configuration

**Files:**
- Modify: `tj` (new section after the `command -v tmux` check)
- Modify: `tests/run.sh`

**Interfaces:**
- Consumes: nothing from Task 1 except the test helpers.
- Produces: `tj_hosts()` printing one host per line; globals `HOSTS` (newline-separated, empty when unconfigured) and `NAMEF` (2 or 3).

- [ ] **Step 1: Write the failing tests**

Append to `tests/run.sh`, before the summary block:

```bash
echo "host configuration"
is "TJ_HOSTS splits on whitespace" \
   "prod dev" \
   "$(TJ_HOSTS='prod dev' "$TJ" --hosts | tr '\n' ' ' | sed 's/ $//')"

cfgdir=$(mktemp -d)
mkdir -p "$cfgdir/tj"
printf '# a comment\nprod\n\n  dev  \n' >"$cfgdir/tj/hosts"
is "config file drops comments and blanks" \
   "prod dev" \
   "$(TJ_HOSTS= XDG_CONFIG_HOME="$cfgdir" "$TJ" --hosts | tr '\n' ' ' | sed 's/ $//')"

is "no config means no hosts" \
   "" \
   "$(TJ_HOSTS= XDG_CONFIG_HOME="$(mktemp -d)" "$TJ" --hosts)"

printf 'local\n' >"$cfgdir/tj/hosts"
TJ_HOSTS= XDG_CONFIG_HOME="$cfgdir" "$TJ" --hosts >/dev/null 2>&1
is "'local' is rejected as a host name" "1" "$?"
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
tests/run.sh
```

Expected: the four new assertions FAIL — `tj` has no `--hosts` entrypoint yet.

- [ ] **Step 3: Implement the host configuration**

In `tj`, immediately after the `command -v tmux >/dev/null || die "tmux is not installed"` line, insert:

```bash
# ---------------------------------------------------------------- remote hosts

# Hosts to ask for sessions, one per line. TJ_HOSTS (space separated) wins over
# the config file. With neither set tj runs no ssh at all, which is what keeps
# the local-only path exactly as fast as it has always been.
tj_hosts() {
  local f line hosts=()
  if [[ -n ${TJ_HOSTS:-} ]]; then
    read -r -a hosts <<<"$TJ_HOSTS"
  else
    f="${XDG_CONFIG_HOME:-$HOME/.config}/tj/hosts"
    [[ -r $f ]] || return 0
    while IFS= read -r line || [[ -n $line ]]; do
      line=${line%%#*}
      line=${line//[[:space:]]/}
      [[ -n $line ]] && hosts+=("$line")
    done <"$f"
  fi
  (( ${#hosts[@]} )) || return 0
  printf '%s\n' "${hosts[@]}"
}

HOSTS=$(tj_hosts)

# "local" labels this machine in the host column, so it cannot also name a
# remote host without making the column ambiguous.
[[ $'\n'$HOSTS$'\n' == *$'\n'local$'\n'* ]] &&
  die "'local' is a reserved host name — rename it in your tj hosts config"

# The session name is field 2 normally and field 3 once a host column exists.
# Everything that reads the name asks this variable instead of hard-coding it.
if [[ -n $HOSTS ]]; then NAMEF=3; else NAMEF=2; fi
```

- [ ] **Step 4: Add the `--hosts` entrypoint**

In the `case "${1:-}" in` block in `tj`, add as the first branch:

```bash
  --hosts)   [[ -n $HOSTS ]] && printf '%s\n' "$HOSTS"; exit 0 ;;
```

- [ ] **Step 5: Run the tests and shellcheck**

```bash
tests/run.sh
shellcheck --shell=bash tj tj.tmux
```

Expected: all assertions PASS, shellcheck silent.

- [ ] **Step 6: Commit**

```bash
git add tj tests/run.sh
git commit -m "Read remote hosts from config, opt-in only

Hosts come from TJ_HOSTS or \$XDG_CONFIG_HOME/tj/hosts. With neither
set, HOSTS is empty and tj behaves exactly as before.

'local' is rejected as a host name because it is the label the host
column uses for this machine."
```

---

### Task 3: Host column in the list

**Files:**
- Modify: `tj` (`list_sessions`, new `emit_row`)
- Modify: `tests/run.sh`

**Interfaces:**
- Consumes: `HOSTS`, `NAMEF` from Task 2.
- Produces: `emit_row <mark> <host> <name> <age> <wins> <path>`, which prints the host column only when `HOSTS` is non-empty. Callers pass `wins` already suffixed, e.g. `3w`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/run.sh`:

```bash
echo "host column"
loc=$(TJ_HOSTS= "$TJ" --list)
is "local-only rows have 5 fields" \
   "0" \
   "$(awk 'NF!=5{c++} END{print c+0}' <<<"$loc")"
is "local-only puts the name in field 2" \
   "alpha" \
   "$(awk '$2=="alpha"{print $2}' <<<"$loc" | head -1)"

rem=$(TJ_HOSTS=nowhere TJ_FAKE_SSH_DEAD=nowhere "$TJ" --list)
is "remote mode labels local rows 'local'" \
   "2" \
   "$(awk '$2=="local"{c++} END{print c+0}' <<<"$rem")"
is "remote mode puts the name in field 3" \
   "alpha" \
   "$(awk '$2=="local" && $3=="alpha"{print $3}' <<<"$rem" | head -1)"
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
tests/run.sh
```

Expected: the last two assertions FAIL — there is no host column yet, so `$2` is the session name and nothing equals `local`.

- [ ] **Step 3: Add `emit_row` and rewrite `list_sessions` to use it**

In `tj`, in the formatting section, add before `list_sessions`:

```bash
# One list row. The host column exists only when hosts are configured, which is
# what keeps today's output — and the name's field index — untouched for anyone
# not using the feature. Colouring the host is safe: fzf strips ANSI both when
# expanding {n} and when printing the selected line.
emit_row() {
  local mark=$1 host=$2 name=$3 age=$4 wins=$5 path=$6
  if [[ -n $HOSTS ]]; then
    printf '%b \033[38;5;110m%-8s\033[0m %-18s \033[38;5;244m%6s  %s  %s\033[0m\n' \
      "$mark" "$host" "$name" "$age" "$wins" "$path"
  else
    printf '%b %-18s \033[38;5;244m%6s  %s  %s\033[0m\n' \
      "$mark" "$name" "$age" "$wins" "$path"
  fi
}
```

Then replace the `printf` at the end of the `while` loop inside `list_sessions` with:

```bash
    emit_row "$mark" local "$name" "$age" "${wins}w" "$home_short"
```

- [ ] **Step 4: Run the tests and confirm today's output is unchanged**

```bash
tests/run.sh
git stash && TJ_HOSTS= ./tj --list > /tmp/tj-before.txt; git stash pop
TJ_HOSTS= ./tj --list > /tmp/tj-after.txt
diff /tmp/tj-before.txt /tmp/tj-after.txt && echo "IDENTICAL"
shellcheck --shell=bash tj tj.tmux
```

Expected: all assertions PASS, `diff` prints nothing followed by `IDENTICAL`, shellcheck silent.

- [ ] **Step 5: Commit**

```bash
git add tj tests/run.sh
git commit -m "Print list rows through emit_row, with an optional host column

The host becomes its own column when hosts are configured, which moves
the session name from field 2 to field 3. With no hosts configured the
format string is unchanged and the output is byte-identical to before."
```

---

### Task 4: Remote listing over SSH

**Files:**
- Modify: `tj` (`ssh_q`, `qq`, `remote_rows`, `list_remote`, `--list` entrypoint)
- Modify: `tests/run.sh`

**Interfaces:**
- Consumes: `emit_row`, `HOSTS`, `human_age`.
- Produces: `ssh_q <host> <command>`, `qq <string>` (single-argument `printf %q`), `remote_rows <host>`, `list_remote` (no arguments, prints every host's rows in config order).

- [ ] **Step 1: Write the failing tests**

Append to `tests/run.sh`:

```bash
echo "remote listing"
export TJ_SSH_LOG; TJ_SSH_LOG=$(mktemp)
: >"$TJ_SSH_LOG"
TJ_HOSTS= "$TJ" --list >/dev/null
is "local-only mode spawns no ssh" "0" "$(wc -l <"$TJ_SSH_LOG" | tr -d ' ')"

rows=$(TJ_HOSTS=prod "$TJ" --list)
is "remote sessions appear" \
   "1" \
   "$(awk '$2=="prod" && $3=="api"{c++} END{print c+0}' <<<"$rows")"
is "remote rows come after local ones" \
   "yes" \
   "$(awk '$2=="local"{l=NR} $2=="prod"{r=NR} END{print (l<r)?"yes":"no"}' <<<"$rows")"
is "every remote-mode row has 6 fields or more" \
   "0" \
   "$(awk 'NF<6{c++} END{print c+0}' <<<"$rows")"

dead=$(TJ_HOSTS=gone TJ_FAKE_SSH_DEAD=gone "$TJ" --list)
is "an unreachable host gets a visible row" \
   "1" \
   "$(awk '$2=="gone" && $3=="-"{c++} END{print c+0}' <<<"$dead")"
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
tests/run.sh
```

Expected: every assertion after the first FAILS — `--list` does not consult hosts yet.

- [ ] **Step 3: Add the SSH helpers**

In `tj`, at the end of the remote-hosts section added in Task 2:

```bash
# Non-interactive ssh for listing and previewing: never prompt, never hang, and
# hold one multiplexed connection open so the fzf preview — which re-runs on
# every cursor move — does not pay for a fresh handshake each time. %C is a
# fixed-length hash, which keeps the control socket inside the unix path limit.
ssh_q() {
  ssh -o BatchMode=yes \
      -o ConnectTimeout=2 \
      -o ControlMaster=auto \
      -o ControlPersist=60 \
      -o ControlPath="$HOME/.ssh/tj-%C" \
      "$@"
}

# Quote one argument for the remote shell.
qq() { printf '%q' "$1"; }
```

- [ ] **Step 4: Add `remote_rows` and `list_remote`**

In `tj`, after `list_sessions`:

```bash
# Sessions on one host. ssh exits 255 when it cannot reach the host at all,
# which is the only failure worth a visible row: a reachable host with no
# sessions should simply contribute nothing.
remote_rows() {
  local host=$1 out rc ts name wins att path age mark
  out=$(ssh_q "$host" \
    "tmux list-sessions -F '#{?session_last_attached,#{session_last_attached},#{session_created}}|#{session_name}|#{session_windows}|#{?session_attached,1,0}|#{session_path}'" \
    2>/dev/null)
  rc=$?
  if (( rc == 255 )); then
    emit_row $'\033[31m!\033[0m' "$host" - - - unreachable
    return 0
  fi
  (( rc == 0 )) || return 0
  printf '%s\n' "$out" | sort -t'|' -rn -k1,1 |
  while IFS='|' read -r ts name wins att path; do
    [[ -n $name ]] || continue
    age=$(human_age "$ts")
    if [[ $att == 1 ]]; then mark=$'\033[36m○\033[0m'
    else                     mark=$'\033[38;5;240m·\033[0m'
    fi
    emit_row "$mark" "$host" "$name" "$age" "${wins}w" "$path"
  done
}

# Every host is queried at once: one slow or dead host must not decide how long
# the picker takes to open. Output files are named by loop index, never by host,
# so a host string can never influence a path.
list_remote() {
  [[ -n $HOSTS ]] || return 0
  local dir host i=0
  dir=$(mktemp -d "${TMPDIR:-/tmp}/tj.XXXXXX") || return 0
  while IFS= read -r host; do
    i=$((i + 1))
    remote_rows "$host" >"$dir/$i" 2>/dev/null &
  done <<<"$HOSTS"
  wait
  i=0
  while IFS= read -r _; do
    i=$((i + 1))
    [[ -f $dir/$i ]] && cat "$dir/$i"
  done <<<"$HOSTS"
  [[ -n $dir && -d $dir ]] && rm -rf "${dir:?}"
}
```

- [ ] **Step 5: Wire `--list` to print both**

Change the `--list` branch of the `case` block to:

```bash
  --list)    list_sessions; list_remote; exit 0 ;;
```

- [ ] **Step 6: Run the tests and shellcheck**

```bash
tests/run.sh
shellcheck --shell=bash tj tj.tmux
```

Expected: all assertions PASS, shellcheck silent.

- [ ] **Step 7: Commit**

```bash
git add tj tests/run.sh
git commit -m "List sessions from configured remote hosts

Hosts are queried in parallel with BatchMode and a 2s connect timeout,
so a slow or dead host cannot hold the picker open. Connection
multiplexing is set up here because the preview added next re-runs on
every cursor move.

A host that cannot be reached (ssh exit 255) gets a visible '!' row
rather than disappearing; a reachable host with no sessions contributes
nothing."
```

---

### Task 5: Preview dispatch

**Files:**
- Modify: `tj` (`render_preview`, `--preview` entrypoint)
- Modify: `tests/run.sh`

**Interfaces:**
- Consumes: `ssh_q`, `qq`.
- Produces: `render_preview [<host>] <name>` — one argument renders locally, two render over SSH; a `<name>` of `-` renders nothing.

- [ ] **Step 1: Write the failing tests**

Append to `tests/run.sh`:

```bash
echo "preview"
srv "$LOCAL_SOCK"  send-keys -t alpha 'echo LOCALMARK' Enter
srv "$REMOTE_SOCK" send-keys -t api   'echo REMOTEMARK' Enter
sleep 1

is "one argument previews a local session" \
   "1" \
   "$(TJ_HOSTS=prod "$TJ" --preview alpha | grep -c LOCALMARK)"
is "'local' as host previews locally" \
   "1" \
   "$(TJ_HOSTS=prod "$TJ" --preview local alpha | grep -c LOCALMARK)"
is "two arguments preview over ssh" \
   "1" \
   "$(TJ_HOSTS=prod "$TJ" --preview prod api | grep -c REMOTEMARK)"
is "a placeholder name previews nothing" \
   "" \
   "$(TJ_HOSTS=prod "$TJ" --preview gone -)"
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
tests/run.sh
```

Expected: the `local alpha`, `prod api` and placeholder assertions FAIL — `--preview` takes one argument today.

- [ ] **Step 3: Rewrite `render_preview`**

Replace the whole `render_preview` function in `tj` with:

```bash
render_preview() {
  local host="" name rule
  if (( $# >= 2 )); then host=$1; name=$2; else name=${1:-}; fi
  [[ -z $name || $name == - ]] && return 0
  rule="────────────────────────────────────────"
  printf '\033[1m%s\033[0m\n' "${host:+$host · }$name"
  if [[ -n $host && $host != local ]]; then
    ssh_q "$host" "tmux list-windows -t $(qq "$name") -F '  #{window_index}: #{window_name}#{?window_active, *,}  (#{pane_current_command})'" 2>/dev/null
    printf '\033[38;5;244m%s\033[0m\n' "$rule"
    ssh_q "$host" "tmux capture-pane -ep -t $(qq "$name")" 2>/dev/null | tail -n 40
  else
    tmux list-windows -t "$name" \
      -F '  #{window_index}: #{window_name}#{?window_active, *,}  (#{pane_current_command})' 2>/dev/null
    printf '\033[38;5;244m%s\033[0m\n' "$rule"
    tmux capture-pane -ep -t "$name" 2>/dev/null | tail -n 40
  fi
}
```

- [ ] **Step 4: Pass every argument through in the entrypoint**

Change the `--preview` branch of the `case` block to:

```bash
  --preview) shift; render_preview "$@"; exit 0 ;;
```

- [ ] **Step 5: Run the tests and shellcheck**

```bash
tests/run.sh
shellcheck --shell=bash tj tj.tmux
```

Expected: all assertions PASS, shellcheck silent.

- [ ] **Step 6: Commit**

```bash
git add tj tests/run.sh
git commit -m "Preview remote panes over the multiplexed connection

--preview takes an optional host argument ahead of the name. The host
'local' renders locally, which is what the host column emits for this
machine's own sessions."
```

---

### Task 6: Kill dispatch

**Files:**
- Modify: `tj` (`kill_target`, `--kill` entrypoint)
- Modify: `tests/run.sh`

**Interfaces:**
- Consumes: `ssh_q`, `qq`.
- Produces: `kill_target [<host>] <name>`, always exiting 0 so an fzf binding never reports failure.

- [ ] **Step 1: Write the failing tests**

Append to `tests/run.sh`:

```bash
echo "kill"
srv "$LOCAL_SOCK"  -f /dev/null new-session -d -s doomed -c /tmp -x 120 -y 30
srv "$REMOTE_SOCK" -f /dev/null new-session -d -s doomed -c /tmp -x 120 -y 30

TJ_HOSTS=prod "$TJ" --kill prod doomed
is "killing a remote session leaves the local one" \
   "1" \
   "$(srv "$LOCAL_SOCK" list-sessions -F '#{session_name}' | grep -c '^doomed$')"
is "the remote session is gone" \
   "0" \
   "$(srv "$REMOTE_SOCK" list-sessions -F '#{session_name}' | grep -c '^doomed$')"

TJ_HOSTS=prod "$TJ" --kill local doomed
is "killing a local session works" \
   "0" \
   "$(srv "$LOCAL_SOCK" list-sessions -F '#{session_name}' | grep -c '^doomed$')"

TJ_HOSTS=prod "$TJ" --kill gone -
is "killing a placeholder row is a silent no-op" "0" "$?"
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
tests/run.sh
```

Expected: all four FAIL — there is no `--kill` entrypoint.

- [ ] **Step 3: Implement `kill_target`**

In `tj`, in the transitions section after `enter_session`:

```bash
# Killing lives behind an entrypoint rather than inline in the fzf binding, so
# the local/remote decision sits in one place. Always exits 0: a failed kill
# must not make the picker's reload look broken.
kill_target() {
  local host="" name
  if (( $# >= 2 )); then host=$1; name=$2; else name=${1:-}; fi
  [[ -z $name || $name == - ]] && return 0
  if [[ -n $host && $host != local ]]; then
    ssh_q "$host" "tmux kill-session -t $(qq "$name")" >/dev/null 2>&1
  else
    tmux kill-session -t "$name" >/dev/null 2>&1
  fi
  return 0
}
```

- [ ] **Step 4: Add the entrypoint**

Add to the `case` block, after the `--preview` branch:

```bash
  --kill)    shift; kill_target "$@"; exit 0 ;;
```

- [ ] **Step 5: Run the tests and shellcheck**

```bash
tests/run.sh
shellcheck --shell=bash tj tj.tmux
```

Expected: all assertions PASS, shellcheck silent.

- [ ] **Step 6: Commit**

```bash
git add tj tests/run.sh
git commit -m "Move ctrl-x's kill behind a --kill entrypoint

The local/remote decision now lives in one function instead of inside
an fzf binding string. Killing a placeholder row is a no-op and the
function always exits 0 so the picker's reload never looks broken."
```

---

### Task 7: Entering a remote session

**Files:**
- Modify: `tj` (`enter_remote`)
- Modify: `tests/run.sh`

**Interfaces:**
- Consumes: `qq`.
- Produces: `enter_remote <host> <name>` — inside tmux it replaces the client via `detach-client -E`; outside it `exec`s `ssh -t`.

- [ ] **Step 1: Write the failing test**

This is the one test needing a real attached client, because `detach-client` has nothing to act on without one. Append to `tests/run.sh`:

```bash
echo "entering a remote session"
srv "$LOCAL_SOCK" -f /dev/null new-session -d -s home -c /tmp -x 120 -y 30
# detach-client -E runs its command from the tmux server's environment, not the
# client's, so the shims have to be visible there too.
srv "$LOCAL_SOCK" set-environment -g PATH "$ROOT/tests/fakebin:$PATH"
srv "$LOCAL_SOCK" set-environment -g TJ_REAL_TMUX "$TJ_REAL_TMUX"
srv "$LOCAL_SOCK" set-environment -g TJ_TEST_SOCKET "$LOCAL_SOCK"
srv "$LOCAL_SOCK" set-environment -g TJ_FAKE_SSH_REMOTE_SOCKET "$REMOTE_SOCK"

nohup script -qc "$TJ_REAL_TMUX -L $LOCAL_SOCK attach -t home" /dev/null >/dev/null 2>&1 &
sleep 1
tty_before=$(srv "$LOCAL_SOCK" list-clients -F '#{client_tty}' | head -1)

srv "$LOCAL_SOCK" send-keys -t home \
  "TJ_HOSTS=prod TJ_TEST_SOCKET=$LOCAL_SOCK TJ_REAL_TMUX=$TJ_REAL_TMUX PATH=$ROOT/tests/fakebin:\$PATH TJ_FAKE_SSH_REMOTE_SOCKET=$REMOTE_SOCK $TJ prod api" Enter
sleep 3

is "the client left the local server" \
   "0" \
   "$(srv "$LOCAL_SOCK" list-clients -F '#{client_tty}' | grep -c "^$tty_before$")"
is "the same terminal now drives the remote server" \
   "1" \
   "$(srv "$REMOTE_SOCK" list-clients -F '#{client_tty}' | grep -c "^$tty_before$")"

srv "$REMOTE_SOCK" kill-session -t api
sleep 2
is "ending the remote session returns the terminal home" \
   "1" \
   "$(srv "$LOCAL_SOCK" list-clients -F '#{client_session}' | grep -c '^home$')"

srv "$REMOTE_SOCK" -f /dev/null new-session -d -s api -c /tmp -x 120 -y 30
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
tests/run.sh
```

Expected: the three assertions FAIL — `tj prod api` is not a supported invocation yet, so nothing moves.

- [ ] **Step 3: Implement `enter_remote`**

In `tj`, after `enter_session`:

```bash
# Inside tmux, switch-client cannot cross machines. Rather than nesting a remote
# tmux inside the local one — which costs a doubled prefix on every remote
# keystroke — hand the terminal over. The chained second command is the return
# ticket: when the remote session ends or ssh drops, the terminal falls back to
# the session it came from.
enter_remote() {
  local host=$1 name=$2 back
  if [[ -n ${TMUX:-} ]]; then
    back=$(tmux display-message -p '#S')
    tmux detach-client -E \
      "ssh -t $(qq "$host") tmux attach -t $(qq "$name"); tmux attach -t $(qq "$back")"
  else
    exec ssh -t "$host" tmux attach -t "$name"
  fi
}
```

- [ ] **Step 4: Accept two positional arguments**

Immediately before the existing `# Direct jump` block in `tj`, insert:

```bash
# `tj prod api` — used by the picker and by the host:name form below.
if [[ -n ${2:-} ]]; then
  enter_remote "$1" "$2"
  exit 0
fi
```

- [ ] **Step 5: Run the test and shellcheck**

```bash
tests/run.sh
shellcheck --shell=bash tj tj.tmux
```

Expected: all assertions PASS, shellcheck silent.

- [ ] **Step 6: Commit**

```bash
git add tj tests/run.sh
git commit -m "Enter remote sessions by replacing the client, not nesting

Inside tmux, detach-client -E hands the terminal to the remote tmux and
chains a command to come back to the session we left. Exactly one tmux
is attached at any moment, so the prefix stays unambiguous and no key
needs pressing twice.

Outside tmux there is no client to replace, so ssh -t is exec'd."
```

---

### Task 8: Picker wiring and the host:name argument

**Files:**
- Modify: `tj` (fzf invocation, selection handling, direct-jump block)
- Modify: `tests/run.sh`

**Interfaces:**
- Consumes: `NAMEF`, `enter_remote`, `kill_target`, `render_preview`.
- Produces: a picker whose preview and `ctrl-x` binding address the right machine, and `tj <host>:<name>` as a direct jump.

- [ ] **Step 1: Write the failing tests**

Append to `tests/run.sh`:

```bash
echo "picker wiring"
srv "$REMOTE_SOCK" -f /dev/null new-session -d -s solo -c /tmp -x 120 -y 30
: >"$TJ_SSH_LOG"
( TJ_HOSTS=prod "$TJ" prod:solo ) >/dev/null 2>&1
is "host:name asks ssh for that host and session" \
   "1" \
   "$(grep -c 'prod.*tmux attach -t solo' "$TJ_SSH_LOG")"

# Feed the picker's own placeholders back through the entrypoints, which is what
# fzf does with {2} and {3}.
line=$(TJ_HOSTS=prod "$TJ" --list | awk '$2=="prod" && $3=="api"' | head -1)
is "remote-mode {2} {3} reach the remote pane" \
   "1" \
   "$(TJ_HOSTS=prod "$TJ" --preview "$(awk '{print $2}' <<<"$line")" "$(awk '{print $3}' <<<"$line")" | grep -c REMOTEMARK)"

line=$(TJ_HOSTS= "$TJ" --list | awk '$2=="alpha"' | head -1)
is "local-mode {2} reaches the local pane" \
   "1" \
   "$(TJ_HOSTS= "$TJ" --preview "$(awk '{print $2}' <<<"$line")" | grep -c LOCALMARK)"
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
tests/run.sh
```

Expected: the `host:name` assertion FAILS — a `:` argument currently falls through to session creation.

- [ ] **Step 3: Handle the host:name form**

In `tj`, inside the existing `if [[ -n ${1:-} ]]; then` direct-jump block, add as the first statement:

```bash
  # `tj prod:api` — ':' cannot occur in a tmux session name (tmux rewrites it to
  # '_'), so a colon unambiguously means "remote".
  if [[ $1 == *:* ]]; then
    enter_remote "${1%%:*}" "${1#*:}"
    exit 0
  fi
```

- [ ] **Step 4: Build the fzf commands from the computed field index**

Replace the `out=$(list_sessions | fzf ... )` block in `tj` with:

```bash
if [[ -n $HOSTS ]]; then
  preview_cmd="\"$self\" --preview {2} {3}"
  kill_cmd="\"$self\" --kill {2} {3}"
else
  preview_cmd="\"$self\" --preview {2}"
  kill_cmd="\"$self\" --kill {2}"
fi

out=$( { list_sessions; list_remote; } | fzf \
  --ansi \
  --reverse \
  --no-sort \
  --print-query \
  --expect=ctrl-n \
  --prompt='session > ' \
  --header=$'enter switch · ctrl-x kill · ctrl-n new · ctrl-/ preview' \
  --preview="$preview_cmd" \
  --preview-window='right,50%,wrap,border-left' \
  --bind='ctrl-/:toggle-preview' \
  --bind="ctrl-x:execute-silent($kill_cmd)+reload(\"$self\" --list)")
```

- [ ] **Step 5: Read the selection through the computed index**

Replace the final `enter_session "$(awk '{print $2}' <<<"$line")"` line with:

```bash
sel_name=$(awk -v f="$NAMEF" '{print $f}' <<<"$line")
[[ -z $sel_name || $sel_name == - ]] && exit 0
if [[ -n $HOSTS ]]; then
  sel_host=$(awk '{print $2}' <<<"$line")
  if [[ $sel_host != local ]]; then
    enter_remote "$sel_host" "$sel_name"
    exit 0
  fi
fi
enter_session "$sel_name"
```

- [ ] **Step 6: Drive the real picker once, end to end**

```bash
tests/run.sh
shellcheck --shell=bash tj tj.tmux
```

Then, manually, against the test servers only:

```bash
S=tjtest-manual-$$
tmux -L "$S" -f /dev/null new-session -d -s demo -x 140 -y 32
tmux -L "$S" send-keys -t demo "TJ_REAL_TMUX=$(command -v tmux) TJ_TEST_SOCKET=$S PATH=$PWD/tests/fakebin:\$PATH TJ_HOSTS=prod TJ_FAKE_SSH_DEAD=prod ./tj" Enter
sleep 2
tmux -L "$S" capture-pane -p -t demo | head -20
tmux -L "$S" kill-server
```

Expected: all assertions PASS, shellcheck silent, and the captured pane shows the picker with a host column and a `!` row for the unreachable host.

- [ ] **Step 7: Commit**

```bash
git add tj tests/run.sh
git commit -m "Point the picker's preview, kill and enter at the right machine

The fzf placeholders and the final awk all read the field index
computed at startup, so nothing hard-codes {2} or {3}. Selecting a row
whose host column is not 'local' enters it remotely.

tj prod:api works as a direct jump; a colon is unambiguous because tmux
rewrites it out of session names."
```

---

### Task 9: Documentation, version and CI

**Files:**
- Modify: `tj` (`VERSION`, header comment)
- Modify: `README.md`
- Modify: `CLAUDE.md`
- Modify: `.github/workflows/lint.yml`

**Interfaces:**
- Consumes: everything above.
- Produces: nothing other tasks depend on.

- [ ] **Step 1: Bump the version and document the flags in the header**

In `tj`, set `VERSION=0.2.0` and extend the comment header (which `--help` prints) so the new forms appear:

```
#   tj <host>:<name> jump to a session on a remote host
#   tj --list       print the formatted session list (used by fzf reload)
#   tj --preview [<host>] <name>  render the preview pane (used by fzf)
#   tj --kill [<host>] <name>     kill a session (used by ctrl-x)
```

- [ ] **Step 2: Add a README section**

Insert a `## Remote sessions` section between `## Usage` and `## How it works` in `README.md`:

```markdown
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

Two things worth knowing:

- Listing uses `ssh -o BatchMode=yes`, so it needs key-based auth. A host that
  would prompt for a password shows as unreachable. Entering a session uses a
  normal `ssh -t`, so passwords and 2FA still work there.
- `local` is reserved as the label for this machine and cannot name a host.

With no hosts configured tj never runs `ssh` and behaves exactly as it always has.
```

- [ ] **Step 3: Update CLAUDE.md**

In the **Architecture** section of `CLAUDE.md`, replace the paragraph beginning "**The list line is a contract**" with:

```markdown
**The list line is a contract, not just formatting.** `list_sessions` prints
`<mark> <name> <age> <windows> <path>`, and `list_remote` prints
`<mark> <host> <name> <age> <windows> <path>` — the host column exists only when
hosts are configured. The session name therefore sits in field 2 or field 3, and
that index is computed once into `NAMEF` at startup; nothing may hard-code `{2}`
or `$2`. The status mark in field 1 must never be an empty string — if it were,
awk's whitespace splitting would shift every field by one and the wrong session
would be switched to or killed. fzf strips ANSI codes both when expanding `{n}`
and when printing the selected line, so colours anywhere in the row are safe.
```

Then add to the same section:

```markdown
**Remote hosts are opt-in and the local path never pays for them.** With no
`~/.config/tj/hosts` and no `TJ_HOSTS`, `HOSTS` is empty, `list_remote` returns
immediately and no `ssh` runs. Remote rows are appended after local ones rather
than merged into one MRU ordering, so a slow or dead host cannot delay the
picker.

**Entering a remote session replaces the client.** `enter_remote` uses
`tmux detach-client -E "ssh -t <host> tmux attach -t <name>; tmux attach -t <back>"`
so exactly one tmux is ever attached to the terminal. Nesting was rejected: it
forces a doubled prefix on every remote keystroke.
```

Replace the **Testing changes** section's body with:

```markdown
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
```

- [ ] **Step 4: Run the suite in CI**

In `.github/workflows/lint.yml`, add a second job:

```yaml
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Install tmux
        run: sudo apt-get update && sudo apt-get install -y tmux
      - name: Test
        run: tests/run.sh
```

- [ ] **Step 5: Verify everything**

```bash
shellcheck --shell=bash tj tj.tmux
tests/run.sh
./tj --version          # must print: tj 0.2.0
./tj --help | head -20  # must show the remote forms
```

Expected: shellcheck silent, suite green, version `0.2.0`, help lists `<host>:<name>`, `--preview` and `--kill`.

- [ ] **Step 6: Commit**

```bash
git add tj README.md CLAUDE.md .github/workflows/lint.yml
git commit -m "Document remote sessions and run the suite in CI

Bumps VERSION to 0.2.0. CLAUDE.md records the two list layouts, the
rule that the name's field index is computed rather than hard-coded,
and that TMUX_TMPDIR must never be used as test isolation.

Release note: the Homebrew formula in aladagemre/homebrew-tap and
packaging/PKGBUILD need their url and sha256 bumped after tagging."
```

---

## Notes for the implementer

- `packaging/PKGBUILD` and the tap formula are bumped **after** tagging, not in this branch.
- If any step's expected output does not appear, stop and re-read the spec section it implements rather than adjusting the test to pass.
