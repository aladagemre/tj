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
