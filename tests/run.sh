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
export TJ_SSH_LOG; TJ_SSH_LOG=$(mktemp)

pass=0
fail=0
ok() { printf '  \033[32mok\033[0m    %s\n' "$1"; pass=$((pass + 1)); }
no() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; printf '        %s\n' "$2"; fail=$((fail + 1)); }
is() { if [[ $2 == "$3" ]]; then ok "$1"; else no "$1" "expected [$2] got [$3]"; fi; }

# A pane holds the typed command, the shell's echo of it, and its output, so a
# marker appears several times, not once. These assertions care whether the
# preview reached the right machine — presence, never a count.
has() { grep -q "$1" && echo yes || echo no; }

# Poll a live pane instead of a fixed sleep: fzf's startup and filtering time
# vary with machine load, so a fixed sleep is either wasteful or flaky. Mode
# "present" (default) waits for the pattern to appear, "absent" waits for it
# to disappear (used after ctrl-x + reload). Bounded at ~4s so a genuine hang
# still fails fast instead of stalling the suite.
wait_for_pane() {
  local sock=$1 target=$2 pattern=$3 mode=${4:-present}
  for _ in $(seq 1 20); do
    if srv "$sock" capture-pane -p -t "$target" 2>/dev/null | grep -q -- "$pattern"; then
      [[ $mode == present ]] && return 0
    else
      [[ $mode == absent ]] && return 0
    fi
    sleep 0.2
  done
  return 1
}

# Same idea for a log file: enter_remote's detach-client -E branch schedules
# its ssh call to run asynchronously (tmux runs it once the client actually
# detaches), so it can still be in flight the instant `send-keys Enter`
# returns. Poll for the pattern instead of guessing a sleep long enough.
wait_for_log() {
  local file=$1 pattern=$2
  for _ in $(seq 1 20); do
    grep -q -- "$pattern" "$file" 2>/dev/null && return 0
    sleep 0.2
  done
  return 1
}

# fzf strips ANSI before expanding {n} and before printing the selected line, so
# every field index in tj is an index into the *stripped* row. Raw output splits
# differently: `%6s` left-pads the age, so its colour escape lands in a field of
# its own. Assert on what fzf actually hands back.
plain() { sed "s/$(printf '\033')\[[0-9;]*m//g"; }

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

# kill-server leaves the socket FILE behind, and it lives in the same directory
# as the user's real `default` socket. Check the name the way srv() does before
# removing anything from there.
rm_sock() {
  case $1 in
    tjtest-*) rm -f "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$1" ;;
  esac
}

# Everything the suite creates is removed here, and nothing else is: the two
# tmux servers and their socket files, the ssh log, the injection marker, and
# the two throwaway XDG_CONFIG_HOME directories. cfgdir/emptycfg do not exist
# yet if the suite dies early, hence the :- guards.
cleanup() {
  local d
  srv "$LOCAL_SOCK"  kill-server 2>/dev/null
  srv "$REMOTE_SOCK" kill-server 2>/dev/null
  rm_sock "$LOCAL_SOCK"
  rm_sock "$REMOTE_SOCK"
  [[ -n ${TJ_SSH_LOG:-} ]] && rm -f "$TJ_SSH_LOG"
  rm -f /tmp/tj-injected
  for d in "${cfgdir:-}" "${emptycfg:-}"; do
    [[ -n $d && -d $d ]] && rm -rf "${d:?}"
  done
  return 0
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

echo "ssh shim"

# Round-trip: invoke the shim the way tj will (an -o pair, then host, then a
# tmux command string) and prove the command lands on the *remote* test
# server, not the local one, by looking for a session that only exists there.
out=$("$ROOT/tests/fakebin/ssh" -o StrictHostKeyChecking=no myhost tmux list-sessions)
is "ssh shim relays a remote command to the remote test server" \
   "1" \
   "$(grep -c '^api:' <<<"$out")"

# Dead host: a host listed in TJ_FAKE_SSH_DEAD must exit exactly 255, the
# value remote listing will branch on.
TJ_FAKE_SSH_DEAD=deadhost "$ROOT/tests/fakebin/ssh" deadhost tmux list-sessions >/dev/null 2>&1
is "ssh shim exits 255 for a host listed in TJ_FAKE_SSH_DEAD" \
   "255" \
   "$?"

# Option skipping: an -o key=value pair AND a bare flag ahead of the host
# must both be consumed by the flag-parsing loop without the host being
# mistaken for one of their arguments.
out=$("$ROOT/tests/fakebin/ssh" -o StrictHostKeyChecking=no -T myhost tmux list-sessions)
is "ssh shim skips an -o pair and a bare flag ahead of the host" \
   "1" \
   "$(grep -c '^api:' <<<"$out")"

# The risk that actually matters, in the form tj really emits: a session name
# carrying a shell metacharacter must cross the ssh hop as data, never as a
# second command.
: >"$TJ_SSH_LOG"
rm -f /tmp/tj-injected
( unset TMUX; TJ_HOSTS=prod "$TJ" 'prod:a;touch /tmp/tj-injected' ) >/dev/null 2>&1
is "a metacharacter in a session name cannot become a second remote command" \
   "no" \
   "$([[ -e /tmp/tj-injected ]] && echo yes || echo no)"
rm -f /tmp/tj-injected

# Two words are NOT a remote target: `tj alph bogus` is a fuzzy jump to `alpha`,
# the behaviour that existed before this branch. The host only ever arrives as
# `host:name`, which is what keeps "no hosts configured means no ssh" true for
# every argument form. Between them the three assertions leave the fuzzy jump as
# the only path taken: no ssh rules out the remote form, and neither word became
# a session, which rules out create_session.
: >"$TJ_SSH_LOG"
( unset TMUX; TJ_HOSTS=prod "$TJ" alph bogus ) >/dev/null 2>&1
is "a two-word argument runs no ssh" \
   "0" \
   "$(wc -l <"$TJ_SSH_LOG" | tr -d ' ')"
is "a two-word argument creates no session from the first word" \
   "0" \
   "$(srv "$LOCAL_SOCK" list-sessions -F '#{session_name}' | grep -c '^alph$')"
is "a two-word argument creates no session from the second word" \
   "0" \
   "$(srv "$LOCAL_SOCK" list-sessions -F '#{session_name}' | grep -c '^bogus$')"

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

emptycfg=$(mktemp -d)
is "no config means no hosts" \
   "" \
   "$(TJ_HOSTS= XDG_CONFIG_HOME="$emptycfg" "$TJ" --hosts)"

# Whitespace inside a config line used to be deleted, gluing `prod dev` into
# one bogus host `proddev` that only showed up later as an unreachable row.
printf 'prod dev\n' >"$cfgdir/tj/hosts"
TJ_HOSTS= XDG_CONFIG_HOME="$cfgdir" "$TJ" --hosts >/dev/null 2>&1
is "two hosts on one config line are rejected, not glued together" "1" "$?"

printf 'local\n' >"$cfgdir/tj/hosts"
TJ_HOSTS= XDG_CONFIG_HOME="$cfgdir" "$TJ" --hosts >/dev/null 2>&1
is "'local' is rejected as a host name" "1" "$?"

echo "host column"
loc=$(TJ_HOSTS= "$TJ" --list | plain)
is "local-only rows have 5 fields" \
   "0" \
   "$(awk 'NF!=5{c++} END{print c+0}' <<<"$loc")"
is "local-only puts the name in field 2" \
   "alpha" \
   "$(awk '$2=="alpha"{print $2}' <<<"$loc" | head -1)"

rem=$(TJ_HOSTS=nowhere TJ_FAKE_SSH_DEAD=nowhere "$TJ" --list | plain)
is "remote mode labels local rows 'local'" \
   "2" \
   "$(awk '$2=="local"{c++} END{print c+0}' <<<"$rem")"
is "remote mode puts the name in field 3" \
   "alpha" \
   "$(awk '$2=="local" && $3=="alpha"{print $3}' <<<"$rem" | head -1)"

echo "remote listing"
: >"$TJ_SSH_LOG"
TJ_HOSTS= "$TJ" --list >/dev/null
is "local-only mode spawns no ssh" "0" "$(wc -l <"$TJ_SSH_LOG" | tr -d ' ')"

rows=$(TJ_HOSTS=prod "$TJ" --list | plain)
is "remote sessions appear" \
   "1" \
   "$(awk '$2=="prod" && $3=="api"{c++} END{print c+0}' <<<"$rows")"
is "remote rows come after local ones" \
   "yes" \
   "$(awk '$2=="local"{l=NR} $2=="prod"{r=NR} END{print (l<r)?"yes":"no"}' <<<"$rows")"
is "every remote-mode row has 6 fields or more" \
   "0" \
   "$(awk 'NF<6{c++} END{print c+0}' <<<"$rows")"

dead=$(TJ_HOSTS=gone TJ_FAKE_SSH_DEAD=gone "$TJ" --list | plain)
is "an unreachable host gets a visible row" \
   "1" \
   "$(awk '$2=="gone" && $3=="-"{c++} END{print c+0}' <<<"$dead")"

# tmux allows spaces in session names, and a remote host — not the user — picks
# this one. Whitespace-split by fzf's {n} and by the final awk, `my project`
# would be previewed, entered and KILLED as `my`, so the row has to arrive
# inert instead.
srv "$REMOTE_SOCK" -f /dev/null new-session -d -s 'my project' -c /tmp -x 120 -y 30
spaced=$(TJ_HOSTS=prod "$TJ" --list | plain)
is "a remote name containing whitespace becomes an inert '-' row" \
   "1" \
   "$(awk '$2=="prod" && $3=="-"{c++} END{print c+0}' <<<"$spaced")"
is "no field of any row carries the first word of that name" \
   "0" \
   "$(awk '$3=="my" || $4=="project"{c++} END{print c+0}' <<<"$spaced")"
srv "$REMOTE_SOCK" kill-session -t 'my project'

echo "preview"
srv "$LOCAL_SOCK"  send-keys -t alpha 'echo LOCALMARK' Enter
srv "$REMOTE_SOCK" send-keys -t api   'echo REMOTEMARK' Enter

# A local session deliberately COLLIDING by name with the remote one. Without
# it the negative assertion below proves nothing: a remote branch that wrongly
# fell through to local would look for `api` on the local socket, find nothing,
# print nothing, and satisfy "no LOCALMARK" vacuously. With the collision, that
# same bug renders the local pane and the assertion catches it.
srv "$LOCAL_SOCK" -f /dev/null new-session -d -s api -c /tmp -x 120 -y 30
srv "$LOCAL_SOCK" send-keys -t api 'echo LOCALMARK' Enter
sleep 1

is "one argument previews a local session" \
   "yes" \
   "$(TJ_HOSTS=prod "$TJ" --preview alpha | has LOCALMARK)"
is "'local' as host previews locally" \
   "yes" \
   "$(TJ_HOSTS=prod "$TJ" --preview local alpha | has LOCALMARK)"
is "two arguments preview over ssh" \
   "yes" \
   "$(TJ_HOSTS=prod "$TJ" --preview prod api | has REMOTEMARK)"
is "the remote preview shows the remote pane, not the local one" \
   "no" \
   "$(TJ_HOSTS=prod "$TJ" --preview prod api | has LOCALMARK)"
is "a placeholder name previews nothing" \
   "" \
   "$(TJ_HOSTS=prod "$TJ" --preview gone -)"

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

: >"$TJ_SSH_LOG"
TJ_HOSTS=prod "$TJ" --kill gone -
is "killing a placeholder row opens no connection" \
   "0" \
   "$(wc -l <"$TJ_SSH_LOG" | tr -d ' ')"

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
# Without a real client there is nothing for detach-client to move, and every
# assertion below would pass against an empty client list. Fail loudly here
# instead of reporting three vacuous successes.
is "a client is attached before the transition" \
   "yes" \
   "$([[ -n $tty_before ]] && echo yes || echo no)"

srv "$LOCAL_SOCK" send-keys -t home \
  "TJ_HOSTS=prod TJ_TEST_SOCKET=$LOCAL_SOCK TJ_REAL_TMUX=$TJ_REAL_TMUX PATH=$ROOT/tests/fakebin:\$PATH TJ_FAKE_SSH_REMOTE_SOCKET=$REMOTE_SOCK $TJ prod:api" Enter
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

# T8 previews this session and greps for the marker, so restore it.
srv "$REMOTE_SOCK" -f /dev/null new-session -d -s api -c /tmp -x 120 -y 30
srv "$REMOTE_SOCK" send-keys -t api 'echo REMOTEMARK' Enter
sleep 1

echo "picker wiring"
srv "$REMOTE_SOCK" -f /dev/null new-session -d -s solo -c /tmp -x 120 -y 30
: >"$TJ_SSH_LOG"
# unset TMUX: this asserts the outside-tmux path, and inheriting a real $TMUX
# would silently exercise the detach-client branch instead.
( unset TMUX; TJ_HOSTS=prod "$TJ" prod:solo ) >/dev/null 2>&1
is "host:name asks ssh for that host and session" \
   "1" \
   "$(grep -c 'prod.*tmux attach -t solo' "$TJ_SSH_LOG")"

# Feed the picker's own placeholders back through the entrypoints, which is what
# fzf does with {2} and {3}.
line=$(TJ_HOSTS=prod "$TJ" --list | plain | awk '$2=="prod" && $3=="api"' | head -1)
is "remote-mode {2} {3} reach the remote pane" \
   "yes" \
   "$(TJ_HOSTS=prod "$TJ" --preview "$(awk '{print $2}' <<<"$line")" "$(awk '{print $3}' <<<"$line")" | has REMOTEMARK)"

line=$(TJ_HOSTS= "$TJ" --list | plain | awk '$2=="alpha"' | head -1)
is "local-mode {2} reaches the local pane" \
   "yes" \
   "$(TJ_HOSTS= "$TJ" --preview "$(awk '{print $2}' <<<"$line")" | has LOCALMARK)"

echo "picker wiring: live fzf"

# Everything above drives entrypoints directly (--preview, --kill, the
# host:name form); none of it presses a key inside the real fzf UI, so a
# hard-coded {2}/$2 in the fzf command strings or the final selection's
# `awk -v f="$NAMEF"` line would be invisible to the suite. Task 7 already
# left a real client attached to LOCAL_SOCK's "home" session (see tty_before
# above) -- reuse it instead of spawning a second `script` process.
is "a client is still attached before the live-picker test" \
   "1" \
   "$(srv "$LOCAL_SOCK" list-clients -F '#{client_session}' | grep -c '^home$')"

# detach-client -E (the enter_remote branch this exercises) and fzf's
# execute-silent(...) (the kill_target branch below) both run from the tmux
# SERVER's environment, not the shell that launched tj -- Task 7's comment
# above explains why PATH/TJ_REAL_TMUX/TJ_TEST_SOCKET/TJ_FAKE_SSH_REMOTE_SOCKET
# are seeded with set-environment -g; TJ_SSH_LOG needs the same treatment or
# the assertion below would read an empty file no matter what tj does.
srv "$LOCAL_SOCK" set-environment -g TJ_SSH_LOG "$TJ_SSH_LOG"

launch_picker() {
  srv "$LOCAL_SOCK" send-keys -t home \
    "TJ_HOSTS=prod TJ_TEST_SOCKET=$LOCAL_SOCK TJ_REAL_TMUX=$TJ_REAL_TMUX PATH=$ROOT/tests/fakebin:\$PATH TJ_FAKE_SSH_REMOTE_SOCKET=$REMOTE_SOCK TJ_SSH_LOG=$TJ_SSH_LOG $TJ" Enter
}

# fzf applies a query asynchronously: the keystrokes are in the pty long before
# the list has been re-filtered, so an enter or ctrl-x sent too early acts on
# the UNFILTERED selection -- the first row, not the one the query picks.
# Waiting for a row the query KEEPS proves nothing, because that row is already
# on screen before any filtering happens; both waits below are for things only
# the finished query can produce: the whole query echoed back in the prompt, and
# a row the query excludes gone from the list.
filtered() { # <typed query> <regex matching a row the query removes>
  wait_for_pane "$LOCAL_SOCK" home "session > $1" &&
    wait_for_pane "$LOCAL_SOCK" home "$2" absent
}

# `solo` (created above, in the "picker wiring" block) exists ONLY on the
# remote server. A stale index that reads the host column ("prod") instead of
# the name column ("solo") therefore cannot land on a session that happens to
# exist under that wrong name too -- it can only fail visibly.
: >"$TJ_SSH_LOG"
launch_picker
# Wait for the unfiltered list, not merely the prompt: `filtered` below decides
# it is done when a row has DISAPPEARED, and a row that was never drawn in the
# first place would satisfy that on the first poll.
is "the live picker has drawn its list before entering a remote row" \
   "yes" \
   "$(wait_for_pane "$LOCAL_SOCK" home 'local.*beta' && echo yes || echo no)"

# `'` forces an exact substring match in fzf so this can't fuzzy-match some
# other row by coincidence.
srv "$LOCAL_SOCK" send-keys -t home "'solo"
is "the 'solo query is applied before enter is sent" \
   "yes" \
   "$(filtered "'solo" 'local.*beta' && echo yes || echo no)"
srv "$LOCAL_SOCK" send-keys -t home Enter

# detach-client -E's command runs once tmux actually finishes detaching the
# client, which is not instantaneous -- wait for the ssh call to land instead
# of racing it.
wait_for_log "$TJ_SSH_LOG" 'tmux attach -t solo'
is "enter on a live remote row asks ssh for that row's host and session" \
   "1" \
   "$(grep -c 'prod.*tmux attach -t solo' "$TJ_SSH_LOG")"

# Killing the remote session is what sends the terminal home again -- the
# same transition Task 7 already proved for the direct two-arg form -- which
# gets a clean local client back for the kill test below.
srv "$REMOTE_SOCK" kill-session -t solo
is "the client returns home after a picker-driven remote enter" \
   "1" \
   "$(for _ in $(seq 1 20); do
        c=$(srv "$LOCAL_SOCK" list-clients -F '#{client_session}' | grep -c '^home$')
        [[ $c == 1 ]] && break
        sleep 0.2
      done; echo "$c")"

# `api` exists under both hosts already (the collision fixture from the
# preview tests above): a stale index that killed the wrong one would either
# leave the remote session alive or take out the local one, and this pair of
# assertions catches either.
launch_picker
is "the live picker has drawn its list before killing a remote row" \
   "yes" \
   "$(wait_for_pane "$LOCAL_SOCK" home 'local.*alpha' && echo yes || echo no)"

srv "$LOCAL_SOCK" send-keys -t home "'prod"
is "the 'prod query is applied before ctrl-x is sent" \
   "yes" \
   "$(filtered "'prod" 'local.*alpha' && echo yes || echo no)"
srv "$LOCAL_SOCK" send-keys -t home C-x
is "ctrl-x's kill and reload land" \
   "yes" \
   "$(wait_for_pane "$LOCAL_SOCK" home 'prod.*api' absent && echo yes || echo no)"
srv "$LOCAL_SOCK" send-keys -t home Escape

is "ctrl-x on a live remote row kills the remote session" \
   "0" \
   "$(srv "$REMOTE_SOCK" list-sessions -F '#{session_name}' 2>/dev/null | grep -c '^api$')"
is "ctrl-x on a live remote row leaves the same-named local session" \
   "1" \
   "$(srv "$LOCAL_SOCK" list-sessions -F '#{session_name}' 2>/dev/null | grep -c '^api$')"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
