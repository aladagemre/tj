# Packaging

## Homebrew

The tap lives in [aladagemre/homebrew-tj](https://github.com/aladagemre/homebrew-tj).
On a new release, bump `url` and `sha256` in `Formula/tj.rb` there.

## AUR

`PKGBUILD` in this directory is ready to publish as `tj-tmux`. It is not on the
AUR yet — publishing needs an AUR account and an SSH key registered with it:

```sh
# one-time: add your SSH key at https://aur.archlinux.org/account
git clone ssh://aur@aur.archlinux.org/tj-tmux.git aur-tj
cp packaging/PKGBUILD aur-tj/
cd aur-tj
# fill in the Maintainer line first
makepkg --printsrcinfo > .SRCINFO
git add PKGBUILD .SRCINFO
git commit -m "Initial import: tj-tmux 0.1.0"
git push
```

The `sha256sums` entry matches the v0.1.0 source tarball; regenerate it with
`makepkg -g` after each release.
