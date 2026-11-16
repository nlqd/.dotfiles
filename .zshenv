# Read by every zsh, including scripts, hooks and cron. Exported environment
# only: keep it fast, silent and free of forks. Interactive settings live in
# .zshrc.aiws.
typeset -U path

# cargo first so the rustup toolchain overrides a system rustc.
path=(
  $HOME/.cargo/bin
  $HOME/.pub-cache/bin
  $HOME/flutter/bin
  $HOME/.foundry/bin
  $HOME/go/bin
  /usr/local/go/bin
  $HOME/.local/scripts
  $HOME/.local/bin/statusbar-lukesmithxyz
  $HOME/.local/bin
  $HOME/.asdf/shims
  # $HOME/Downloads/zips/platform-tools
  $path
)

export EDITOR=nvim
export DEV_HOME="$HOME/dev"
