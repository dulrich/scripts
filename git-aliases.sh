#!/bin/bash

# git-aliases.sh: shorten common git tasks
# 2013 - 2024  David Ulrich
#
# CC0: This work has been marked as dedicated to the public domain. 
#
# You may have received a copy of the Creative Commons Public Domain dedication
# along with this program.  If not, see <https://creativecommons.org/publicdomain/zero/1.0/>.

# aliases.sh declares this shared search-option array before sourcing this file.
declare -a grep_options

alias s="git status -bs"
a () {
	if [ "$#" -gt 0 ]; then
		git add "$@"
	else
		git add .
	fi
}
ap () {
	if [ "$#" -gt 0 ]; then
		git add -p "$@"
	else
		git add -p .
	fi
}
b () {
	local bname
	bname=$(git branch | grep -oP "\b(main|master)\b")
	git checkout "${1:-$bname}"
}
bb () {
	local exists
	exists=$(git rev-parse --quiet --verify "$1")
	if [ "$exists" == '' ]; then
		git checkout -b "$1"
	fi
	git push origin "$1"
	git branch --set-upstream-to="origin/$1" "$1"
}
c () {
	git commit -m "$*"
}
alias d="git diff -D -M9 -b --ignore-space-at-eol --ignore-blank-lines"
alias ds="d --staged"
alias f="git fetch upstream"
gc () {
	local repo="$1"

	if [ "${repo: -4}" != ".git" ]; then
		repo="$repo.git"
	fi
	
	# maybe parse the ref to see if it's already a protocol and don't duplicate
	
	git clone "git@github.com:/$repo"
}
alias gls="git log --stat"
alias glt="git ls-tree --abbrev HEAD"
alias gmv="git mv"
alias grm="git rm"
alias grv="git remote -v"
alias gss="git stash"
alias gsa="git stash apply"
alias gsl="git stash list"
alias gsp="git stash pop"
gx () {
	chmod 755 "$1"
	git update-index --chmod=+x "$1"
}
m () {
	local bname
	bname=$(git branch | grep -oP "\b(main|master)\b")
	git merge --no-edit "${1:-$bname}"
}
alias o="git checkout"
alias p="git push"
alias r="git reset HEAD"
alias rh="git reset --hard HEAD"
alias u="git pull --no-edit"
um () {
	u "$@"
	m "$@"
}
ump () {
	u "$@"
	m "$@"
	p "$@"
}
pgl () {
	local branch
	branch=$(git rev-parse --abbrev-ref HEAD)
	git push gitlab "$branch:$1"
}

pp () {
	local bname
	bname=$(git branch | grep -oP "\b(main|master)\b")
	git push production "${1:-$bname}"
}
up () {
	local bname
	bname=$(git branch | grep -oP "\b(main|master)\b")
	git pull --no-edit production "${1:-$bname}"
}

pu () {
	local bname
	bname=$(git branch | grep -oP "\b(main|master)\b")
	git push ulrichdev "${1:-$bname}"
}
uu () {
	local bname
	bname=$(git branch | grep -oP "\b(main|master)\b")
	git pull --no-edit ulrichdev "${1:-$bname}"
}

z () {
	git commit -m "$*"
	git push
}
zz () {
	git pull --no-edit
	git commit -m "$*"
	git push
}


nopush() {
	git remote set-url --push "$1" no_push
}
pall() {
	local -a remotes=()
	local name push_url
	mapfile -t remotes < <(git remote)
	for name in "${remotes[@]}"
	do
		push_url=$(git remote get-url --push "$name")
		if [ "$push_url" != "no_push" ]; then
			echo "Pushing to remote $name..."
			git push "$name"
		fi
	done
}


blameline () {
	local author hash line
	local -a blame inv

	IFS=: read -r -a inv <<< "$1"
	mapfile -t blame < <(git blame -pw "-L${inv[1]},${inv[1]}" -- "${inv[0]}")

	hash=${blame[0]:0:10}
	author=${blame[1]#* }

	line="${blame[${#blame[@]} - 1]}"

	echo "$1 ($author $hash) $line"
}
blamepipe () {
	local data
	while read -r data; do
		blameline "$data"
	done
}

# grep and blame at the same time
gb () {
	local path
	path=$(defarg "$*" 1 './')

	grep -Pn "${grep_options[@]}" "$1" "$path" | blamepipe
}


# http://stackoverflow.com/questions/342969/how-do-i-get-bash-completion-to-work-with-aliases
# git completion functions don't exist until this file is executed,
# which would normally be the first time a full git command is tab-completed
if [ -f /usr/share/bash-completion/completions/git ]; then
	# System-provided Git completion is optional and external to this repository.
	# shellcheck source=/dev/null
	source /usr/share/bash-completion/completions/git

	# https://gist.github.com/mmrko/b3ec6da9bea172cdb6bd83bdf95ee817
	__git_checkout_local() {
		__gitcomp_nl "$(__git_heads '' "${track-}")"
	}

	__git_complete a _git_add
	__git_complete as _git_add
	__git_complete b __git_checkout_local
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
