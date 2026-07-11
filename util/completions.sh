#!/bin/bash

# completions.sh: bash completion for the `util` router command.
# Level 1 completes the subcommand list, generated from util/*.sh (so new
# commands appear automatically). Deeper levels complete filenames.
#
# CC0: This work has been marked as dedicated to the public domain.
# https://creativecommons.org/publicdomain/zero/1.0/

# resolved once at source time; the function reuses it on every completion
_UTIL_DIR=$( dirname $( realpath "${BASH_SOURCE[0]}" ) )
# optional private overlay (scripts-private symlinked in as ../private)
_UTIL_PRIV="$_UTIL_DIR/../private/util"

_util_complete() {
	local cur cmds f name
	cur=${COMP_WORDS[COMP_CWORD]}

	if [[ COMP_CWORD -eq 1 ]]; then
		cmds=""
		for f in "$_UTIL_DIR"/*.sh; do
			[ -e "$f" ] || continue
			name=$( basename "$f" .sh )
			case "$name" in
				dispatch|lib|completions) continue ;;
			esac
			cmds="$cmds $name"
		done
		# private overlay commands, if the overlay is present
		if [ -d "$_UTIL_PRIV" ]; then
			for f in "$_UTIL_PRIV"/*.sh; do
				[ -e "$f" ] || continue
				cmds="$cmds $( basename "$f" .sh )"
			done
		fi
		COMPREPLY=( $( compgen -W "${cmds}" -- "${cur}" ) )
	else
		# subcommand arguments are completed as filenames
		COMPREPLY=( $( compgen -f -- "${cur}" ) )
	fi

	return 0
}

complete -o filenames -F _util_complete util
