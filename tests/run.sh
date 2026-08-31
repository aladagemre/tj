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

# fzf strips ANSI before expanding {n} and before printing the selected line, so
# every field index in tj is an index into the *stripped* row. Raw output splits
# differently: `%6s` right-pads the age, so its colour escape lands in a field of
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
( unset TMUX; TJ_HOSTS=prod "$TJ" prod 'a;touch /tmp/tj-injected' ) >/dev/null 2>&1
is "a metacharacter in a session name cannot become a second remote command" \
   "no" \
   "$([[ -e /tmp/tj-injected ]] && echo yes || echo no)"
rm -f /tmp/tj-injected

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

# T8 previews this session and greps for the marker, so restore it.
srv "$REMOTE_SOCK" -f /dev/null new-session -d -s api -c /tmp -x 120 -y 30
srv "$REMOTE_SOCK" send-keys -t api 'echo REMOTEMARK' Enter
sleep 1

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
