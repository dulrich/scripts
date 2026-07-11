#!/bin/bash

# lib.sh: shared helpers for util/ subcommands.
# Subcommands run as separate processes (exec'd by dispatch.sh), so they do not
# inherit the functions defined in aliases.sh. Source this to reuse them.
#
# CC0: This work has been marked as dedicated to the public domain.
# https://creativecommons.org/publicdomain/zero/1.0/

# defarg: return positional arg $which from the string $1, or $def if absent.
# `defarg "$*" 0 './'` -> first word, defaulting to ./
defarg () {
	local all=0
	local args=($1)
	local which=$2
	local def=$3

	if [ "$which" == '@' ]; then
		all=1
		which=0
	fi

	if [ ${#args[@]} -gt $which ]; then
		if [ $all -eq 1 ]; then echo "${args[@]}"
		else echo "${args[$which]}"; fi
	else
		echo $def
	fi
}
