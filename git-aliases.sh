#!/bin/bash

alias s="git status"
function a {
	git add $(defarg "$*" '@' '.')
}
function b {
	git checkout $(defarg "$*" 0 'master')
}
function c {
	git commit -m "$*"
}
alias d="git diff"
alias f="git fetch upstream"
alias gls="git log --stat"
alias glt="git ls-tree --abbrev HEAD"
function gx {
	chmod 755 $1
	git update-index --chmod=+x $1
}
function m {
	git merge $(defarg "$*" 0 'master')
}
alias r="git reset HEAD"
alias u="git pull"
alias p="git push"
alias pp="git push production master"
alias up="git pull;git push"
function z {
	git commit -m "$*"
	git push
}

# http://stackoverflow.com/questions/342969/how-do-i-get-bash-completion-to-work-with-aliases
# git completion functions don't exist until this file is executed,
# which would normally be the first time a full git command is tab-completed
if [ -f /usr/share/bash-completion/completions/git ]; then
	source /usr/share/bash-completion/completions/git

	__git_complete a _git_add
	__git_complete b _git_checkout
	__git_complete d _git_diff
	__git_complete m _git_merge
	__git_complete p _git_push
	__git_complete u _git_pull
fi