#
# ~/.bashrc
#

# If not running interactively, don't do anything
[[ $- != *i* ]] && return

alias ls='ls --color=auto'
alias grep='grep --color=auto'
PS1='[\u@\h \W]\$ '

# Dotfiles repo (bare, work tree = $HOME)
alias config='git --git-dir=$HOME/.dotfiles.git --work-tree=$HOME'
