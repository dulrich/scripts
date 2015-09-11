#!/bin/bash

# git-aliases.sh: shorten common git tasks
# Copyright 2013 - 2015  David Ulrich
# 
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
# 
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
# 
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

alias s="git status"
a () {
	git add $(defarg "$*" '@' '.')
}
as () {
	git add $(defarg "$*" '@' '.')
	git status
}
b () {
	git checkout $(defarg "$*" 0 'master')
}
c () {
	git commit -m "$*"
}
alias d="git diff"
alias f="git fetch upstream"
gc () {
	local repo="$1"

	if [ ${repo: -4} != ".git" ]; then
		repo="$repo.git"
	fi

	git clone "git@github.com:/$repo"
}
alias gls="git log --stat"
alias glt="git ls-tree --abbrev HEAD"
alias gmv="git mv"
alias grm="git rm"
alias gss="git stash"
alias gsa="git stash apply"
alias gsl="git stash list"
alias gsp="git stash pop"
gx () {
	chmod 755 $1
	git update-index --chmod=+x $1
}
m () {
	git merge $(defarg "$*" 0 'master')
}
alias o="git checkout"
alias r="git reset HEAD"
alias rh="git reset --hard HEAD"
alias u="git pull"
um () {
	git pull
	git merge $(defarg "$*" 0 'master')
}
alias p="git push"
pp() {
	git push production $(defarg "$*" 0 'master')
}
up() {
	git pull production $(defarg "$*" 0 'master')
}

z () {
	git commit -m "$*"
	git push
}
zz () {
	git pull
	git commit -m "$*"
	git push
}

blameline () {
	local author blame line inv
	
	IFS=:
	inv=($1)
	unset IFS
	
	IFS=$'\n'
	blame=( $(git blame -pw -L${inv[1]},${inv[1]} ${inv[0]}) )
	unset IFS
	
	hash=${blame[0]:0:10}
	author=$(echo ${blame[1]} | cut -d" " -f2-)
	
	line="${blame[${#blame[@]} - 1]}"
	
	echo "$1 ($author $hash) $line"
}
blamepipe () {
	while read data; do
		blameline $data
	done
}

# grep and blame at the same time
gb () {
	local path=$(defarg "$*" 1 './')
	
	grep -Pn ${grep_options[@]} $1 $path | blamepipe
}

# http://stackoverflow.com/questions/342969/how-do-i-get-bash-completion-to-work-with-aliases
# git completion functions don't exist until this file is executed,
# which would normally be the first time a full git command is tab-completed
if [ -f /usr/share/bash-completion/completions/git ]; then
	source /usr/share/bash-completion/completions/git

	__git_complete a _git_add
	__git_complete as _git_add
	__git_complete b _git_checkout
	__git_complete d _git_diff
	__git_complete gmv _git_mv
	__git_complete grm _git_rm
	__git_complete gss _git_stash
	__git_complete m _git_merge
	__git_complete um _git_merge
	__git_complete o _git_checkout
	__git_complete p _git_push
	__git_complete r _git_reset
	__git_complete rh _git_reset
	__git_complete u _git_pull
fi
