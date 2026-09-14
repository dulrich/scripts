#!/bin/bash
set -euo pipefail

# link.sh: create the standard dotfile symlinks into $HOME.
#
# CC0: This work has been marked as dedicated to the public domain.
# https://creativecommons.org/publicdomain/zero/1.0/

here=$(dirname "$(realpath "${BASH_SOURCE[0]}")")

# aliases load on every shell (~/.bash_aliases is sourced by ~/.bashrc)
rm -f "$HOME/.bash_aliases"
ln -s "$here/aliases.sh" "$HOME/.bash_aliases"

# X resources (terminal colors / theme); merged via the `xres` alias
rm -f "$HOME/.Xresources"
ln -s "$here/Xresources" "$HOME/.Xresources"

# ghostty terminal config (canonical name is `config`, not `config.ghostty`)
mkdir -p "$HOME/.config/ghostty"
ln -sfn "$here/ghostty/config" "$HOME/.config/ghostty/config"

# zellij multiplexer config
mkdir -p "$HOME/.config/zellij"
ln -sfn "$here/zellij/config.kdl" "$HOME/.config/zellij/config.kdl"
