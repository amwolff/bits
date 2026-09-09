# shellcheck shell=sh
# Sourced by bash and zsh, so keep it POSIX-ish. Add to it and re-run setup.sh.

# Listing
alias l='ls -CF'
alias la='ls -A'
alias ll='ls -alF'

# Git
alias g='git'
alias gd='git diff'
alias gl='git log --oneline --graph --decorate'
alias gs='git status --short --branch'

# Environment
export EDITOR="${EDITOR:-vi}"
export HISTCONTROL=ignoreboth
export HISTFILESIZE=200000
export HISTSIZE=100000
