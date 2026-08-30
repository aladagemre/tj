# tj

**t**mux **j**ump — because you bind it to `prefix + j`.

An interactive tmux session picker, sorted by **most recently used** — not
alphabetically.

`tmux ls` + `tmux attach -t <name>` stops working once you keep more than a
dozen sessions around: the list is long, it is sorted by name, and the session
you actually want is almost always one of the last few you touched. `tj` puts
those on top, lets you fuzzy-filter them, and shows you each session's live
screen so you can recognise it without attaching.

```
session > api
  ● api-gateway      3m  2w  ~/code/api-gateway     │ api-gateway
  ○ dotfiles        11m  1w  ~/.dotfiles            │   0: nvim *  (nvim)
  · blog             1d  1w  ~/code/blog            │   1: server    (node)
  · infra         14 Jun  3w  ~/code/infra          │ ─────────────────────
                                                    │ $ npm run dev
                                                    │ ready on :3000
```

- `●` current session · `○` attached by another client · `·` detached
- then: how long ago you last attached, window count, session directory
- the right pane is a live capture of that session's active pane

## Install

Requires `tmux` and [`fzf`](https://github.com/junegunn/fzf).

```sh
git clone https://github.com/aladagemre/tj ~/.local/share/tj
ln -sf ~/.local/share/tj/tj ~/.local/bin/tj
```

Then bind it in `~/.tmux.conf` so it opens in a popup:

```tmux
bind j display-popup -E -w 80% -h 75% "$HOME/.local/bin/tj"
```

Reload with `tmux source-file ~/.tmux.conf`.

## Usage

```
tj              open the picker
tj <name>       jump straight to a session (fuzzy; creates it if there's no match)
tj --help       key reference
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

## How it works

Sessions are ordered by tmux's own `session_last_attached`, falling back to
`session_created` for sessions that have never been attached. Everything else is
`fzf`: the script re-invokes itself for `--list` (so `ctrl-x` can reload the list
after a kill) and for `--preview`.

It is one self-contained bash script with no dependencies beyond `tmux` and
`fzf`, and it works on both GNU and BSD/macOS userlands.

## Prior art

[`sesh`](https://github.com/joshmedeski/sesh) is the fuller-featured take on
this idea — it also starts sessions from directories, zoxide results and config
files. `tj` is deliberately smaller: one file, one job, no config.

## License

MIT
