#!/bin/bash

# completions.sh: bash completion for the `util` router command.
# Level 1 completes the subcommand list, generated from util/*.sh (so new
# commands appear automatically). Deeper levels complete filenames.
#
# CC0: This work has been marked as dedicated to the public domain.
# https://creativecommons.org/publicdomain/zero/1.0/

# resolved once at source time; the function reuses it on every completion
_UTIL_DIR=$(dirname "$(realpath "${BASH_SOURCE[0]}")")

# shared with dispatch.sh's listing, resolved relative to this file's own
# directory so completion keeps working when aliases.sh sources it through
# a symlink.
# shellcheck source=util/lib.sh
source "$_UTIL_DIR/lib.sh"

_util_complete() {
	local cur
	local -a cmds=()
	cur=${COMP_WORDS[COMP_CWORD]}

	if [[ ${COMP_CWORD:-0} == 1 ]]; then
		mapfile -t cmds < <(_util_commands "$_UTIL_DIR")
		mapfile -t COMPREPLY < <(compgen -W "${cmds[*]}" -- "$cur")
	else
		# subcommand arguments are completed as filenames
		mapfile -t COMPREPLY < <(compgen -f -- "$cur")
	fi

	return 0
}

complete -o filenames -F _util_complete util
