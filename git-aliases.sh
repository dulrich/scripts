#!/bin/bash

# git-aliases.sh: shorten common git tasks
# Copyright 2013 - 2015 David Ulrich
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
b () {
	git checkout $(defarg "$*" 0 'master')
}
c () {
	git commit -m "$*"
}
alias d="git diff"
alias f="git fetch upstream"
alias gls="git log --stat"
alias glt="git ls-tree --abbrev HEAD"
gx () {
	chmod 755 $1
	git update-index --chmod=+x $1
}
m () {
	git merge $(defarg "$*" 0 'master')
}
alias r="git reset HEAD"
alias u="git pull"
alias p="git push"
alias pp="git push production master"
alias up="git pull;git push"
z () {
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
