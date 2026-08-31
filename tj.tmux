#!/usr/bin/env bash
# TPM entry point: binds the picker to prefix + j (configurable).
#
#   set -g @plugin 'aladagemre/tj'
#   set -g @tj-key 'j'      # default
#   set -g @tj-width '80%'  # default
#   set -g @tj-height '75%' # default

set -u

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

opt() {
  local value
  value="$(tmux show-option -gqv "$1")"
  [ -n "$value" ] && printf '%s' "$value" || printf '%s' "$2"
}

key="$(opt '@tj-key' 'j')"
width="$(opt '@tj-width' '80%')"
height="$(opt '@tj-height' '75%')"

tmux bind-key "$key" display-popup -E -w "$width" -h "$height" "$CURRENT_DIR/tj"
