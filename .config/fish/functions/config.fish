# Dotfiles repo: a bare git repo whose work tree is $HOME, so tracked configs
# live in place (no symlinks, nothing for an app to clobber on rewrite).
#   config status / add / commit / push   -- ordinary git, scoped to $HOME
# Untracked files are hidden (status.showUntrackedFiles=no); add files on purpose.
function config --description 'git for the ~/.dotfiles.git config repo'
    git --git-dir=$HOME/.dotfiles.git --work-tree=$HOME $argv
end
